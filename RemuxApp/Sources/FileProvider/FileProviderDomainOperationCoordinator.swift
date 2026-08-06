import Foundation

actor FileProviderDomainOperationCoordinator {
    private final class Request: Hashable, Sendable {
        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs === rhs
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }

    private struct Waiter {
        let request: Request
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeRequest: Request?
    private var waiters: [Waiter] = []
    private var registeredRequests: Set<Request> = []
    private var cancelledBeforeEnqueue: Set<Request> = []

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let request = Request()
        registeredRequests.insert(request)
        return try await withTaskCancellationHandler {
            defer { complete(request) }
            try await acquire(request)
            try Task.checkCancellation()
            return try await operation()
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func acquire(_ request: Request) async throws {
        guard registeredRequests.remove(request) != nil else {
            throw CancellationError()
        }
        guard cancelledBeforeEnqueue.remove(request) == nil else {
            throw CancellationError()
        }
        guard activeRequest != nil else {
            activeRequest = request
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(request: request, continuation: continuation))
        }
    }

    private func cancel(_ request: Request) {
        guard activeRequest !== request else { return }
        guard let index = waiters.firstIndex(where: { $0.request === request }) else {
            guard registeredRequests.contains(request) else { return }
            cancelledBeforeEnqueue.insert(request)
            return
        }
        waiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }

    private func complete(_ request: Request) {
        registeredRequests.remove(request)
        cancelledBeforeEnqueue.remove(request)
        release(request)
    }

    private func release(_ request: Request) {
        guard activeRequest === request else { return }
        guard !waiters.isEmpty else {
            activeRequest = nil
            return
        }
        let next = waiters.removeFirst()
        activeRequest = next.request
        next.continuation.resume()
    }
}
