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
    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async
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
        let items = try await coordinator.refresh(directory: directory) {
            try await self.service.list(directory: self.directory)
        }
        let record = try await snapshots.record(directory: directory, items: items)
        return FileProviderEnumerationPage(
            items: items,
            nextPage: nil,
            anchor: record.anchor
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
        let items = try await coordinator.refresh(directory: directory) {
            try await self.service.list(directory: self.directory)
        }
        let record = try await snapshots.record(directory: directory, items: items)
        guard !record.delta.updated.isEmpty || !record.delta.deleted.isEmpty else {
            return
        }

        let directoryIdentifier = FileProviderItemIdentifierCodec()
            .identifier(for: directory)
        await signaler.signalEnumerator(for: directoryIdentifier)
        await signaler.signalEnumerator(for: .workingSet)
    }
}
