import Foundation
import NIO

enum RemuxSFTPClientError: LocalizedError, Equatable, Sendable {
    case operationTimedOut
    case sessionUnavailable
    case invalidReadLength(Int)
    case oversizedReadResult(requested: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .operationTimedOut:
            return "The remote file operation timed out."
        case .sessionUnavailable:
            return "The terminal session is no longer available."
        case .invalidReadLength:
            return "The remote file read length is invalid."
        case .oversizedReadResult:
            return "The remote server returned more file data than requested."
        }
    }
}

struct RemuxSFTPFileMetadata: Equatable, Sendable {
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?
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
    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue
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
    private let releaseRoot: @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
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
        await rootReleaseTaskIfNeeded(disposition: .invalidated).value
    }

    func close() async throws {
        if invalidationError != nil {
            await rootReleaseTaskIfNeeded(disposition: .invalidated).value
            return
        }

        let childCloseResult = await childCloseTaskIfNeeded().value
        isBestEffortCloseObserved = true
        if invalidationError != nil {
            await rootReleaseTaskIfNeeded(disposition: .invalidated).value
            return
        }

        switch childCloseResult {
        case .success:
            await rootReleaseTaskIfNeeded(disposition: .reusable).value
        case .failure(let error):
            invalidationError = .operationTimedOut
            await rootReleaseTaskIfNeeded(disposition: .invalidated).value
            throw error
        }
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
    ) -> Task<Void, Never> {
        if let rootReleaseTask {
            return rootReleaseTask
        }

        let releaseRoot = releaseRoot
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

/// SFTP operations against a deadline, failing with `RemuxSFTPClientError.operationTimedOut`.
enum RemuxSFTPTimeout {
    static func run<Value: Sendable>(
        timeout: TimeAmount,
        operation: @escaping @Sendable () async throws -> Value,
        onTimeout: @escaping @Sendable () async -> Void = {},
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        try await RemuxOperationTimeout.run(
            timeout: timeout,
            timeoutError: RemuxSFTPClientError.operationTimedOut,
            operation: operation,
            onTimeout: onTimeout,
            cleanupLateSuccess: cleanupLateSuccess
        )
    }
}
