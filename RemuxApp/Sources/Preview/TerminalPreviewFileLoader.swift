import Foundation

enum TerminalPreviewFileError: LocalizedError, Equatable, Sendable {
    case tooLarge(maximumByteCount: UInt64)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge(let maximumByteCount):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(maximumByteCount),
                countStyle: .file
            )
            return "This file is larger than the \(size) preview limit."
        case .unsupported:
            return "This file type cannot be previewed."
        }
    }
}

/// Reads a remote file in order, failing with `TerminalPreviewFileError.tooLarge` past `maximumByteCount`.
///
/// When the server gives the file's size, reads go out `readWindow` at a time at explicit offsets, and their data is
/// handed on in order. The window's last read asks at the known size: it finds the end, or, when the file grew, data
/// to read on from without another round trip. Otherwise, and after a short read, the file is read one read at a
/// time to its end.
enum TerminalPreviewRemoteFileReader {
    typealias MetadataHandler = @Sendable (RemuxSFTPFileMetadata) async throws -> Void
    typealias ChunkHandler = @Sendable (Data) async throws -> Void

    /// Reads outstanding at once. Measured on far and cellular links, more gained nothing.
    static let readWindow = 8
    /// The most OpenSSH's SFTP server returns for one read.
    static let readLength = 255 * 1024

    static func stream<Client: RemuxSFTPReadOnlyClient>(
        client: Client,
        remotePath: String,
        maximumByteCount: UInt64,
        knownMetadata: RemuxSFTPFileMetadata? = nil,
        onMetadata: @escaping MetadataHandler = { _ in },
        onChunk: @escaping ChunkHandler
    ) async throws -> RemuxSFTPFileMetadata {
        try await client.withFile(atPath: remotePath, knownMetadata: knownMetadata) { remoteFile, metadata in
            if let size = metadata.size, size > maximumByteCount {
                throw TerminalPreviewFileError.tooLarge(
                    maximumByteCount: maximumByteCount
                )
            }
            try await onMetadata(metadata)

            var offset: UInt64 = 0
            if let size = metadata.size {
                guard let next = try await readWindowed(
                    remoteFile,
                    size: size,
                    maximumByteCount: maximumByteCount,
                    onChunk: onChunk
                ) else {
                    return metadata
                }
                offset = next
            }
            try await readSequentially(
                remoteFile,
                from: offset,
                maximumByteCount: maximumByteCount,
                onChunk: onChunk
            )
            return metadata
        }
    }

    /// Reads a file of known size; returns the offset to read on from one read at a time, or nil when the file
    /// ended at that size.
    private static func readWindowed(
        _ remoteFile: RemuxSFTPReadableFile,
        size: UInt64,
        maximumByteCount: UInt64,
        onChunk: ChunkHandler
    ) async throws -> UInt64? {
        let chunkLength = UInt64(readLength)
        var reads = stride(from: UInt64(0), to: size, by: Int(chunkLength)).map { offset in
            (offset: offset, length: Int(min(chunkLength, size - offset)))
        }
        reads.append((
            offset: size,
            length: sequentialReadLength(at: size, maximumByteCount: maximumByteCount)
        ))

        return try await withThrowingTaskGroup(of: (index: Int, data: Data).self) { group in
            var issued = 0
            var arrived: [Int: Data] = [:]
            for (index, read) in reads.enumerated() {
                while issued < reads.count, issued - index < readWindow {
                    let issuedIndex = issued
                    let issuedRead = reads[issuedIndex]
                    group.addTask {
                        let data = try await remoteFile.readChunk(from: issuedRead.offset, length: issuedRead.length)
                        return (index: issuedIndex, data: data)
                    }
                    issued += 1
                }
                while arrived[index] == nil, let result = try await group.next() {
                    arrived[result.index] = result.data
                }
                guard let data = arrived.removeValue(forKey: index) else {
                    preconditionFailure("read \(index) was issued and not delivered")
                }

                if read.offset == size {
                    guard !data.isEmpty else { return nil }
                    // The file grew since its size was read.
                    guard UInt64(data.count) <= maximumByteCount - size else {
                        throw TerminalPreviewFileError.tooLarge(
                            maximumByteCount: maximumByteCount
                        )
                    }
                    try await onChunk(data)
                    return size + UInt64(data.count)
                }
                if !data.isEmpty {
                    try await onChunk(data)
                }
                if data.count < read.length {
                    // The server caps reads below `readLength`, or the file shrank: the rest is read in order.
                    group.cancelAll()
                    return read.offset + UInt64(data.count)
                }
            }
            preconditionFailure("the read at the known size ends the window")
        }
    }

    private static func readSequentially(
        _ remoteFile: RemuxSFTPReadableFile,
        from start: UInt64,
        maximumByteCount: UInt64,
        onChunk: ChunkHandler
    ) async throws {
        var offset = start
        while true {
            try Task.checkCancellation()
            let remaining = maximumByteCount - min(offset, maximumByteCount)
            let data = try await remoteFile.readChunk(
                from: offset,
                length: sequentialReadLength(at: offset, maximumByteCount: maximumByteCount)
            )
            guard !data.isEmpty else { break }
            guard UInt64(data.count) <= remaining else {
                throw TerminalPreviewFileError.tooLarge(
                    maximumByteCount: maximumByteCount
                )
            }
            try await onChunk(data)
            offset += UInt64(data.count)
        }
    }

    /// One byte past the maximum at most, which is how a file over it shows.
    private static func sequentialReadLength(at offset: UInt64, maximumByteCount: UInt64) -> Int {
        let remaining = maximumByteCount - min(offset, maximumByteCount)
        return Int(min(UInt64(RemuxSFTPReadableFile.maximumChunkLength), remaining + 1))
    }
}

final class TerminalPreviewFileResource: @unchecked Sendable, Equatable {
    let url: URL
    private let directoryURL: URL

    init(url: URL, directoryURL: URL) {
        self.url = url
        self.directoryURL = directoryURL
    }

    static func == (lhs: TerminalPreviewFileResource, rhs: TerminalPreviewFileResource) -> Bool {
        lhs === rhs
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directoryURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            NSLog(
                "Remux preview temp cleanup failed for %@: %@",
                directoryURL.path,
                String(describing: error)
            )
        }
    }
}

struct TerminalPreviewFileLoader<Provider>: Sendable
where Provider: RemuxSFTPClientProvider,
      Provider.Client: RemuxSFTPReadOnlyClient {
    static var defaultMaximumByteCount: UInt64 { 64 * 1024 * 1024 }

    let provider: Provider
    let temporaryDirectory: URL
    let maximumByteCount: UInt64

    init(
        provider: Provider,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        maximumByteCount: UInt64 = Self.defaultMaximumByteCount
    ) {
        precondition(maximumByteCount > 0 && maximumByteCount < UInt64.max)
        self.provider = provider
        self.temporaryDirectory = temporaryDirectory
        self.maximumByteCount = maximumByteCount
    }

    func load(remotePath: String) async throws -> TerminalPreviewFileResource {
        try await provider.withClient { client in
            let fileManager = FileManager.default
            let directoryURL = temporaryDirectory.appendingPathComponent(
                "RemuxPreview-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false
                )
                let fileURL = directoryURL.appendingPathComponent(
                    Self.localFilename(for: remotePath),
                    isDirectory: false
                )
                let probePlainText = fileURL.pathExtension.isEmpty
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }

                let handle = try FileHandle(forWritingTo: fileURL)
                let plainTextProbe: ExtensionlessPlainTextProbe?
                do {
                    let probe = LockedPlainTextProbe(enabled: probePlainText)
                    _ = try await TerminalPreviewRemoteFileReader.stream(
                        client: client,
                        remotePath: remotePath,
                        maximumByteCount: maximumByteCount
                    ) { data in
                        probe.consume(data)
                        try handle.write(contentsOf: data)
                    }
                    plainTextProbe = probe.value
                    try handle.close()
                } catch {
                    do {
                        try handle.close()
                    } catch {
                        NSLog(
                            "Remux preview partial file close failed: %@",
                            String(describing: error)
                        )
                    }
                    throw error
                }

                let previewURL: URL
                if plainTextProbe?.isPlainText == true {
                    previewURL = fileURL.appendingPathExtension("txt")
                    try fileManager.moveItem(at: fileURL, to: previewURL)
                } else {
                    previewURL = fileURL
                }

                return TerminalPreviewFileResource(
                    url: previewURL,
                    directoryURL: directoryURL
                )
            } catch {
                do {
                    try fileManager.removeItem(at: directoryURL)
                } catch let cleanupError as CocoaError
                    where cleanupError.code == .fileNoSuchFile {
                } catch {
                    NSLog(
                        "Remux preview failed-open cleanup failed for %@: %@",
                        directoryURL.path,
                        String(describing: error)
                    )
                }
                throw error
            }
        }
    }

    private static func localFilename(for remotePath: String) -> String {
        let component = URL(fileURLWithPath: remotePath).lastPathComponent
        guard !component.isEmpty, component != ".", component != ".." else {
            return "Preview"
        }
        return component
    }
}

private final class LockedPlainTextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probe: ExtensionlessPlainTextProbe?

    init(enabled: Bool) {
        self.probe = enabled ? ExtensionlessPlainTextProbe() : nil
    }

    func consume(_ data: Data) {
        lock.withLock { probe?.consume(data) }
    }

    var value: ExtensionlessPlainTextProbe? {
        lock.withLock { probe }
    }
}

private struct ExtensionlessPlainTextProbe: Sendable {
    private var continuationByteCount = 0
    private var nextContinuationRange: ClosedRange<UInt8> = 0x80...0xBF
    private var valid = true

    var isPlainText: Bool {
        valid && continuationByteCount == 0
    }

    mutating func consume(_ data: Data) {
        guard valid else { return }

        for byte in data {
            if continuationByteCount > 0 {
                guard nextContinuationRange.contains(byte) else {
                    valid = false
                    return
                }
                continuationByteCount -= 1
                nextContinuationRange = 0x80...0xBF
                continue
            }

            switch byte {
            case 0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F:
                valid = false
                return
            case 0x00...0x7F:
                continue
            case 0xC2...0xDF:
                beginSequence(continuationBytes: 1)
            case 0xE0:
                beginSequence(continuationBytes: 2, firstByteRange: 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF:
                beginSequence(continuationBytes: 2)
            case 0xED:
                beginSequence(continuationBytes: 2, firstByteRange: 0x80...0x9F)
            case 0xF0:
                beginSequence(continuationBytes: 3, firstByteRange: 0x90...0xBF)
            case 0xF1...0xF3:
                beginSequence(continuationBytes: 3)
            case 0xF4:
                beginSequence(continuationBytes: 3, firstByteRange: 0x80...0x8F)
            default:
                valid = false
                return
            }
        }
    }

    private mutating func beginSequence(
        continuationBytes: Int,
        firstByteRange: ClosedRange<UInt8> = 0x80...0xBF
    ) {
        continuationByteCount = continuationBytes
        nextContinuationRange = firstByteRange
    }
}

struct TerminalPreviewFileClient: Sendable {
    private let loadHandler: @Sendable (String) async throws -> TerminalPreviewFileResource

    init(
        load: @escaping @Sendable (String) async throws -> TerminalPreviewFileResource
    ) {
        self.loadHandler = load
    }

    init<Provider>(provider: Provider) where Provider: RemuxSFTPClientProvider,
            Provider.Client: RemuxSFTPReadOnlyClient {
        let loader = TerminalPreviewFileLoader(provider: provider)
        self.init { remotePath in
            try await loader.load(remotePath: remotePath)
        }
    }

    func load(remotePath: String) async throws -> TerminalPreviewFileResource {
        try await loadHandler(remotePath)
    }
}
