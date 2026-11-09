import Foundation
import NIOCore
import Synchronization

/// Runs an operation against a deadline. At the deadline the caller's `onTimeout` runs, then the call fails with
/// `timeoutError`; an operation that still succeeds afterwards is handed to `cleanupLateSuccess`, so a late
/// channel or handle is never leaked. With `extendWhile`, the deadline is about silence rather than duration: each
/// time `timeout` passes, the wait goes on for another `timeout` if `extendWhile` reports progress since the window
/// began (it gets the window's start).
enum RemuxOperationTimeout {
    static func run<Value: Sendable>(
        timeout: TimeAmount,
        timeoutError: Error,
        extendWhile isMakingProgress: (@Sendable (_ windowStart: NIODeadline) -> Bool)? = nil,
        operation: @escaping @Sendable () async throws -> Value,
        onTimeout: @escaping @Sendable () async -> Void = {},
        cleanupLateSuccess: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        let gate = RemuxOperationTimeoutGate<Value>(timeoutError: timeoutError)
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
                        var windowStart = NIODeadline.now()
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        while let isMakingProgress, isMakingProgress(windowStart) {
                            windowStart = .now()
                            try await Task.sleep(nanoseconds: timeoutNanos)
                        }
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

/// When something was last heard (bytes, an answer), for an `extendWhile` that keeps a deadline going while it is.
final class RemuxLastActivity: Sendable {
    private let last = Mutex(NIODeadline.now())

    func record() {
        last.withLock { $0 = .now() }
    }

    func hasRecorded(since start: NIODeadline) -> Bool {
        last.withLock { $0 > start }
    }
}

final class RemuxOperationTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let timeoutError: Error
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var isFinished = false

    init(timeoutError: Error) {
        self.timeoutError = timeoutError
    }

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
        let result = Result<Value, Error>.failure(timeoutError)
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
