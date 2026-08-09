import Foundation
import NIO

enum RemuxSFTPClientError: LocalizedError, Equatable, Sendable {
    case operationTimedOut
    case sessionUnavailable
    case noSuchFile(String)
    case invalidReadLength(Int)
    case oversizedReadResult(requested: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .operationTimedOut:
            return "The remote file operation timed out."
        case .sessionUnavailable:
            return "The terminal session is no longer available."
        case .noSuchFile:
            return "The remote file does not exist."
        case .invalidReadLength:
            return "The remote file read length is invalid."
        case .oversizedReadResult:
            return "The remote server returned more file data than requested."
        }
    }
}

enum RemuxSFTPFileType: String, Codable, Sendable {
    case regular
    case directory
    case symbolicLink
    case other

    init(permissions: UInt32?) {
        let typeBits = permissions.map { $0 & 0o170000 }
        switch typeBits {
        case 0o100000:
            self = .regular
        case 0o040000:
            self = .directory
        case 0o120000:
            self = .symbolicLink
        default:
            self = .other
        }
    }
}

struct RemuxSFTPFileMetadata: Equatable, Sendable {
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?
    let type: RemuxSFTPFileType

    init(
        size: UInt64?,
        permissions: UInt32?,
        modificationDate: Date?,
        type: RemuxSFTPFileType? = nil
    ) {
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.type = type ?? RemuxSFTPFileType(permissions: permissions)
    }
}

struct RemuxSFTPDirectoryEntry: Equatable, Sendable {
    let name: String
    let metadata: RemuxSFTPFileMetadata
}

final class RemuxSFTPReadableFile {
    static let maximumChunkLength = 4 * 1024 * 1024

    private let readChunkHandler: @Sendable (UInt64, UInt32) async throws -> Data

    init(
        readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> Data
    ) {
        self.readChunkHandler = readChunk
    }

    func readChunk(from offset: UInt64, length: Int) async throws -> Data {
        guard (1...Self.maximumChunkLength).contains(length) else {
            throw RemuxSFTPClientError.invalidReadLength(length)
        }

        let data = try await readChunkHandler(offset, UInt32(length))
        guard data.count <= length else {
            throw RemuxSFTPClientError.oversizedReadResult(
                requested: length,
                actual: data.count
            )
        }
        return data
    }
}

protocol RemuxSFTPReadOnlyClient: Sendable {
    func realPath(atPath path: String) async throws -> String
    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry]
    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata
    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue

    func downloadFile(
        atPath remotePath: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
}

extension RemuxSFTPReadOnlyClient {
    func downloadFile(
        atPath remotePath: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        do {
            try Data().write(to: localURL, options: .atomic)
            let localFile = try FileHandle(forWritingTo: localURL)
            defer {
                try? localFile.close()
            }

            try await withFile(atPath: remotePath) { remoteFile in
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let data = try await remoteFile.readChunk(
                        from: offset,
                        length: RemuxSFTPReadableFile.maximumChunkLength
                    )
                    try Task.checkCancellation()
                    guard !data.isEmpty else { break }

                    try Task.checkCancellation()
                    try localFile.write(contentsOf: data)
                    try Task.checkCancellation()

                    offset += UInt64(data.count)
                    await progress(Int64(min(offset, UInt64(Int64.max))))
                    try Task.checkCancellation()
                }
            }
            try localFile.close()
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }
}

typealias RemuxSFTPFileUploadProgressHandler = @Sendable (Int64) async -> Void

protocol RemuxSFTPUploadClient: Sendable {
    func realPath(atPath path: String) async throws -> String
    func ensureDirectoryExists(atPath path: String) async throws
    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws
    func renameFile(from temporaryPath: String, to finalPath: String) async throws
    func removeFileIfExists(atPath path: String) async throws
}

protocol RemuxSFTPClientProvider: Sendable {
    associatedtype Client: Sendable

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (Client) async throws -> ReturnValue
    ) async throws -> ReturnValue
}

struct RemuxSFTPClientLease<Client: Sendable>: Sendable {
    let client: Client
    private let closeHandler: @Sendable () async throws -> Void

    init(
        client: Client,
        close: @escaping @Sendable () async throws -> Void
    ) {
        self.client = client
        self.closeHandler = close
    }

    func close() async throws {
        try await closeHandler()
    }
}

actor RemuxSFTPLeaseTeardown {
    private let closeChild: @Sendable () async throws -> Void
    private let releaseRoot: (@Sendable (RemuxSSHRootLeaseDisposition) async -> Void)?
    private var invalidationError: RemuxSFTPClientError?
    private var childCloseTask: Task<Result<Void, Error>, Never>?
    private var rootReleaseTask: Task<Void, Never>?
    private var isBestEffortCloseObserved = false

    init(
        closeChild: @escaping @Sendable () async throws -> Void,
        releaseRoot: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    ) {
        self.closeChild = closeChild
        self.releaseRoot = releaseRoot
    }

    init(
        closeBorrowedChild: @escaping @Sendable () async throws -> Void
    ) {
        self.closeChild = closeBorrowedChild
        self.releaseRoot = nil
    }

    func checkActive() throws {
        if let invalidationError {
            throw invalidationError
        }
    }

    func invalidate(
        reason: RemuxSFTPClientError = .operationTimedOut
    ) async {
        if invalidationError == nil {
            invalidationError = reason
        }
        let childCloseTask = childCloseTaskIfNeeded()
        observeBestEffortCloseIfNeeded(childCloseTask)
        if let rootReleaseTask = rootReleaseTaskIfNeeded(disposition: .invalidated) {
            await rootReleaseTask.value
        }
    }

    func close() async throws {
        if invalidationError != nil {
            if let task = rootReleaseTaskIfNeeded(disposition: .invalidated) {
                await task.value
            }
            return
        }

        let childCloseResult = await childCloseTaskIfNeeded().value
        isBestEffortCloseObserved = true
        if invalidationError != nil {
            if let task = rootReleaseTaskIfNeeded(disposition: .invalidated) {
                await task.value
            }
            return
        }

        switch childCloseResult {
        case .success:
            if let task = rootReleaseTaskIfNeeded(disposition: .reusable) {
                await task.value
            }
        case .failure(let error):
            invalidationError = .operationTimedOut
            if let task = rootReleaseTaskIfNeeded(disposition: .invalidated) {
                await task.value
            }
            throw error
        }
    }

    func childCloseResult() async -> Result<Void, Error> {
        await childCloseTaskIfNeeded().value
    }

    private func childCloseTaskIfNeeded() -> Task<Result<Void, Error>, Never> {
        if let childCloseTask {
            return childCloseTask
        }

        let closeChild = closeChild
        let task = Task<Result<Void, Error>, Never> {
            do {
                try await closeChild()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        childCloseTask = task
        return task
    }

    private func observeBestEffortCloseIfNeeded(
        _ task: Task<Result<Void, Error>, Never>
    ) {
        guard !isBestEffortCloseObserved else { return }
        isBestEffortCloseObserved = true

        Task {
            if case .failure(let error) = await task.value {
                NSLog(
                    "Remux SFTP child close after invalidation failed: %@",
                    String(describing: error)
                )
            }
        }
    }

    private func rootReleaseTaskIfNeeded(
        disposition: RemuxSSHRootLeaseDisposition
    ) -> Task<Void, Never>? {
        if let rootReleaseTask {
            return rootReleaseTask
        }

        guard let releaseRoot else { return nil }
        let task = Task {
            await releaseRoot(disposition)
        }
        rootReleaseTask = task
        return task
    }
}

struct RemuxShortLivedSFTPClientProvider<Client: Sendable>: RemuxSFTPClientProvider {
    let openLease: @Sendable () async throws -> RemuxSFTPClientLease<Client>
    let closeFailureHandler: @Sendable (Error) -> Void

    init(
        openLease: @escaping @Sendable () async throws -> RemuxSFTPClientLease<Client>,
        closeFailureHandler: @escaping @Sendable (Error) -> Void = { error in
            NSLog("Remux SFTP close failed: %@", String(describing: error))
        }
    ) {
        self.openLease = openLease
        self.closeFailureHandler = closeFailureHandler
    }

    func withClient<ReturnValue: Sendable>(
        _ operation: @Sendable (Client) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let lease = try await openClientLease()
        do {
            let result = try await operation(lease.client)
            await close(lease)
            return result
        } catch {
            await close(lease)
            throw error
        }
    }

    func openClientLease() async throws -> RemuxSFTPClientLease<Client> {
        try await openLease()
    }

    private func close(_ lease: RemuxSFTPClientLease<Client>) async {
        do {
            try await lease.close()
        } catch {
            closeFailureHandler(error)
        }
    }
}

final class RemuxSFTPTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pendingResult: Result<Value, Error>?
        lock.lock()
        if isFinished {
            pendingResult = self.pendingResult
        } else {
            self.continuation = continuation
            pendingResult = nil
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        let tasksToCancel: [Task<Void, Never>]
        lock.lock()
        if isFinished {
            tasksToCancel = tasks
        } else {
            self.tasks = tasks
            tasksToCancel = []
        }
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
    }

    @discardableResult
    func succeed(_ value: Value) -> Bool {
        finish(.success(value))
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        finish(.failure(error))
    }

    func cancel() {
        _ = fail(CancellationError())
    }

    func beginTimeout() -> Bool {
        let tasksToCancel: [Task<Void, Never>]

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }

        isFinished = true
        tasksToCancel = tasks
        tasks.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }
        return true
    }

    func finishTimeout() {
        let result = Result<Value, Error>.failure(
            RemuxSFTPClientError.operationTimedOut
        )
        let continuation: CheckedContinuation<Value, Error>?

        lock.lock()
        pendingResult = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    @discardableResult
    private func finish(_ result: Result<Value, Error>) -> Bool {
        let continuation: CheckedContinuation<Value, Error>?
        let tasksToCancel: [Task<Void, Never>]

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }

        isFinished = true
        pendingResult = result
        continuation = self.continuation
        self.continuation = nil
        tasksToCancel = tasks
        tasks.removeAll()
        lock.unlock()

        for task in tasksToCancel {
            task.cancel()
        }

        continuation?.resume(with: result)
        return true
    }
}

enum RemuxSFTPTimeout {
    static func run<Value: Sendable>(
        timeout: TimeAmount,
        operation: @escaping @Sendable () async throws -> Value,
        onTimeout: @escaping @Sendable () async -> Void = {},
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        let gate = RemuxSFTPTimeoutGate<Value>()
        let timeoutNanos = UInt64(clamping: timeout.nanoseconds)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        if !gate.succeed(value) {
                            await cleanupLateSuccess(value)
                        }
                    } catch {
                        _ = gate.fail(error)
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        if gate.beginTimeout() {
                            await onTimeout()
                            gate.finishTimeout()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        _ = gate.fail(error)
                    }
                }
                gate.setTasks([operationTask, timeoutTask])
            }
        } onCancel: {
            gate.cancel()
        }
    }
}
