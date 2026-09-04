import Foundation

struct ShortcutStoreSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var installedStarterIDs: Set<String>
    var deletedStarterIDs: Set<String>
    var deletedCollectionIDs: Set<ShortcutCollectionID>
    var collections: [ShortcutCollection]
    var shortcuts: [Shortcut]
    var favoriteIDs: [UUID]
    var hiddenAppActionTabs: Set<AppActionTabID>
    var lastSelectedTab: ShortcutPaletteTabID

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        installedStarterIDs: Set<String> = [],
        deletedStarterIDs: Set<String> = [],
        deletedCollectionIDs: Set<ShortcutCollectionID> = [],
        collections: [ShortcutCollection] = ShortcutCollection.starterCollections,
        shortcuts: [Shortcut] = [],
        favoriteIDs: [UUID] = [],
        hiddenAppActionTabs: Set<AppActionTabID> = [.upload],
        lastSelectedTab: ShortcutPaletteTabID = .favorites
    ) {
        self.schemaVersion = schemaVersion
        self.installedStarterIDs = installedStarterIDs
        self.deletedStarterIDs = deletedStarterIDs
        self.deletedCollectionIDs = deletedCollectionIDs
        self.collections = collections
        self.shortcuts = shortcuts
        self.favoriteIDs = favoriteIDs
        self.hiddenAppActionTabs = hiddenAppActionTabs
        self.lastSelectedTab = lastSelectedTab
        repairCollectionReferences()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case installedStarterIDs
        case deletedStarterIDs
        case deletedCollectionIDs
        case collections
        case shortcuts
        case favoriteIDs
        case hiddenAppActionTabs
        case lastSelectedTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        installedStarterIDs = try container.decodeIfPresent(Set<String>.self, forKey: .installedStarterIDs) ?? []
        deletedStarterIDs = try container.decodeIfPresent(Set<String>.self, forKey: .deletedStarterIDs) ?? []
        deletedCollectionIDs = try container.decodeIfPresent(Set<ShortcutCollectionID>.self, forKey: .deletedCollectionIDs) ?? []
        collections = try container.decodeIfPresent([ShortcutCollection].self, forKey: .collections) ?? ShortcutCollection.starterCollections
        shortcuts = try container.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        favoriteIDs = try container.decodeIfPresent([UUID].self, forKey: .favoriteIDs) ?? []
        hiddenAppActionTabs = try container.decodeIfPresent(Set<AppActionTabID>.self, forKey: .hiddenAppActionTabs) ?? [.upload]
        lastSelectedTab = try container.decodeIfPresent(ShortcutPaletteTabID.self, forKey: .lastSelectedTab) ?? .favorites
        schemaVersion = Self.currentSchemaVersion
        repairCollectionReferences()
    }

    var visiblePaletteTabs: [ShortcutPaletteTabID] {
        [.favorites]
            + orderedCollections
                .filter { !$0.isHidden }
                .map { .collection($0.id) }
            + AppActionTabID.allCases
                .filter { !hiddenAppActionTabs.contains($0) }
                .map { .appAction($0) }
    }

    var orderedCollections: [ShortcutCollection] {
        collections.sorted(by: collectionSort)
    }

    func collection(id: ShortcutCollectionID) -> ShortcutCollection? {
        collections.first { $0.id == id }
    }

    func collectionTitle(_ id: ShortcutCollectionID) -> String {
        collection(id: id)?.title ?? id.rawValue
    }

    func displayTitle(for tab: ShortcutPaletteTabID) -> String {
        switch tab {
        case .collection(let id):
            collectionTitle(id)
        default:
            tab.fallbackDisplayTitle
        }
    }

    var defaultShortcutCollectionID: ShortcutCollectionID? {
        orderedCollections.first?.id
    }

    func visibleShortcuts(in collection: ShortcutCollectionID) -> [Shortcut] {
        shortcuts
            .filter { $0.collection == collection && !$0.isHidden }
            .sorted(by: shortcutSort)
    }

    var favoriteShortcuts: [Shortcut] {
        let byID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
        return favoriteIDs.compactMap { id in
            guard let shortcut = byID[id], !shortcut.isHidden else { return nil }
            return shortcut
        }
    }

    func shortcuts(in collection: ShortcutCollectionID) -> [Shortcut] {
        shortcuts
            .filter { $0.collection == collection }
            .sorted(by: shortcutSort)
    }

    func isFavorite(_ shortcutID: UUID) -> Bool {
        favoriteIDs.contains(shortcutID)
    }

    var hasMissingStarterCollections: Bool {
        StarterShortcuts.collections.contains { collection(id: $0.id) == nil }
    }

    func missingStarterShortcuts(
        in collection: ShortcutCollectionID,
        from starters: [StarterShortcut]
    ) -> [StarterShortcut] {
        guard self.collection(id: collection) != nil else { return [] }
        let existingStarterIDs = Set(shortcuts.compactMap(\.starterID))
        return starters.filter {
            $0.collection == collection && !existingStarterIDs.contains($0.id)
        }
    }

    @discardableResult
    mutating func installMissingCollections(_ starterCollections: [ShortcutCollection]) -> Bool {
        var changed = false
        let existingIDs = Set(collections.map(\.id))

        for collection in starterCollections
        where !existingIDs.contains(collection.id)
            && !deletedCollectionIDs.contains(collection.id) {
            collections.append(collection)
            changed = true
        }

        let beforeRepair = collections
        repairCollectionReferences()
        changed = changed || beforeRepair != collections
        return changed
    }

    @discardableResult
    mutating func restoreMissingStarterCollections(
        _ starterCollections: [ShortcutCollection],
        starters: [StarterShortcut]
    ) -> Bool {
        var changed = false
        var restoredCollectionIDs: [ShortcutCollectionID] = []
        for collection in starterCollections where self.collection(id: collection.id) == nil {
            collections.append(collection)
            deletedCollectionIDs.remove(collection.id)
            restoredCollectionIDs.append(collection.id)
            changed = true
        }

        if changed {
            normalizeCollectionSortIndexes()
        }

        for collectionID in restoredCollectionIDs {
            changed = restoreMissingStarters(in: collectionID, starters: starters) || changed
        }
        return changed
    }

    @discardableResult
    mutating func installMissingStarters(_ starters: [StarterShortcut]) -> Bool {
        var changed = false
        let existingStarterIDs = Set(shortcuts.compactMap(\.starterID))
        let repairedStarterIDs = existingStarterIDs.subtracting(installedStarterIDs)
        if !repairedStarterIDs.isEmpty {
            installedStarterIDs.formUnion(repairedStarterIDs)
            deletedStarterIDs.subtract(repairedStarterIDs)
            changed = true
        }

        for starter in starters
        where !installedStarterIDs.contains(starter.id)
            && !deletedStarterIDs.contains(starter.id)
            && !deletedCollectionIDs.contains(starter.collection)
            && !existingStarterIDs.contains(starter.id) {
            shortcuts.append(starter.makeShortcut())
            installedStarterIDs.insert(starter.id)
            changed = true
        }
        if changed {
            normalizeSortIndexes()
        }
        return changed
    }

    @discardableResult
    mutating func restoreMissingStarters(
        in collection: ShortcutCollectionID,
        starters: [StarterShortcut]
    ) -> Bool {
        guard self.collection(id: collection) != nil else { return false }
        let collectionStarters = starters.filter { $0.collection == collection }
        let starterIDs = Set(collectionStarters.map(\.id))
        deletedStarterIDs.subtract(starterIDs)

        var changed = false
        for starter in missingStarterShortcuts(in: collection, from: starters) {
            shortcuts.append(starter.makeShortcut())
            installedStarterIDs.insert(starter.id)
            changed = true
        }
        if changed {
            normalizeSortIndexes(in: collection)
        }
        return changed
    }

    @discardableResult
    mutating func addCollection(title: String, icon: ShortcutCollectionIcon = .folder) -> ShortcutCollectionID {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = ShortcutCollection(
            id: ShortcutCollectionID(rawValue: "custom.\(UUID().uuidString.lowercased())"),
            title: trimmedTitle.isEmpty ? "Shortcuts" : trimmedTitle,
            icon: icon,
            sortIndex: (collections.map(\.sortIndex).max() ?? -1) + 1
        )
        collections.append(collection)
        normalizeCollectionSortIndexes()
        return collection.id
    }

    mutating func upsertCollection(_ collection: ShortcutCollection) {
        let trimmedTitle = collection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = collection
        normalized.title = trimmedTitle.isEmpty ? "Shortcuts" : trimmedTitle

        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = normalized
        } else {
            collections.append(normalized)
        }
        deletedCollectionIDs.remove(collection.id)
        normalizeCollectionSortIndexes()
    }

    mutating func deleteCollection(id: ShortcutCollectionID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        let removedShortcuts = shortcuts.filter { $0.collection == id }
        let removedShortcutIDs = Set(removedShortcuts.map(\.id))

        deletedStarterIDs.formUnion(removedShortcuts.compactMap(\.starterID))
        if StarterShortcuts.collectionIDs.contains(id) {
            deletedCollectionIDs.insert(id)
        }

        collections.removeAll { $0.id == id }
        shortcuts.removeAll { $0.collection == id }
        favoriteIDs.removeAll { removedShortcutIDs.contains($0) }
        if lastSelectedTab == .collection(id) {
            lastSelectedTab = .favorites
        }
        normalizeCollectionSortIndexes()
    }

    mutating func moveCollections(from source: IndexSet, to destination: Int) {
        var ordered = orderedCollections
        ordered.moveItems(fromOffsets: source, toOffset: destination)
        for index in ordered.indices {
            ordered[index].sortIndex = index
        }
        collections = ordered
    }

    mutating func setFavorite(_ isFavorite: Bool, shortcutID: UUID) {
        favoriteIDs.removeAll { $0 == shortcutID }
        if isFavorite, shortcuts.contains(where: { $0.id == shortcutID }) {
            favoriteIDs.append(shortcutID)
        }
    }

    mutating func upsertShortcut(_ shortcut: Shortcut) {
        if collection(id: shortcut.collection) == nil {
            upsertCollection(
                ShortcutCollection(
                    id: shortcut.collection,
                    title: shortcut.collection.rawValue,
                    icon: .folder,
                    sortIndex: (collections.map(\.sortIndex).max() ?? -1) + 1
                )
            )
        }
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            let previousCollection = shortcuts[index].collection
            shortcuts[index] = shortcut
            normalizeSortIndexes(in: previousCollection)
        } else {
            shortcuts.append(shortcut)
        }
        normalizeSortIndexes(in: shortcut.collection)
    }

    mutating func deleteShortcut(id: UUID) {
        guard let shortcut = shortcuts.first(where: { $0.id == id }) else { return }
        if let starterID = shortcut.starterID {
            deletedStarterIDs.insert(starterID)
        }
        shortcuts.removeAll { $0.id == id }
        favoriteIDs.removeAll { $0 == id }
        normalizeSortIndexes(in: shortcut.collection)
    }

    mutating func moveShortcuts(
        in collection: ShortcutCollectionID,
        from source: IndexSet,
        to destination: Int
    ) {
        var collectionShortcuts = shortcuts(in: collection)
        collectionShortcuts.moveItems(fromOffsets: source, toOffset: destination)
        for (index, shortcut) in collectionShortcuts.enumerated() {
            if let globalIndex = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                shortcuts[globalIndex].sortIndex = index
            }
        }
    }

    mutating func setHidden(_ isHidden: Bool, shortcutID: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
        shortcuts[index].isHidden = isHidden
    }

    mutating func setLastSelectedTab(_ tab: ShortcutPaletteTabID) {
        lastSelectedTab = tab
    }

    private func shortcutSort(_ lhs: Shortcut, _ rhs: Shortcut) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func collectionSort(_ lhs: ShortcutCollection, _ rhs: ShortcutCollection) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private mutating func normalizeSortIndexes() {
        repairCollectionReferences()
        for collection in collections {
            normalizeSortIndexes(in: collection.id)
        }
    }

    private mutating func normalizeCollectionSortIndexes() {
        collections.sort(by: collectionSort)
        for index in collections.indices {
            collections[index].sortIndex = index
        }
    }

    private mutating func normalizeSortIndexes(in collection: ShortcutCollectionID) {
        let ordered = shortcuts(in: collection)
        for (index, shortcut) in ordered.enumerated() {
            if let globalIndex = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
                shortcuts[globalIndex].sortIndex = index
            }
        }
    }

    private mutating func repairCollectionReferences() {
        var seenIDs: Set<ShortcutCollectionID> = []
        var repaired: [ShortcutCollection] = []

        for collection in collections.sorted(by: collectionSort) where !seenIDs.contains(collection.id) {
            var normalized = collection
            if normalized.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.title = collection.id.rawValue
            }
            repaired.append(normalized)
            seenIDs.insert(collection.id)
        }

        let missingIDs = Set(shortcuts.map(\.collection)).subtracting(seenIDs)
        for id in missingIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            repaired.append(
                ShortcutCollection(
                    id: id,
                    title: id.rawValue,
                    icon: .folder,
                    sortIndex: repaired.count
                )
            )
        }

        collections = repaired
        normalizeCollectionSortIndexes()
    }
}

private extension Array {
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let indexes = source.sorted()
        guard !indexes.isEmpty else { return }
        let moving = indexes.map { self[$0] }
        for index in indexes.reversed() {
            remove(at: index)
        }
        let removedBeforeDestination = indexes.filter { $0 < destination }.count
        let insertionIndex = Swift.min(
            Swift.max(destination - removedBeforeDestination, 0),
            count
        )
        insert(contentsOf: moving, at: insertionIndex)
    }
}

protocol ShortcutRepository: Sendable {
    func loadSnapshot() async throws -> ShortcutStoreSnapshot
    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws
}

actor FileBackedShortcutRepository: ShortcutRepository {
    private let store: JSONFileStore<ShortcutStoreSnapshot>
    private let starters: [StarterShortcut]

    init(
        rootURL: URL,
        starters: [StarterShortcut] = StarterShortcuts.all
    ) {
        self.store = JSONFileStore(fileURL: rootURL.appendingPathComponent("shortcuts.json"))
        self.starters = starters
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        var snapshot = try await store.load(defaultValue: [ShortcutStoreSnapshot()]).first ?? ShortcutStoreSnapshot()
        let installedCollections = snapshot.installMissingCollections(StarterShortcuts.collections)
        let installedStarters = snapshot.installMissingStarters(starters)
        if installedCollections || installedStarters {
            try await store.save([snapshot])
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        try await store.save([snapshot])
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var snapshot: ShortcutStoreSnapshot
    @Published private(set) var persistenceError: String?

    private let repository: any ShortcutRepository
    private var pendingSaveSnapshot: ShortcutStoreSnapshot?
    private var isSaveLoopRunning = false

    init(
        repository: any ShortcutRepository,
        initialSnapshot: ShortcutStoreSnapshot = ShortcutStoreSnapshot()
    ) {
        self.repository = repository
        self.snapshot = initialSnapshot
    }

    func load() async {
        do {
            snapshot = try await repository.loadSnapshot()
            persistenceError = nil
        } catch {
            persistenceError = String(describing: error)
        }
    }

    func update(_ mutation: (inout ShortcutStoreSnapshot) -> Void) {
        mutation(&snapshot)
        persist()
    }

    private func persist() {
        pendingSaveSnapshot = snapshot
        guard !isSaveLoopRunning else { return }
        isSaveLoopRunning = true
        Task {
            await savePendingSnapshots()
        }
    }

    private func savePendingSnapshots() async {
        while let snapshot = pendingSaveSnapshot {
            pendingSaveSnapshot = nil
            do {
                try await repository.saveSnapshot(snapshot)
                persistenceError = nil
            } catch {
                persistenceError = String(describing: error)
            }
        }
        isSaveLoopRunning = false
    }
}
