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

enum FileProviderEnumeratorScope: Equatable, Sendable {
    case directory(FileProviderRemotePath)
    case workingSet
}

actor FileProviderEnumeratorCore {
    private let scope: FileProviderEnumeratorScope
    private let service: any FileProviderRemoteServicing
    private let snapshots: FileProviderSnapshotStore
    private let coordinator: FileProviderPollingCoordinator
    private let signaler: any FileProviderEnumeratorSignaling

    init(
        scope: FileProviderEnumeratorScope,
        service: any FileProviderRemoteServicing,
        snapshots: FileProviderSnapshotStore,
        coordinator: FileProviderPollingCoordinator,
        signaler: any FileProviderEnumeratorSignaling
    ) {
        self.scope = scope
        self.service = service
        self.snapshots = snapshots
        self.coordinator = coordinator
        self.signaler = signaler
    }

    func enumerateItems() async throws -> FileProviderEnumerationPage {
        switch scope {
        case .directory(let directory):
            let refresh = try await refresh(directory: directory)
            try Task.checkCancellation()
            return FileProviderEnumerationPage(
                items: refresh.items,
                nextPage: nil,
                anchor: refresh.anchor
            )
        case .workingSet:
            let snapshot = try await snapshots.workingSetSnapshot()
            try Task.checkCancellation()
            return FileProviderEnumerationPage(
                items: snapshot.items,
                nextPage: nil,
                anchor: snapshot.anchor
            )
        }
    }

    func currentSyncAnchor() async throws -> NSFileProviderSyncAnchor? {
        switch scope {
        case .directory:
            try await snapshots.currentAnchor()
        case .workingSet:
            try await snapshots.workingSetSnapshot().anchor
        }
    }

    func enumerateChanges(
        from anchor: NSFileProviderSyncAnchor
    ) async throws -> FileProviderEnumerationChanges {
        let changes: (
            anchor: NSFileProviderSyncAnchor,
            delta: FileProviderSnapshotDelta
        )
        switch scope {
        case .directory(let directory):
            changes = try await snapshots.delta(
                directory: directory,
                from: anchor
            )
        case .workingSet:
            changes = try await snapshots.workingSetDelta(from: anchor)
        }
        return FileProviderEnumerationChanges(
            updated: changes.delta.updated,
            deleted: changes.delta.deleted,
            moreComing: false,
            anchor: changes.anchor
        )
    }

    func refreshAndSignalChanges() async throws {
        if case .directory(let directory) = scope {
            _ = try await refresh(directory: directory)
        }
        try Task.checkCancellation()
        guard let pendingGeneration = try await snapshots
            .pendingWorkingSetSignalGeneration()
        else {
            return
        }

        try await signaler.signalEnumerator(for: .workingSet)
        try Task.checkCancellation()
        try await snapshots.acknowledgeWorkingSetSignal(
            generation: pendingGeneration
        )
    }

    private func refresh(
        directory: FileProviderRemotePath
    ) async throws -> FileProviderPollingRefresh {
        try await coordinator.refresh(directory: directory) {
            let items = try await self.service.list(directory: directory)
            try Task.checkCancellation()
            let record = try await self.snapshots.record(
                directory: directory,
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
