import FileProvider
import Foundation

struct FileProviderPollingRefresh: Sendable {
    let items: [FileProviderIdentifiedItem]
    let anchor: NSFileProviderSyncAnchor
    let delta: FileProviderSnapshotDelta
}

actor FileProviderDomainOperationCoordinator {
    private enum OperationKind: Equatable {
        case refresh(FileProviderRemotePath)
        case mutation
    }

    private struct ActiveOperation {
        let id: UUID
        let kind: OperationKind
        let task: Task<Void, Never>
        var isCancelling: Bool
        var refreshWaiters: [
            UUID: CheckedContinuation<FileProviderPollingRefresh, Error>
        ]
    }

    private enum PendingOperation {
        case refresh(
            id: UUID,
            directory: FileProviderRemotePath,
            operation: @Sendable () async throws -> FileProviderPollingRefresh,
            continuation: CheckedContinuation<FileProviderPollingRefresh, Error>
        )
        case mutation(
            id: UUID,
            start: @Sendable () async -> Void,
            cancel: @Sendable () -> Void
        )

        var id: UUID {
            switch self {
            case .refresh(let id, _, _, _), .mutation(let id, _, _):
                id
            }
        }

        var kind: OperationKind {
            switch self {
            case .refresh(_, let directory, _, _):
                .refresh(directory)
            case .mutation:
                .mutation
            }
        }
    }

    private var active: ActiveOperation?
    private var pending: [PendingOperation] = []
    private var cancelledRequestIDs: Set<UUID> = []
#if DEBUG
    private var queuedRefreshWaiters: [
        FileProviderRemotePath: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var coalescedRefreshWaiters: [
        FileProviderRemotePath: [CheckedContinuation<Void, Never>]
    ] = [:]
#endif

    func performRefresh(
        directory: FileProviderRemotePath,
        operation: @escaping @Sendable () async throws -> FileProviderPollingRefresh
    ) async throws -> FileProviderPollingRefresh {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    submitRefresh(
                        id: id,
                        directory: directory,
                        operation: operation,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelRefresh(id: id)
            }
        }
    }

    func performMutation<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    submitMutation(
                        id: id,
                        operation: operation,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelMutation(id: id)
            }
        }
    }

    private func submitRefresh(
        id: UUID,
        directory: FileProviderRemotePath,
        operation: @escaping @Sendable () async throws -> FileProviderPollingRefresh,
        continuation: CheckedContinuation<FileProviderPollingRefresh, Error>
    ) {
        guard cancelledRequestIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }

        if case .refresh(let activeDirectory)? = active?.kind,
           activeDirectory == directory,
            active?.isCancelling == false,
           active?.refreshWaiters.isEmpty == false,
           !pending.contains(where: { $0.kind == .mutation }) {
            active?.refreshWaiters[id] = continuation
#if DEBUG
            notifyCoalescedRefreshWaiters(for: directory)
#endif
            return
        }

        let request = PendingOperation.refresh(
            id: id,
            directory: directory,
            operation: operation,
            continuation: continuation
        )
        if active == nil {
            start(request)
        } else {
            pending.append(request)
#if DEBUG
            notifyQueuedRefreshWaiters(for: directory)
#endif
        }
    }

    private func submitMutation<Value: Sendable>(
        id: UUID,
        operation: @escaping @Sendable () async throws -> Value,
        continuation: CheckedContinuation<Value, Error>
    ) {
        guard cancelledRequestIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }

        let request = PendingOperation.mutation(
            id: id,
            start: { [self] in
                do {
                    continuation.resume(returning: try await operation())
                } catch {
                    continuation.resume(throwing: error)
                }
                await completeMutation(id: id)
            },
            cancel: {
                continuation.resume(throwing: CancellationError())
            }
        )
        if active == nil {
            start(request)
        } else {
            pending.append(request)
        }
    }

    private func cancelRefresh(id: UUID) {
        if var active,
           let continuation = active.refreshWaiters.removeValue(forKey: id) {
            self.active = active
            continuation.resume(throwing: CancellationError())
            if active.refreshWaiters.isEmpty {
                active.isCancelling = true
                self.active = active
                active.task.cancel()
            }
            return
        }

        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            cancelledRequestIDs.insert(id)
            return
        }
        guard case .refresh(_, _, _, let continuation) = pending.remove(at: index) else {
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelMutation(id: UUID) {
        if active?.id == id {
            active?.task.cancel()
            return
        }

        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            cancelledRequestIDs.insert(id)
            return
        }
        guard case .mutation(_, _, let cancel) = pending.remove(at: index) else {
            return
        }
        cancel()
    }

    private func start(_ request: PendingOperation) {
        switch request {
        case .refresh(let id, let directory, let operation, let continuation):
            let task = Task { [self] in
                do {
                    let refresh = try await operation()
                    completeRefresh(id: id, result: .success(refresh))
                } catch {
                    completeRefresh(id: id, result: .failure(error))
                }
            }
            active = ActiveOperation(
                id: id,
                kind: .refresh(directory),
                task: task,
                isCancelling: false,
                refreshWaiters: [id: continuation]
            )
        case .mutation(let id, let operation, _):
            let task = Task {
                await operation()
            }
            active = ActiveOperation(
                id: id,
                kind: .mutation,
                task: task,
                isCancelling: false,
                refreshWaiters: [:]
            )
        }
    }

    private func completeRefresh(
        id: UUID,
        result: Result<FileProviderPollingRefresh, Error>
    ) {
        guard let active, active.id == id else { return }
        self.active = nil
        active.refreshWaiters.values.forEach { $0.resume(with: result) }
        startNext()
    }

    private func completeMutation(id: UUID) {
        guard let active, active.id == id else { return }
        self.active = nil
        startNext()
    }

    private func startNext() {
        guard !pending.isEmpty else { return }
        start(pending.removeFirst())
    }

#if DEBUG
    func waitUntilRefreshIsQueued(directory: FileProviderRemotePath) async {
        guard !pending.contains(where: {
            if case .refresh(_, let pendingDirectory, _, _) = $0 {
                return pendingDirectory == directory
            }
            return false
        }) else {
            return
        }
        await withCheckedContinuation {
            queuedRefreshWaiters[directory, default: []].append($0)
        }
    }

    func waitUntilRefreshIsCoalesced(directory: FileProviderRemotePath) async {
        guard case .refresh(let activeDirectory)? = active?.kind,
              activeDirectory == directory,
              active?.refreshWaiters.count ?? 0 > 1
        else {
            await withCheckedContinuation {
                coalescedRefreshWaiters[directory, default: []].append($0)
            }
            return
        }
    }

    private func notifyQueuedRefreshWaiters(for directory: FileProviderRemotePath) {
        queuedRefreshWaiters.removeValue(forKey: directory)?.forEach { $0.resume() }
    }

    private func notifyCoalescedRefreshWaiters(for directory: FileProviderRemotePath) {
        coalescedRefreshWaiters.removeValue(forKey: directory)?.forEach { $0.resume() }
    }
#endif
}
