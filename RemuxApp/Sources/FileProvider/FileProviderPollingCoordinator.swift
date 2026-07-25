import Foundation

actor FileProviderPollingCoordinator {
    private struct InFlight {
        let id: UUID
        let directory: FileProviderRemotePath
        let task: Task<[FileProviderRemoteItem], Error>
        var waiterIDs: Set<UUID>
    }

    private var inFlight: InFlight?

    func refresh(
        directory: FileProviderRemotePath,
        operation: @escaping @Sendable () async throws -> [FileProviderRemoteItem]
    ) async throws -> [FileProviderRemoteItem] {
        try Task.checkCancellation()
        let waiterID = UUID()

        if var inFlight {
            if inFlight.directory == directory {
                inFlight.waiterIDs.insert(waiterID)
                self.inFlight = inFlight
                return try await waitForRefresh(inFlight, waiterID: waiterID)
            }

            _ = try? await inFlight.task.value
            clearInFlight(id: inFlight.id)
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
            waiterIDs: [waiterID]
        )
        self.inFlight = inFlight
        return try await waitForRefresh(inFlight, waiterID: waiterID)
    }

    private func clearInFlight(id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }

    private func waitForRefresh(
        _ inFlight: InFlight,
        waiterID: UUID
    ) async throws -> [FileProviderRemoteItem] {
        do {
            let items = try await withTaskCancellationHandler {
                try await inFlight.task.value
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        inFlightID: inFlight.id,
                        waiterID: waiterID
                    )
                }
            }
            clearInFlight(id: inFlight.id)
            try Task.checkCancellation()
            return items
        } catch {
            clearInFlight(id: inFlight.id)
            throw error
        }
    }

    private func cancelWaiter(inFlightID: UUID, waiterID: UUID) {
        guard var inFlight,
              inFlight.id == inFlightID,
              inFlight.waiterIDs.remove(waiterID) != nil
        else {
            return
        }
        self.inFlight = inFlight
        if inFlight.waiterIDs.isEmpty {
            inFlight.task.cancel()
        }
    }
}
