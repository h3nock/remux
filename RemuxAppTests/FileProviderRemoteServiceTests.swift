import Foundation
import XCTest
@testable import Remux

final class FileProviderRemoteServiceTests: XCTestCase {
    func testServiceListsHomeAndFiltersUnsupportedAndUnsafeLinks() async throws {
        let fixture = try await FileProviderRemoteServiceFixture.make()

        let items = try await fixture.service.list(directory: .root)

        XCTAssertEqual(items.map(\.name), [".env", "folder", "safe-link", "file.txt"])
        XCTAssertEqual(
            items.first(where: { $0.name == "safe-link" })?.symlinkTargetRelativePath,
            "folder/target"
        )
    }

    func testServiceLoadsAnItemRelativeToCanonicalHome() async throws {
        let fixture = try await FileProviderRemoteServiceFixture.make()
        let path = try FileProviderRemotePath(relative: "file.txt")

        let item = try await fixture.service.item(at: path)

        XCTAssertEqual(item.path, path)
        XCTAssertEqual(item.name, "file.txt")
        XCTAssertEqual(item.type, .regular)
        XCTAssertEqual(item.size, 4)
    }

    func testServiceLoadsOnlySymlinksWhoseCanonicalTargetStaysInHome() async throws {
        let fixture = try await FileProviderRemoteServiceFixture.make()

        let safe = try await fixture.service.item(
            at: FileProviderRemotePath(relative: "safe-link")
        )

        XCTAssertEqual(safe.type, .symbolicLink)
        XCTAssertEqual(safe.symlinkTargetRelativePath, "folder/target")
        await XCTAssertThrowsErrorAsync {
            try await fixture.service.item(
                at: FileProviderRemotePath(relative: "escape-link")
            )
        }
    }

    func testFetchCancellationCancelsRemoteReadAndRemovesPartialFile() async throws {
        let home = "/home/reader"
        let metadata = RemuxSFTPFileMetadata(
            size: 8 * 1024 * 1024,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 400)
        )
        let readState = FileProviderTestReadState()
        let client = FileProviderTestSFTPClient(
            realPaths: [".": .success(home)],
            listings: [
                home: [RemuxSFTPDirectoryEntry(name: "large.bin", metadata: metadata)],
            ],
            fileRead: { _, _ in
                await readState.markStarted()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return Data()
                } catch is CancellationError {
                    await readState.markCancelled()
                    throw CancellationError()
                }
            }
        )
        let fixture = try await FileProviderRemoteServiceFixture.make(client: client)
        let partialURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let task = Task {
            try await fixture.service.fetch(
                path: FileProviderRemotePath(relative: "large.bin"),
                to: partialURL,
                progress: { _ in }
            )
        }

        await readState.waitUntilStarted()
        task.cancel()

        await XCTAssertThrowsErrorAsync { try await task.value }
        let wasCancelled = await readState.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
    }
}

struct FileProviderRemoteServiceFixture {
    let service: FileProviderRemoteService

    static func make() async throws -> FileProviderRemoteServiceFixture {
        let home = "/home/reader"
        let regular = RemuxSFTPFileMetadata(
            size: 4,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 100)
        )
        let directory = RemuxSFTPFileMetadata(
            size: nil,
            permissions: 0o040755,
            modificationDate: Date(timeIntervalSince1970: 200)
        )
        let link = RemuxSFTPFileMetadata(
            size: 12,
            permissions: 0o120777,
            modificationDate: Date(timeIntervalSince1970: 300)
        )
        let other = RemuxSFTPFileMetadata(
            size: nil,
            permissions: 0o140755,
            modificationDate: nil
        )
        let client = FileProviderTestSFTPClient(
            realPaths: [
                ".": .success(home),
                "\(home)/safe-link": .success("\(home)/folder/target"),
                "\(home)/escape-link": .success("/etc/passwd"),
                "\(home)/broken-link": .failure(.unresolved),
                "\(home)/cycle-link": .failure(.unresolved),
            ],
            listings: [
                home: [
                    RemuxSFTPDirectoryEntry(name: ".env", metadata: regular),
                    RemuxSFTPDirectoryEntry(name: "folder", metadata: directory),
                    RemuxSFTPDirectoryEntry(name: "safe-link", metadata: link),
                    RemuxSFTPDirectoryEntry(name: "file.txt", metadata: regular),
                    RemuxSFTPDirectoryEntry(name: "socket", metadata: other),
                    RemuxSFTPDirectoryEntry(name: "escape-link", metadata: link),
                    RemuxSFTPDirectoryEntry(name: "broken-link", metadata: link),
                    RemuxSFTPDirectoryEntry(name: "cycle-link", metadata: link),
                ],
            ],
            metadataByPath: ["\(home)/file.txt": regular]
        )
        return try await make(client: client)
    }

    static func make(
        client: any RemuxSFTPReadOnlyClient
    ) async throws -> FileProviderRemoteServiceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profiles = FileBackedConnectionProfileRepository(rootURL: root)
        let credentials = FileProviderTestCredentialStore()
        let identity = SSHIdentity(name: "Read only", authenticationKind: .password)
        let server = SavedServer(
            displayName: "Fixture",
            host: "fixture.example.test",
            username: "reader",
            identityID: identity.id
        )
        try await profiles.saveIdentity(identity)
        try await profiles.saveServer(server)
        await credentials.saveCredential(.password("fixture-password"), identityID: identity.id)

        let opener = FileProviderTestSFTPSessionOpener(client: client)
        return FileProviderRemoteServiceFixture(
            service: FileProviderRemoteService(
                domainIdentifier: server.id.uuidString.lowercased(),
                profiles: profiles,
                credentials: credentials,
                sessionOpener: opener
            )
        )
    }
}

actor FileProviderTestCredentialStore: SSHCredentialStore {
    private var credentials: [SSHIdentity.ID: SSHCredential] = [:]

    func loadCredential(identityID: SSHIdentity.ID) -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: SSHIdentity.ID) {
        credentials.removeValue(forKey: identityID)
    }
}

struct FileProviderTestSFTPSession: FileProviderSFTPClientSession {
    let client: any RemuxSFTPReadOnlyClient

    func close() async {
    }
}

struct FileProviderTestSFTPSessionOpener: FileProviderSFTPClientSessionOpening {
    let client: any RemuxSFTPReadOnlyClient

    func open(
        server: SavedServer,
        authentication: ResolvedSSHAuth
    ) async throws -> any FileProviderSFTPClientSession {
        FileProviderTestSFTPSession(client: client)
    }
}

enum FileProviderTestSFTPFailure: Error {
    case unresolved
}

final class FileProviderTestSFTPClient: RemuxSFTPReadOnlyClient, @unchecked Sendable {
    private let realPaths: [String: Result<String, FileProviderTestSFTPFailure>]
    private let listings: [String: [RemuxSFTPDirectoryEntry]]
    private let metadataByPath: [String: RemuxSFTPFileMetadata]
    private let fileDataByPath: [String: Data]
    private let fileRead: (@Sendable (UInt64, UInt32) async throws -> Data)?

    init(
        realPaths: [String: Result<String, FileProviderTestSFTPFailure>],
        listings: [String: [RemuxSFTPDirectoryEntry]],
        metadataByPath: [String: RemuxSFTPFileMetadata] = [:],
        fileDataByPath: [String: Data] = [:],
        fileRead: (@Sendable (UInt64, UInt32) async throws -> Data)? = nil
    ) {
        self.realPaths = realPaths
        self.listings = listings
        self.metadataByPath = metadataByPath
        self.fileDataByPath = fileDataByPath
        self.fileRead = fileRead
    }

    func realPath(atPath path: String) async throws -> String {
        guard let result = realPaths[path] else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return try result.get()
    }

    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry] {
        guard let listing = listings[path] else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return listing
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        guard let metadata = metadataByPath[path] else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return metadata
    }

    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let metadata = listings[parent]?.first(where: { $0.name == name })?.metadata else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return metadata
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        if let fileRead {
            return try await operation(RemuxSFTPReadableFile(readChunk: fileRead))
        }
        guard let data = fileDataByPath[path] else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        let file = RemuxSFTPReadableFile { offset, length in
            let start = min(Int(offset), data.count)
            let end = min(start + Int(length), data.count)
            return data.subdata(in: start..<end)
        }
        return try await operation(file)
    }
}

private actor FileProviderTestReadState {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func markCancelled() {
        wasCancelled = true
    }
}
