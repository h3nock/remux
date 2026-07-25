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
        XCTAssertEqual(first.delta, FileProviderSnapshotDelta(updated: [a, b], deleted: []))
        XCTAssertEqual(unchanged.delta, FileProviderSnapshotDelta(updated: [], deleted: []))
        XCTAssertEqual(changed.delta.updated, [aChanged, c])
        XCTAssertEqual(changed.delta.deleted, [identifier(for: b)])
        XCTAssertEqual(generation(of: first.anchor), 1)
        XCTAssertEqual(generation(of: changed.anchor), 2)

        let delta = try await store.delta(directory: .root, from: first.anchor)
        XCTAssertEqual(delta.anchor, changed.anchor)
        XCTAssertEqual(delta.delta, changed.delta)
    }

    func testRecordPersistsMetadataForFreshStoreInstance() async throws {
        let firstStore = FileProviderSnapshotStore(rootURL: root)
        let document = try item(path: "documents/report.txt", size: 42)

        let recorded = try await firstStore.record(directory: .root, items: [document])

        let reloadedStore = FileProviderSnapshotStore(rootURL: root)
        let reloadedItems = try await reloadedStore.items(directory: .root)
        XCTAssertEqual(reloadedItems, [document])
        let unchanged = try await reloadedStore.record(directory: .root, items: [document])
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

    func testDuplicatePathsInPersistedStateThrowTypedError() async throws {
        let store = FileProviderSnapshotStore(rootURL: root)
        let document = try item(path: "document.txt")
        _ = try await store.record(directory: .root, items: [document])
        let stateURL = root.appendingPathComponent("snapshot-generations.json")
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

    private func item(path: String, size: UInt64 = 1) throws -> FileProviderRemoteItem {
        try FileProviderRemoteItem(
            path: FileProviderRemotePath(relative: path),
            metadata: RemuxSFTPFileMetadata(
                size: size,
                permissions: 0o100644,
                modificationDate: Date(timeIntervalSince1970: 1),
                type: .regular
            )
        )
    }

    private func identifier(for item: FileProviderRemoteItem) -> NSFileProviderItemIdentifier {
        FileProviderItemIdentifierCodec().identifier(for: item.path)
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
