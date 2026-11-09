@preconcurrency import Citadel
import Foundation
import NIO

struct RemuxCitadelSFTPClient: RemuxSFTPUploadClient, RemuxSFTPReadOnlyClient {
    private static let pipelinedWriteMaxInFlight = 64

    private let sftp: SFTPClient
    private let chunkSize: Int
    private let operationTimeout: TimeAmount
    private let leaseState: RemuxSFTPLeaseTeardown

    fileprivate init(
        sftp: SFTPClient,
        chunkSize: Int = 4 * 1024 * 1024,
        operationTimeout: TimeAmount = .seconds(15),
        leaseState: RemuxSFTPLeaseTeardown
    ) {
        self.sftp = sftp
        self.chunkSize = chunkSize
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
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
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
            operationResult = .success(try await operation(readableFile))
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

    func ensureDirectoryExists(atPath path: String) async throws {
        do {
            _ = try await getAttributes(at: path)
            return
        } catch where isNoSuchFile(error) {
            do {
                try await withOperationTimeout {
                    try await sftp.createDirectory(atPath: path)
                }
            } catch {
                if try await exists(atPath: path) {
                    return
                }
                throw error
            }
        }
    }

    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws {
        let localFile = try FileHandle(forReadingFrom: localURL)
        defer {
            try? localFile.close()
        }

        let remoteFile = try await openRemoteFile(
            at: remotePath,
            flags: [.write, .create, .truncate]
        )

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()

                let data = try localFile.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { break }

                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                let writeBuffer = buffer
                let writeOffset = offset
                try await withOperationTimeout {
                    try await remoteFile.file.writePipelined(
                        writeBuffer,
                        at: writeOffset,
                        maxInFlight: Self.pipelinedWriteMaxInFlight
                    )
                }
                offset += UInt64(data.count)
                await progress(Int64(min(offset, UInt64(Int64.max))))
            }

            try await closeRemoteFile(remoteFile)
        } catch let error as RemuxSFTPClientError where error == .operationTimedOut {
            throw RemuxSFTPClientError.operationTimedOut
        } catch {
            try? await closeRemoteFile(remoteFile)
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

    private func exists(atPath path: String) async throws -> Bool {
        do {
            _ = try await getAttributes(at: path)
            return true
        } catch where isNoSuchFile(error) {
            return false
        }
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
                operation: operation,
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

/// SFTP on the server's pooled SSH connection: each client lease claims the connection, as one of its
/// consumers, and gives it back when it closes.
struct RemuxCitadelSFTPClientProvider: RemuxSFTPClientProvider {
    private let provider: RemuxShortLivedSFTPClientProvider<RemuxCitadelSFTPClient>

    init(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int = 4 * 1024 * 1024,
        closeFailureHandler: @escaping @Sendable (Error) -> Void = { error in
            NSLog("Remux Citadel SFTP lease close failed: %@", String(describing: error))
        }
    ) {
        self.provider = RemuxShortLivedSFTPClientProvider(
            openLease: {
                try await Self.openLease(
                    sshRootService: sshRootService,
                    rootKey: rootKey,
                    rootConfiguration: rootConfiguration,
                    operationTimeout: operationTimeout,
                    chunkSize: chunkSize
                )
            },
            closeFailureHandler: closeFailureHandler
        )
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (RemuxCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await provider.withClient(operation)
    }

    /// A client the caller holds, with the connection claimed, until it closes the lease.
    func openClientLease() async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        try await provider.openClientLease()
    }

    private static func openLease(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int
    ) async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
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
                chunkSize: chunkSize,
                operationTimeout: operationTimeout,
                leaseState: leaseState
            )
            return RemuxSFTPClientLease(
                client: client,
                close: {
                    try await leaseState.close()
                }
            )
        } catch {
            await claimedRoot.release(.invalidated)
            throw error
        }
    }
}
