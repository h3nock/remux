import FileProvider
import XCTest

@testable import Remux

final class FileProviderSnapshotStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProviderSnapshotStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRecordProducesInsertUpdateDeleteAndStableGeneration() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let a = try item(path: "a.txt", size: 1)
        let b = try item(path: "b.txt", size: 2)
        let aChanged = try item(path: "a.txt", size: 3)
        let c = try item(path: "c.txt", size: 4)

        let first = try await store.record(directory: .root, items: [b, a])
        let unchanged = try await store.record(directory: .root, items: [a, b])
        let changed = try await store.record(directory: .root, items: [c, aChanged])

        XCTAssertEqual(first.anchor, unchanged.anchor)
        XCTAssertEqual(first.delta.updated.map(\.remoteItem), [a, b])
        XCTAssertTrue(first.delta.deleted.isEmpty)
        XCTAssertEqual(unchanged.delta, FileProviderSnapshotDelta(updated: [], deleted: []))
        XCTAssertEqual(changed.delta.updated.map(\.remoteItem), [aChanged, c])
        XCTAssertEqual(changed.delta.deleted, [first.items[1].itemIdentifier])
        XCTAssertEqual(generation(of: first.anchor), 1)
        XCTAssertEqual(generation(of: changed.anchor), 2)

        let delta = try await store.delta(directory: .root, from: first.anchor)
        XCTAssertEqual(delta.anchor, changed.anchor)
        XCTAssertEqual(delta.delta, changed.delta)
    }

    func testRecordAllocatesAndPersistsIdentityForPath() async throws {
        let ids = FileProviderTestIdentitySequence([
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        ])
        let store = FileProviderSnapshotStore(
            rootURL: root,
            identityGenerator: { ids.next() }
        )
        let remote = try item(path: "report.txt")

        let first = try await store.record(directory: .root, items: [remote])
        let second = try await store.record(directory: .root, items: [remote])

        XCTAssertEqual(first.items, second.items)
        XCTAssertEqual(
            first.items.first?.identity,
            .item(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        )
        let path = try await store.path(for: first.items[0].itemIdentifier)
        XCTAssertEqual(path, remote.path)
        XCTAssertEqual(
            try store.pathSynchronously(for: first.items[0].itemIdentifier),
            remote.path
        )
    }

    func testNestedRecordPersistsOpaqueParentIdentity() async throws {
        let ids = FileProviderTestIdentitySequence([
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
        ])
        let store = FileProviderSnapshotStore(
            rootURL: root,
            identityGenerator: { ids.next() }
        )
        let directory = try item(path: "reports", type: .directory)
        let nestedPath = try FileProviderRemotePath(relative: "reports")
        let child = try item(path: "reports/week.txt")

        let rootRecord = try await store.record(directory: .root, items: [directory])
        let nestedRecord = try await store.record(
            directory: nestedPath,
            items: [child]
        )

        XCTAssertEqual(nestedRecord.items[0].parentIdentity, rootRecord.items[0].identity)
        XCTAssertEqual(
            FileProviderItemProjection(
                item: nestedRecord.items[0],
                rootDisplayName: "Fixture"
            ).parentItemIdentifier,
            rootRecord.items[0].itemIdentifier
        )
    }

    func testRemoteRenameUsesDeleteAndNewIdentity() async throws {
        let ids = FileProviderTestIdentitySequence([
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
        ])
        let store = FileProviderSnapshotStore(
            rootURL: root,
            identityGenerator: { ids.next() }
        )
        let original = try item(path: "old.txt")
        let renamed = try item(path: "new.txt")
        let first = try await store.record(directory: .root, items: [original])

        let second = try await store.record(directory: .root, items: [renamed])

        XCTAssertNotEqual(first.items[0].identity, second.items[0].identity)
        XCTAssertEqual(second.delta.deleted, [first.items[0].itemIdentifier])
    }

    func testUnshippedLegacySnapshotFileIsIgnored() async throws {
        try Data("legacy-path-identity-state".utf8).write(
            to: root.appendingPathComponent("snapshot-generations.json")
        )
        let store = FileProviderSnapshotStore(rootURL: root)

        let result = try await store.record(
            directory: .root,
            items: [try item(path: "report.txt")]
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "snapshot-generations-v2.json"
                ).path
            )
        )
    }

    func testRecordPersistsMetadataForFreshStoreInstance() async throws {
        let firstStore = FileProviderSnapshotStore(rootURL: root)
        let documents = try item(path: "documents", type: .directory)
        let document = try item(path: "documents/report.txt", size: 42)
        let directory = try FileProviderRemotePath(relative: "documents")

        _ = try await firstStore.record(directory: .root, items: [documents])
        let recorded = try await firstStore.record(
            directory: directory,
            items: [document]
        )

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        let reloadedItems = try await reloadedStore.items(directory: directory)
        XCTAssertEqual(reloadedItems.map(\.remoteItem), [document])
        let unchanged = try await reloadedStore.record(
            directory: directory,
            items: [document]
        )
        XCTAssertEqual(unchanged.anchor, recorded.anchor)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.contains(".tmp") }
        )
    }

    func testEmptyInitialRecordPersistsAReusableAnchor() async throws {
        let firstStore = FileProviderSnapshotStore(rootURL: root)

        let first = try await firstStore.record(directory: .root, items: [])

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        let delta = try await reloadedStore.delta(directory: .root, from: first.anchor)
        XCTAssertEqual(delta.anchor, first.anchor)
        XCTAssertEqual(delta.delta, FileProviderSnapshotDelta(updated: [], deleted: []))
    }

    func testEvictedMalformedAndForeignAnchorsThrowSyncAnchorExpired() async throws {
        let store = FileProviderSnapshotStore(rootURL: root, retainedGenerationCount: 2)
        let old = try await store.record(directory: .root, items: [try item(path: "a.txt")]).anchor
        _ = try await store.record(directory: .root, items: [try item(path: "b.txt")])
        _ = try await store.record(directory: .root, items: [try item(path: "c.txt")])

        let anchors: [NSFileProviderSyncAnchor] = [
            old,
            NSFileProviderSyncAnchor(rawValue: Data([0xFF])),
            anchor(for: 99),
        ]
        for anchor in anchors {
            await XCTAssertThrowsErrorAsync(
                try await store.delta(directory: .root, from: anchor)
            ) { error in
                XCTAssertEqual(error as? FileProviderSnapshotStoreError, .syncAnchorExpired)
                let mapped = FileProviderErrorMapper.map(error)
                XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
                XCTAssertEqual(mapped.code, NSFileProviderError.syncAnchorExpired.rawValue)
            }
        }
    }

    func testForeignAnchorWithSameGenerationThrowsSyncAnchorExpired() async throws {
        let otherRoot = root.appendingPathComponent("other-domain", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let store = FileProviderSnapshotStore(rootURL: root)
        let otherStore = FileProviderSnapshotStore(rootURL: otherRoot)

        _ = try await store.record(directory: .root, items: [try item(path: "local.txt")])
        let foreign = try await otherStore.record(directory: .root, items: [try item(path: "foreign.txt")])

        await XCTAssertThrowsErrorAsync(
            try await store.delta(directory: .root, from: foreign.anchor)
        ) { error in
            XCTAssertEqual(error as? FileProviderSnapshotStoreError, .syncAnchorExpired)
        }
    }

    func testWorkingSetUsesRetainedDomainAnchorsAndRejectsExpiredOrForeignAnchors() async throws {
        let otherRoot = root.appendingPathComponent("other-domain", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let store = FileProviderSnapshotStore(
            rootURL: root,
            retainedGenerationCount: 2
        )
        let otherStore = FileProviderSnapshotStore(rootURL: otherRoot)
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try item(path: "nested")
        let original = try item(path: "nested/item.txt", size: 1)
        let changed = try item(path: "nested/item.txt", size: 2)

        let expired = try await store.record(
            directory: .root,
            items: [rootItem]
        ).anchor
        let retained = try await store.record(
            directory: directory,
            items: [original]
        ).anchor
        let latest = try await store.record(
            directory: directory,
            items: [changed]
        ).anchor
        _ = try await otherStore.record(directory: .root, items: [rootItem])
        let foreign = try await otherStore.record(
            directory: directory,
            items: [original]
        ).anchor

        let delta = try await store.workingSetDelta(from: retained)
        XCTAssertEqual(delta.anchor, latest)
        XCTAssertEqual(delta.delta.updated.map(\.remoteItem), [changed])
        XCTAssertTrue(delta.delta.deleted.isEmpty)
        XCTAssertEqual(generation(of: foreign), generation(of: retained))
        XCTAssertNotEqual(foreign.rawValue, retained.rawValue)

        for invalidAnchor in [
            expired,
            foreign,
            NSFileProviderSyncAnchor(rawValue: Data([0xFF])),
        ] {
            await XCTAssertThrowsErrorAsync(
                try await store.workingSetDelta(from: invalidAnchor)
            ) { error in
                XCTAssertEqual(
                    error as? FileProviderSnapshotStoreError,
                    .syncAnchorExpired
                )
            }
        }
    }

    func testRemovingDirectoryPrunesTrackedSubtreeAndRecreationStartsEmpty() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let nestedPath = try FileProviderRemotePath(relative: "nested")
        let childPath = try FileProviderRemotePath(relative: "nested/child")
        let nested = try item(path: "nested", type: .directory)
        let child = try item(path: "nested/child", type: .directory)
        let leaf = try item(path: "nested/child/leaf.txt")

        let rootRecord = try await store.record(directory: .root, items: [nested])
        let childRecord = try await store.record(directory: nestedPath, items: [child])
        let baseline = try await store.record(directory: childPath, items: [leaf])

        let removed = try await store.record(directory: .root, items: [])

        XCTAssertEqual(generation(of: removed.anchor), generation(of: baseline.anchor) + 1)
        let removedDelta = try await store.workingSetDelta(from: baseline.anchor)
        XCTAssertEqual(removedDelta.anchor, removed.anchor)
        XCTAssertTrue(removedDelta.delta.updated.isEmpty)
        XCTAssertEqual(
            removedDelta.delta.deleted,
            [rootRecord.items[0], childRecord.items[0], baseline.items[0]]
                .map(\.itemIdentifier)
                .sorted { $0.rawValue < $1.rawValue }
        )

        let recreated = try await store.record(directory: .root, items: [nested])
        let recreatedSnapshot = try await store.workingSetSnapshot()
        XCTAssertEqual(recreatedSnapshot.anchor, recreated.anchor)
        XCTAssertEqual(recreatedSnapshot.items.map(\.remoteItem), [nested])
        let recreatedDelta = try await store.workingSetDelta(from: removed.anchor)
        XCTAssertEqual(recreatedDelta.delta.updated.map(\.remoteItem), [nested])
        XCTAssertTrue(recreatedDelta.delta.deleted.isEmpty)
    }

    func testRenamingDirectoryPrunesTrackedOldSubtreeInOneGeneration() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let oldPath = try FileProviderRemotePath(relative: "old")
        let oldChildPath = try FileProviderRemotePath(relative: "old/child")
        let old = try item(path: "old", type: .directory)
        let oldChild = try item(path: "old/child", type: .directory)
        let oldLeaf = try item(path: "old/child/leaf.txt")
        let renamed = try item(path: "renamed", type: .directory)

        let rootRecord = try await store.record(directory: .root, items: [old])
        let childRecord = try await store.record(directory: oldPath, items: [oldChild])
        let baseline = try await store.record(directory: oldChildPath, items: [oldLeaf])

        let changed = try await store.record(directory: .root, items: [renamed])

        XCTAssertEqual(generation(of: changed.anchor), generation(of: baseline.anchor) + 1)
        let delta = try await store.workingSetDelta(from: baseline.anchor)
        XCTAssertEqual(delta.anchor, changed.anchor)
        XCTAssertEqual(delta.delta.updated.map(\.remoteItem), [renamed])
        XCTAssertEqual(
            delta.delta.deleted,
            [rootRecord.items[0], childRecord.items[0], baseline.items[0]]
                .map(\.itemIdentifier)
                .sorted { $0.rawValue < $1.rawValue }
        )
        let snapshot = try await store.workingSetSnapshot()
        XCTAssertEqual(snapshot.items.map(\.remoteItem), [renamed])
    }

    func testReplacingDirectoryWithFilePrunesTrackedDescendantsInOneGeneration() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let nestedPath = try FileProviderRemotePath(relative: "nested")
        let childPath = try FileProviderRemotePath(relative: "nested/child")
        let nestedDirectory = try item(path: "nested", type: .directory)
        let child = try item(path: "nested/child", type: .directory)
        let leaf = try item(path: "nested/child/leaf.txt")
        let nestedFile = try item(path: "nested", size: 7)

        _ = try await store.record(directory: .root, items: [nestedDirectory])
        let childRecord = try await store.record(directory: nestedPath, items: [child])
        let baseline = try await store.record(directory: childPath, items: [leaf])

        let changed = try await store.record(directory: .root, items: [nestedFile])

        XCTAssertEqual(generation(of: changed.anchor), generation(of: baseline.anchor) + 1)
        let delta = try await store.workingSetDelta(from: baseline.anchor)
        XCTAssertEqual(delta.anchor, changed.anchor)
        XCTAssertEqual(delta.delta.updated.map(\.remoteItem), [nestedFile])
        XCTAssertEqual(
            delta.delta.deleted,
            [childRecord.items[0], baseline.items[0]]
                .map(\.itemIdentifier)
                .sorted { $0.rawValue < $1.rawValue }
        )
        let snapshot = try await store.workingSetSnapshot()
        XCTAssertEqual(snapshot.items.map(\.remoteItem), [nestedFile])
    }

    func testDuplicatePathsInPersistedStateThrowTypedError() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let document = try item(path: "document.txt")
        _ = try await store.record(directory: .root, items: [document])
        let stateURL = root.appendingPathComponent("snapshot-generations-v2.json")
        var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        var generations = state["generations"] as! [[String: Any]]
        var generation = generations[0]
        var directories = generation["directories"] as! [[String: Any]]
        var directory = directories[0]
        var items = directory["items"] as! [Any]
        items.append(items[0])
        directory["items"] = items
        directories[0] = directory
        generation["directories"] = directories
        generations[0] = generation
        state["generations"] = generations
        try JSONSerialization.data(withJSONObject: state, options: .sortedKeys)
            .write(to: stateURL, options: .atomic)

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        await XCTAssertThrowsErrorAsync(
            try await reloadedStore.items(directory: .root)
        ) { error in
            XCTAssertEqual(error as? FileProviderSnapshotStoreError, .duplicatePath)
            let mapped = FileProviderErrorMapper.map(error)
            XCTAssertEqual(mapped.domain, NSCocoaErrorDomain)
            XCTAssertEqual(mapped.code, NSXPCConnectionReplyInvalid)
        }
    }

    private func item(
        path: String,
        size: UInt64 = 1,
        type: RemuxSFTPFileType = .regular
    ) throws -> FileProviderRemoteItem {
        let permissions: UInt32
        switch type {
        case .regular:
            permissions = 0o100644
        case .directory:
            permissions = 0o040755
        case .symbolicLink:
            permissions = 0o120777
        case .other:
            permissions = 0
        }
        return try FileProviderRemoteItem(
            path: FileProviderRemotePath(relative: path),
            metadata: RemuxSFTPFileMetadata(
                size: size,
                permissions: permissions,
                modificationDate: Date(timeIntervalSince1970: 1),
                type: type
            )
        )
    }

    private func anchor(for generation: UInt64) -> NSFileProviderSyncAnchor {
        var namespace = UUID().uuid
        var bigEndian = generation.bigEndian
        var data = Data(bytes: &namespace, count: 16)
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
        return NSFileProviderSyncAnchor(
            rawValue: data
        )
    }

    private func generation(of anchor: NSFileProviderSyncAnchor) -> UInt64 {
        let data = anchor.rawValue
        XCTAssertEqual(data.count, 16 + MemoryLayout<UInt64>.size)
        return data.suffix(MemoryLayout<UInt64>.size)
            .reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private final class FileProviderTestIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<Value>(
        _ expression: @autoclosure () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
