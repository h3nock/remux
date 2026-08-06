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

        _ = try await store.record(directory: .root, items: [])
        let initialAnchor = try await requiredCurrentAnchor(of: store)
        let first = try await store.record(directory: .root, items: [b, a])
        let firstAnchor = try await requiredCurrentAnchor(of: store)
        let firstDelta = try await store.delta(directory: .root, from: initialAnchor)
        let unchanged = try await store.record(directory: .root, items: [a, b])
        let unchangedAnchor = try await requiredCurrentAnchor(of: store)
        let unchangedDelta = try await store.delta(directory: .root, from: firstAnchor)
        let changed = try await store.record(directory: .root, items: [c, aChanged])
        let changedAnchor = try await requiredCurrentAnchor(of: store)
        let changedDelta = try await store.delta(directory: .root, from: firstAnchor)

        XCTAssertEqual(firstAnchor, unchangedAnchor)
        XCTAssertEqual(firstDelta.delta.updated.map(\.remoteItem), [a, b])
        XCTAssertTrue(firstDelta.delta.deleted.isEmpty)
        XCTAssertEqual(
            unchangedDelta.delta,
            FileProviderSnapshotDelta(updated: [], deleted: [])
        )
        XCTAssertEqual(changedDelta.delta.updated.map(\.remoteItem), [aChanged, c])
        XCTAssertEqual(changedDelta.delta.deleted, [first[1].itemIdentifier])
        XCTAssertEqual(generation(of: firstAnchor), 2)
        XCTAssertEqual(generation(of: changedAnchor), 3)
        XCTAssertEqual(changedDelta.anchor, changedAnchor)
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(changed.map(\.remoteItem), [aChanged, c])
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

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.first?.identity,
            .item(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
        )
        let path = try await store.path(for: first[0].itemIdentifier)
        XCTAssertEqual(path, remote.path)
        XCTAssertEqual(
            try store.pathSynchronously(for: first[0].itemIdentifier),
            remote.path
        )
    }

    func testPathSynchronouslyReturnsRootForFreshDomain() throws {
        let store = FileProviderSnapshotStore(rootURL: root)

        XCTAssertEqual(
            try store.pathSynchronously(for: .rootContainer),
            .root
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

        XCTAssertEqual(nestedRecord[0].parentIdentity, rootRecord[0].identity)
        XCTAssertEqual(
            FileProviderItemProjection(
                item: nestedRecord[0],
                rootDisplayName: "Fixture"
            ).parentItemIdentifier,
            rootRecord[0].itemIdentifier
        )
    }

    func testLocalMoveRetainsIdentityRelocatesDescendantsAndDoesNotQueueSignal() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let folder = try item(path: "old", type: .directory)
        let child = try item(path: "old/child.txt")
        let rootRecord = try await store.record(directory: .root, items: [folder])
        let childRecord = try await store.record(
            directory: FileProviderRemotePath(relative: "old"),
            items: [child]
        )
        let identity = rootRecord[0].identity
        let childIdentity = childRecord[0].identity
        let pendingSignal = try await store.pendingWorkingSetSignalGeneration()

        try await store.commit(
            localMutation: FileProviderSnapshotLocalMutation(
                refreshedDirectories: [
                    .init(directory: .root, items: [
                        try item(path: "new", type: .directory),
                    ]),
                    .init(
                        directory: FileProviderRemotePath(relative: "new"),
                        items: [try item(path: "new/child.txt")]
                    ),
                ],
                relocations: [
                    .init(
                        identity: identity,
                        from: FileProviderRemotePath(relative: "old"),
                        to: FileProviderRemotePath(relative: "new")
                    ),
                ],
                deletedIdentities: []
            )
        )
        let moved = try await store.workingSetSnapshot()

        let movedPath = try await store.path(for: identity.itemIdentifier)
        XCTAssertEqual(movedPath, try FileProviderRemotePath(relative: "new"))
        XCTAssertEqual(
            moved.items.first(where: { $0.identity == identity })?.remoteItem.path,
            try FileProviderRemotePath(relative: "new")
        )
        let movedChild = moved.items.first { $0.identity == childIdentity }
        XCTAssertEqual(
            movedChild?.remoteItem.path,
            try FileProviderRemotePath(relative: "new/child.txt")
        )
        XCTAssertEqual(movedChild?.parentIdentity, identity)
        let pendingSignalAfterMutation = try await store.pendingWorkingSetSignalGeneration()
        XCTAssertEqual(pendingSignalAfterMutation, pendingSignal)
    }

    func testCreateAliasSurvivesRetainedGenerationTrimming() async throws {
        let store = FileProviderSnapshotStore(
            rootURL: root,
            retainedGenerationCount: 2
        )
        let created = FileProviderIdentifiedItem(
            identity: .item(UUID()),
            parentIdentity: .root,
            remoteItem: try item(path: "created.txt")
        )

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [created.remoteItem])],
                identityReservations: [.init(identity: created.identity, path: created.remoteItem.path)],
                createAlias: FileProviderCreateAlias(
                    templateIdentifier: "system-template-1",
                    identity: created.identity
                )
            )
        )

        _ = try await store.record(directory: .root, items: [created.remoteItem, try item(path: "a")])
        _ = try await store.record(directory: .root, items: [created.remoteItem, try item(path: "b")])

        let reopenedStore = FileProviderSnapshotStore(
            rootURL: root,
            retainedGenerationCount: 2
        )
        let replayed = try await reopenedStore.item(
            forCreateTemplateIdentifier: "system-template-1"
        )
        XCTAssertEqual(replayed, created)
    }

    func testCreateAliasFollowsIdentityAcrossLocalMove() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let created = FileProviderIdentifiedItem(
            identity: .item(UUID()),
            parentIdentity: .root,
            remoteItem: try item(path: "old.txt")
        )
        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [created.remoteItem])],
                identityReservations: [.init(identity: created.identity, path: created.remoteItem.path)],
                createAlias: FileProviderCreateAlias(
                    templateIdentifier: "system-template-2",
                    identity: created.identity
                )
            )
        )
        let movedItem = try item(path: "new.txt")

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [movedItem])],
                relocations: [
                    .init(
                        identity: created.identity,
                        from: created.remoteItem.path,
                        to: movedItem.path
                    ),
                ]
            )
        )

        let replayed = try await store.item(
            forCreateTemplateIdentifier: "system-template-2"
        )
        XCTAssertEqual(replayed?.identity, created.identity)
        XCTAssertEqual(replayed?.remoteItem, movedItem)
    }

    func testCreateAliasIsPrunedWhenIdentityLeavesWorkingSet() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let created = FileProviderIdentifiedItem(
            identity: .item(UUID()),
            parentIdentity: .root,
            remoteItem: try item(path: "created.txt")
        )
        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [created.remoteItem])],
                identityReservations: [.init(identity: created.identity, path: created.remoteItem.path)],
                createAlias: FileProviderCreateAlias(
                    templateIdentifier: "system-template-3",
                    identity: created.identity
                )
            )
        )

        _ = try await store.record(directory: .root, items: [])

        let replayed = try await store.item(
            forCreateTemplateIdentifier: "system-template-3"
        )
        XCTAssertNil(replayed)
    }

    func testLocalRefreshPrunesRemovedTrackedDirectory() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let directory = try item(path: "nested", type: .directory)
        let child = try item(path: "nested/child.txt")
        let rootRecord = try await store.record(directory: .root, items: [directory])
        let childRecord = try await store.record(
            directory: FileProviderRemotePath(relative: "nested"),
            items: [child]
        )
        let beforeMutation = try await requiredCurrentAnchor(of: store)

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [])]
            )
        )
        let afterMutation = try await requiredCurrentAnchor(of: store)
        let mutationDelta = try await store.workingSetDelta(from: beforeMutation)

        XCTAssertEqual(mutationDelta.anchor, afterMutation)
        XCTAssertEqual(mutationDelta.delta.deleted, [
            rootRecord[0].itemIdentifier,
            childRecord[0].itemIdentifier,
        ].sorted { $0.rawValue < $1.rawValue })
        let nestedItems = try await store.items(
            directory: FileProviderRemotePath(relative: "nested")
        )
        XCTAssertTrue(nestedItems.isEmpty)
    }

    func testLocalMutationQueuesWorkingSetSignalOnlyWhenRequested() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        _ = try await store.record(
            directory: .root,
            items: [try item(path: "initial.txt")]
        )
        _ = try await store.record(
            directory: .root,
            items: [try item(path: "remote.txt")]
        )
        let remoteAnchor = try await requiredCurrentAnchor(of: store)
        let remoteSignal = try await store.pendingWorkingSetSignalGeneration()
        XCTAssertEqual(remoteSignal, generation(of: remoteAnchor))

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(
                    directory: .root,
                    items: [try item(path: "local.txt")]
                )]
            )
        )
        let normalAnchor = try await requiredCurrentAnchor(of: store)
        let normalSignal = try await store.pendingWorkingSetSignalGeneration()
        XCTAssertEqual(normalSignal, remoteSignal)

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(
                    directory: .root,
                    items: [try item(path: "partial.txt")]
                )],
                queuesWorkingSetSignal: true
            )
        )
        let partialAnchor = try await requiredCurrentAnchor(of: store)
        XCTAssertEqual(generation(of: normalAnchor) + 1, generation(of: partialAnchor))
        let partialSignal = try await store.pendingWorkingSetSignalGeneration()
        XCTAssertEqual(partialSignal, generation(of: partialAnchor))
        let stateURL = root.appendingPathComponent("snapshot-generations-v3.json")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        XCTAssertEqual(
            (state["pendingWorkingSetSignalGeneration"] as? NSNumber)?.uint64Value,
            generation(of: partialAnchor)
        )
    }

    func testInvalidIdentityReservationDoesNotPersistMutation() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let existing = try item(path: "existing.txt")
        let baseline = try await store.record(directory: .root, items: [existing])
        let baselineAnchor = try await requiredCurrentAnchor(of: store)
        let identity = baseline[0].identity

        await XCTAssertThrowsErrorAsync(
            try await store.commit(
                localMutation: .init(
                    refreshedDirectories: [.init(
                        directory: .root,
                        items: [existing, try item(path: "new.txt")]
                    )],
                    identityReservations: [.init(
                        identity: identity,
                        path: try FileProviderRemotePath(relative: "new.txt")
                    )]
                )
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderSnapshotStoreError, .duplicatePath)
        }

        let anchor = try await store.currentAnchor()
        XCTAssertEqual(anchor, baselineAnchor)
        let items = try await store.items(directory: .root)
        XCTAssertEqual(
            items.map(\.remoteItem),
            [existing]
        )
    }

    func testCollidingRelocationDoesNotPersistMutation() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let old = try item(path: "old", type: .directory)
        let new = try item(path: "new", type: .directory)
        let baseline = try await store.record(directory: .root, items: [old, new])
        let baselineAnchor = try await requiredCurrentAnchor(of: store)

        await XCTAssertThrowsErrorAsync(
            try await store.commit(
                localMutation: .init(
                    refreshedDirectories: [],
                    relocations: [.init(
                        identity: baseline.first(where: {
                            $0.remoteItem.path == old.path
                        })!.identity,
                        from: old.path,
                        to: new.path
                    )]
                )
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderSnapshotStoreError, .duplicatePath)
        }

        let anchor = try await store.currentAnchor()
        XCTAssertEqual(anchor, baselineAnchor)
        let items = try await store.items(directory: .root)
        XCTAssertEqual(items, baseline)
    }

    func testRelocationOntoDeletedIdentityRetainsMovedItem() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let old = try item(path: "old.txt")
        let new = try item(path: "new.txt")
        let baseline = try await store.record(directory: .root, items: [old, new])
        let oldIdentity = try XCTUnwrap(
            baseline.first(where: { $0.remoteItem.path == old.path })?.identity
        )
        let deletedIdentity = try XCTUnwrap(
            baseline.first(where: { $0.remoteItem.path == new.path })?.identity
        )

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [new])],
                relocations: [.init(
                    identity: oldIdentity,
                    from: old.path,
                    to: new.path
                )],
                deletedIdentities: [deletedIdentity]
            )
        )
        let moved = try await store.workingSetSnapshot()

        XCTAssertEqual(moved.items.map(\.identity), [oldIdentity])
        XCTAssertEqual(moved.items.map(\.remoteItem), [new])
        let path = try await store.path(for: oldIdentity.itemIdentifier)
        XCTAssertEqual(path, new.path)
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
        let firstAnchor = try await requiredCurrentAnchor(of: store)

        let second = try await store.record(directory: .root, items: [renamed])
        let secondAnchor = try await requiredCurrentAnchor(of: store)
        let delta = try await store.delta(directory: .root, from: firstAnchor)

        XCTAssertNotEqual(first[0].identity, second[0].identity)
        XCTAssertEqual(delta.anchor, secondAnchor)
        XCTAssertEqual(delta.delta.deleted, [first[0].itemIdentifier])
    }

    func testUnshippedLegacySnapshotFileIsIgnored() async throws {
        let v2URL = root.appendingPathComponent("snapshot-generations-v2.json")
        let v2Data = Data("unshipped-v2-state".utf8)
        try v2Data.write(to: v2URL)
        let store = FileProviderSnapshotStore(rootURL: root)

        let result = try await store.record(
            directory: .root,
            items: [try item(path: "report.txt")]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "snapshot-generations-v3.json"
                ).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: v2URL), v2Data)
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
        let recordedAnchor = try await requiredCurrentAnchor(of: firstStore)

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        let reloadedItems = try await reloadedStore.items(directory: directory)
        XCTAssertEqual(reloadedItems.map(\.remoteItem), [document])
        let unchanged = try await reloadedStore.record(
            directory: directory,
            items: [document]
        )
        let unchangedAnchor = try await requiredCurrentAnchor(of: reloadedStore)
        XCTAssertEqual(unchangedAnchor, recordedAnchor)
        XCTAssertEqual(unchanged.map(\.remoteItem), recorded.map(\.remoteItem))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.contains(".tmp") }
        )
    }

    func testEmptyInitialRecordPersistsAReusableAnchor() async throws {
        let firstStore = FileProviderSnapshotStore(rootURL: root)

        let first = try await firstStore.record(directory: .root, items: [])
        let firstAnchor = try await requiredCurrentAnchor(of: firstStore)

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        let delta = try await reloadedStore.delta(directory: .root, from: firstAnchor)
        XCTAssertEqual(delta.anchor, firstAnchor)
        XCTAssertEqual(delta.delta, FileProviderSnapshotDelta(updated: [], deleted: []))
        XCTAssertTrue(first.isEmpty)
    }

    func testEvictedMalformedAndForeignAnchorsThrowSyncAnchorExpired() async throws {
        let store = FileProviderSnapshotStore(rootURL: root, retainedGenerationCount: 2)
        _ = try await store.record(directory: .root, items: [try item(path: "a.txt")])
        let old = try await requiredCurrentAnchor(of: store)
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
        _ = try await otherStore.record(directory: .root, items: [try item(path: "foreign.txt")])
        let foreign = try await requiredCurrentAnchor(of: otherStore)

        await XCTAssertThrowsErrorAsync(
            try await store.delta(directory: .root, from: foreign)
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

        _ = try await store.record(
            directory: .root,
            items: [rootItem]
        )
        let expired = try await requiredCurrentAnchor(of: store)
        _ = try await store.record(
            directory: directory,
            items: [original]
        )
        let retained = try await requiredCurrentAnchor(of: store)
        _ = try await store.record(
            directory: directory,
            items: [changed]
        )
        let latest = try await requiredCurrentAnchor(of: store)
        _ = try await otherStore.record(directory: .root, items: [rootItem])
        _ = try await otherStore.record(
            directory: directory,
            items: [original]
        )
        let foreign = try await requiredCurrentAnchor(of: otherStore)

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
        let baselineAnchor = try await requiredCurrentAnchor(of: store)

        _ = try await store.record(directory: .root, items: [])
        let removedAnchor = try await requiredCurrentAnchor(of: store)

        XCTAssertEqual(generation(of: removedAnchor), generation(of: baselineAnchor) + 1)
        let removedDelta = try await store.workingSetDelta(from: baselineAnchor)
        XCTAssertEqual(removedDelta.anchor, removedAnchor)
        XCTAssertTrue(removedDelta.delta.updated.isEmpty)
        XCTAssertEqual(
            removedDelta.delta.deleted,
            [rootRecord[0], childRecord[0], baseline[0]]
                .map(\.itemIdentifier)
                .sorted { $0.rawValue < $1.rawValue }
        )

        _ = try await store.record(directory: .root, items: [nested])
        let recreatedAnchor = try await requiredCurrentAnchor(of: store)
        let recreatedSnapshot = try await store.workingSetSnapshot()
        XCTAssertEqual(recreatedSnapshot.anchor, recreatedAnchor)
        XCTAssertEqual(recreatedSnapshot.items.map(\.remoteItem), [nested])
        let recreatedDelta = try await store.workingSetDelta(from: removedAnchor)
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
        let baselineAnchor = try await requiredCurrentAnchor(of: store)

        _ = try await store.record(directory: .root, items: [renamed])
        let changedAnchor = try await requiredCurrentAnchor(of: store)

        XCTAssertEqual(generation(of: changedAnchor), generation(of: baselineAnchor) + 1)
        let delta = try await store.workingSetDelta(from: baselineAnchor)
        XCTAssertEqual(delta.anchor, changedAnchor)
        XCTAssertEqual(delta.delta.updated.map(\.remoteItem), [renamed])
        XCTAssertEqual(
            delta.delta.deleted,
            [rootRecord[0], childRecord[0], baseline[0]]
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
        let baselineAnchor = try await requiredCurrentAnchor(of: store)

        _ = try await store.record(directory: .root, items: [nestedFile])
        let changedAnchor = try await requiredCurrentAnchor(of: store)

        XCTAssertEqual(generation(of: changedAnchor), generation(of: baselineAnchor) + 1)
        let delta = try await store.workingSetDelta(from: baselineAnchor)
        XCTAssertEqual(delta.anchor, changedAnchor)
        XCTAssertEqual(delta.delta.updated.map(\.remoteItem), [nestedFile])
        XCTAssertEqual(
            delta.delta.deleted,
            [childRecord[0], baseline[0]]
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
        let stateURL = root.appendingPathComponent("snapshot-generations-v3.json")
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

    func testDeleteDirectoryPrunesTrackedDescendants() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let directory = try item(path: "folder", type: .directory)
        let child = try item(path: "folder/child.txt")
        let rootRecord = try await store.record(directory: .root, items: [directory])
        let childRecord = try await store.record(
            directory: FileProviderRemotePath(relative: "folder"),
            items: [child]
        )
        let directoryIdentity = rootRecord[0].identity

        try await store.commit(
            localMutation: .init(
                refreshedDirectories: [.init(directory: .root, items: [])],
                deletedIdentities: [directoryIdentity]
            )
        )

        let deletedDirectory = try await store.item(for: rootRecord[0].itemIdentifier)
        let deletedChild = try await store.item(for: childRecord[0].itemIdentifier)
        XCTAssertNil(deletedDirectory)
        XCTAssertNil(deletedChild)
    }

    private func requiredCurrentAnchor(
        of store: FileProviderSnapshotStore
    ) async throws -> NSFileProviderSyncAnchor {
        let anchor = try await store.currentAnchor()
        return try XCTUnwrap(anchor)
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
