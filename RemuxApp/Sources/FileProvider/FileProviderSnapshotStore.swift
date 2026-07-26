import FileProvider
import Foundation

struct FileProviderSnapshotDelta: Equatable, Sendable {
    let updated: [FileProviderIdentifiedItem]
    let deleted: [NSFileProviderItemIdentifier]
}

enum FileProviderSnapshotStoreError: Error, Equatable, Sendable {
    case syncAnchorExpired
    case generationExhausted
    case duplicatePath
    case itemIdentityNotFound
}

actor FileProviderSnapshotStore {
    private static let stateFilename = "snapshot-generations-v2.json"
    private static let namespaceByteCount = 16
    private static let generationByteCount = MemoryLayout<UInt64>.size

    private let stateURL: URL
    private let retainedGenerationCount: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let identifierCodec = FileProviderItemIdentifierCodec()
    private let identityGenerator: @Sendable () -> UUID

    init(
        rootURL: URL,
        retainedGenerationCount: Int = 8,
        fileManager: FileManager = .default,
        identityGenerator: @escaping @Sendable () -> UUID = UUID.init
    ) {
        precondition(retainedGenerationCount > 0)

        self.stateURL = rootURL.appendingPathComponent(Self.stateFilename)
        self.retainedGenerationCount = retainedGenerationCount
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.identityGenerator = identityGenerator
        encoder.outputFormatting = [.sortedKeys]
    }

    func record(
        directory: FileProviderRemotePath,
        items: [FileProviderRemoteItem]
    ) throws -> (
        anchor: NSFileProviderSyncAnchor,
        items: [FileProviderIdentifiedItem],
        delta: FileProviderSnapshotDelta
    ) {
        try Task.checkCancellation()
        var state = try loadState()
        try Task.checkCancellation()
        try validateUniquePaths(in: items)
        let items = items.sorted { $0.path.relative < $1.path.relative }
        let previousItems = state.generations.last?.items(for: directory) ?? []
        let previousRemoteItems = previousItems.map(\.remoteItem)

        if let latest = state.generations.last, items == previousRemoteItems {
            return (
                anchor: makeAnchor(namespace: state.namespace, generation: latest.generation),
                items: previousItems,
                delta: .init(updated: [], deleted: [])
            )
        }

        let hadPreviousGeneration = state.generations.last != nil
        let nextGeneration = try generation(after: state.generations.last?.generation)
        var directories = state.generations.last?.directories ?? []
        let previousByPath = Dictionary(
            uniqueKeysWithValues: previousItems.map { ($0.remoteItem.path, $0.identity) }
        )
        let identitiesByPath = Dictionary(
            uniqueKeysWithValues: directories
                .flatMap(\.items)
                .map { ($0.remoteItem.path, $0.identity) }
        )
        let identifiedItems = try items.map { remote in
            FileProviderIdentifiedItem(
                identity: previousByPath[remote.path] ?? .item(identityGenerator()),
                parentIdentity: try parentIdentity(
                    for: remote,
                    identitiesByPath: identitiesByPath
                ),
                remoteItem: remote
            )
        }
        if let index = directories.firstIndex(where: { $0.path == directory }) {
            directories[index] = PersistedDirectory(path: directory, items: identifiedItems)
        } else {
            directories.append(PersistedDirectory(path: directory, items: identifiedItems))
        }
        pruneTrackedSubtrees(
            from: &directories,
            previousItems: previousRemoteItems,
            currentItems: items
        )
        directories.sort { $0.path.relative < $1.path.relative }

        let latest = PersistedGeneration(
            generation: nextGeneration,
            directories: directories,
            receipt: nil
        )
        state.generations.append(latest)
        state.generations = Array(state.generations.suffix(retainedGenerationCount))
        let delta = makeDelta(from: previousItems, to: identifiedItems)
        if hadPreviousGeneration,
           !delta.updated.isEmpty || !delta.deleted.isEmpty
        {
            state.pendingSignals.removeAll {
                $0.directory == directory
            }
            state.pendingSignals.append(
                PersistedPendingSignal(
                    directory: directory,
                    generation: nextGeneration
                )
            )
            state.pendingSignals.sort {
                $0.directory.relative < $1.directory.relative
            }
        }
        try Task.checkCancellation()
        try save(state)

        return (
            anchor: makeAnchor(namespace: state.namespace, generation: nextGeneration),
            items: identifiedItems,
            delta: delta
        )
    }

    func commit(
        localMutation: FileProviderSnapshotLocalMutation
    ) throws -> (
        anchor: NSFileProviderSyncAnchor,
        items: [FileProviderIdentifiedItem],
        delta: FileProviderSnapshotDelta
    ) {
        try Task.checkCancellation()
        var state = try loadState()
        try Task.checkCancellation()
        var directories = state.generations.last?.directories ?? []
        let previousItems = try state.generations.last?.workingSetItems() ?? []

        pruneDeletedIdentities(
            localMutation.deletedIdentities,
            from: &directories
        )
        try apply(
            localMutation.relocations,
            to: &directories
        )
        _ = try workingSetItems(in: directories)
        try validateIdentityReservations(
            localMutation.identityReservations,
            in: directories
        )

        var identitiesByPath = Dictionary(
            uniqueKeysWithValues: directories
                .flatMap(\.items)
                .map { ($0.remoteItem.path, $0.identity) }
        )
        for reservation in localMutation.identityReservations {
            identitiesByPath[reservation.path] = reservation.identity
        }

        for refresh in localMutation.refreshedDirectories {
            try validateUniquePaths(in: refresh.items)
            let previousDirectoryItems = directories
                .first(where: { $0.path == refresh.directory })?
                .items
                .map(\.remoteItem) ?? []
            let identifiedItems = try refresh.items
                .sorted { $0.path.relative < $1.path.relative }
                .map { remote in
                    FileProviderIdentifiedItem(
                        identity: identitiesByPath[remote.path] ?? .item(identityGenerator()),
                        parentIdentity: try parentIdentity(
                            for: remote,
                            identitiesByPath: identitiesByPath
                        ),
                        remoteItem: remote
                    )
                }
            if let index = directories.firstIndex(where: { $0.path == refresh.directory }) {
                directories[index] = PersistedDirectory(
                    path: refresh.directory,
                    items: identifiedItems
                )
            } else {
                directories.append(PersistedDirectory(
                    path: refresh.directory,
                    items: identifiedItems
                ))
            }
            pruneTrackedSubtrees(
                from: &directories,
                previousItems: previousDirectoryItems,
                currentItems: refresh.items
            )
            for item in identifiedItems {
                identitiesByPath[item.remoteItem.path] = item.identity
            }
        }

        directories.sort { $0.path.relative < $1.path.relative }
        let items = try workingSetItems(in: directories)
        let delta = makeDelta(from: previousItems, to: items)
        let nextGeneration = try generation(after: state.generations.last?.generation)
        let latest = PersistedGeneration(
            generation: nextGeneration,
            directories: directories,
            receipt: localMutation.receipt
        )
        state.generations.append(latest)
        state.generations = Array(state.generations.suffix(retainedGenerationCount))
        if localMutation.queuesWorkingSetSignal {
            state.pendingSignals.append(
                PersistedPendingSignal(
                    directory: .root,
                    generation: nextGeneration
                )
            )
            state.pendingSignals.sort {
                $0.directory.relative < $1.directory.relative
            }
        }
        try Task.checkCancellation()
        try save(state)

        return (
            anchor: makeAnchor(namespace: state.namespace, generation: nextGeneration),
            items: items,
            delta: delta
        )
    }

    func receipt(
        for key: FileProviderMutationReplayKey
    ) throws -> FileProviderMutationReceipt? {
        try loadState().generations.reversed().compactMap(\.receipt).first {
            $0.key == key
        }
    }

    func pendingWorkingSetSignalGeneration() throws -> UInt64? {
        try loadState().pendingSignals
            .map(\.generation)
            .max()
    }

    func acknowledgeWorkingSetSignal(
        generation: UInt64
    ) throws {
        var state = try loadState()
        let remainingSignals = state.pendingSignals.filter {
            $0.generation > generation
        }
        guard remainingSignals.count != state.pendingSignals.count else {
            return
        }
        state.pendingSignals = remainingSignals
        try save(state)
    }

    func items(directory: FileProviderRemotePath) throws -> [FileProviderIdentifiedItem] {
        try loadState().generations.last?.items(for: directory) ?? []
    }

    func path(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderRemotePath {
        try Self.path(in: loadState(), for: identifier)
    }

    nonisolated func pathSynchronously(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderRemotePath {
        guard identifier != .rootContainer else { return .root }
        let stateURL = stateURL
        let decoder = JSONDecoder()
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        let state = try decoder.decode(PersistedState.self, from: Data(contentsOf: stateURL))
        return try Self.path(in: state, for: identifier)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderIdentifiedItem? {
        let state = try loadState()
        let identity = try identifierCodec.identity(for: identifier)
        guard identity != .root else { return nil }
        return state.generations.last?.directories
            .flatMap(\.items)
            .first(where: { $0.identity == identity })
    }

    func currentAnchor() throws -> NSFileProviderSyncAnchor? {
        let state = try loadState()
        guard let latest = state.generations.last else {
            return nil
        }
        return makeAnchor(namespace: state.namespace, generation: latest.generation)
    }

    func workingSetSnapshot() throws -> (
        anchor: NSFileProviderSyncAnchor,
        items: [FileProviderIdentifiedItem]
    ) {
        let state = try loadState()
        if let latest = state.generations.last {
            return (
                anchor: makeAnchor(
                    namespace: state.namespace,
                    generation: latest.generation
                ),
                items: try latest.workingSetItems()
            )
        }

        let initial = try record(directory: .root, items: [])
        return (anchor: initial.anchor, items: [])
    }

    func delta(
        directory: FileProviderRemotePath,
        from anchor: NSFileProviderSyncAnchor
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta) {
        let state = try loadState()
        let requestedAnchor = try parse(anchor)
        guard requestedAnchor.namespace == state.namespace,
              let requested = state.generations.first(where: { $0.generation == requestedAnchor.generation }),
              let latest = state.generations.last
        else {
            throw FileProviderSnapshotStoreError.syncAnchorExpired
        }

        return (
            anchor: makeAnchor(namespace: state.namespace, generation: latest.generation),
            delta: makeDelta(
                from: requested.items(for: directory),
                to: latest.items(for: directory)
            )
        )
    }

    func workingSetDelta(
        from anchor: NSFileProviderSyncAnchor
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta) {
        let state = try loadState()
        let requestedAnchor = try parse(anchor)
        guard requestedAnchor.namespace == state.namespace,
              let requested = state.generations.first(where: {
                  $0.generation == requestedAnchor.generation
              }),
              let latest = state.generations.last
        else {
            throw FileProviderSnapshotStoreError.syncAnchorExpired
        }

        return (
            anchor: makeAnchor(
                namespace: state.namespace,
                generation: latest.generation
            ),
            delta: makeDelta(
                from: try requested.workingSetItems(),
                to: try latest.workingSetItems()
            )
        )
    }

    private func loadState() throws -> PersistedState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return PersistedState(
                namespace: UUID(),
                generations: [],
                pendingSignals: []
            )
        }
        let state = try decoder.decode(PersistedState.self, from: Data(contentsOf: stateURL))
        try validate(state)
        return state
    }

    private func save(_ state: PersistedState) throws {
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func generation(after generation: UInt64?) throws -> UInt64 {
        guard generation != UInt64.max else {
            throw FileProviderSnapshotStoreError.generationExhausted
        }
        return (generation ?? 0) + 1
    }

    private func makeAnchor(
        namespace: UUID,
        generation: UInt64
    ) -> NSFileProviderSyncAnchor {
        var namespaceBytes = namespace.uuid
        var bigEndian = generation.bigEndian
        var data = Data(bytes: &namespaceBytes, count: Self.namespaceByteCount)
        data.append(Data(bytes: &bigEndian, count: Self.generationByteCount))
        return NSFileProviderSyncAnchor(
            rawValue: data
        )
    }

    private func parse(_ anchor: NSFileProviderSyncAnchor) throws -> (namespace: UUID, generation: UInt64) {
        let data = anchor.rawValue
        guard data.count == Self.namespaceByteCount + Self.generationByteCount else {
            throw FileProviderSnapshotStoreError.syncAnchorExpired
        }
        let bytes = [UInt8](data)
        let namespace = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        let generation = bytes.suffix(Self.generationByteCount)
            .reduce(0) { ($0 << 8) | UInt64($1) }
        return (namespace, generation)
    }

    private func validate(_ state: PersistedState) throws {
        guard Set(state.generations.map(\.generation)).count == state.generations.count else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }

        for generation in state.generations {
            guard Set(generation.directories.map(\.path)).count == generation.directories.count else {
                throw FileProviderSnapshotStoreError.duplicatePath
            }
            for directory in generation.directories {
                try validateUniquePaths(in: directory.items)
            }
        }
    }

    private func validateUniquePaths(in items: [FileProviderRemoteItem]) throws {
        guard Set(items.map(\.path)).count == items.count else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }
    }

    private func validateUniquePaths(in items: [FileProviderIdentifiedItem]) throws {
        guard Set(items.map(\.remoteItem.path)).count == items.count,
              Set(items.map(\.identity)).count == items.count
        else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }
    }

    private func pruneTrackedSubtrees(
        from directories: inout [PersistedDirectory],
        previousItems: [FileProviderRemoteItem],
        currentItems: [FileProviderRemoteItem]
    ) {
        let currentDirectoryPaths = Set(
            currentItems
                .filter { $0.type == .directory }
                .map(\.path)
        )
        let removedDirectoryPaths = previousItems.compactMap { item in
            item.type == .directory && !currentDirectoryPaths.contains(item.path)
                ? item.path
                : nil
        }

        directories.removeAll { directory in
            removedDirectoryPaths.contains { removedPath in
                directory.path == removedPath
                    || directory.path.relative.hasPrefix(removedPath.relative + "/")
            }
        }
    }

    private func apply(
        _ relocations: [FileProviderSnapshotLocalMutation.IdentityRelocation],
        to directories: inout [PersistedDirectory]
    ) throws {
        for relocation in relocations {
            guard let movedItem = directories
                .flatMap(\.items)
                .first(where: { $0.identity == relocation.identity }),
                  movedItem.remoteItem.path == relocation.from
            else {
                throw FileProviderSnapshotStoreError.itemIdentityNotFound
            }
            directories = try directories.map { directory in
                PersistedDirectory(
                    path: try relocatedPath(
                        directory.path,
                        from: relocation.from,
                        to: relocation.to
                    ),
                    items: try directory.items.map { item in
                        FileProviderIdentifiedItem(
                            identity: item.identity,
                            parentIdentity: item.parentIdentity,
                            remoteItem: try relocatedRemoteItem(
                                item.remoteItem,
                                from: relocation.from,
                                to: relocation.to
                            )
                        )
                    }
                )
            }
        }
    }

    private func validateIdentityReservations(
        _ reservations: [FileProviderSnapshotLocalMutation.IdentityReservation],
        in directories: [PersistedDirectory]
    ) throws {
        let items = try workingSetItems(in: directories)
        guard Set(reservations.map(\.identity)).count == reservations.count,
              Set(reservations.map(\.path)).count == reservations.count
        else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }
        let identitiesByPath = Dictionary(
            uniqueKeysWithValues: items.map { ($0.remoteItem.path, $0.identity) }
        )
        let pathsByIdentity = Dictionary(
            uniqueKeysWithValues: items.map { ($0.identity, $0.remoteItem.path) }
        )
        for reservation in reservations {
            guard identitiesByPath[reservation.path] == nil
                    || identitiesByPath[reservation.path] == reservation.identity,
                  pathsByIdentity[reservation.identity] == nil
                    || pathsByIdentity[reservation.identity] == reservation.path
            else {
                throw FileProviderSnapshotStoreError.duplicatePath
            }
        }
    }

    private func workingSetItems(
        in directories: [PersistedDirectory]
    ) throws -> [FileProviderIdentifiedItem] {
        let items = directories
            .flatMap(\.items)
            .sorted { $0.remoteItem.path.relative < $1.remoteItem.path.relative }
        guard Set(items.map(\.remoteItem.path)).count == items.count,
              Set(items.map(\.identity)).count == items.count
        else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }
        return items
    }

    private func pruneDeletedIdentities(
        _ deletedIdentities: Set<FileProviderItemIdentity>,
        from directories: inout [PersistedDirectory]
    ) {
        let deletedPaths = directories
            .flatMap(\.items)
            .filter { deletedIdentities.contains($0.identity) }
            .map(\.remoteItem.path)
        directories.removeAll { directory in
            deletedPaths.contains { path in
                directory.path == path
                    || directory.path.relative.hasPrefix(path.relative + "/")
            }
        }
        directories = directories.compactMap { directory in
            let items = directory.items.filter { item in
                !deletedPaths.contains { path in
                    item.remoteItem.path == path
                        || item.remoteItem.path.relative.hasPrefix(path.relative + "/")
                }
            }
            return PersistedDirectory(path: directory.path, items: items)
        }
    }

    private func relocatedPath(
        _ path: FileProviderRemotePath,
        from: FileProviderRemotePath,
        to: FileProviderRemotePath
    ) throws -> FileProviderRemotePath {
        guard from != .root else { return path }
        guard path == from || path.relative.hasPrefix(from.relative + "/") else {
            return path
        }
        let suffix = String(path.relative.dropFirst(from.relative.count))
        return try FileProviderRemotePath(relative: to.relative + suffix)
    }

    private func relocatedRemoteItem(
        _ item: FileProviderRemoteItem,
        from: FileProviderRemotePath,
        to: FileProviderRemotePath
    ) throws -> FileProviderRemoteItem {
        let path = try relocatedPath(item.path, from: from, to: to)
        guard path != item.path else { return item }
        return try FileProviderRemoteItem(
            path: path,
            metadata: RemuxSFTPFileMetadata(
                size: item.size,
                permissions: item.permissions,
                modificationDate: item.modificationDate,
                type: item.type
            ),
            symlinkTargetRelativePath: item.symlinkTargetRelativePath
        )
    }

    private func makeDelta(
        from previousItems: [FileProviderIdentifiedItem],
        to currentItems: [FileProviderIdentifiedItem]
    ) -> FileProviderSnapshotDelta {
        let previousByPath = Dictionary(
            uniqueKeysWithValues: previousItems.map { ($0.remoteItem.path, $0) }
        )
        let currentByPath = Dictionary(
            uniqueKeysWithValues: currentItems.map { ($0.remoteItem.path, $0) }
        )

        let updated = currentItems.filter {
            currentByPath[$0.remoteItem.path]?.remoteItem
                != previousByPath[$0.remoteItem.path]?.remoteItem
        }
        let deleted = previousByPath.keys
            .filter { currentByPath[$0] == nil }
            .compactMap { previousByPath[$0]?.itemIdentifier }
            .sorted { $0.rawValue < $1.rawValue }

        return FileProviderSnapshotDelta(updated: updated, deleted: deleted)
    }

    private func parentIdentity(
        for remoteItem: FileProviderRemoteItem,
        identitiesByPath: [FileProviderRemotePath: FileProviderItemIdentity]
    ) throws -> FileProviderItemIdentity {
        guard remoteItem.parent != .root else { return .root }
        guard let parentIdentity = identitiesByPath[remoteItem.parent] else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        return parentIdentity
    }

    private nonisolated static func path(
        in state: PersistedState,
        for identifier: NSFileProviderItemIdentifier
    ) throws -> FileProviderRemotePath {
        let identity = try FileProviderItemIdentifierCodec().identity(for: identifier)
        guard identity != .root else { return .root }
        guard let item = state.generations.last?.directories
            .flatMap(\.items)
            .first(where: { $0.identity == identity })
        else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        return item.remoteItem.path
    }
}

private struct PersistedState: Codable {
    let namespace: UUID
    var generations: [PersistedGeneration]
    var pendingSignals: [PersistedPendingSignal]
}

private struct PersistedPendingSignal: Codable {
    let directory: FileProviderRemotePath
    let generation: UInt64
}

private struct PersistedGeneration: Codable {
    let generation: UInt64
    let directories: [PersistedDirectory]
    let receipt: FileProviderMutationReceipt?

    func items(for directory: FileProviderRemotePath) -> [FileProviderIdentifiedItem] {
        directories.first(where: { $0.path == directory })?.items ?? []
    }

    func workingSetItems() throws -> [FileProviderIdentifiedItem] {
        let items = directories
            .flatMap(\.items)
            .sorted { $0.remoteItem.path.relative < $1.remoteItem.path.relative }
        guard Set(items.map(\.remoteItem.path)).count == items.count,
              Set(items.map(\.identity)).count == items.count
        else {
            throw FileProviderSnapshotStoreError.duplicatePath
        }
        return items
    }
}

private struct PersistedDirectory: Codable {
    let path: FileProviderRemotePath
    let items: [FileProviderIdentifiedItem]
}
