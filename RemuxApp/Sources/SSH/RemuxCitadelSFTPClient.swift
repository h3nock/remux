@preconcurrency import Citadel
import Foundation
import NIO

struct RemuxCitadelSFTPClient: RemuxSFTPUploadClient, RemuxSFTPReadOnlyClient {
    private let sftp: SFTPClient
    /// Each operation fails once the session has gone this long without an answer.
    private let operationTimeout: TimeAmount
    private let leaseState: RemuxSFTPLeaseTeardown
    private let activity = RemuxSFTPActivity()

    fileprivate init(
        sftp: SFTPClient,
        operationTimeout: TimeAmount = .seconds(15),
        leaseState: RemuxSFTPLeaseTeardown
    ) {
        self.sftp = sftp
        self.operationTimeout = operationTimeout
        self.leaseState = leaseState
    }

    func realPath(atPath path: String) async throws -> String {
        try await withOperationTimeout {
            try await sftp.getRealPath(atPath: path)
        }
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        let attributes = try await getAttributes(at: path)
        return RemuxSFTPFileMetadata(
            size: attributes.size,
            permissions: attributes.permissions,
            modificationDate: attributes.accessModificationTime?.modificationTime
        )
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        knownMetadata: RemuxSFTPFileMetadata?,
        _ operation: @Sendable (RemuxSFTPReadableFile, RemuxSFTPFileMetadata) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        async let fileMetadata = metadata(atPath: path, unlessKnown: knownMetadata)
        let remoteFile = try await openRemoteFile(
            at: path,
            flags: .read
        )
        let readableFile = RemuxSFTPReadableFile { offset, length in
            let buffer = try await withOperationTimeout {
                try await remoteFile.file.read(from: offset, length: length)
            }
            return Data(buffer.readableBytesView)
        }

        let operationResult: Result<ReturnValue, Error>
        do {
            let metadata = try await fileMetadata
            operationResult = .success(try await operation(readableFile, metadata))
        } catch {
            operationResult = .failure(error)
        }

        switch operationResult {
        case .success(let result):
            try await closeRemoteFile(remoteFile)
            return result
        case .failure(let operationError):
            do {
                try await closeRemoteFile(remoteFile)
            } catch {
                NSLog(
                    "Remux read-only SFTP file close failed for %@ after operation failure: %@",
                    path,
                    String(describing: error)
                )
            }
            throw operationError
        }
    }

    func makeDirectory(atPath path: String) async throws -> RemuxSFTPMakeDirectoryResult {
        do {
            try await withOperationTimeout {
                try await sftp.createDirectory(atPath: path)
            }
            return .created
        } catch where isNoSuchFile(error) {
            return .parentMissing
        } catch is SFTPMessage.Status {
            return .refused
        }
    }

    func itemExists(atPath path: String) async throws -> Bool {
        do {
            _ = try await getAttributes(at: path)
            return true
        } catch where isNoSuchFile(error) {
            return false
        }
    }

    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws {
        let localFile = try FileHandle(forReadingFrom: localURL)
        let remoteFile: RemuxCitadelSFTPFileBox
        do {
            remoteFile = try await openRemoteFile(
                at: remotePath,
                flags: [.write, .create, .truncate]
            )
        } catch {
            try? localFile.close()
            throw error
        }

        do {
            try await leaseState.checkActive()
            try await RemuxSFTPUploadWindow(noProgressTimeout: operationTimeout).upload(
                localFile,
                activity: activity,
                onTimeout: { [leaseState] in
                    await leaseState.invalidate()
                },
                progress: progress,
                write: { data, offset in
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    // At most `RemuxSFTPUploadWindow.defaultWriteLength` bytes, which Citadel sends as one request.
                    try await remoteFile.file.write(buffer, at: offset)
                }
            )
            try await closeRemoteFile(remoteFile)
        } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
            // The session was given up on, so a close would only wait on it too.
            throw error
        } catch {
            try? await closeRemoteFile(remoteFile)
            try await leaseState.checkActive()
            throw error
        }
    }

    func renameFile(from temporaryPath: String, to finalPath: String) async throws {
        try await withOperationTimeout {
            try await sftp.rename(at: temporaryPath, to: finalPath)
        }
    }

    func removeFileIfExists(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await sftp.remove(at: path)
            }
        } catch where isNoSuchFile(error) {
            return
        }
    }

    private func openRemoteFile(
        at remotePath: String,
        flags: SFTPOpenFileFlags
    ) async throws -> RemuxCitadelSFTPFileBox {
        try await withOperationTimeout(
            operation: {
                let file = try await sftp.openFile(
                    filePath: remotePath,
                    flags: flags
                )
                return RemuxCitadelSFTPFileBox(file: file)
            },
            cleanupLateSuccess: { fileBox in
                do {
                    try await fileBox.file.close()
                } catch {
                    NSLog(
                        "Remux SFTP late file open close failed for %@: %@",
                        remotePath,
                        String(describing: error)
                    )
                }
            }
        )
    }

    private func closeRemoteFile(_ fileBox: RemuxCitadelSFTPFileBox) async throws {
        try await withOperationTimeout {
            try await fileBox.file.close()
        }
    }

    private func metadata(
        atPath path: String,
        unlessKnown knownMetadata: RemuxSFTPFileMetadata?
    ) async throws -> RemuxSFTPFileMetadata {
        if let knownMetadata {
            return knownMetadata
        }
        return try await metadata(atPath: path)
    }

    private func getAttributes(at path: String) async throws -> SFTPFileAttributes {
        try await withOperationTimeout {
            try await sftp.getAttributes(at: path)
        }
    }

    private func withOperationTimeout<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value,
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        try await leaseState.checkActive()

        do {
            let value = try await RemuxSFTPTimeout.run(
                timeout: operationTimeout,
                extendWhile: { [activity] windowStart in activity.hasAnswered(since: windowStart) },
                operation: { [activity] in
                    defer { activity.recordAnswer() }
                    return try await operation()
                },
                onTimeout: {
                    await leaseState.invalidate()
                },
                cleanupLateSuccess: cleanupLateSuccess
            )
            try await leaseState.checkActive()
            return value
        } catch {
            try await leaseState.checkActive()
            throw error
        }
    }

    private func isNoSuchFile(_ error: Error) -> Bool {
        guard let status = error as? SFTPMessage.Status else {
            return false
        }
        return status.errorCode == .noSuchFile
    }
}

private final class RemuxCitadelSFTPFileBox: @unchecked Sendable {
    let file: SFTPFile

    init(file: SFTPFile) {
        self.file = file
    }
}


/// The app's kept SFTP sessions, one per server transfer connection.
typealias RemuxTransferSFTPSessions = RemuxSFTPSessionKeeper<RemuxSSHRootKey, RemuxCitadelSFTPClient>

/// SFTP on the server's pooled SSH connection, through the session `sessions` keeps for it: the session claims the
/// connection, as one of its consumers, while it is open.
struct RemuxCitadelSFTPClientProvider: RemuxSFTPUploadClientProvider {
    private let sessions: RemuxTransferSFTPSessions
    private let rootKey: RemuxSSHRootKey
    private let openSession: @Sendable () async throws -> RemuxTransferSFTPSessions.Session

    init(
        sshRootService: RemuxSSHRootService,
        sessions: RemuxTransferSFTPSessions,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount
    ) {
        self.sessions = sessions
        self.rootKey = rootKey
        self.openSession = {
            try await Self.openSession(
                sshRootService: sshRootService,
                rootKey: rootKey,
                rootConfiguration: rootConfiguration,
                operationTimeout: operationTimeout
            )
        }
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (RemuxCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await RemuxShortLivedSFTPClientProvider(openLease: { try await openClientLease() }).withClient(operation)
    }

    /// A client the caller holds, keeping the session open, until it closes the lease.
    func openClientLease() async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        try await sessions.lease(for: rootKey, open: openSession)
    }

    func withUploadTurn<ReturnValue: Sendable>(
        _ upload: @Sendable (RemuxCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await sessions.withUploadTurn(for: rootKey) {
            try await withClient(upload)
        }
    }

    func prepare() async {
        do {
            try await openClientLease().close()
        } catch {
            NSLog("Remux SFTP prepare failed: %@", String(describing: error))
        }
    }

    private static func openSession(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount
    ) async throws -> RemuxTransferSFTPSessions.Session {
        let claimedRoot = try await sshRootService.claimRoot(
            for: rootKey,
            configuration: rootConfiguration,
            trace: RemuxTransportStartupTrace(flowID: nil)
        )

        do {
            let sftpOpenStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency("sftp.open begin host=\(rootConfiguration.host):\(rootConfiguration.port)")
            // The SFTP subsystem takes one of the server's sessions, so a refused or unanswered start moves the
            // claim to another of the server's connections, as an exec session's does.
            let sftp = try await claimedRoot.openSession(trace: RemuxTransportStartupTrace(flowID: nil)) { root in
                try await root.withOpenDeadline(
                    {
                        try await SFTPClient.open(overAuthenticatedSSHChannel: root.rootChannel)
                    },
                    cleanupLateSuccess: { sftp in
                        do {
                            try await sftp.close()
                        } catch {
                            NSLog("Remux Citadel SFTP late open close failed: %@", String(describing: error))
                        }
                    }
                )
            }
            if let sftpOpenStartedAt {
                GhosttyRuntimeTrace.latency(
                    "sftp.open end host=\(rootConfiguration.host):\(rootConfiguration.port) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sftpOpenStartedAt))"
                )
            }
            let leaseState = RemuxSFTPLeaseTeardown(
                closeChild: {
                    try await RemuxSFTPTimeout.run(
                        timeout: operationTimeout,
                        operation: {
                            try await sftp.close()
                        }
                    )
                },
                releaseRoot: { disposition in
                    await claimedRoot.release(disposition)
                }
            )
            let client = RemuxCitadelSFTPClient(
                sftp: sftp,
                operationTimeout: operationTimeout,
                leaseState: leaseState
            )
            return RemuxTransferSFTPSessions.Session(
                client: client,
                isUsable: {
                    let isInvalidated = await leaseState.isInvalidated
                    return sftp.isActive && !isInvalidated
                },
                close: {
                    do {
                        try await leaseState.close()
                    } catch {
                        NSLog("Remux Citadel SFTP session close failed: %@", String(describing: error))
                    }
                }
            )
        } catch {
            await claimedRoot.release(.invalidated)
            throw error
        }
    }
}
