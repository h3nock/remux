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

enum RemuxSFTPChildDrain: Equatable, Sendable {
    case clean
    case dirty

    init(closeResult: Result<Void, Error>) {
        switch closeResult {
        case .success:
            self = .clean
        case .failure:
            self = .dirty
        }
    }
}

actor RemuxSessionSFTPChildScope {
    struct Registration: Sendable {
        let id: UUID
        let rootChannel: Channel
    }

    private enum State {
        case waiting
        case active(Channel)
        case closed
    }

    private enum Operation {
        case opening
        case open(RemuxSFTPLeaseTeardown)
    }

    private var state = State.waiting
    private var operations: [UUID: Operation] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var invalidateRootForReuse: (@Sendable () async -> Void)?
    private var childDrain = RemuxSFTPChildDrain.clean
    private var didInvalidateRootForReuse = false

    func activate(
        rootChannel: Channel,
        invalidateRootForReuse: @escaping @Sendable () async -> Void = {}
    ) throws {
        guard case .waiting = state else {
            throw RemuxSFTPClientError.sessionUnavailable
        }
        self.invalidateRootForReuse = invalidateRootForReuse
        state = .active(rootChannel)
    }

    func begin() throws -> Registration {
        guard case .active(let rootChannel) = state else {
            throw RemuxSFTPClientError.sessionUnavailable
        }
        let registration = Registration(id: UUID(), rootChannel: rootChannel)
        operations[registration.id] = .opening
        return registration
    }

    func register(
        _ teardown: RemuxSFTPLeaseTeardown,
        for registration: Registration
    ) -> Bool {
        guard case .active = state,
              case .opening? = operations[registration.id]
        else { return false }
        operations[registration.id] = .open(teardown)
        return true
    }

    func finish(
        _ registration: Registration,
        childDrain: RemuxSFTPChildDrain = .clean
    ) async {
        await finish(registration.id, childDrain: childDrain)
    }

    func close() async -> RemuxSFTPChildDrain {
        state = .closed

        let activeChildren: [(UUID, RemuxSFTPLeaseTeardown)] = operations.compactMap {
            id, operation in
            guard case .open(let teardown) = operation else { return nil }
            return (id, teardown)
        }
        for (_, teardown) in activeChildren {
            await teardown.invalidate(reason: .sessionUnavailable)
        }
        for (id, teardown) in activeChildren {
            let closeResult = await teardown.childCloseResult()
            await finish(
                id,
                childDrain: RemuxSFTPChildDrain(closeResult: closeResult)
            )
        }

        if !operations.isEmpty {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }
        return childDrain
    }

    private func finish(
        _ id: UUID,
        childDrain: RemuxSFTPChildDrain
    ) async {
        guard operations[id] != nil else { return }
        await record(childDrain)
        operations.removeValue(forKey: id)
        guard operations.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func record(_ drain: RemuxSFTPChildDrain) async {
        guard drain == .dirty else { return }
        childDrain = .dirty
        guard !didInvalidateRootForReuse,
              let invalidateRootForReuse
        else { return }

        didInvalidateRootForReuse = true
        await invalidateRootForReuse()
    }
}

struct RemuxSessionCitadelSFTPClientProvider: RemuxSFTPClientProvider {
    private let provider: RemuxShortLivedSFTPClientProvider<RemuxCitadelSFTPClient>

    init(
        scope: RemuxSessionSFTPChildScope,
        hostDescription: String,
        operationTimeout: TimeAmount,
        chunkSize: Int = 4 * 1024 * 1024
    ) {
        self.provider = RemuxShortLivedSFTPClientProvider(
            openLease: {
                try await Self.openLease(
                    scope: scope,
                    hostDescription: hostDescription,
                    operationTimeout: operationTimeout,
                    chunkSize: chunkSize
                )
            },
            closeFailureHandler: { error in
                NSLog("Remux session SFTP child close failed: %@", String(describing: error))
            }
        )
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (RemuxCitadelSFTPClient) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await provider.withClient(operation)
    }

    func openClientLease() async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        try await provider.openClientLease()
    }

    private static func openLease(
        scope: RemuxSessionSFTPChildScope,
        hostDescription: String,
        operationTimeout: TimeAmount,
        chunkSize: Int
    ) async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        let registration = try await scope.begin()
        do {
#if !REMUX_FILE_PROVIDER_EXTENSION
            let startedAt = GhosttyRuntimeTrace.latencyEnabled
                ? GhosttyRuntimeTrace.nowNanos()
                : nil
            GhosttyRuntimeTrace.latency(
                "sftp.open begin host=\(hostDescription) source=session"
            )
#endif

            // Citadel bounds subsystem negotiation internally. Await the raw
            // open so shutdown cannot release a shared root while a child is
            // still being created on it.
            let sftp = try await SFTPClient.open(
                overAuthenticatedSSHChannel: registration.rootChannel
            )
#if !REMUX_FILE_PROVIDER_EXTENSION
            if let startedAt {
                GhosttyRuntimeTrace.latency(
                    "sftp.open end host=\(hostDescription) source=session elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
                )
            }
#endif

            let teardown = RemuxSFTPLeaseTeardown(
                closeBorrowedChild: {
                    try await RemuxSFTPTimeout.run(
                        timeout: operationTimeout,
                        operation: {
                            try await sftp.close()
                        }
                    )
                }
            )
            guard await scope.register(teardown, for: registration) else {
                await teardown.invalidate(reason: .sessionUnavailable)
                let childCloseResult = await teardown.childCloseResult()
                await scope.finish(
                    registration,
                    childDrain: RemuxSFTPChildDrain(closeResult: childCloseResult)
                )
                throw RemuxSFTPClientError.sessionUnavailable
            }

            let client = RemuxCitadelSFTPClient(
                sftp: sftp,
                chunkSize: chunkSize,
                operationTimeout: operationTimeout,
                leaseState: teardown
            )
            return RemuxSFTPClientLease(
                client: client,
                close: {
                    let closeResult: Result<Void, Error>
                    do {
                        try await teardown.close()
                        closeResult = .success(())
                    } catch {
                        closeResult = .failure(error)
                    }

                    let childCloseResult = await teardown.childCloseResult()
                    await scope.finish(
                        registration,
                        childDrain: RemuxSFTPChildDrain(closeResult: childCloseResult)
                    )
                    try closeResult.get()
                }
            )
        } catch {
            await scope.finish(registration)
            throw error
        }
    }
}

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

    private static func openLease(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration,
        operationTimeout: TimeAmount,
        chunkSize: Int
    ) async throws -> RemuxSFTPClientLease<RemuxCitadelSFTPClient> {
        let trace = RemuxTransportStartupTrace(flowID: nil)
        let preparedRoot = await sshRootService.preparedRoot(
            for: rootKey,
            configuration: rootConfiguration,
            trace: trace
        )

        let sshRoot: RemuxSSHRoot
        do {
            sshRoot = try await trace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }

        let claimedRoot: RemuxSSHClaimedRoot
        do {
            claimedRoot = try await preparedRoot.claim(sshRoot, trace: trace)
        } catch {
            await preparedRoot.cancelAndCleanup()
            throw error
        }

        do {
#if !REMUX_FILE_PROVIDER_EXTENSION
            let sftpOpenStartedAt = GhosttyRuntimeTrace.latencyEnabled ? GhosttyRuntimeTrace.nowNanos() : nil
            GhosttyRuntimeTrace.latency("sftp.open begin host=\(rootConfiguration.host):\(rootConfiguration.port)")
#endif
            let sftp = try await RemuxSFTPTimeout.run(
                timeout: operationTimeout,
                operation: {
                    try await SFTPClient.open(overAuthenticatedSSHChannel: claimedRoot.sshRoot.rootChannel)
                },
                cleanupLateSuccess: { sftp in
                    do {
                        try await sftp.close()
                    } catch {
                        NSLog("Remux Citadel SFTP late open close failed: %@", String(describing: error))
                    }
                }
            )
#if !REMUX_FILE_PROVIDER_EXTENSION
            if let sftpOpenStartedAt {
                GhosttyRuntimeTrace.latency(
                    "sftp.open end host=\(rootConfiguration.host):\(rootConfiguration.port) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: sftpOpenStartedAt))"
                )
            }
#endif
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
