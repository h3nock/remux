import FileProvider
import Foundation

struct FileProviderSnapshotDelta: Equatable, Sendable {
    let updated: [FileProviderRemoteItem]
    let deleted: [NSFileProviderItemIdentifier]
}

enum FileProviderSnapshotStoreError: Error, Equatable, Sendable {
    case syncAnchorExpired
    case generationExhausted
}

actor FileProviderSnapshotStore {
    private static let stateFilename = "snapshot-generations.json"

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
        var state = try loadState()
        let items = items.sorted { $0.path.relative < $1.path.relative }
        let previousItems = state.generations.last?.items(for: directory) ?? []

        if let latest = state.generations.last, items == previousItems {
            return (anchor: makeAnchor(for: latest.generation), delta: .init(updated: [], deleted: []))
        }

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
        try save(state)

        return (
            anchor: makeAnchor(for: nextGeneration),
            delta: makeDelta(from: previousItems, to: items)
        )
    }

    func items(directory: FileProviderRemotePath) throws -> [FileProviderRemoteItem] {
        try loadState().generations.last?.items(for: directory) ?? []
    }

    func delta(
        directory: FileProviderRemotePath,
        from anchor: NSFileProviderSyncAnchor
    ) throws -> (anchor: NSFileProviderSyncAnchor, delta: FileProviderSnapshotDelta) {
        let state = try loadState()
        let requestedGeneration = try generation(from: anchor)
        guard let requested = state.generations.first(where: { $0.generation == requestedGeneration }),
              let latest = state.generations.last
        else {
            throw FileProviderSnapshotStoreError.syncAnchorExpired
        }

        return (
            anchor: makeAnchor(for: latest.generation),
            delta: makeDelta(
                from: requested.items(for: directory),
                to: latest.items(for: directory)
            )
        )
    }

    private func loadState() throws -> PersistedState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return PersistedState(generations: [])
        }
        return try decoder.decode(PersistedState.self, from: Data(contentsOf: stateURL))
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

    private func makeAnchor(for generation: UInt64) -> NSFileProviderSyncAnchor {
        var bigEndian = generation.bigEndian
        return NSFileProviderSyncAnchor(
            rawValue: Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        )
    }

    private func generation(from anchor: NSFileProviderSyncAnchor) throws -> UInt64 {
        let data = anchor.rawValue
        guard data.count == MemoryLayout<UInt64>.size else {
            throw FileProviderSnapshotStoreError.syncAnchorExpired
        }
        return data.reduce(0) { ($0 << 8) | UInt64($1) }
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
    var generations: [PersistedGeneration]
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
