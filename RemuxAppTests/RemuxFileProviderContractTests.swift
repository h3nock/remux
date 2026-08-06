@preconcurrency import Citadel
import FileProvider
import Foundation
import NIOEmbedded
@preconcurrency import NIOSSH
import UniformTypeIdentifiers
import XCTest
@testable import Remux

final class RemuxFileProviderContractTests: XCTestCase {

    func testSharedAuthenticationFactoryPreservesPasswordCredentials() throws {
        let authentication = ResolvedSSHAuth.password(
            username: "reader",
            password: "test-password",
            identityID: UUID(),
            displayLabel: "Fixture"
        )

        let credential: SSHCredential
        switch authentication.credential {
        case .password(let password):
            credential = .password(password)
        case .privateKey(let privateKey):
            credential = .privateKey(privateKey)
        }

        let method = try SSHAuthenticationMethodFactory.make(
            username: authentication.username,
            credential: credential
        )
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        method.nextAuthenticationType(
            availableMethods: [.password],
            nextChallengePromise: promise
        )
        let offer = try XCTUnwrap(promise.futureResult.wait())

        XCTAssertEqual(offer.username, "reader")
        guard case .password(let password) = offer.offer else {
            XCTFail("Expected password authentication")
            return
        }
        XCTAssertEqual(password.password, "test-password")
    }

    func testSSHRootKeyCanBeBuiltWithoutATmuxConnectionTarget() {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Fixture",
            host: "reader.example.test",
            port: 2222,
            username: "saved-user",
            identityID: identityID
        )
        let authentication = ResolvedSSHAuth.password(
            username: "resolved-user",
            password: "test-password",
            identityID: identityID,
            displayLabel: "Fixture"
        )

        let key = RemuxSSHRootKey(server: server, auth: authentication)

        XCTAssertEqual(key.serverID, server.id)
        XCTAssertEqual(key.host, "reader.example.test")
        XCTAssertEqual(key.port, 2222)
        XCTAssertEqual(key.username, "resolved-user")
    }

    func testPollingCoordinatorCoalescesConcurrentRefreshesForSameDirectory() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "shared")
        let firstItems = [
            try fileProviderTestItem(relative: "shared/first.txt", size: 1),
        ]
        let secondItems = [
            try fileProviderTestItem(relative: "shared/second.txt", size: 2),
        ]
        let first = Task {
            try await coordinator.performRefresh(directory: directory) {
                await gate.beginAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.performRefresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: secondItems)
            }
        }
        await coordinator.waitUntilRefreshIsCoalesced(directory: directory)

        await gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(firstResult.items.map(\.remoteItem), firstItems)
        XCTAssertEqual(secondResult.items.map(\.remoteItem), firstItems)
        XCTAssertEqual(operationCount, 1)
    }

    func testPollingCoordinatorNeverReturnsAnotherDirectorysData() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let firstDirectory = try FileProviderRemotePath(relative: "first")
        let secondDirectory = try FileProviderRemotePath(relative: "second")
        let firstItems = [
            try fileProviderTestItem(relative: "first/item.txt", size: 1),
        ]
        let secondItems = [
            try fileProviderTestItem(relative: "second/item.txt", size: 2),
        ]
        let first = Task {
            try await coordinator.performRefresh(directory: firstDirectory) {
                await gate.beginAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.performRefresh(directory: secondDirectory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: secondItems)
            }
        }
        await coordinator.waitUntilRefreshIsQueued(directory: secondDirectory)

        await gate.release()

        _ = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(secondResult.items.map(\.remoteItem), secondItems)
        XCTAssertEqual(operationCount, 2)
    }

    func testPollingCoordinatorCancelsNetworkRefreshWhenOnlyRequesterCancels() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "cancelled")
        let items = [
            try fileProviderTestItem(relative: "cancelled/item.txt", size: 1),
        ]
        let refresh = Task {
            try await coordinator.performRefresh(directory: directory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: items)
            }
        }
        await gate.waitUntilStarted()

        refresh.cancel()
        for _ in 0..<20 {
            await Task.yield()
        }
        let wasCancelled = await gate.wasCancelled()
        if !wasCancelled {
            await gate.release()
        }

        await XCTAssertFileProviderThrowsAsync { try await refresh.value }
        XCTAssertTrue(wasCancelled)
    }

    func testCancellingOneCoalescedRequesterKeepsSharedRefreshAlive() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "coalesced")
        let items = [
            try fileProviderTestItem(relative: "coalesced/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.performRefresh(directory: directory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: items)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.performRefresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: [])
            }
        }
        await coordinator.waitUntilRefreshIsCoalesced(directory: directory)
        second.cancel()
        let networkWasCancelled = await gate.wasCancelled()
        await gate.release()

        let firstResult = try await first.value
        await XCTAssertFileProviderThrowsAsync { try await second.value }
        XCTAssertEqual(firstResult.items.map(\.remoteItem), items)
        XCTAssertFalse(networkWasCancelled)
    }

    func testCancellingCoalescedRequesterReturnsBeforeSharedRefreshFinishes() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let directory = try FileProviderRemotePath(relative: "coalesced")
        let items = [
            try fileProviderTestItem(relative: "coalesced/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.performRefresh(directory: directory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: items)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            do {
                let result = try await coordinator.performRefresh(directory: directory) {
                    await gate.recordUnexpectedOperation()
                    return fileProviderTestRefresh(items: [])
                }
                await completion.finish()
                return result
            } catch {
                await completion.finish()
                throw error
            }
        }
        await coordinator.waitUntilRefreshIsCoalesced(directory: directory)

        second.cancel()

        let didFinishBeforeRefresh = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        let networkWasCancelled = await gate.wasCancelled()
        await gate.release()

        let firstResult = try await first.value
        await XCTAssertFileProviderThrowsAsync { try await second.value }
        XCTAssertTrue(didFinishBeforeRefresh)
        XCTAssertEqual(firstResult.items.map(\.remoteItem), items)
        XCTAssertFalse(networkWasCancelled)
    }

    func testCancellingRequesterWaitingForAnotherDirectoryReturnsBeforeSharedRefreshFinishes() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let firstDirectory = try FileProviderRemotePath(relative: "first")
        let secondDirectory = try FileProviderRemotePath(relative: "second")
        let firstItems = [
            try fileProviderTestItem(relative: "first/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.performRefresh(directory: firstDirectory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            do {
                let result = try await coordinator.performRefresh(directory: secondDirectory) {
                    await gate.recordUnexpectedOperation()
                    return fileProviderTestRefresh(items: [])
                }
                await completion.finish()
                return result
            } catch {
                await completion.finish()
                throw error
            }
        }
        await coordinator.waitUntilRefreshIsQueued(directory: secondDirectory)

        second.cancel()

        let didFinishBeforeRefresh = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        let networkWasCancelled = await gate.wasCancelled()
        await gate.release()

        _ = try await first.value
        await XCTAssertFileProviderThrowsAsync { try await second.value }
        let operationCount = await gate.operationCount()
        XCTAssertTrue(didFinishBeforeRefresh)
        XCTAssertFalse(networkWasCancelled)
        XCTAssertEqual(operationCount, 1)
    }

    func testEnumeratorCoreRefreshesImmediatelyAndRecordsTerminalPage() async throws {
        let home = "/home/reader"
        let metadata = RemuxSFTPFileMetadata(
            size: 7,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 500)
        )
        let client = FileProviderTestSFTPClient(
            realPaths: [".": .success(home)],
            listings: [
                home: [RemuxSFTPDirectoryEntry(name: "now.txt", metadata: metadata)],
            ]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let page = try await core.enumerateItems()

        XCTAssertEqual(page.items.map(\.remoteItem.name), ["now.txt"])
        XCTAssertNil(page.nextPage)
        XCTAssertNotNil(page.anchor)
        let persisted = try await snapshots.items(directory: .root)
        XCTAssertEqual(persisted, page.items)
        let currentAnchor = try await core.currentSyncAnchor()
        XCTAssertEqual(currentAnchor, page.anchor)
    }

    func testEnumeratorCoreReportsRetainedSnapshotChanges() async throws {
        let home = "/home/reader"
        let client = FileProviderTestSFTPClient(
            realPaths: [".": .success(home)],
            listings: [home: []]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let original = try fileProviderTestItem(relative: "changed.txt", size: 1)
        let removed = try fileProviderTestItem(relative: "removed.txt", size: 2)
        let requested = try await snapshots.record(
            directory: .root,
            items: [original, removed]
        )
        let updated = try fileProviderTestItem(relative: "changed.txt", size: 3)
        let latest = try await snapshots.record(directory: .root, items: [updated])
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let changes = try await core.enumerateChanges(from: requested.anchor)

        XCTAssertEqual(changes.updated.map(\.remoteItem), [updated])
        XCTAssertEqual(
            changes.deleted,
            [requested.items[1].itemIdentifier]
        )
        XCTAssertFalse(changes.moreComing)
        XCTAssertEqual(changes.anchor, latest.anchor)
    }

    func testCoalescedOldRefreshCannotOverwriteNewerSnapshot() async throws {
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldItem = try fileProviderTestItem(relative: "item.txt", size: 1)
        let newItem = try fileProviderTestItem(relative: "item.txt", size: 2)
        let refreshGate = FileProviderTestRefreshGate()
        let service = FileProviderTestSequencedRemoteService(
            listings: [[oldItem], [newItem]],
            firstRefreshGate: refreshGate
        )
        let coordinator = FileProviderDomainOperationCoordinator()
        let primaryCore = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: coordinator,
            signaler: FileProviderTestSignaler()
        )
        let blockingGate = FileProviderBlockingGate()
        let blockingFileManager = FileProviderBlockingFileManager(
            gate: blockingGate
        )
        let delayedCore = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: FileProviderSnapshotStore(
                rootURL: snapshotRoot,
                fileManager: blockingFileManager
            ),
            coordinator: coordinator,
            signaler: FileProviderTestSignaler()
        )

        let first = Task {
            try await primaryCore.enumerateItems()
        }
        await refreshGate.waitUntilStarted()
        let delayedOldRefresh = Task {
            try await delayedCore.enumerateItems()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        await refreshGate.release()

        _ = try await first.value
        let callCountAfterCoalescing = await service.listCallCount()
        let newerPage = try await primaryCore.enumerateItems()
        blockingGate.release()
        _ = try await delayedOldRefresh.value

        let persisted = try await FileProviderSnapshotStore(rootURL: snapshotRoot)
            .items(directory: .root)
        XCTAssertEqual(callCountAfterCoalescing, 1)
        XCTAssertEqual(newerPage.items.map(\.remoteItem), [newItem])
        XCTAssertEqual(persisted.map(\.remoteItem), [newItem])
    }

    func testWorkingSetAggregatesNestedCreateUpdateDeleteAndSignalsOnlyWorkingSet() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let original = try fileProviderTestItem(
            relative: "nested/updated.txt",
            size: 1
        )
        let removed = try fileProviderTestItem(
            relative: "nested/deleted.txt",
            size: 2
        )
        let changed = try fileProviderTestItem(
            relative: "nested/updated.txt",
            size: 3
        )
        let created = try fileProviderTestItem(
            relative: "nested/created.txt",
            size: 4
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let rootRecord = try await snapshots.record(directory: .root, items: [rootItem])
        let baseline = try await snapshots.record(
            directory: directory,
            items: [original, removed]
        )
        let signaler = FileProviderTestSignaler()
        let nestedCore = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: FileProviderTestSequencedRemoteService(
                listings: [[changed, created]]
            ),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        let workingSetCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(listings: [[]]),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )

        try await nestedCore.refreshAndSignalChanges()
        let page = try await workingSetCore.enumerateItems()
        let changes = try await workingSetCore.enumerateChanges(
            from: baseline.anchor
        )

        XCTAssertEqual(page.items.map(\.remoteItem), [rootItem, created, changed])
        XCTAssertEqual(changes.updated.map(\.remoteItem), [created, changed])
        XCTAssertEqual(
            changes.updated.map(\.parentIdentity),
            [rootRecord.items[0].identity, rootRecord.items[0].identity]
        )
        XCTAssertEqual(
            changes.deleted,
            [
                try XCTUnwrap(
                    baseline.items.first {
                        $0.remoteItem.path == removed.path
                    }
                ).itemIdentifier,
            ]
        )
        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(signals, [.workingSet])
    }

    func testChangedDirectoryPollSignalsOnlyWorkingSet() async throws {
        let home = "/home/reader"
        let original = RemuxSFTPFileMetadata(
            size: 1,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 600)
        )
        let changed = RemuxSFTPFileMetadata(
            size: 2,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 601)
        )
        let client = FileProviderSequencedSFTPClient(
            home: home,
            listings: [
                [RemuxSFTPDirectoryEntry(name: "item.txt", metadata: original)],
                [RemuxSFTPDirectoryEntry(name: "item.txt", metadata: changed)],
            ]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshots = FileProviderSnapshotStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let signaler = FileProviderTestSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        try await core.refreshAndSignalChanges()

        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(signals, [.workingSet])
    }

    func testUnchangedNestedPollDoesNotAdvanceGenerationOrSignalAgain() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let item = try fileProviderTestItem(
            relative: "nested/same.txt",
            size: 1
        )
        let snapshots = FileProviderSnapshotStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        _ = try await snapshots.record(directory: .root, items: [rootItem])
        let signaler = FileProviderTestSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: FileProviderTestSequencedRemoteService(
                listings: [[item], [item], [item]]
            ),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()
        try await core.refreshAndSignalChanges()
        let currentAnchorBeforeUnchangedPoll = try await core.currentSyncAnchor()
        let anchorBeforeUnchangedPoll = try XCTUnwrap(
            currentAnchorBeforeUnchangedPoll
        )

        try await core.refreshAndSignalChanges()

        let currentAnchorAfterUnchangedPoll = try await core.currentSyncAnchor()
        let anchorAfterUnchangedPoll = try XCTUnwrap(
            currentAnchorAfterUnchangedPoll
        )
        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(anchorAfterUnchangedPoll, anchorBeforeUnchangedPoll)
        XCTAssertEqual(signals, [.workingSet])
    }

    func testCancelledSnapshotRecordDoesNotPersistAfterStorageBoundary() async throws {
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockingGate = FileProviderBlockingGate()
        let snapshots = FileProviderSnapshotStore(
            rootURL: snapshotRoot,
            fileManager: FileProviderBlockingFileManager(gate: blockingGate)
        )
        let item = try fileProviderTestItem(relative: "cancelled.txt", size: 1)
        let record = Task {
            try await snapshots.record(directory: .root, items: [item])
        }
        await blockingGate.waitUntilEntered()

        record.cancel()
        blockingGate.release()

        await XCTAssertFileProviderThrowsAsync { try await record.value }
        let stateURL = snapshotRoot.appendingPathComponent(
            "snapshot-generations.json"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testCancelledNestedSignalIsDrainedByReopenedWorkingSet() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let original = try fileProviderTestItem(
            relative: "nested/item.txt",
            size: 1
        )
        let changed = try fileProviderTestItem(
            relative: "nested/item.txt",
            size: 2
        )
        let service = FileProviderTestSequencedRemoteService(
            listings: [[original], [changed]]
        )
        let signaler = FileProviderBlockingSignaler()
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        _ = try await snapshots.record(directory: .root, items: [rootItem])
        let core = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()
        let refresh = Task {
            try await core.refreshAndSignalChanges()
        }
        await signaler.waitUntilFirstSignal()

        refresh.cancel()
        await signaler.release()

        await XCTAssertFileProviderThrowsAsync { try await refresh.value }
        let identifiers = await signaler.signaledIdentifiers()
        XCTAssertEqual(identifiers, [.workingSet])

        let retrySignaler = FileProviderTestSignaler()
        let reopenedCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(
                listings: [[changed]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: retrySignaler
        )

        try await reopenedCore.refreshAndSignalChanges()
        try await reopenedCore.refreshAndSignalChanges()

        let retryIdentifiers = await retrySignaler.signaledIdentifiers()
        XCTAssertEqual(retryIdentifiers, [.workingSet])
    }

    func testFailedSignalDeliveryRemainsPendingUntilRetrySucceeds() async throws {
        let original = try fileProviderTestItem(relative: "item.txt", size: 1)
        let changed = try fileProviderTestItem(relative: "item.txt", size: 2)
        let signaler = FileProviderFailingOnceSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: FileProviderTestSequencedRemoteService(
                listings: [[original], [changed]]
            ),
            snapshots: FileProviderSnapshotStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        await XCTAssertFileProviderThrowsAsync {
            try await core.refreshAndSignalChanges()
        }
        try await core.refreshAndSignalChanges()
        try await core.refreshAndSignalChanges()

        let identifiers = await signaler.signaledIdentifiers()
        XCTAssertEqual(identifiers, [.workingSet])
    }

    func testOlderSignalDeliveryDoesNotAcknowledgeNewerSnapshot() async throws {
        let original = try fileProviderTestItem(relative: "item.txt", size: 1)
        let firstChange = try fileProviderTestItem(
            relative: "item.txt",
            size: 2
        )
        let secondChange = try fileProviderTestItem(
            relative: "item.txt",
            size: 3
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockingSignaler = FileProviderBlockingSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: FileProviderTestSequencedRemoteService(
                listings: [[original], [firstChange], [secondChange]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: blockingSignaler
        )
        _ = try await core.enumerateItems()
        let firstDelivery = Task {
            try await core.refreshAndSignalChanges()
        }
        await blockingSignaler.waitUntilFirstSignal()

        let newerPage = try await core.enumerateItems()
        XCTAssertEqual(newerPage.items.map(\.remoteItem), [secondChange])
        await blockingSignaler.release()
        try await firstDelivery.value

        let retrySignaler = FileProviderTestSignaler()
        let reopenedCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(
                listings: [[secondChange]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: retrySignaler
        )

        try await reopenedCore.refreshAndSignalChanges()
        try await reopenedCore.refreshAndSignalChanges()

        let retryIdentifiers = await retrySignaler.signaledIdentifiers()
        XCTAssertEqual(retryIdentifiers, [.workingSet])
    }

    func testPollingLoopRefreshesImmediatelyWhenEnumeratorOpens() async {
        let refreshes = FileProviderTestRefreshCounter()
        let loop = FileProviderPollingLoop(
            clock: FileProviderTestPollingClock(),
            refresh: {
                await refreshes.record()
            }
        )

        loop.start()
        await refreshes.wait(for: 1)

        let refreshCount = await refreshes.count()
        XCTAssertEqual(refreshCount, 1)
        loop.invalidate()
    }

    func testPollingLoopWaitsFiveSecondsBetweenRefreshes() async {
        let refreshes = FileProviderTestRefreshCounter()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await refreshes.record()
            }
        )

        loop.start()
        await refreshes.wait(for: 1)
        for _ in 0..<20 {
            await Task.yield()
        }
        let durations = await clock.requestedDurations()
        XCTAssertEqual(durations, [.seconds(5)])
        guard !durations.isEmpty else {
            loop.invalidate()
            return
        }

        await clock.advance()
        await refreshes.wait(for: 2)

        let refreshCount = await refreshes.count()
        XCTAssertEqual(refreshCount, 2)
        loop.invalidate()
    }

    func testPollingLoopStartsRefreshesOnFiveSecondCadenceWhenRefreshTakesTime() async {
        let refreshes = FileProviderTestRefreshCounter()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await clock.recordRefreshStart()
                await clock.elapse(.seconds(2))
                await refreshes.record()
            }
        )

        loop.start()
        await refreshes.wait(for: 1)
        for _ in 0..<20 {
            await Task.yield()
        }
        let durations = await clock.requestedDurations()
        XCTAssertEqual(durations, [.seconds(3)])
        guard !durations.isEmpty else {
            loop.invalidate()
            return
        }

        await clock.advance()
        await refreshes.wait(for: 2)

        let startTimes = await clock.recordedRefreshStartTimes()
        XCTAssertEqual(startTimes, [.zero, .seconds(5)])
        loop.invalidate()
    }

    func testPollingLoopInvalidationCancelsCurrentRefresh() async {
        let gate = FileProviderTestRefreshGate()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                try await gate.beginCancellableAndWait()
            }
        )
        loop.start()
        await gate.waitUntilStarted()

        loop.invalidate()
        for _ in 0..<20 {
            await Task.yield()
        }
        let wasCancelled = await gate.wasCancelled()
        if !wasCancelled {
            await gate.release()
            for _ in 0..<20 {
                await Task.yield()
            }
            await clock.cancelAll()
        }

        XCTAssertTrue(wasCancelled)
    }

    func testPollingLoopInvalidationWaitsForCurrentRefreshToFinish() async {
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let loop = FileProviderPollingLoop(
            clock: FileProviderTestPollingClock(),
            refresh: {
                await gate.beginAndWait()
            }
        )
        loop.start()
        await gate.waitUntilStarted()

        loop.invalidate()
        let drain = Task {
            await loop.waitUntilInvalidated()
            await completion.finish()
        }
        let finishedBeforeRelease = await completion.waitUntilFinished(
            timeout: .milliseconds(100)
        )
        XCTAssertFalse(finishedBeforeRelease)

        await gate.release()
        await drain.value

        let finishedAfterRelease = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        XCTAssertTrue(finishedAfterRelease)
    }

}

private actor FileProviderTestCompletionFlag {
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func finish() {
        finished = true
        let waiters = self.waiters.values
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitUntilFinished(timeout: Duration) async -> Bool {
        guard !finished else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                timeOut(waiterID: waiterID)
            }
        }
    }

    private func timeOut(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}

private actor FileProviderTestSequencedRemoteService: FileProviderRemoteServicing {
    private let listings: [[FileProviderRemoteItem]]
    private let firstRefreshGate: FileProviderTestRefreshGate?
    private var nextListingIndex = 0

    init(
        listings: [[FileProviderRemoteItem]],
        firstRefreshGate: FileProviderTestRefreshGate? = nil
    ) {
        self.listings = listings
        self.firstRefreshGate = firstRefreshGate
    }

    func item(at path: FileProviderRemotePath) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func list(directory: FileProviderRemotePath) async -> [FileProviderRemoteItem] {
        let index = min(nextListingIndex, listings.count - 1)
        nextListingIndex += 1
        if index == 0, let firstRefreshGate {
            await firstRefreshGate.beginAndWait()
        }
        return listings[index]
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func invalidate() {
    }

    func listCallCount() -> Int {
        nextListingIndex
    }
}

private actor FileProviderBlockingSignaler: FileProviderEnumeratorSignaling {
    private var identifiers: [NSFileProviderItemIdentifier] = []
    private var firstSignalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async {
        identifiers.append(identifier)
        guard identifiers.count == 1 else { return }

        let firstSignalWaiters = self.firstSignalWaiters
        self.firstSignalWaiters.removeAll()
        firstSignalWaiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstSignal() async {
        guard identifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstSignalWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private final class FileProviderBlockingGate: @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() {
        let entryWaiters = lock.withLock {
            hasEntered = true
            let entryWaiters = self.entryWaiters
            self.entryWaiters.removeAll()
            return entryWaiters
        }
        entryWaiters.forEach { $0.resume() }
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !hasEntered else { return true }
                entryWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class FileProviderBlockingFileManager: FileManager {
    private let gate: FileProviderBlockingGate

    init(gate: FileProviderBlockingGate) {
        self.gate = gate
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        gate.wait()
        return super.fileExists(atPath: path)
    }
}

private func XCTAssertFileProviderThrowsAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
    }
}

private func fileProviderTestItem(
    relative: String,
    size: UInt64,
    type: RemuxSFTPFileType = .regular
) throws -> FileProviderRemoteItem {
    try FileProviderRemoteItem(
        path: FileProviderRemotePath(relative: relative),
        metadata: RemuxSFTPFileMetadata(
            size: size,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(size)),
            type: type
        )
    )
}

private func fileProviderTestRefresh(
    items: [FileProviderRemoteItem]
) -> FileProviderPollingRefresh {
    let identifiedItems = items.map {
        FileProviderIdentifiedItem(
            identity: .item(UUID()),
            parentIdentity: .root,
            remoteItem: $0
        )
    }
    return FileProviderPollingRefresh(
        items: identifiedItems,
        anchor: NSFileProviderSyncAnchor(rawValue: Data()),
        delta: FileProviderSnapshotDelta(updated: identifiedItems, deleted: [])
    )
}

private actor FileProviderTestRefreshGate {
    private var count = 0
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var cancellationObserved = false

    func beginAndWait() async {
        count += 1
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func recordUnexpectedOperation() {
        count += 1
    }

    func beginCancellableAndWait() async throws {
        try await withTaskCancellationHandler {
            await beginAndWait()
            try Task.checkCancellation()
        } onCancel: {
            Task {
                await self.recordCancellationAndRelease()
            }
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func operationCount() -> Int {
        count
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }

    private func recordCancellationAndRelease() {
        cancellationObserved = true
        release()
    }
}

private actor FileProviderTestSignaler: FileProviderEnumeratorSignaling {
    private var identifiers: [NSFileProviderItemIdentifier] = []

    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) {
        identifiers.append(identifier)
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private actor FileProviderFailingOnceSignaler:
    FileProviderEnumeratorSignaling
{
    private enum Failure: Error {
        case rejected
    }

    private var shouldFail = true
    private var identifiers: [NSFileProviderItemIdentifier] = []

    func signalEnumerator(
        for identifier: NSFileProviderItemIdentifier
    ) throws {
        if shouldFail {
            shouldFail = false
            throw Failure.rejected
        }
        identifiers.append(identifier)
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private actor FileProviderSequencedSFTPClient: RemuxSFTPReadOnlyClient {
    private let home: String
    private let listings: [[RemuxSFTPDirectoryEntry]]
    private var listingIndex = 0

    init(home: String, listings: [[RemuxSFTPDirectoryEntry]]) {
        self.home = home
        self.listings = listings
    }

    func realPath(atPath path: String) async throws -> String {
        guard path == "." else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return home
    }

    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry] {
        guard path == home, !listings.isEmpty else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        let index = min(listingIndex, listings.count - 1)
        listingIndex += 1
        return listings[index]
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        let name = (path as NSString).lastPathComponent
        guard let metadata = listings.last?.first(where: { $0.name == name })?.metadata else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return metadata
    }

    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        try await metadata(atPath: path)
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        throw RemuxSFTPClientError.noSuchFile(path)
    }
}

private actor FileProviderTestRefreshCounter {
    private var refreshCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        refreshCount += 1
        let ready = waiters.filter { refreshCount >= $0.count }
        waiters.removeAll { refreshCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for count: Int) async {
        guard refreshCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func count() -> Int {
        refreshCount
    }
}

private actor FileProviderTestPollingClock: FileProviderPollingClock {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentTime: Duration = .zero
    private var durations: [Duration] = []
    private var refreshStartTimes: [Duration] = []
    private var waiters: [Waiter] = []

    func now() -> Duration {
        currentTime
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                durations.append(duration)
                waiters.append(
                    Waiter(
                        id: id,
                        duration: duration,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func recordRefreshStart() {
        refreshStartTimes.append(currentTime)
    }

    func recordedRefreshStartTimes() -> [Duration] {
        refreshStartTimes
    }

    func elapse(_ duration: Duration) {
        currentTime += duration
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        currentTime += waiter.duration
        waiter.continuation.resume()
    }

    func cancelAll() {
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
