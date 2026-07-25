import Foundation

final class FileProviderRequestController: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [UUID: FileProviderRequestTask] = [:]
    private var invalidatedRequests: [FileProviderRequestTask]?
    private var isInvalidated = false

    func perform<Value: Sendable>(
        errorMapper: @escaping @Sendable (Error) -> NSError = {
            FileProviderErrorMapper.map($0)
        },
        operation: @escaping @Sendable () async throws -> Value,
        discardResult: @escaping @Sendable (Value) -> Void = { _ in },
        completion: @escaping @Sendable (Result<Value, NSError>) -> Void
    ) -> Progress {
        perform(
            errorMapper: errorMapper,
            progressOperation: { _ in
                try await operation()
            },
            discardResult: discardResult,
            completion: completion
        )
    }

    func perform<Value: Sendable>(
        errorMapper: @escaping @Sendable (Error) -> NSError = {
            FileProviderErrorMapper.map($0)
        },
        progressOperation: @escaping @Sendable (Progress) async throws -> Value,
        discardResult: @escaping @Sendable (Value) -> Void = { _ in },
        completion: @escaping @Sendable (Result<Value, NSError>) -> Void
    ) -> Progress {
        let requestID = UUID()
        let request: FileProviderRequestTask? = lock.withLock {
            guard !isInvalidated else { return nil }
            let request = FileProviderRequestTask()
            requests[requestID] = request
            return request
        }
        guard let request else {
            let progress = Progress(totalUnitCount: 1)
            progress.isCancellable = false
            completion(.failure(errorMapper(CancellationError())))
            progress.completedUnitCount = 1
            return progress
        }

        let progress = Progress(totalUnitCount: -1)
        progress.isCancellable = true
        progress.cancellationHandler = {
            request.cancel()
        }

        let task = Task {
            let result: Result<Value, NSError>
            do {
                try Task.checkCancellation()
                let value = try await progressOperation(progress)
                do {
                    try Task.checkCancellation()
                } catch {
                    discardResult(value)
                    throw error
                }
                result = .success(value)
            } catch {
                result = .failure(errorMapper(error))
            }

            completion(result)
            request.finish()
            self.remove(requestID)
        }
        request.install(task)
        return progress
    }

    func invalidate(
        onDrained: (@Sendable () async -> Void)? = nil
    ) {
        let requests: [FileProviderRequestTask]? = lock.withLock {
            guard !isInvalidated else { return nil }
            isInvalidated = true
            let requests = Array(self.requests.values)
            self.requests.removeAll()
            invalidatedRequests = requests
            return requests
        }
        guard let requests else { return }

        requests.forEach { $0.cancel() }
        guard let onDrained else { return }

        Task {
            await self.waitUntilInvalidated()
            await onDrained()
        }
    }

    func waitUntilInvalidated() async {
        let requests = lock.withLock {
            invalidatedRequests ?? []
        }
        for request in requests {
            await request.waitUntilFinished()
        }
    }

    private func remove(_ requestID: UUID) {
        _ = lock.withLock {
            requests.removeValue(forKey: requestID)
        }
    }
}

private final class FileProviderRequestTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false
    private var isFinished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func install(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func finish() {
        let waiters = lock.withLock {
            task = nil
            isFinished = true
            let waiters = finishWaiters
            finishWaiters.removeAll()
            return waiters
        }
        waiters.forEach { waiter in
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !isFinished else { return true }
                finishWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}
