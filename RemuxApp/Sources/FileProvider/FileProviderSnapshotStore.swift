import FileProvider
import Foundation

struct FileProviderSnapshotDelta: Equatable, Sendable {
    let updated: [FileProviderRemoteItem]
    let deleted: [NSFileProviderItemIdentifier]
}

enum FileProviderSnapshotStoreError: Error, Equatable, Sendable {
    case syncAnchorExpired
    case generationExhausted
    case duplicatePath
}

actor FileProviderSnapshotStore {
    private static let stateFilename = "snapshot-generations.json"
    private static let namespaceByteCount = 16
    private static let generationByteCount = MemoryLayout<UInt64>.size

    private let stateURL: URL
    private let retainedGenerationCount: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let identifierCodec = FileProviderItemIdentifierCodec()

    init(
        rootURL: URL,
        retainedGenerationCount: Int = 8,
        fileManager: FileManager = .default
    ) {
        precondition(retainedGenerationCount > 0)

        self.stateURL = rootURL.appendingPathComponent(Self.stateFilename)
        self.retainedGenerationCount = retainedGenerationCount
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func record(
        directory: FileProviderRemotePath,
        items: [FileProviderRemoteItem]
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta) {
        try Task.checkCancellation()
        var state = try loadState()
        try Task.checkCancellation()
        try validateUniquePaths(in: items)
        let items = items.sorted { $0.path.relative < $1.path.relative }
        let previousItems = state.generations.last?.items(for: directory) ?? []

        if let latest = state.generations.last, items == previousItems {
            return (
                anchor: makeAnchor(namespace: state.namespace, generation: latest.generation),
                delta: .init(updated: [], deleted: [])
            )
        }

        let hadPreviousGeneration = state.generations.last != nil
        let nextGeneration = try generation(after: state.generations.last?.generation)
        var directories = state.generations.last?.directories ?? []
        if let index = directories.firstIndex(where: { $0.path == directory }) {
            directories[index] = PersistedDirectory(path: directory, items: items)
        } else {
            directories.append(PersistedDirectory(path: directory, items: items))
        }
        directories.sort { $0.path.relative < $1.path.relative }

        let latest = PersistedGeneration(generation: nextGeneration, directories: directories)
        state.generations.append(latest)
        state.generations = Array(state.generations.suffix(retainedGenerationCount))
        let delta = makeDelta(from: previousItems, to: items)
        if hadPreviousGeneration,
           (!delta.updated.isEmpty || !delta.deleted.isEmpty),
           !state.pendingSignalDirectories.contains(directory)
        {
            state.pendingSignalDirectories.append(directory)
            state.pendingSignalDirectories.sort {
                $0.relative < $1.relative
            }
        }
        try Task.checkCancellation()
        try save(state)

        return (
            anchor: makeAnchor(namespace: state.namespace, generation: nextGeneration),
            delta: delta
        )
    }

    func hasPendingSignals(for directory: FileProviderRemotePath) throws -> Bool {
        try loadState().pendingSignalDirectories.contains(directory)
    }

    func acknowledgeSignals(for directory: FileProviderRemotePath) throws {
        var state = try loadState()
        let originalCount = state.pendingSignalDirectories.count
        state.pendingSignalDirectories.removeAll { $0 == directory }
        guard state.pendingSignalDirectories.count != originalCount else {
            return
        }
        try save(state)
    }

    func items(directory: FileProviderRemotePath) throws -> [FileProviderRemoteItem] {
        try loadState().generations.last?.items(for: directory) ?? []
    }

    func currentAnchor() throws -> NSFileProviderSyncAnchor? {
        let state = try loadState()
        guard let latest = state.generations.last else {
            return nil
        }
        return makeAnchor(namespace: state.namespace, generation: latest.generation)
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

    private func loadState() throws -> PersistedState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return PersistedState(
                namespace: UUID(),
                generations: [],
                pendingSignalDirectories: []
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

    private func makeDelta(
        from previousItems: [FileProviderRemoteItem],
        to currentItems: [FileProviderRemoteItem]
    ) -> FileProviderSnapshotDelta {
        let previousByPath = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.path, $0) })
        let currentByPath = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.path, $0) })

        let updated = currentItems.filter { currentByPath[$0.path] != previousByPath[$0.path] }
        let deleted = previousByPath.keys
            .filter { currentByPath[$0] == nil }
            .map { identifierCodec.identifier(for: $0) }
            .sorted { $0.rawValue < $1.rawValue }

        return FileProviderSnapshotDelta(updated: updated, deleted: deleted)
    }
}

private struct PersistedState: Codable {
    let namespace: UUID
    var generations: [PersistedGeneration]
    var pendingSignalDirectories: [FileProviderRemotePath]
}

private struct PersistedGeneration: Codable {
    let generation: UInt64
    let directories: [PersistedDirectory]

    func items(for directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        directories.first(where: { $0.path == directory })?.items ?? []
    }
}

private struct PersistedDirectory: Codable {
    let path: FileProviderRemotePath
    let items: [FileProviderRemoteItem]
}
