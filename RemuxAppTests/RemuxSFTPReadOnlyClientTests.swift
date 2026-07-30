import Foundation
import NIO
import XCTest

@testable import Remux

final class RemuxSFTPReadOnlyClientTests: XCTestCase {
    func testDirectoryListingFlattensResponsesDropsDotEntriesAndClassifiesModes() async throws {
        // Catches returning Citadel response batches without flattening, hiding dotfiles,
        // or comparing full permission values instead of the POSIX file-type bits.
        let connection = FakeCitadelSFTPConnection(
            directoryResponses: [
                ".": [
                    RemuxCitadelSFTPDirectoryResponse(
                        components: [
                            component(".", permissions: 0o040755),
                            component("folder", permissions: 0o040750),
                            component(".env", permissions: 0o100600),
                        ]
                    ),
                    RemuxCitadelSFTPDirectoryResponse(
                        components: [
                            component("..", permissions: 0o040755),
                            component("link", permissions: 0o120777),
                            component("socket", permissions: 0o140600),
                        ]
                    ),
                ],
            ]
        )
        let client = makeClient(connection: connection)

        let entries = try await client.listDirectory(atPath: ".")

        XCTAssertEqual(entries.map(\.name), ["folder", ".env", "link", "socket"])
        XCTAssertEqual(entries.first(named: "folder")?.metadata.type, .directory)
        XCTAssertEqual(entries.first(named: ".env")?.metadata.type, .regular)
        XCTAssertEqual(entries.first(named: "link")?.metadata.type, .symbolicLink)
        XCTAssertEqual(entries.first(named: "socket")?.metadata.type, .other)
    }

    func testLinkMetadataListsParentAndMatchesBasenameWithoutFollowingLink() async throws {
        // Catches implementing link metadata with stat/getAttributes, which follows links,
        // or listing the link path itself instead of its parent.
        let expectedDate = Date(timeIntervalSince1970: 1_721_234_567)
        let connection = FakeCitadelSFTPConnection(
            directoryResponses: [
                "/home/demo": [
                    RemuxCitadelSFTPDirectoryResponse(
                        components: [
                            component(
                                "link",
                                size: 12,
                                permissions: 0o120777,
                                modificationDate: expectedDate
                            ),
                        ]
                    ),
                ],
            ]
        )
        let client = makeClient(connection: connection)

        let metadata = try await client.linkMetadata(atPath: "/home/demo/link")

        XCTAssertEqual(
            metadata,
            RemuxSFTPFileMetadata(
                size: 12,
                permissions: 0o120777,
                modificationDate: expectedDate,
                type: .symbolicLink
            )
        )
        let listedPaths = await connection.listedPaths()
        let attributePaths = await connection.attributePaths()
        XCTAssertEqual(listedPaths, ["/home/demo"])
        XCTAssertEqual(attributePaths, [])
    }

    func testLinkMetadataThrowsTypedMissingFileWhenBasenameIsAbsent() async throws {
        // Catches treating a missing directory entry as default metadata or an empty result.
        let connection = FakeCitadelSFTPConnection(
            directoryResponses: [
                "/home/demo": [
                    RemuxCitadelSFTPDirectoryResponse(
                        components: [component("other", permissions: 0o100600)]
                    ),
                ],
            ]
        )
        let client = makeClient(connection: connection)

        do {
            _ = try await client.linkMetadata(atPath: "/home/demo/missing")
            XCTFail("missing basename should throw")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .noSuchFile("/home/demo/missing"))
        }
    }

    func testListDirectoryPropagatesTypedMissingPath() async throws {
        // Catches swallowing a missing remote directory and returning an empty listing.
        let connection = FakeCitadelSFTPConnection(
            directoryFailures: ["/missing": .noSuchFile("/missing")]
        )
        let client = makeClient(connection: connection)

        do {
            _ = try await client.listDirectory(atPath: "/missing")
            XCTFail("missing directory should throw")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .noSuchFile("/missing"))
        }
    }

    func testListDirectoryTimesOutThroughCitadelOperationBoundary() async throws {
        // Catches bypassing the concrete client's operation timeout for directory reads.
        let connection = FakeCitadelSFTPConnection(
            directoryDelay: Duration.seconds(30)
        )
        let client = makeClient(
            connection: connection,
            operationTimeout: .milliseconds(20)
        )

        do {
            _ = try await client.listDirectory(atPath: ".")
            XCTFail("stalled listing should time out")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        }
    }

    func testDownloadUsesBoundedMonotonicReadsReportsProgressAndWritesBytes() async throws {
        // Catches unbounded reads, repeated offsets, non-cumulative progress, or dropping
        // a final short chunk.
        let firstChunk = Data(repeating: 1, count: RemuxSFTPReadableFile.maximumChunkLength)
        let finalChunk = Data([2])
        let source = RecordingDownloadSource(chunks: [firstChunk, finalChunk, Data()])
        let progress = Int64Recorder()
        let client = makeClient(
            connection: FakeCitadelSFTPConnection(readableFile: source)
        )
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination) }

        try await client.downloadFile(atPath: "/large", to: destination) { value in
            await progress.append(value)
        }

        let requests = await source.requests()
        let progressValues = await progress.values()
        XCTAssertEqual(
            requests,
            [
                .init(offset: 0, length: RemuxSFTPReadableFile.maximumChunkLength),
                .init(
                    offset: UInt64(RemuxSFTPReadableFile.maximumChunkLength),
                    length: RemuxSFTPReadableFile.maximumChunkLength
                ),
                .init(
                    offset: UInt64(RemuxSFTPReadableFile.maximumChunkLength + 1),
                    length: RemuxSFTPReadableFile.maximumChunkLength
                ),
            ]
        )
        XCTAssertEqual(
            progressValues,
            [
                Int64(RemuxSFTPReadableFile.maximumChunkLength),
                Int64(RemuxSFTPReadableFile.maximumChunkLength + 1),
            ]
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            firstChunk + finalChunk
        )
        let closeCount = await source.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testDownloadPropagatesTimeoutAndRemovesPartialFile() async throws {
        // Catches retaining a corrupt partial file or translating away the remote timeout.
        let source = TimeoutDownloadSource()
        let client = makeClient(
            connection: FakeCitadelSFTPConnection(readableFile: source)
        )
        let destination = temporaryURL()

        do {
            try await client.downloadFile(atPath: "/stalls", to: destination) { _ in }
            XCTFail("remote timeout should throw")
        } catch let error as RemuxSFTPClientError {
            XCTAssertEqual(error, .operationTimedOut)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let closeCount = await source.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testDownloadCancellationRemovesPartialFile() async throws {
        // Catches checking cancellation only before the first remote read or leaving the
        // already-written prefix behind when a later read is cancelled.
        let source = CancellableDownloadSource()
        let client = makeClient(
            connection: FakeCitadelSFTPConnection(readableFile: source)
        )
        let destination = temporaryURL()
        let task = Task {
            try await client.downloadFile(atPath: "/cancel", to: destination) { _ in }
        }

        for _ in 0..<1_000 {
            if await source.readCount() == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let readCount = await source.readCount()
        XCTAssertEqual(readCount, 2)
        task.cancel()

        do {
            try await task.value
            XCTFail("cancelled download should throw")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let closeCount = await source.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    private func makeClient(
        connection: FakeCitadelSFTPConnection,
        operationTimeout: TimeAmount = .seconds(1)
    ) -> RemuxCitadelSFTPClient {
        RemuxCitadelSFTPClient(
            connection: connection,
            chunkSize: 4 * 1024 * 1024,
            operationTimeout: operationTimeout,
            leaseState: RemuxSFTPLeaseTeardown(closeBorrowedChild: {})
        )
    }

    private func component(
        _ filename: String,
        size: UInt64? = nil,
        permissions: UInt32?,
        modificationDate: Date? = nil
    ) -> RemuxCitadelSFTPDirectoryComponent {
        RemuxCitadelSFTPDirectoryComponent(
            filename: filename,
            attributes: RemuxCitadelSFTPAttributes(
                size: size,
                permissions: permissions,
                modificationDate: modificationDate
            )
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }
}

private extension Array where Element == RemuxSFTPDirectoryEntry {
    func first(named name: String) -> RemuxSFTPDirectoryEntry? {
        first { $0.name == name }
    }
}

private struct DownloadReadRequest: Equatable, Sendable {
    let offset: UInt64
    let length: Int
}

private actor RecordingDownloadSource: RemuxCitadelSFTPFile {
    private var chunks: [Data]
    private var recordedRequests: [DownloadReadRequest] = []
    private var recordedCloseCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func readData(from offset: UInt64, length: UInt32) -> Data {
        recordedRequests.append(.init(offset: offset, length: Int(length)))
        return chunks.removeFirst()
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) throws {
        throw FakeCitadelSFTPConnectionError.unexpectedFileWrite
    }

    func close() {
        recordedCloseCount += 1
    }

    func requests() -> [DownloadReadRequest] {
        recordedRequests
    }

    func closeCount() -> Int {
        recordedCloseCount
    }
}

private actor TimeoutDownloadSource: RemuxCitadelSFTPFile {
    private var count = 0
    private var recordedCloseCount = 0

    func readData(from offset: UInt64, length: UInt32) throws -> Data {
        count += 1
        if count == 1 {
            return Data([1])
        }
        throw RemuxSFTPClientError.operationTimedOut
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) throws {
        throw FakeCitadelSFTPConnectionError.unexpectedFileWrite
    }

    func close() {
        recordedCloseCount += 1
    }

    func closeCount() -> Int {
        recordedCloseCount
    }
}

private actor CancellableDownloadSource: RemuxCitadelSFTPFile {
    private var count = 0
    private var recordedCloseCount = 0

    func readData(from offset: UInt64, length: UInt32) async throws -> Data {
        count += 1
        if count == 1 {
            return Data([1])
        }
        try await Task.sleep(for: .seconds(30))
        return Data()
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) throws {
        throw FakeCitadelSFTPConnectionError.unexpectedFileWrite
    }

    func close() {
        recordedCloseCount += 1
    }

    func readCount() -> Int {
        count
    }

    func closeCount() -> Int {
        recordedCloseCount
    }
}

private actor Int64Recorder {
    private var recordedValues: [Int64] = []

    func append(_ value: Int64) {
        recordedValues.append(value)
    }

    func values() -> [Int64] {
        recordedValues
    }
}

private actor FakeCitadelSFTPConnection: RemuxCitadelSFTPConnection {
    private let directoryResponses: [String: [RemuxCitadelSFTPDirectoryResponse]]
    private let directoryFailures: [String: RemuxSFTPClientError]
    private let directoryDelay: Duration?
    private let readableFile: (any RemuxCitadelSFTPFile)?
    private var recordedListedPaths: [String] = []
    private var recordedAttributePaths: [String] = []

    init(
        directoryResponses: [String: [RemuxCitadelSFTPDirectoryResponse]] = [:],
        directoryFailures: [String: RemuxSFTPClientError] = [:],
        directoryDelay: Duration? = nil,
        readableFile: (any RemuxCitadelSFTPFile)? = nil
    ) {
        self.directoryResponses = directoryResponses
        self.directoryFailures = directoryFailures
        self.directoryDelay = directoryDelay
        self.readableFile = readableFile
    }

    func remuxRealPath(atPath path: String) -> String {
        path
    }

    func remuxListDirectory(
        atPath path: String
    ) async throws -> [RemuxCitadelSFTPDirectoryResponse] {
        recordedListedPaths.append(path)
        if let directoryDelay {
            try await Task.sleep(for: directoryDelay)
        }
        if let failure = directoryFailures[path] {
            throw failure
        }
        return directoryResponses[path] ?? []
    }

    func remuxGetAttributes(atPath path: String) -> RemuxCitadelSFTPAttributes {
        recordedAttributePaths.append(path)
        return RemuxCitadelSFTPAttributes(
            size: nil,
            permissions: nil,
            modificationDate: nil
        )
    }

    func remuxOpenFileForReading(
        atPath path: String
    ) async throws -> any RemuxCitadelSFTPFile {
        guard let readableFile else {
            throw FakeCitadelSFTPConnectionError.unexpectedFileOpen
        }
        return readableFile
    }

    func remuxOpenFileForWriting(
        atPath path: String
    ) async throws -> any RemuxCitadelSFTPFile {
        throw FakeCitadelSFTPConnectionError.unexpectedFileOpen
    }

    func remuxCreateDirectory(atPath path: String) {}
    func remuxRename(from sourcePath: String, to destinationPath: String) {}
    func remuxRemove(atPath path: String) {}

    func listedPaths() -> [String] {
        recordedListedPaths
    }

    func attributePaths() -> [String] {
        recordedAttributePaths
    }
}

private enum FakeCitadelSFTPConnectionError: Error {
    case unexpectedFileOpen
    case unexpectedFileWrite
}
