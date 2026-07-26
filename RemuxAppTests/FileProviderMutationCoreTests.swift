import FileProvider
import Foundation
import XCTest
@testable import Remux

final class FileProviderMutationCoreTests: XCTestCase {
    func testCreateFileUploadsTemporarySiblingThenRenamesAndCommitsReceipt() async throws {
        let fixture = try MutationFixture()
        let localURL = fixture.localFile(contents: Data("hello".utf8))
        let request = fixture.createRequest(
            template: "template-1",
            parent: .rootContainer,
            filename: "report.txt",
            type: .regular,
            contentsURL: localURL
        )

        let result = try await fixture.core.create(request: request) { bytes in
            await fixture.progress.record(bytes)
        }

        let mutations = await fixture.remote.mutations()
        XCTAssertEqual(mutations, [
            .upload(localURL, "/home/me/.remux-upload-\(fixture.nonce)"),
            .rename("/home/me/.remux-upload-\(fixture.nonce)", "/home/me/report.txt"),
        ])
        XCTAssertEqual(result.item.remoteItem.path.relative, "report.txt")
        let receipt = try await fixture.snapshots.receipt(for: .create(templateIdentifier: "template-1"))
        XCTAssertEqual(
            receipt,
            .item(key: .create(templateIdentifier: "template-1"), item: result.item)
        )
    }

    func testCreateDirectoryUsesStrictMkdirAndReturnsAuthoritativeItem() async throws {
        let fixture = try MutationFixture()

        let result = try await fixture.core.create(
            request: fixture.createRequest(
                template: "template-dir",
                parent: .rootContainer,
                filename: "notes",
                type: .directory,
                contentsURL: nil
            )
        ) { _ in }

        let mutations = await fixture.remote.mutations()
        XCTAssertEqual(mutations, [.mkdir("/home/me/notes")])
        XCTAssertEqual(result.item.remoteItem.type, .directory)
    }

    func testCreateRejectsExistingDestinationWithoutMutation() async throws {
        let fixture = try await MutationFixture.withFile(path: "report.txt")
        await assertThrows({
            try await fixture.core.create(
                request: fixture.createRequest(
                    template: "collision",
                    parent: .rootContainer,
                    filename: "report.txt",
                    type: .regular,
                    contentsURL: fixture.localFile(contents: Data())
                )
            ) { _ in }
        }) { error in
            guard case .collision(let existing) = error as? FileProviderCreateMutationError else {
                XCTFail("Expected collision carrying the existing item")
                return
            }
            XCTAssertEqual(existing.remoteItem.path.relative, "report.txt")
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testCreateEmptyFileUploadsZeroByteTemporarySibling() async throws {
        let fixture = try MutationFixture()
        _ = try await fixture.core.create(
            request: fixture.createRequest(
                template: "empty",
                parent: .rootContainer,
                filename: "empty.txt",
                type: .regular,
                contentsURL: nil
            )
        ) { _ in }
        let contents = await fixture.remote.contents(path: "/home/me/empty.txt")
        XCTAssertEqual(contents, Data())
    }

    func testCreateReplayReturnsRecordedIdentityWithoutRemoteCalls() async throws {
        let fixture = try MutationFixture()
        let request = fixture.createRequest(
            template: "replay",
            parent: .rootContainer,
            filename: "report.txt",
            type: .regular,
            contentsURL: fixture.localFile(contents: Data("one".utf8))
        )
        let first = try await fixture.core.create(request: request) { _ in }
        let mutations = await fixture.remote.mutations()
        let replay = try await fixture.core.create(request: request) { _ in }
        XCTAssertEqual(replay.item.identity, first.item.identity)
        let replayMutations = await fixture.remote.mutations()
        XCTAssertEqual(replayMutations, mutations)
    }

    func testCreateMayAlreadyExistWithoutContentsRequiresRecordedAlias() async throws {
        let fixture = try MutationFixture()
        let request = fixture.createRequest(
            template: "alias",
            parent: .rootContainer,
            filename: "report.txt",
            type: .regular,
            contentsURL: nil
        )
        let created = try await fixture.core.create(request: request) { _ in }
        let replay = try await fixture.core.create(request: request) { _ in }
        XCTAssertEqual(replay.item.identity, created.item.identity)
        XCTAssertEqual(replay.item.remoteItem.path.relative, "report.txt")
    }

    func testCreateRejectsSymlinkWithoutRemoteCalls() async throws {
        let fixture = try MutationFixture()
        await assertThrows({
            try await fixture.core.create(
                request: fixture.createRequest(
                    template: "link",
                    parent: .rootContainer,
                    filename: "link",
                    type: .symbolicLink,
                    contentsURL: nil
                )
            ) { _ in }
        }) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .symbolicLinkMutation)
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testCreateUploadFailureRemovesExactTemporarySibling() async throws {
        let fixture = try MutationFixture()
        await fixture.remote.failNextUpload()
        await assertThrows {
            try await fixture.core.create(
                request: fixture.createRequest(template: "upload-fail", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))
            ) { _ in }
        }
        let mutations = await fixture.remote.mutations()
        let exists = await fixture.remote.exists("/home/me/report.txt")
        XCTAssertEqual(mutations.last, .removeFile("/home/me/.remux-upload-\(fixture.nonce)"))
        XCTAssertFalse(exists)
    }

    func testCreateRenameFailureRemovesTemporarySiblingAndLeavesDestination() async throws {
        let fixture = try MutationFixture()
        await fixture.remote.failNextRename()
        await assertThrows {
            try await fixture.core.create(
                request: fixture.createRequest(template: "rename-fail", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))
            ) { _ in }
        }
        let mutations = await fixture.remote.mutations()
        let exists = await fixture.remote.exists("/home/me/report.txt")
        XCTAssertEqual(mutations.last, .removeFile("/home/me/.remux-upload-\(fixture.nonce)"))
        XCTAssertFalse(exists)
    }

    func testCreateRenameFailureWaitsForExactTemporaryCleanup() async throws {
        let fixture = try MutationFixture()
        await fixture.remote.failNextRename()
        await fixture.remote.blockRemoval()
        let task = Task {
            try await fixture.core.create(request: fixture.createRequest(template: "rename-cleanup-gate", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))) { _ in }
        }
        await fixture.remote.waitUntilRemovalBlocked()
        await fixture.remote.releaseRemoval()
        await assertThrows { try await task.value }
        let temporaryExists = await fixture.remote.exists("/home/me/.remux-upload-\(fixture.nonce)")
        let destinationExists = await fixture.remote.exists("/home/me/report.txt")
        XCTAssertFalse(temporaryExists)
        XCTAssertFalse(destinationExists)
    }

    func testCreateReportsCumulativeProgressAndCancellationBeforeRenameDoesNotCommit() async throws {
        let fixture = try MutationFixture()
        await fixture.remote.blockRename()
        let task = Task {
            try await fixture.core.create(
                request: fixture.createRequest(template: "cancel-before", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))
            ) { bytes in
                await fixture.progress.record(bytes)
            }
        }
        await fixture.remote.waitUntilRenameBlocked()
        task.cancel()
        await Task.yield()
        await fixture.remote.releaseRename()
        await assertThrows { try await task.value }
        let progress = await fixture.progress.values()
        let exists = await fixture.remote.exists("/home/me/report.txt")
        let receipt = try await fixture.snapshots.receipt(for: .create(templateIdentifier: "cancel-before"))
        XCTAssertEqual(progress, [0, 5])
        XCTAssertFalse(exists)
        XCTAssertNil(receipt)
    }

    func testCreateCancellationAfterRenameCommitsAuthoritativeSnapshotAndReceipt() async throws {
        let fixture = try MutationFixture()
        await fixture.remote.blockItemReadAfterRename()
        let task = Task {
            try await fixture.core.create(
                request: fixture.createRequest(template: "cancel-after", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))
            ) { _ in }
        }
        await fixture.remote.waitUntilItemReadBlocked()
        task.cancel()
        await fixture.remote.releaseItemRead()
        let result = try await task.value
        let exists = await fixture.remote.exists("/home/me/report.txt")
        let receipt = try await fixture.snapshots.receipt(for: .create(templateIdentifier: "cancel-after"))
        let path = try await fixture.snapshots.path(for: result.item.itemIdentifier)
        XCTAssertTrue(exists)
        XCTAssertEqual(receipt, .item(key: .create(templateIdentifier: "cancel-after"), item: result.item))
        XCTAssertEqual(path.relative, "report.txt")
    }

    func testExtensionCreatePreservesCommittedResultAfterCancellation() async throws {
        let fixture = try MutationFixture()
        let completion = MutationCompletionRecorder()
        let core = FileProviderReplicatedExtensionCore(
            service: fixture.remote,
            snapshots: fixture.snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: { FileManager.default.temporaryDirectory },
            coordinator: FileProviderDomainOperationCoordinator()
        )
        await fixture.remote.blockItemReadAfterRename()
        let progress = core.createItem(
            request: fixture.createRequest(template: "bridge-cancel", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))
        ) { result in
            Task { await completion.record(result) }
        }
        await fixture.remote.waitUntilItemReadBlocked()
        progress.cancel()
        await fixture.remote.releaseItemRead()
        await completion.waitForFirst()
        let results = await completion.results()
        XCTAssertEqual(results.count, 1)
        guard case .success(let result) = results[0] else {
            XCTFail("Expected committed create to succeed after cancellation")
            return
        }
        let receipt = try await fixture.snapshots.receipt(for: .create(templateIdentifier: "bridge-cancel"))
        XCTAssertNotNil(receipt)
        XCTAssertEqual(result.item.remoteItem.path.relative, "report.txt")
    }

    func testExtensionCreateMapsCollisionToFilenameCollisionWithExistingItem() async throws {
        let fixture = try await MutationFixture.withFile(path: "report.txt")
        let completion = MutationCompletionRecorder()
        let core = FileProviderReplicatedExtensionCore(service: fixture.remote, snapshots: fixture.snapshots, rootDisplayName: "Fixture", temporaryDirectoryURL: { FileManager.default.temporaryDirectory })
        _ = core.createItem(request: fixture.createRequest(template: "bridge-collision", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: nil)) { result in Task { await completion.record(result) } }
        await completion.waitForFirst()
        guard case .failure(let error) = (await completion.results())[0] else { XCTFail("Expected collision"); return }
        XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.filenameCollision.rawValue)
        XCTAssertNotNil(error.userInfo[NSFileProviderErrorItemKey] as? FileProviderSDKItem)
    }

    func testExtensionCreateMapsSymbolicLinkToCannotSynchronize() async throws {
        let fixture = try MutationFixture()
        let completion = MutationCompletionRecorder()
        let core = FileProviderReplicatedExtensionCore(service: fixture.remote, snapshots: fixture.snapshots, rootDisplayName: "Fixture", temporaryDirectoryURL: { FileManager.default.temporaryDirectory })
        _ = core.createItem(request: fixture.createRequest(template: "bridge-link", parent: .rootContainer, filename: "link", type: .symbolicLink, contentsURL: nil)) { result in Task { await completion.record(result) } }
        await completion.waitForFirst()
        guard case .failure(let error) = (await completion.results())[0] else { XCTFail("Expected cannot synchronize"); return }
        XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.cannotSynchronize.rawValue)
    }

    func testSharedExtensionAndEnumeratorCoordinatorPreventsStaleRefreshAfterCreate() async throws {
        let fixture = try MutationFixture()
        let coordinator = FileProviderDomainOperationCoordinator()
        let extensionCore = FileProviderReplicatedExtensionCore(service: fixture.remote, snapshots: fixture.snapshots, rootDisplayName: "Fixture", temporaryDirectoryURL: { FileManager.default.temporaryDirectory }, coordinator: coordinator)
        let enumerator = FileProviderEnumeratorCore(scope: .directory(.root), service: fixture.remote, snapshots: fixture.snapshots, coordinator: coordinator, signaler: MutationSignaler())
        await fixture.remote.blockNextList()
        let refresh = Task { try await enumerator.enumerateItems() }
        await fixture.remote.waitUntilListBlocked()
        let completion = MutationCompletionRecorder()
        _ = extensionCore.createItem(request: fixture.createRequest(template: "race", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))) { result in Task { await completion.record(result) } }
        await fixture.remote.releaseList()
        _ = try await refresh.value
        await completion.waitForFirst()
        guard case .success = (await completion.results())[0] else { XCTFail("Expected create"); return }
        let items = try await fixture.snapshots.items(directory: .root)
        XCTAssertEqual(items.map { $0.remoteItem.path.relative }, ["report.txt"])
    }

    func testSeparateExtensionAndEnumeratorCoordinatorsPublishCapturedStaleRefresh() async throws {
        let fixture = try MutationFixture()
        let extensionCore = FileProviderReplicatedExtensionCore(service: fixture.remote, snapshots: fixture.snapshots, rootDisplayName: "Fixture", temporaryDirectoryURL: { FileManager.default.temporaryDirectory }, coordinator: FileProviderDomainOperationCoordinator())
        let enumerator = FileProviderEnumeratorCore(scope: .directory(.root), service: fixture.remote, snapshots: fixture.snapshots, coordinator: FileProviderDomainOperationCoordinator(), signaler: MutationSignaler())
        await fixture.remote.blockNextList()
        let refresh = Task { try await enumerator.enumerateItems() }
        await fixture.remote.waitUntilListBlocked()
        let completion = MutationCompletionRecorder()
        _ = extensionCore.createItem(request: fixture.createRequest(template: "separate-race", parent: .rootContainer, filename: "report.txt", type: .regular, contentsURL: fixture.localFile(contents: Data("hello".utf8)))) { result in Task { await completion.record(result) } }
        await completion.waitForFirst()
        await fixture.remote.releaseList()
        _ = try await refresh.value
        let items = try await fixture.snapshots.items(directory: .root)
        XCTAssertTrue(items.isEmpty)
    }

    func testRenameRetainsIdentityAndRefreshesParent() async throws {
        let fixture = try await MutationFixture.withFile(path: "old.txt")
        let original = try await fixture.identifiedItem(path: "old.txt")
        await fixture.remote.clearListedDirectories()

        let result = try await fixture.core.modify(
            request: fixture.modifyRequest(
                item: original,
                filename: "new.txt",
                changedFields: [.filename]
            )
        ) { _ in }

        XCTAssertEqual(result.item.identity, original.identity)
        XCTAssertEqual(result.item.remoteItem.path.relative, "new.txt")
        let mutations = await fixture.remote.mutations()
        XCTAssertEqual(mutations, [
            .rename("/home/me/old.txt", "/home/me/new.txt"),
        ])
        let listedDirectories = await fixture.remote.listedDirectories()
        XCTAssertEqual(listedDirectories, [.root, .root])
    }

    func testMoveRefreshesOldAndNewParentsAndRetainsIdentity() async throws {
        let fixture = try await MutationFixture.withDirectory(path: "from", children: ["report.txt"])
        try await fixture.seedDirectory("to")
        let original = try await fixture.identifiedItem(path: "from/report.txt")
        await fixture.remote.clearListedDirectories()

        let result = try await fixture.core.modify(
            request: fixture.modifyRequest(
                item: original,
                parent: try await fixture.identifier(path: "to"),
                changedFields: [.parentItemIdentifier]
            )
        ) { _ in }

        XCTAssertEqual(result.item.identity, original.identity)
        XCTAssertEqual(result.item.remoteItem.path.relative, "to/report.txt")
        let listedDirectories = await fixture.remote.listedDirectories()
        XCTAssertEqual(listedDirectories, [
            try FileProviderRemotePath(relative: "from"),
            try FileProviderRemotePath(relative: "to"),
        ])
    }

    func testMoveDirectoryRelocatesKnownDescendantIdentities() async throws {
        let fixture = try await MutationFixture.withDirectory(path: "old", children: ["child.txt"])
        let original = try await fixture.identifiedItem(path: "old")
        let child = try await fixture.identifiedItem(path: "old/child.txt")

        _ = try await fixture.core.modify(
            request: fixture.modifyRequest(item: original, filename: "new", changedFields: [.filename])
        ) { _ in }

        let movedPath = try await fixture.snapshots.path(for: original.itemIdentifier)
        let movedChildPath = try await fixture.snapshots.path(for: child.itemIdentifier)
        XCTAssertEqual(movedPath.relative, "new")
        XCTAssertEqual(movedChildPath.relative, "new/child.txt")
    }

    func testMoveRejectsDirectoryCycleWithoutMutation() async throws {
        let fixture = try await MutationFixture.withDirectory(path: "old", children: ["child.txt"])
        try await fixture.seedDirectory("old/child")
        let original = try await fixture.identifiedItem(path: "old")

        await assertThrows({
            try await fixture.core.modify(
                request: fixture.modifyRequest(
                    item: original,
                    parent: try await fixture.identifier(path: "old/child"),
                    changedFields: [.parentItemIdentifier]
                )
            ) { _ in }
        }) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .directoryCycle)
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testRenameRejectsOccupiedDestinationWithoutMutation() async throws {
        let fixture = try await MutationFixture.withDirectory(path: "root", children: ["old.txt", "new.txt"])
        let original = try await fixture.identifiedItem(path: "root/old.txt")

        await assertThrows({
            try await fixture.core.modify(
                request: fixture.modifyRequest(item: original, filename: "new.txt", changedFields: [.filename])
            ) { _ in }
        }) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .destinationOccupied)
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testModifyRejectsChangedRemoteBaseVersionWithCurrentItemWithoutMutation() async throws {
        let fixture = try await MutationFixture.withFile(path: "old.txt")
        let original = try await fixture.identifiedItem(path: "old.txt")
        await fixture.remote.changeMetadata(path: "old.txt")

        await assertThrows({
            try await fixture.core.modify(
                request: fixture.modifyRequest(item: original, filename: "new.txt", changedFields: [.filename])
            ) { _ in }
        }) { error in
            guard case .conflict(let current) = error as? FileProviderModifyMutationError else {
                XCTFail("Expected conflict carrying the current remote item")
                return
            }
            XCTAssertEqual(current.remoteItem.path.relative, "old.txt")
            XCTAssertNotEqual(current.remoteItem.metadataVersion, original.remoteItem.metadataVersion)
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testModifyRejectsRootAndSymlinkWithoutMutation() async throws {
        let fixture = try await MutationFixture.withFile(path: "link")
        await fixture.remote.seed(path: "symlink", type: .symbolicLink, contents: Data())
        try await fixture.recordRoot()
        let symlink = try await fixture.identifiedItem(path: "symlink")

        await assertThrows({
            try await fixture.core.modify(
                request: fixture.modifyRequest(
                    item: FileProviderIdentifiedItem(
                        identity: .root,
                        parentIdentity: .root,
                        remoteItem: try await fixture.remote.item(at: .root)
                    ),
                    filename: "renamed",
                    changedFields: [.filename]
                )
            ) { _ in }
        }) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .rootMutation)
        }
        await assertThrows({
            try await fixture.core.modify(
                request: fixture.modifyRequest(item: symlink, filename: "renamed", changedFields: [.filename])
            ) { _ in }
        }) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .symbolicLinkMutation)
        }
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testModifyReplayReturnsMovedItemWithoutSecondRename() async throws {
        let fixture = try await MutationFixture.withFile(path: "old.txt")
        let original = try await fixture.identifiedItem(path: "old.txt")
        let request = fixture.modifyRequest(item: original, filename: "new.txt", changedFields: [.filename])
        let moved = try await fixture.core.modify(request: request) { _ in }
        let mutations = await fixture.remote.mutations()
        let replay = try await fixture.core.modify(request: request) { _ in }

        XCTAssertEqual(replay.item, moved.item)
        let replayMutations = await fixture.remote.mutations()
        XCTAssertEqual(replayMutations, mutations)
    }

    func testModifyUnsupportedFieldsReturnCurrentItemAndExactPendingFields() async throws {
        let fixture = try await MutationFixture.withFile(path: "old.txt")
        let original = try await fixture.identifiedItem(path: "old.txt")

        let pendingFields: NSFileProviderItemFields = [.tagData, .extendedAttributes]
        let result = try await fixture.core.modify(
            request: fixture.modifyRequest(
                item: original,
                changedFields: pendingFields
            )
        ) { _ in }

        XCTAssertEqual(result.item, original)
        XCTAssertEqual(result.stillPendingFields, pendingFields)
        let mutations = await fixture.remote.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testMutableRemoteRenameMovesDirectoryDescendants() async throws {
        let fixture = try await MutationFixture.withDirectory(path: "old", children: ["child.txt"])
        try await fixture.remote.renameItem(from: FileProviderRemotePath(relative: "old"), to: FileProviderRemotePath(relative: "new"))
        let newExists = await fixture.remote.exists("/home/me/new")
        let childContents = await fixture.remote.contents(path: "/home/me/new/child.txt")
        let oldChildExists = await fixture.remote.exists("/home/me/old/child.txt")
        XCTAssertTrue(newExists)
        XCTAssertEqual(childContents, Data("contents".utf8))
        XCTAssertFalse(oldChildExists)
    }
}

private actor MutationCompletionRecorder {
    private var values: [Result<FileProviderMutationResult, NSError>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func record(_ value: Result<FileProviderMutationResult, NSError>) { values.append(value); let waiters = waiters; self.waiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitForFirst() async { guard values.isEmpty else { return }; await withCheckedContinuation { waiters.append($0) } }
    func results() -> [Result<FileProviderMutationResult, NSError>] { values }
}

private actor MutationGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func beginAndWait() async { started = true; let waiters = startedWaiters; startedWaiters.removeAll(); waiters.forEach { $0.resume() }; guard !released else { return }; await withCheckedContinuation { releaseWaiters.append($0) } }
    func waitUntilStarted() async { guard !started else { return }; await withCheckedContinuation { startedWaiters.append($0) } }
    func release() { released = true; let waiters = releaseWaiters; releaseWaiters.removeAll(); waiters.forEach { $0.resume() } }
}

private actor MutationSignaler: FileProviderEnumeratorSignaling {
    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async throws {}
}

private func assertThrows<Value: Sendable>(
    _ operation: () async throws -> Value,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

private final class MutationFixture: @unchecked Sendable {
    let core: FileProviderMutationCore
    let snapshots: FileProviderSnapshotStore
    let remote: FileProviderMutableRemoteService
    let progress = FileProviderTestProgressRecorder()
    let nonce = "11111111-2222-3333-4444-555555555555"
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        snapshots = FileProviderSnapshotStore(rootURL: root, identityGenerator: { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! })
        remote = FileProviderMutableRemoteService()
        core = FileProviderMutationCore(
            remote: remote,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            nonce: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )
    }

    static func withFile(path: String, contents: Data = Data("contents".utf8)) async throws -> MutationFixture {
        let fixture = try MutationFixture()
        await fixture.remote.seed(path: path, type: .regular, contents: contents)
        try await fixture.recordRoot()
        return fixture
    }

    static func withEmptyDirectory(path: String) async throws -> MutationFixture {
        try await withDirectory(path: path, children: [])
    }

    static func withDirectory(path: String, children: [String]) async throws -> MutationFixture {
        let fixture = try MutationFixture()
        await fixture.remote.seed(path: path, type: .directory, contents: Data())
        for child in children {
            await fixture.remote.seed(path: "\(path)/\(child)", type: .regular, contents: Data("contents".utf8))
        }
        try await fixture.recordRoot()
        try await fixture.recordDirectory(path)
        return fixture
    }

    func localFile(contents: Data) -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try! contents.write(to: url)
        return url
    }

    func createRequest(template: String, parent: NSFileProviderItemIdentifier, filename: String, type: RemuxSFTPFileType, contentsURL: URL?) -> FileProviderCreateRequest {
        FileProviderCreateRequest(templateIdentifier: .init(rawValue: template), parentIdentifier: parent, filename: filename, type: type, fields: [.filename, .parentItemIdentifier, .contents], contentsURL: contentsURL, options: [])
    }

    func modifyRequest(item: FileProviderIdentifiedItem, parent: NSFileProviderItemIdentifier? = nil, filename: String? = nil, contentsURL: URL? = nil, changedFields: NSFileProviderItemFields) -> FileProviderModifyRequest {
        FileProviderModifyRequest(
            identifier: item.itemIdentifier,
            parentIdentifier: parent ?? item.parentIdentity.itemIdentifier,
            filename: filename ?? item.remoteItem.name,
            baseVersion: NSFileProviderItemVersion(
                contentVersion: item.remoteItem.contentVersion,
                metadataVersion: item.remoteItem.metadataVersion
            ),
            changedFields: changedFields,
            contentsURL: contentsURL,
            options: []
        )
    }
    func deleteRequest(item: FileProviderIdentifiedItem, options: NSFileProviderDeleteItemOptions = []) -> FileProviderDeleteRequest { fatalError("Task 7 only") }
    func identifiedItem(path: String) async throws -> FileProviderIdentifiedItem { try await snapshots.item(for: try await identifier(path: path))! }
    func identifier(path: String) async throws -> NSFileProviderItemIdentifier { try await identifiedItemForPath(path).itemIdentifier }

    private func identifiedItemForPath(_ path: String) async throws -> FileProviderIdentifiedItem {
        let remotePath = try FileProviderRemotePath(relative: path)
        let parent = remotePath == .root ? .root : try FileProviderRemotePath(relative: remotePath.relative.split(separator: "/").dropLast().joined(separator: "/"))
        let items = try await snapshots.items(directory: parent)
        return try XCTUnwrap(items.first { $0.remoteItem.path == remotePath })
    }

    func seedDirectory(_ path: String) async throws {
        await remote.seed(path: path, type: .directory, contents: Data())
        try await recordRoot()
    }

    func recordRoot() async throws { _ = try await snapshots.record(directory: .root, items: await remote.list(directory: .root)) }
    private func recordDirectory(_ path: String) async throws { let directory = try FileProviderRemotePath(relative: path); _ = try await snapshots.record(directory: directory, items: await remote.list(directory: directory)) }
}

private actor FileProviderTestProgressRecorder {
    private var reportedBytes: [Int64] = []
    func record(_ bytes: Int64) { reportedBytes.append(bytes) }
    func values() -> [Int64] { reportedBytes }
}

private actor FileProviderMutableRemoteService: FileProviderRemoteServicing, FileProviderRemoteMutationAccess {
    enum Mutation: Equatable { case mkdir(String); case upload(URL, String); case rename(String, String); case removeFile(String); case rmdir(String) }
    private var entries: [FileProviderRemotePath: (metadata: RemuxSFTPFileMetadata, contents: Data)] = [:]
    private var recordedMutations: [Mutation] = []
    private var uploadFailure = false
    private var renameFailure = false
    private var renameBlocked = false
    private var renameWaiters: [CheckedContinuation<Void, Never>] = []
    private var renameStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var itemReadBlocked = false
    private var itemReadAfterRename = false
    private var itemReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var itemReadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var removalBlocked = false
    private var removalWaiters: [CheckedContinuation<Void, Never>] = []
    private var removalStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var listBlocked = false
    private var listWaiters: [CheckedContinuation<Void, Never>] = []
    private var listStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var listedDirectoryPaths: [FileProviderRemotePath] = []

    init() {
        entries[.root] = (
            RemuxSFTPFileMetadata(
                size: nil,
                permissions: nil,
                modificationDate: Date(timeIntervalSince1970: 1),
                type: .directory
            ),
            Data()
        )
    }

    func mutations() -> [Mutation] { recordedMutations }
    func listedDirectories() -> [FileProviderRemotePath] { listedDirectoryPaths }
    func clearListedDirectories() { listedDirectoryPaths.removeAll() }
    func listedPaths() -> [String] { entries.keys.map { "/home/me/\($0.relative)" }.sorted() }
    func contents(path: String) -> Data? { entries.first { "/home/me/\($0.key.relative)" == path }?.value.contents }
    func exists(_ absolutePath: String) -> Bool { contents(path: absolutePath) != nil }
    func seed(path: String, type: RemuxSFTPFileType, contents: Data) { let remotePath = try! FileProviderRemotePath(relative: path); entries[remotePath] = (RemuxSFTPFileMetadata(size: type == .regular ? UInt64(contents.count) : nil, permissions: nil, modificationDate: Date(timeIntervalSince1970: 1), type: type), contents) }
    func changeMetadata(path: String) { let remotePath = try! FileProviderRemotePath(relative: path); guard var entry = entries[remotePath] else { return }; entry.metadata = RemuxSFTPFileMetadata(size: entry.metadata.size, permissions: 0o600, modificationDate: Date(timeIntervalSince1970: 2), type: entry.metadata.type); entries[remotePath] = entry }
    func failNextUpload() { uploadFailure = true }
    func failNextRename() { renameFailure = true }
    func blockRename() { renameBlocked = true }
    func releaseRename() { renameBlocked = false; let waiters = renameWaiters; renameWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitUntilRenameBlocked() async { guard renameStartedWaiters.isEmpty else { return }; await withCheckedContinuation { renameStartedWaiters.append($0) } }
    func blockItemReadAfterRename() { itemReadBlocked = true }
    func releaseItemRead() { itemReadBlocked = false; let waiters = itemReadWaiters; itemReadWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitUntilItemReadBlocked() async { guard itemReadStartedWaiters.isEmpty else { return }; await withCheckedContinuation { itemReadStartedWaiters.append($0) } }
    func blockRemoval() { removalBlocked = true }
    func releaseRemoval() { removalBlocked = false; let waiters = removalWaiters; removalWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitUntilRemovalBlocked() async { guard removalStartedWaiters.isEmpty else { return }; await withCheckedContinuation { removalStartedWaiters.append($0) } }
    func blockNextList() { listBlocked = true }
    func releaseList() { listBlocked = false; let waiters = listWaiters; listWaiters.removeAll(); waiters.forEach { $0.resume() } }
    func waitUntilListBlocked() async { guard listStartedWaiters.isEmpty else { return }; await withCheckedContinuation { listStartedWaiters.append($0) } }

    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem {
        if itemReadBlocked && itemReadAfterRename {
            let waiters = itemReadStartedWaiters
            itemReadStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { itemReadWaiters.append($0) }
        }
        guard let entry = entries[path] else {
            throw RemuxSFTPClientError.noSuchFile(path.relative)
        }
        return try FileProviderRemoteItem(path: path, metadata: entry.metadata)
    }
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem] { listedDirectoryPaths.append(directory); let listed: [FileProviderRemoteItem] = try entries.compactMap { path, entry in guard path != .root, try FileProviderRemoteItem(path: path, metadata: entry.metadata).parent == directory else { return nil }; return try FileProviderRemoteItem(path: path, metadata: entry.metadata) }.sorted { $0.path.relative < $1.path.relative }; if listBlocked { listBlocked = false; let waiters = listStartedWaiters; listStartedWaiters.removeAll(); waiters.forEach { $0.resume() }; await withCheckedContinuation { listWaiters.append($0) } }; return listed }
    func fetch(path: FileProviderRemotePath, to localURL: URL, progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void) async throws -> FileProviderRemoteItem { throw RemuxSFTPClientError.unsupportedMutation }
    func withMutationAccess<Value: Sendable>(_ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value) async throws -> Value { try await operation(self) }
    func invalidate() {}
    func createDirectory(at path: FileProviderRemotePath) throws { try Task.checkCancellation(); guard entries[path] == nil else { throw FileProviderMutationValidationError.destinationOccupied }; entries[path] = (RemuxSFTPFileMetadata(size: nil, permissions: nil, modificationDate: Date(timeIntervalSince1970: 1), type: .directory), Data()); recordedMutations.append(.mkdir("/home/me/\(path.relative)")) }
    func uploadFile(from localURL: URL, to path: FileProviderRemotePath, progress: @escaping @Sendable (Int64) async -> Void) async throws { try Task.checkCancellation(); recordedMutations.append(.upload(localURL, "/home/me/\(path.relative)")); await progress(0); if uploadFailure { uploadFailure = false; throw RemuxSFTPClientError.unsupportedMutation }; let data = try Data(contentsOf: localURL); await progress(Int64(data.count)); entries[path] = (RemuxSFTPFileMetadata(size: UInt64(data.count), permissions: nil, modificationDate: Date(timeIntervalSince1970: 1), type: .regular), data) }
    func renameItem(from source: FileProviderRemotePath, to destination: FileProviderRemotePath) async throws { let waiters = renameStartedWaiters; renameStartedWaiters.removeAll(); waiters.forEach { $0.resume() }; if renameBlocked { await withCheckedContinuation { renameWaiters.append($0) } }; try Task.checkCancellation(); recordedMutations.append(.rename("/home/me/\(source.relative)", "/home/me/\(destination.relative)")); if renameFailure { renameFailure = false; throw RemuxSFTPClientError.unsupportedMutation }; let moved = entries.filter { $0.key == source || $0.key.relative.hasPrefix(source.relative + "/") }; guard !moved.isEmpty else { throw RemuxSFTPClientError.noSuchFile(source.relative) }; for path in moved.keys { entries.removeValue(forKey: path) }; for (path, entry) in moved { let suffix = path == source ? "" : String(path.relative.dropFirst(source.relative.count)); entries[try FileProviderRemotePath(relative: destination.relative + suffix)] = entry }; itemReadAfterRename = true }
    func removeFile(at path: FileProviderRemotePath) async throws { let waiters = removalStartedWaiters; removalStartedWaiters.removeAll(); waiters.forEach { $0.resume() }; if removalBlocked { await withCheckedContinuation { removalWaiters.append($0) } }; entries.removeValue(forKey: path); recordedMutations.append(.removeFile("/home/me/\(path.relative)")) }
    func removeEmptyDirectory(at path: FileProviderRemotePath) throws { guard !entries.keys.contains(where: { $0.relative.hasPrefix(path.relative + "/") }) else { throw FileProviderMutationValidationError.destinationOccupied }; entries.removeValue(forKey: path); recordedMutations.append(.rmdir("/home/me/\(path.relative)")) }
}
