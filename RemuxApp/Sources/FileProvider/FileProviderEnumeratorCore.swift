import FileProvider
import Foundation

struct FileProviderEnumerationPage: Sendable {
    let items: [FileProviderRemoteItem]
    let nextPage: NSFileProviderPage?
    let anchor: NSFileProviderSyncAnchor
}

struct FileProviderEnumerationChanges: Sendable {
    let updated: [FileProviderRemoteItem]
    let deleted: [NSFileProviderItemIdentifier]
    let moreComing: Bool
    let anchor: NSFileProviderSyncAnchor
}

protocol FileProviderEnumeratorSignaling: Sendable {
    func signalEnumerator(
        for identifier: NSFileProviderItemIdentifier
    ) async throws
}

actor FileProviderEnumeratorCore {
    private let directory: FileProviderRemotePath
    private let service: any FileProviderRemoteServicing
    private let snapshots: FileProviderSnapshotStore
    private let coordinator: FileProviderPollingCoordinator
    private let signaler: any FileProviderEnumeratorSignaling

    init(
        directory: FileProviderRemotePath,
        service: any FileProviderRemoteServicing,
        snapshots: FileProviderSnapshotStore,
        coordinator: FileProviderPollingCoordinator,
        signaler: any FileProviderEnumeratorSignaling
    ) {
        self.directory = directory
        self.service = service
        self.snapshots = snapshots
        self.coordinator = coordinator
        self.signaler = signaler
    }

    func enumerateItems() async throws -> FileProviderEnumerationPage {
        let refresh = try await refresh()
        try Task.checkCancellation()
        return FileProviderEnumerationPage(
            items: refresh.items,
            nextPage: nil,
            anchor: refresh.anchor
        )
    }

    func currentSyncAnchor() async throws -> NSFileProviderSyncAnchor? {
        try await snapshots.currentAnchor()
    }

    func enumerateChanges(
        from anchor: NSFileProviderSyncAnchor
    ) async throws -> FileProviderEnumerationChanges {
        let changes = try await snapshots.delta(directory: directory, from: anchor)
        return FileProviderEnumerationChanges(
            updated: changes.delta.updated,
            deleted: changes.delta.deleted,
            moreComing: false,
            anchor: changes.anchor
        )
    }

    func refreshAndSignalChanges() async throws {
        _ = try await refresh()
        try Task.checkCancellation()
        guard let pendingGeneration = try await snapshots
            .pendingSignalGeneration(for: directory)
        else {
            return
        }

        let directoryIdentifier = FileProviderItemIdentifierCodec()
            .identifier(for: directory)
        try await signaler.signalEnumerator(for: directoryIdentifier)
        try Task.checkCancellation()
        try await signaler.signalEnumerator(for: .workingSet)
        try await snapshots.acknowledgeSignals(
            for: directory,
            generation: pendingGeneration
        )
    }

    private func refresh() async throws -> FileProviderPollingRefresh {
        try await coordinator.refresh(directory: directory) {
            let items = try await self.service.list(directory: self.directory)
            try Task.checkCancellation()
            let record = try await self.snapshots.record(
                directory: self.directory,
                items: items
            )
            try Task.checkCancellation()
            return FileProviderPollingRefresh(
                items: items,
                anchor: record.anchor,
                delta: record.delta
            )
        }
    }
}
