import FileProvider
import Foundation

struct FileProviderPollingRefresh: Sendable {
    let items: [FileProviderRemoteItem]
    let anchor: NSFileProviderSyncAnchor
    let delta: FileProviderSnapshotDelta
}

actor FileProviderPollingCoordinator {
    private struct InFlight {
        let id: UUID
        let directory: FileProviderRemotePath
        let task: Task<FileProviderPollingRefresh, Error>
        var refreshWaiters: [
            UUID: CheckedContinuation<FileProviderPollingRefresh, Error>
        ]
        var turnWaiters: [UUID: CheckedContinuation<Void, Error>]
    }

    private var inFlight: InFlight?

    func refresh(
        directory: FileProviderRemotePath,
        operation: @escaping @Sendable () async throws -> FileProviderPollingRefresh
    ) async throws -> FileProviderPollingRefresh {
        try Task.checkCancellation()
        let waiterID = UUID()

        if let inFlight {
            if inFlight.directory == directory {
                return try await waitForRefresh(
                    inFlightID: inFlight.id,
                    waiterID: waiterID
                )
            }

            try await waitForTurn(
                inFlightID: inFlight.id,
                waiterID: waiterID
            )
            try Task.checkCancellation()
            return try await refresh(directory: directory, operation: operation)
        }

        let id = UUID()
        let task = Task {
            try await operation()
        }
        let inFlight = InFlight(
            id: id,
            directory: directory,
            task: task,
            refreshWaiters: [:],
            turnWaiters: [:]
        )
        self.inFlight = inFlight
        Task {
            let result = await task.result
            completeRefresh(inFlightID: id, result: result)
        }
        return try await waitForRefresh(
            inFlightID: id,
            waiterID: waiterID
        )
    }

    private func waitForRefresh(
        inFlightID: UUID,
        waiterID: UUID
    ) async throws -> FileProviderPollingRefresh {
        let refresh: FileProviderPollingRefresh = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard var inFlight,
                      inFlight.id == inFlightID
                else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                inFlight.refreshWaiters[waiterID] = continuation
                self.inFlight = inFlight
            }
        } onCancel: {
            Task {
                await self.cancelRefreshWaiter(
                    inFlightID: inFlightID,
                    waiterID: waiterID
                )
            }
        }
        try Task.checkCancellation()
        return refresh
    }

    private func waitForTurn(
        inFlightID: UUID,
        waiterID: UUID
    ) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard var inFlight,
                      inFlight.id == inFlightID
                else {
                    continuation.resume()
                    return
                }

                inFlight.turnWaiters[waiterID] = continuation
                self.inFlight = inFlight
            }
        } onCancel: {
            Task {
                await self.cancelTurnWaiter(
                    inFlightID: inFlightID,
                    waiterID: waiterID
                )
            }
        }
        try Task.checkCancellation()
    }

    private func cancelRefreshWaiter(inFlightID: UUID, waiterID: UUID) {
        guard var inFlight,
              inFlight.id == inFlightID,
              let continuation = inFlight.refreshWaiters.removeValue(
                forKey: waiterID
              )
        else {
            return
        }
        self.inFlight = inFlight
        continuation.resume(throwing: CancellationError())
        if inFlight.refreshWaiters.isEmpty {
            inFlight.task.cancel()
        }
    }

    private func cancelTurnWaiter(inFlightID: UUID, waiterID: UUID) {
        guard var inFlight,
              inFlight.id == inFlightID,
              let continuation = inFlight.turnWaiters.removeValue(
                forKey: waiterID
              )
        else {
            return
        }
        self.inFlight = inFlight
        continuation.resume(throwing: CancellationError())
    }

    private func completeRefresh(
        inFlightID: UUID,
        result: Result<FileProviderPollingRefresh, Error>
    ) {
        guard let inFlight,
              inFlight.id == inFlightID
        else {
            return
        }

        self.inFlight = nil
        inFlight.refreshWaiters.values.forEach {
            $0.resume(with: result)
        }
        inFlight.turnWaiters.values.forEach {
            $0.resume()
        }
    }
}
