import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import Remux

/// Attachments and file previews through the app's own transfer service and preview reader, on the server's kept SFTP
/// session, against the private OpenSSH server of `SSHPoolLiveTests` (`REMUX_LIVE_SSH_POOL_CONFIG`).
/// `REMUX_LIVE_SFTP_DIRECTORY` names an absolute directory on that server for the files the tests write (pass both
/// to `xcodebuild test` with the `TEST_RUNNER_` prefix); without them the tests skip.
final class SFTPTransferLiveTests: XCTestCase {
    func testMultiFileAttachmentArrivesWithTerminalPathsFromItsDirectory() async throws {
        let server = try SFTPTransferLiveServer()
        addTeardownBlock { await server.close() }
        let files = [
            try server.localFile(named: "note.txt", bytes: 1_000),
            try server.localFile(named: "photo one.jpg", bytes: 300_000),
            try server.localFile(named: "archive.zip", bytes: 3_000_000),
        ]
        let workspaceID = UUID()
        let job = GhosttyAttachmentTransferJob(
            workspaceID: workspaceID,
            sources: files.map { url in
                GhosttyAttachmentTransferSource(
                    title: url.lastPathComponent,
                    payload: .file(url, filename: url.lastPathComponent)
                )
            } + [GhosttyAttachmentTransferSource(title: "Note", payload: .text("see"))]
        )
        let progress = NIOLockedValueBox<[GhosttyAttachmentTransferProgress]>([])

        // The workspace's directory is new, so its parents are made too.
        let result = try await server.attachments.transfer(job) { update in
            progress.withLockedValue { $0.append(update) }
        }

        let directory = "\(server.attachmentRoot)/\(workspaceID.uuidString.lowercased())/\(job.transferID.uuidString.lowercased())"
        let remoteFiles = result.items.compactMap { item -> GhosttyRemoteAttachmentPath? in
            guard case .remoteFile(_, let path) = item else { return nil }
            return path
        }
        XCTAssertEqual(remoteFiles.map(\.terminalPath), files.map { "\(directory)/\($0.lastPathComponent)" })
        for (local, remote) in zip(files, remoteFiles) {
            let arrived = try await server.preview(remote.remoteFinalPath)
            XCTAssertEqual(arrived, try Data(contentsOf: local), remote.filename)
        }
        let lastReports = progress.withLockedValue { $0 }.filter { $0.currentUploadedBytes == $0.currentTotalBytes }
        XCTAssertEqual(lastReports.map(\.currentUploadIndex), [1, 2, 3], "each file reports its last byte")

        // The next send in the workspace makes only its own directory, on the same session.
        let next = try await server.attachments.transfer(
            GhosttyAttachmentTransferJob(
                workspaceID: workspaceID,
                sources: [GhosttyAttachmentTransferSource(title: "again", payload: .file(files[0], filename: "again.txt"))]
            ),
            progress: { _ in }
        )
        XCTAssertEqual(next.items.count, 1)
        let sessionCount = await server.sessions.sessionCountForTesting
        XCTAssertEqual(sessionCount, 1)
        let transferEntries = await server.pool.snapshot().entries(for: server.key)
        XCTAssertEqual(transferEntries.count, 1)
        XCTAssertEqual(transferEntries.first?.activeLeaseCount, 1, "the kept session is the connection's one consumer")
    }

    func testPreviewsSmallMultiChunkAndGrownFiles() async throws {
        let server = try SFTPTransferLiveServer()
        addTeardownBlock { await server.close() }
        // Prepared as the composer does when an attachment is added: the session is open before the first read.
        await server.attachments.prepare()
        let previews = "\(server.directory)/previews-\(UUID().uuidString.lowercased())"
        let small = try server.localFile(named: "small.txt", bytes: 100)
        let large = try server.localFile(named: "large.bin", bytes: 3_000_000)
        try await server.upload(small, to: "\(previews)/small.txt")
        try await server.upload(large, to: "\(previews)/large.bin")

        let smallPreview = try await server.preview("\(previews)/small.txt")
        XCTAssertEqual(smallPreview, try Data(contentsOf: small))
        let largePreview = try await server.preview("\(previews)/large.bin")
        XCTAssertEqual(largePreview, try Data(contentsOf: large))

        // A file read with a size taken before it grew (as a page's entry file is) is still read to its end.
        let grown = try await server.read("\(previews)/large.bin", knownSize: 700_000)
        XCTAssertEqual(grown, try Data(contentsOf: large))

        // The same file under a maximum it outgrew fails as too large.
        do {
            _ = try await server.read("\(previews)/large.bin", knownSize: 700_000, maximumByteCount: 1_000_000)
            XCTFail("Expected the read to fail")
        } catch let error as TerminalPreviewFileError {
            XCTAssertEqual(error, .tooLarge(maximumByteCount: 1_000_000))
        }
        let sessionCount = await server.sessions.sessionCountForTesting
        XCTAssertEqual(sessionCount, 1, "every read used the prepared session")
    }
}

/// The live server as the app sees a saved server's transfer connection, with the app's service and reader on it.
final class SFTPTransferLiveServer: @unchecked Sendable {
    let pool = RemuxSSHRootService()
    let sessions = RemuxTransferSFTPSessions()
    let key: RemuxSSHRootKey
    let directory: String
    let attachmentRoot: String
    let attachments: GhosttyAttachmentSFTPClientProviderTransferService<RemuxCitadelSFTPClientProvider>
    private let provider: RemuxCitadelSFTPClientProvider
    private let localDirectory: URL

    init() throws {
        let configuration = try SSHPoolLiveConfiguration.load()
        guard let directory = ProcessInfo.processInfo.environment["REMUX_LIVE_SFTP_DIRECTORY"],
              directory.hasPrefix("/") else {
            throw XCTSkip("Set REMUX_LIVE_SFTP_DIRECTORY to an absolute directory on the live server.")
        }
        self.directory = directory
        attachmentRoot = "\(directory)/attachments"
        let id = UUID()
        localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPTransferLiveTests-\(id.uuidString)")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let store = TrustedHostStore(rootURL: localDirectory.appendingPathComponent("trust"))
        let server = SavedServer(
            id: id,
            displayName: "sftp-transfer-live",
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            identityID: id
        )
        let keyParts = configuration.hostKey.split(separator: " ")
        guard keyParts.count >= 2 else {
            throw XCTSkip("hostKey must be an OpenSSH public key line")
        }
        try store.trustHostKey(
            SSHHostKeyTrustChallenge(
                kind: .unknown,
                serverID: id,
                host: configuration.host,
                trustedKeyType: nil,
                trustedOpenSSHPublicKey: nil,
                receivedKeyType: String(keyParts[0]),
                receivedOpenSSHPublicKey: "\(keyParts[0]) \(keyParts[1])"
            )
        )
        let target = SessionTarget(
            server: server,
            workspace: SavedWorkspace(serverID: id, sessionName: "transfer"),
            sshAuth: try ResolvedSSHAuth.privateKey(
                username: configuration.username,
                credential: SSHPrivateKeyCredential(privateKeyPEM: configuration.privateKeyPEM),
                identityID: id,
                displayLabel: "sftp-transfer-live"
            )
        )
        key = RemuxSSHRootKey(target: target, purpose: .transfer)
        provider = RemuxCitadelSFTPClientProvider(
            sshRootService: pool,
            sessions: sessions,
            rootKey: key,
            rootConfiguration: RemuxAppDependencies.transferSSHRootConfiguration(for: target, trustedHostStore: store),
            operationTimeout: RemuxConnectionTimeouts.sftpOperation
        )
        attachments = GhosttyAttachmentSFTPClientProviderTransferService(
            provider: provider,
            pathBuilder: GhosttyRemoteAttachmentPathBuilder(remoteRoot: attachmentRoot, terminalRoot: attachmentRoot)
        )
    }

    func localFile(named name: String, bytes: Int) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        let url = localDirectory.appendingPathComponent(name)
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        return url
    }

    /// Writes a server file as attachments do: into a new directory, then renamed into place.
    func upload(_ local: URL, to remotePath: String) async throws {
        let job = GhosttyAttachmentTransferJob(
            workspaceID: UUID(),
            sources: [GhosttyAttachmentTransferSource(title: "file", payload: .file(local, filename: "file"))]
        )
        let result = try await attachments.transfer(job, progress: { _ in })
        guard case .remoteFile(_, let path) = result.items.first else {
            throw SSHPoolLiveError("the upload returned no file")
        }
        try await provider.withClient { client in
            _ = try await client.makeDirectory(atPath: (remotePath as NSString).deletingLastPathComponent)
            try await client.renameFile(from: path.remoteFinalPath, to: remotePath)
        }
    }

    /// The file as a preview loads it.
    func preview(_ remotePath: String) async throws -> Data {
        let loader = TerminalPreviewFileLoader(provider: provider, temporaryDirectory: localDirectory)
        let resource = try await loader.load(remotePath: remotePath)
        return try Data(contentsOf: resource.url)
    }

    func read(
        _ remotePath: String,
        knownSize: UInt64,
        maximumByteCount: UInt64 = TerminalPreviewFileLoader<RemuxCitadelSFTPClientProvider>.defaultMaximumByteCount
    ) async throws -> Data {
        let received = NIOLockedValueBox(Data())
        _ = try await provider.withClient { client in
            try await TerminalPreviewRemoteFileReader.stream(
                client: client,
                remotePath: remotePath,
                maximumByteCount: maximumByteCount,
                knownMetadata: RemuxSFTPFileMetadata(size: knownSize, permissions: nil, modificationDate: nil)
            ) { data in
                received.withLockedValue { $0.append(data) }
            }
        }
        return received.withLockedValue { $0 }
    }

    func close() async {
        await sessions.closeIdleSessions { _ in true }
        await pool.closeAllConnectionsForTesting()
        try? FileManager.default.removeItem(at: localDirectory)
    }
}
