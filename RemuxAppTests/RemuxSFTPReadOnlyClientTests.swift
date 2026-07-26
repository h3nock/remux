@preconcurrency import Citadel
import Foundation
import NIO
import XCTest

@testable import Remux

final class RemuxSFTPReadOnlyClientTests: XCTestCase {
    func testWritableSFTPIntegrationRootRejectsUnsafePaths() {
        XCTAssertNil(WritableSFTPIntegrationRoot(""))
        XCTAssertNil(WritableSFTPIntegrationRoot("/"))
        XCTAssertNil(WritableSFTPIntegrationRoot("."))
        XCTAssertNil(WritableSFTPIntegrationRoot("/one"))
        XCTAssertNil(WritableSFTPIntegrationRoot("/one/../two"))
        XCTAssertNil(WritableSFTPIntegrationRoot("one/../../two"))
    }

    func testWritableSFTPIntegrationRootAcceptsDedicatedNestedDirectory() {
        XCTAssertEqual(
            WritableSFTPIntegrationRoot("/srv/remux-writable-tests")?.path,
            "/srv/remux-writable-tests"
        )
    }

    func testWritableSFTPIntegrationMutationsStayInDedicatedRoot() async throws {
        guard ProcessInfo.processInfo.environment[
            "REMUX_WRITABLE_SFTP_INTEGRATION"
        ] == "1" else {
            throw XCTSkip("Set REMUX_WRITABLE_SFTP_INTEGRATION=1 for disposable-host tests")
        }

        guard let root = WritableSFTPIntegrationRoot(
            ProcessInfo.processInfo.environment["REMUX_WRITABLE_SFTP_TEST_ROOT"]
        ) else {
            throw XCTSkip(
                "Set REMUX_WRITABLE_SFTP_TEST_ROOT to an empty dedicated remote directory"
            )
        }

        let dependencies = try RemuxAppDependencies.live()
        let snapshot = try await dependencies.profileRepository.loadSnapshot()
        guard let (server, _) = snapshot.latestProfile else {
            throw XCTSkip("Configure the disposable host as Remux's latest saved profile")
        }
        let authentication = try await SSHAuthResolver(
            credentialStore: dependencies.credentialStore
        ).resolve(server: server, in: snapshot)
        let provider = FileProviderCitadelSFTPClientProvider(
            sshRootService: RemuxSSHRootService(),
            trustedHosts: dependencies.trustedHostStore
        )
        let oldContents = Data("old destination".utf8)
        let newContents = Data("replacement destination".utf8)
        let source = try temporaryFile(contents: oldContents)
        let replacement = try temporaryFile(contents: newContents)
        let largeSource = try temporaryFile(
            contents: Data(repeating: 0xA5, count: 16 * 1024 * 1024)
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: largeSource)
        }

        try await provider.withClient(server: server, authentication: authentication) { client in
            let canonicalRoot = try await client.realPath(atPath: root.path)
            guard canonicalRoot == root.path else {
                XCTFail("The supplied integration root must already be canonical")
                throw WritableSFTPIntegrationError.nonCanonicalRoot
            }
            let initialRootEntries = try await client.listDirectory(atPath: root.path)
            guard initialRootEntries.isEmpty else {
                XCTFail("The supplied integration root must be empty before mutation tests begin")
                throw WritableSFTPIntegrationError.nonEmptyRoot
            }

            let paths = WritableSFTPIntegrationPaths(root: root)

            do {
                try await client.createDirectory(atPath: paths.createdDirectory)
                try await client.uploadFile(
                    from: source,
                    to: paths.uploadedFile,
                    progress: { _ in }
                )
                let downloaded = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try await client.downloadFile(
                    atPath: paths.uploadedFile,
                    to: downloaded,
                    progress: { _ in }
                )
                XCTAssertEqual(try Data(contentsOf: downloaded), oldContents)

                try await client.renameItem(
                    from: paths.uploadedFile,
                    to: paths.renamedFile
                )
                try await client.createDirectory(atPath: paths.directoryToRename)
                try await client.renameItem(
                    from: paths.directoryToRename,
                    to: paths.renamedDirectory
                )

                try await client.uploadFile(
                    from: source,
                    to: paths.replacedFile,
                    progress: { _ in }
                )
                try await client.uploadFile(
                    from: replacement,
                    to: paths.replacementTemporaryFile,
                    progress: { _ in }
                )
                try await client.renameItem(
                    from: paths.replacementTemporaryFile,
                    to: paths.replacedFile
                )
                try await client.downloadFile(
                    atPath: paths.replacedFile,
                    to: downloaded,
                    progress: { _ in }
                )
                XCTAssertEqual(try Data(contentsOf: downloaded), newContents)

                try await client.uploadFile(
                    from: source,
                    to: paths.fileToRemove,
                    progress: { _ in }
                )
                try await client.removeFile(atPath: paths.fileToRemove)
                try await client.createDirectory(atPath: paths.emptyDirectory)
                try await client.removeEmptyDirectory(atPath: paths.emptyDirectory)

                try await client.createDirectory(atPath: paths.nonEmptyDirectory)
                try await client.uploadFile(
                    from: source,
                    to: paths.nonEmptyChild,
                    progress: { _ in }
                )
                await XCTAssertThrowsErrorAsync {
                    try await client.removeEmptyDirectory(atPath: paths.nonEmptyDirectory)
                }
                _ = try await client.metadata(atPath: paths.nonEmptyChild)

                try await client.uploadFile(
                    from: source,
                    to: paths.cancelledDestination,
                    progress: { _ in }
                )
                let uploadProgress = WritableSFTPIntegrationUploadProgress()
                let cancelledUpload = Task {
                    try await client.uploadFile(
                        from: largeSource,
                        to: paths.cancelledTemporaryFile,
                        progress: { _ in await uploadProgress.recordProgress() }
                    )
                }
                await uploadProgress.waitForProgress()
                cancelledUpload.cancel()
                await XCTAssertThrowsErrorAsync {
                    _ = try await cancelledUpload.value
                }
                try await client.downloadFile(
                    atPath: paths.cancelledDestination,
                    to: downloaded,
                    progress: { _ in }
                )
                XCTAssertEqual(try Data(contentsOf: downloaded), oldContents)
            } catch {
                await paths.removeExplicitly(using: client)
                throw error
            }

            await paths.removeExplicitly(using: client)
            let finalRootEntries = try await client.listDirectory(atPath: root.path)
            XCTAssertTrue(finalRootEntries.isEmpty)
        }
    }

    func testFileProviderWriteOperationsCallExactCitadelRequests() async throws {
        let connection = FakeCitadelSFTPConnection(writableFile: RecordingUploadSource())
        let client = makeClient(connection: connection)
        let source = try temporaryFile(contents: Data("new".utf8))
        defer { try? FileManager.default.removeItem(at: source) }

        try await client.createDirectory(atPath: "/home/me/new")
        try await client.uploadFile(
            from: source,
            to: "/home/me/.remux-upload-fixture",
            progress: { _ in }
        )
        try await client.renameItem(
            from: "/home/me/.remux-upload-fixture",
            to: "/home/me/report.txt"
        )
        try await client.removeFile(atPath: "/home/me/report.txt")
        try await client.removeEmptyDirectory(atPath: "/home/me/new")

        let mutations = await connection.mutations()
        XCTAssertEqual(mutations, [
            .mkdir("/home/me/new"),
            .openWrite(
                "/home/me/.remux-upload-fixture",
                flags: [.write, .create, .forceCreate]
            ),
            .rename("/home/me/.remux-upload-fixture", "/home/me/report.txt"),
            .removeFile("/home/me/report.txt"),
            .rmdir("/home/me/new"),
        ])
    }

    func testFileProviderWritePermissionDeniedNormalizesToTypedError() {
        XCTAssertEqual(
            RemuxCitadelSFTPClient.normalizedWriteError(for: .permissionDenied),
            .permissionDenied
        )
    }

    func testFileProviderAmbiguousWriteFailureNormalizesToUnsupportedMutation() {
        XCTAssertEqual(
            RemuxCitadelSFTPClient.normalizedWriteError(for: .failure),
            .unsupportedMutation
        )
    }

    func testFileProviderUploadCancellationClosesRemoteHandleWithoutMutations() async throws {
        let source = CancellableUploadSource()
        let connection = FakeCitadelSFTPConnection(writableFile: source)
        let client = makeClient(connection: connection)
        let localFile = try temporaryFile(contents: Data("new".utf8))
        defer { try? FileManager.default.removeItem(at: localFile) }

        let task = Task {
            try await client.uploadFile(
                from: localFile,
                to: "/home/me/.remux-upload-fixture",
                progress: { _ in }
            )
        }

        for _ in 0..<1_000 {
            if await source.writeCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let writeCount = await source.writeCount()
        XCTAssertEqual(writeCount, 1)
        task.cancel()

        do {
            try await task.value
            XCTFail("cancelled upload should throw")
        } catch is CancellationError {
        }

        let closeCount = await source.closeCount()
        let mutations = await connection.mutations()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(mutations, [
            .openWrite(
                "/home/me/.remux-upload-fixture",
                flags: [.write, .create, .forceCreate]
            ),
        ])
    }

    func testFileProviderUploadFailsWhenRemoteDestinationAlreadyExists() async throws {
        let source = RecordingUploadSource()
        let connection = FakeCitadelSFTPConnection(
            writableFile: source,
            existingWritePaths: ["/home/me/report.txt"]
        )
        let client = makeClient(connection: connection)
        let localFile = try temporaryFile(contents: Data("new".utf8))
        defer { try? FileManager.default.removeItem(at: localFile) }

        do {
            try await client.uploadFile(
                from: localFile,
                to: "/home/me/report.txt",
                progress: { _ in }
            )
            XCTFail("existing remote destination should reject a strict upload")
        } catch is FakeCitadelSFTPConnectionError {
        }

        let mutations = await connection.mutations()
        let writeCount = await source.writeCount()
        XCTAssertEqual(mutations, [
            .openWrite(
                "/home/me/report.txt",
                flags: [.write, .create, .forceCreate]
            ),
        ])
        XCTAssertEqual(writeCount, 0)
    }

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

    private func temporaryFile(contents: Data) throws -> URL {
        let url = temporaryURL()
        try contents.write(to: url)
        return url
    }
}

private enum WritableSFTPIntegrationError: Error {
    case nonCanonicalRoot
    case nonEmptyRoot
}

private struct WritableSFTPIntegrationRoot: Sendable {
    let path: String

    init?(_ value: String?) {
        guard let value,
              !value.isEmpty,
              value != "/",
              value != "."
        else {
            return nil
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2,
              !components.contains("."),
              !components.contains("..")
        else {
            return nil
        }

        path = value
    }
}

private struct WritableSFTPIntegrationPaths: Sendable {
    let createdDirectory: String
    let uploadedFile: String
    let renamedFile: String
    let directoryToRename: String
    let renamedDirectory: String
    let replacedFile: String
    let replacementTemporaryFile: String
    let fileToRemove: String
    let emptyDirectory: String
    let nonEmptyDirectory: String
    let nonEmptyChild: String
    let cancelledDestination: String
    let cancelledTemporaryFile: String

    init(root: WritableSFTPIntegrationRoot) {
        let prefix = root.path + "/remux-writable-" + UUID().uuidString.lowercased()
        createdDirectory = prefix + "-created"
        uploadedFile = prefix + "-uploaded.txt"
        renamedFile = prefix + "-renamed.txt"
        directoryToRename = prefix + "-directory-before-rename"
        renamedDirectory = prefix + "-directory-after-rename"
        replacedFile = prefix + "-replace.txt"
        replacementTemporaryFile = prefix + "-replace-uploading.txt"
        fileToRemove = prefix + "-remove.txt"
        emptyDirectory = prefix + "-empty"
        nonEmptyDirectory = prefix + "-non-empty"
        nonEmptyChild = nonEmptyDirectory + "/child.txt"
        cancelledDestination = prefix + "-cancelled-destination.txt"
        cancelledTemporaryFile = prefix + "-cancelled-uploading.txt"
    }

    func removeExplicitly(using client: any RemuxSFTPFileProviderClient) async {
        for file in [
            uploadedFile,
            renamedFile,
            replacedFile,
            replacementTemporaryFile,
            fileToRemove,
            nonEmptyChild,
            cancelledDestination,
            cancelledTemporaryFile,
        ] {
            try? await client.removeFile(atPath: file)
        }
        for directory in [
            createdDirectory,
            directoryToRename,
            renamedDirectory,
            emptyDirectory,
            nonEmptyDirectory,
        ] {
            try? await client.removeEmptyDirectory(atPath: directory)
        }
    }
}

private actor WritableSFTPIntegrationUploadProgress {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasProgress = false

    func recordProgress() {
        hasProgress = true
        continuation?.resume()
        continuation = nil
    }

    func waitForProgress() async {
        guard !hasProgress else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
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

private actor RecordingUploadSource: RemuxCitadelSFTPFile {
    private var recordedWriteCount = 0

    func readData(from offset: UInt64, length: UInt32) throws -> Data {
        throw FakeCitadelSFTPConnectionError.unexpectedFileRead
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) {
        recordedWriteCount += 1
    }

    func close() {}

    func writeCount() -> Int {
        recordedWriteCount
    }
}

private actor CancellableUploadSource: RemuxCitadelSFTPFile {
    private var recordedWriteCount = 0
    private var recordedCloseCount = 0

    func readData(from offset: UInt64, length: UInt32) throws -> Data {
        throw FakeCitadelSFTPConnectionError.unexpectedFileRead
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) async throws {
        recordedWriteCount += 1
        try await Task.sleep(for: .seconds(30))
    }

    func close() {
        recordedCloseCount += 1
    }

    func writeCount() -> Int {
        recordedWriteCount
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
    private let writableFile: (any RemuxCitadelSFTPFile)?
    private let existingWritePaths: Set<String>
    private let mutationFailure: Error?
    private var recordedListedPaths: [String] = []
    private var recordedAttributePaths: [String] = []
    private var recordedMutations: [Mutation] = []

    init(
        directoryResponses: [String: [RemuxCitadelSFTPDirectoryResponse]] = [:],
        directoryFailures: [String: RemuxSFTPClientError] = [:],
        directoryDelay: Duration? = nil,
        readableFile: (any RemuxCitadelSFTPFile)? = nil,
        writableFile: (any RemuxCitadelSFTPFile)? = nil,
        existingWritePaths: Set<String> = [],
        mutationFailure: Error? = nil
    ) {
        self.directoryResponses = directoryResponses
        self.directoryFailures = directoryFailures
        self.directoryDelay = directoryDelay
        self.readableFile = readableFile
        self.writableFile = writableFile
        self.existingWritePaths = existingWritePaths
        self.mutationFailure = mutationFailure
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
        atPath path: String,
        flags: SFTPOpenFileFlags
    ) async throws -> any RemuxCitadelSFTPFile {
        recordedMutations.append(.openWrite(path, flags: flags))
        if let mutationFailure { throw mutationFailure }
        if existingWritePaths.contains(path), flags.contains(.forceCreate) {
            throw FakeCitadelSFTPConnectionError.destinationAlreadyExists
        }
        guard let writableFile else {
            throw FakeCitadelSFTPConnectionError.unexpectedFileOpen
        }
        return writableFile
    }

    func remuxCreateDirectory(atPath path: String) throws {
        recordedMutations.append(.mkdir(path))
        if let mutationFailure { throw mutationFailure }
    }

    func remuxRename(from sourcePath: String, to destinationPath: String) throws {
        recordedMutations.append(.rename(sourcePath, destinationPath))
        if let mutationFailure { throw mutationFailure }
    }

    func remuxRemove(atPath path: String) throws {
        recordedMutations.append(.removeFile(path))
        if let mutationFailure { throw mutationFailure }
    }

    func remuxRemoveDirectory(atPath path: String) throws {
        recordedMutations.append(.rmdir(path))
        if let mutationFailure { throw mutationFailure }
    }

    func listedPaths() -> [String] {
        recordedListedPaths
    }

    func attributePaths() -> [String] {
        recordedAttributePaths
    }

    func mutations() -> [Mutation] {
        recordedMutations
    }

    enum Mutation: Equatable {
        case mkdir(String)
        case openWrite(String, flags: SFTPOpenFileFlags)
        case rename(String, String)
        case removeFile(String)
        case rmdir(String)
    }
}

private enum FakeCitadelSFTPConnectionError: Error {
    case unexpectedFileOpen
    case unexpectedFileRead
    case unexpectedFileWrite
    case destinationAlreadyExists
}
