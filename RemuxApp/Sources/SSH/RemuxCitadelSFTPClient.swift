@preconcurrency import Citadel
import Foundation
import NIO

struct RemuxCitadelSFTPAttributes: Sendable {
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?

    init(
        size: UInt64?,
        permissions: UInt32?,
        modificationDate: Date?
    ) {
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }

    init(_ attributes: SFTPFileAttributes) {
        self.init(
            size: attributes.size,
            permissions: attributes.permissions,
            modificationDate: attributes.accessModificationTime?.modificationTime
        )
    }
}

struct RemuxCitadelSFTPDirectoryComponent: Sendable {
    let filename: String
    let attributes: RemuxCitadelSFTPAttributes
}

struct RemuxCitadelSFTPDirectoryResponse: Sendable {
    let components: [RemuxCitadelSFTPDirectoryComponent]
}

protocol RemuxCitadelSFTPFile: Sendable {
    func readData(from offset: UInt64, length: UInt32) async throws -> Data
    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) async throws
    func close() async throws
}

protocol RemuxCitadelSFTPConnection: Sendable {
    func remuxRealPath(atPath path: String) async throws -> String
    func remuxListDirectory(
        atPath path: String
    ) async throws -> [RemuxCitadelSFTPDirectoryResponse]
    func remuxGetAttributes(atPath path: String) async throws -> RemuxCitadelSFTPAttributes
    func remuxOpenFileForReading(atPath path: String) async throws -> any RemuxCitadelSFTPFile
    func remuxOpenFileForWriting(atPath path: String) async throws -> any RemuxCitadelSFTPFile
    func remuxCreateDirectory(atPath path: String) async throws
    func remuxRename(from sourcePath: String, to destinationPath: String) async throws
    func remuxRemove(atPath path: String) async throws
    func remuxRemoveDirectory(atPath path: String) async throws
}

extension SFTPClient: RemuxCitadelSFTPConnection {
    func remuxRealPath(atPath path: String) async throws -> String {
        try await getRealPath(atPath: path)
    }

    func remuxListDirectory(
        atPath path: String
    ) async throws -> [RemuxCitadelSFTPDirectoryResponse] {
        try await listDirectory(atPath: path).map { response in
            RemuxCitadelSFTPDirectoryResponse(
                components: response.components.map { component in
                    RemuxCitadelSFTPDirectoryComponent(
                        filename: component.filename,
                        attributes: RemuxCitadelSFTPAttributes(component.attributes)
                    )
                }
            )
        }
    }

    func remuxGetAttributes(atPath path: String) async throws -> RemuxCitadelSFTPAttributes {
        RemuxCitadelSFTPAttributes(try await getAttributes(at: path))
    }

    func remuxOpenFileForReading(
        atPath path: String
    ) async throws -> any RemuxCitadelSFTPFile {
        RemuxCitadelSFTPFileBox(
            file: try await openFile(filePath: path, flags: .read)
        )
    }

    func remuxOpenFileForWriting(
        atPath path: String
    ) async throws -> any RemuxCitadelSFTPFile {
        RemuxCitadelSFTPFileBox(
            file: try await openFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            )
        )
    }

    func remuxCreateDirectory(atPath path: String) async throws {
        try await createDirectory(atPath: path)
    }

    func remuxRename(from sourcePath: String, to destinationPath: String) async throws {
        try await rename(at: sourcePath, to: destinationPath)
    }

    func remuxRemove(atPath path: String) async throws {
        try await remove(at: path)
    }

    func remuxRemoveDirectory(atPath path: String) async throws {
        try await rmdir(at: path)
    }
}

struct RemuxCitadelSFTPClient: RemuxSFTPFileProviderClient, RemuxSFTPReadOnlyClient, RemuxSFTPUploadClient {
    private static let pipelinedWriteMaxInFlight = 64

    private let connection: any RemuxCitadelSFTPConnection
    private let chunkSize: Int
    private let operationTimeout: TimeAmount
    private let leaseState: RemuxSFTPLeaseTeardown

    fileprivate init(
        sftp: SFTPClient,
        chunkSize: Int = 4 * 1024 * 1024,
        operationTimeout: TimeAmount = .seconds(15),
        leaseState: RemuxSFTPLeaseTeardown
    ) {
        self.init(
            connection: sftp,
            chunkSize: chunkSize,
            operationTimeout: operationTimeout,
            leaseState: leaseState
        )
    }

    init(
        connection: any RemuxCitadelSFTPConnection,
        chunkSize: Int = 4 * 1024 * 1024,
        operationTimeout: TimeAmount = .seconds(15),
        leaseState: RemuxSFTPLeaseTeardown
    ) {
        self.connection = connection
        self.chunkSize = chunkSize
        self.operationTimeout = operationTimeout
        self.leaseState = leaseState
    }

    func realPath(atPath path: String) async throws -> String {
        try await withOperationTimeout {
            try await connection.remuxRealPath(atPath: path)
        }
    }

    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry] {
        do {
            let responses = try await withOperationTimeout {
                try await connection.remuxListDirectory(atPath: path)
            }
            return responses
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    RemuxSFTPDirectoryEntry(
                        name: component.filename,
                        metadata: metadata(from: component.attributes)
                    )
                }
        } catch {
            throw normalizedReadError(error, path: path)
        }
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        do {
            return metadata(from: try await getAttributes(at: path))
        } catch {
            throw normalizedReadError(error, path: path)
        }
    }

    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        let parentPath = (path as NSString).deletingLastPathComponent
        let directoryPath = parentPath.isEmpty ? "." : parentPath
        let basename = (path as NSString).lastPathComponent
        guard !basename.isEmpty else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        guard let entry = try await listDirectory(atPath: directoryPath)
            .first(where: { $0.name == basename })
        else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return entry.metadata
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let remoteFile: any RemuxCitadelSFTPFile
        do {
            remoteFile = try await openRemoteFile(at: path, mode: .read)
        } catch {
            throw normalizedReadError(error, path: path)
        }
        let readableFile = RemuxSFTPReadableFile { offset, length in
            do {
                return try await withOperationTimeout {
                    try await remoteFile.readData(from: offset, length: length)
                }
            } catch {
                throw normalizedReadError(error, path: path)
            }
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
                    try await connection.remuxCreateDirectory(atPath: path)
                }
            } catch {
                if try await exists(atPath: path) {
                    return
                }
                throw error
            }
        }
    }

    func createDirectory(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await connection.remuxCreateDirectory(atPath: path)
            }
        } catch {
            throw normalizedWriteError(error)
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

        let remoteFile: any RemuxCitadelSFTPFile
        do {
            remoteFile = try await openRemoteFile(at: remotePath, mode: .write)
        } catch {
            throw normalizedWriteError(error)
        }

        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()

                let data = try localFile.read(upToCount: chunkSize) ?? Data()
                guard !data.isEmpty else { break }

                let writeOffset = offset
                try await withOperationTimeout {
                    try await remoteFile.writeDataPipelined(
                        data,
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
            throw normalizedWriteError(error)
        }
    }

    func renameFile(from temporaryPath: String, to finalPath: String) async throws {
        try await renameItem(from: temporaryPath, to: finalPath)
    }

    func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        do {
            try await withOperationTimeout {
                try await connection.remuxRename(
                    from: sourcePath,
                    to: destinationPath
                )
            }
        } catch {
            throw normalizedWriteError(error)
        }
    }

    func removeFile(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await connection.remuxRemove(atPath: path)
            }
        } catch {
            throw normalizedWriteError(error)
        }
    }

    func removeEmptyDirectory(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await connection.remuxRemoveDirectory(atPath: path)
            }
        } catch {
            throw normalizedWriteError(error)
        }
    }

    func removeFileIfExists(atPath path: String) async throws {
        do {
            try await withOperationTimeout {
                try await connection.remuxRemove(atPath: path)
            }
        } catch where isNoSuchFile(error) {
            return
        }
    }

    private func openRemoteFile(
        at remotePath: String,
        mode: RemuxCitadelSFTPOpenMode
    ) async throws -> any RemuxCitadelSFTPFile {
        try await withOperationTimeout(
            operation: {
                switch mode {
                case .read:
                    return try await connection.remuxOpenFileForReading(
                        atPath: remotePath
                    )
                case .write:
                    return try await connection.remuxOpenFileForWriting(
                        atPath: remotePath
                    )
                }
            },
            cleanupLateSuccess: { file in
                do {
                    try await file.close()
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

    private func closeRemoteFile(_ file: any RemuxCitadelSFTPFile) async throws {
        try await withOperationTimeout {
            try await file.close()
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

    private func getAttributes(at path: String) async throws -> RemuxCitadelSFTPAttributes {
        try await withOperationTimeout {
            try await connection.remuxGetAttributes(atPath: path)
        }
    }

    private func metadata(
        from attributes: RemuxCitadelSFTPAttributes
    ) -> RemuxSFTPFileMetadata {
        RemuxSFTPFileMetadata(
            size: attributes.size,
            permissions: attributes.permissions,
            modificationDate: attributes.modificationDate
        )
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
        if case .noSuchFile = error as? RemuxSFTPClientError {
            return true
        }
        guard let status = error as? SFTPMessage.Status else {
            return false
        }
        return status.errorCode == .noSuchFile
    }

    private func normalizedReadError(_ error: Error, path: String) -> Error {
        isNoSuchFile(error) ? RemuxSFTPClientError.noSuchFile(path) : error
    }

    static func normalizedWriteError(for statusCode: SFTPStatusCode) -> RemuxSFTPClientError? {
        switch statusCode {
        case .permissionDenied:
            return .permissionDenied
        case .failure:
            return .unsupportedMutation
        default:
            return nil
        }
    }

    private func normalizedWriteError(_ error: Error) -> Error {
        guard case .errorStatus(let status) = error as? SFTPError,
              let normalizedError = Self.normalizedWriteError(for: status.errorCode)
        else {
            return error
        }
        return normalizedError
    }
}

private enum RemuxCitadelSFTPOpenMode: Sendable {
    case read
    case write
}

private final class RemuxCitadelSFTPFileBox: RemuxCitadelSFTPFile, @unchecked Sendable {
    private let file: SFTPFile

    init(file: SFTPFile) {
        self.file = file
    }

    func readData(from offset: UInt64, length: UInt32) async throws -> Data {
        let buffer = try await file.read(from: offset, length: length)
        return Data(buffer.readableBytesView)
    }

    func writeDataPipelined(
        _ data: Data,
        at offset: UInt64,
        maxInFlight: Int
    ) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await file.writePipelined(
            buffer,
            at: offset,
            maxInFlight: maxInFlight
        )
    }

    func close() async throws {
        try await file.close()
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
