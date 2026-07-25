@preconcurrency import Citadel
import FileProvider
import Foundation
import NIOEmbedded
@preconcurrency import NIOSSH
import UniformTypeIdentifiers
import XCTest
@testable import Remux

final class RemuxFileProviderContractTests: XCTestCase {
    func testReadOnlyMutationPolicyReturnsWritePermission() {
        let error = FileProviderReadOnlyMutationPolicy.rejection

        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
        XCTAssertTrue(error.userInfo.isEmpty)
    }

    func testRequestProgressCancellationCancelsWorkAndCompletesExactlyOnce() async {
        let controller = FileProviderRequestController()
        let state = FileProviderTestRequestState()
        let completions = FileProviderTestCompletionRecorder<Int>()

        let progress = controller.perform(
            operation: {
                try await state.run()
            },
            completion: { result in
                Task {
                    await completions.record(result)
                }
            }
        )
        await state.waitUntilStarted()

        progress.cancel()
        await completions.waitForFirst()

        let wasCancelled = await state.wasCancelled()
        let results = await completions.results()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected cancellation to fail the request")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
    }

    func testRequestControllerInvalidationCancelsWorkAndCompletesExactlyOnce() async {
        let controller = FileProviderRequestController()
        let state = FileProviderTestRequestState()
        let completions = FileProviderTestCompletionRecorder<Int>()

        _ = controller.perform(
            operation: {
                try await state.run()
            },
            completion: { result in
                Task {
                    await completions.record(result)
                }
            }
        )
        await state.waitUntilStarted()

        controller.invalidate()
        await completions.waitForFirst()

        let wasCancelled = await state.wasCancelled()
        let results = await completions.results()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected invalidation to fail the request")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
    }

    func testExtensionCoreItemLookupDecodesIdentifierAndProjectsResult() async throws {
        let remoteItem = try fileProviderTestItem(relative: "folder/report.txt", size: 42)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let completions = FileProviderTestCompletionRecorder<FileProviderItemProjection>()
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                FileManager.default.temporaryDirectory
            }
        )
        let identifier = FileProviderItemIdentifierCodec().identifier(for: remoteItem.path)

        _ = core.item(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await completions.waitForFirst()

        let results = await completions.results()
        guard case .success(let projection) = results.first else {
            XCTFail("Expected a projected item")
            return
        }
        XCTAssertEqual(projection.itemIdentifier, identifier)
        XCTAssertEqual(projection.filename, "report.txt")
        XCTAssertEqual(projection.capabilities, [.allowsReading])
        let itemPaths = await service.itemPaths()
        XCTAssertEqual(itemPaths, [remoteItem.path])
    }

    func testExtensionCoreFetchUsesOnlyTheDomainTemporaryDirectory() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let completions = FileProviderTestCompletionRecorder<FileProviderFetchedContents>()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                temporaryDirectory
            }
        )
        let identifier = FileProviderItemIdentifierCodec().identifier(for: remoteItem.path)

        _ = core.fetchContents(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await completions.waitForFirst()

        let results = await completions.results()
        guard case .success(let fetched) = results.first else {
            XCTFail("Expected fetched contents")
            return
        }
        XCTAssertEqual(
            fetched.localURL.deletingLastPathComponent().standardizedFileURL,
            temporaryDirectory.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: fetched.localURL), Data("contents".utf8))
        XCTAssertEqual(fetched.item.itemIdentifier, identifier)
        let fetchURLs = await service.fetchURLs()
        XCTAssertEqual(fetchURLs, [fetched.localURL])
    }

    func testExtensionCoreRejectsMutationImmediatelyWithoutRemoteCalls() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                FileManager.default.temporaryDirectory
            }
        )
        var errors: [NSError] = []

        let progress = core.rejectMutation { error in
            errors.append(error)
        }

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(errors.first?.code, NSFileWriteNoPermissionError)
        XCTAssertEqual(progress.totalUnitCount, 1)
        XCTAssertEqual(progress.completedUnitCount, 1)
        let remoteCallCount = await service.totalCallCount()
        XCTAssertEqual(remoteCallCount, 0)
    }

    func testSharedAuthenticationFactoryPreservesPasswordCredentials() throws {
        let authentication = ResolvedSSHAuth.password(
            username: "reader",
            password: "test-password",
            identityID: UUID(),
            displayLabel: "Fixture"
        )

        let method = try RemuxSSHAuthenticationMethodFactory.make(for: authentication)
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
        let coordinator = FileProviderPollingCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "shared")
        let firstItems = [
            try fileProviderTestItem(relative: "shared/first.txt", size: 1),
        ]
        let secondItems = [
            try fileProviderTestItem(relative: "shared/second.txt", size: 2),
        ]
        let first = Task {
            try await coordinator.refresh(directory: directory) {
                await gate.beginAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: secondItems)
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        await gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(firstResult.items, firstItems)
        XCTAssertEqual(secondResult.items, firstItems)
        XCTAssertEqual(operationCount, 1)
    }

    func testPollingCoordinatorNeverReturnsAnotherDirectorysData() async throws {
        let coordinator = FileProviderPollingCoordinator()
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
            try await coordinator.refresh(directory: firstDirectory) {
                await gate.beginAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: secondDirectory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: secondItems)
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        await gate.release()

        _ = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(secondResult.items, secondItems)
        XCTAssertEqual(operationCount, 2)
    }

    func testPollingCoordinatorCancelsNetworkRefreshWhenOnlyRequesterCancels() async throws {
        let coordinator = FileProviderPollingCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "cancelled")
        let items = [
            try fileProviderTestItem(relative: "cancelled/item.txt", size: 1),
        ]
        let refresh = Task {
            try await coordinator.refresh(directory: directory) {
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
        let coordinator = FileProviderPollingCoordinator()
        let gate = FileProviderTestRefreshGate()
        let directory = try FileProviderRemotePath(relative: "coalesced")
        let items = [
            try fileProviderTestItem(relative: "coalesced/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.refresh(directory: directory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: items)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return fileProviderTestRefresh(items: [])
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        second.cancel()
        for _ in 0..<20 {
            await Task.yield()
        }
        let networkWasCancelled = await gate.wasCancelled()
        await gate.release()

        let firstResult = try await first.value
        await XCTAssertFileProviderThrowsAsync { try await second.value }
        XCTAssertEqual(firstResult.items, items)
        XCTAssertFalse(networkWasCancelled)
    }

    func testCancellingCoalescedRequesterReturnsBeforeSharedRefreshFinishes() async throws {
        let coordinator = FileProviderPollingCoordinator()
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let directory = try FileProviderRemotePath(relative: "coalesced")
        let items = [
            try fileProviderTestItem(relative: "coalesced/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.refresh(directory: directory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: items)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            do {
                let result = try await coordinator.refresh(directory: directory) {
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
        for _ in 0..<20 {
            await Task.yield()
        }

        second.cancel()

        let didFinishBeforeRefresh = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        let networkWasCancelled = await gate.wasCancelled()
        await gate.release()

        let firstResult = try await first.value
        await XCTAssertFileProviderThrowsAsync { try await second.value }
        XCTAssertTrue(didFinishBeforeRefresh)
        XCTAssertEqual(firstResult.items, items)
        XCTAssertFalse(networkWasCancelled)
    }

    func testCancellingRequesterWaitingForAnotherDirectoryReturnsBeforeSharedRefreshFinishes() async throws {
        let coordinator = FileProviderPollingCoordinator()
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let firstDirectory = try FileProviderRemotePath(relative: "first")
        let secondDirectory = try FileProviderRemotePath(relative: "second")
        let firstItems = [
            try fileProviderTestItem(relative: "first/item.txt", size: 1),
        ]
        let first = Task {
            try await coordinator.refresh(directory: firstDirectory) {
                try await gate.beginCancellableAndWait()
                return fileProviderTestRefresh(items: firstItems)
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            do {
                let result = try await coordinator.refresh(directory: secondDirectory) {
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
        for _ in 0..<20 {
            await Task.yield()
        }

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
            directory: .root,
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderPollingCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let page = try await core.enumerateItems()

        XCTAssertEqual(page.items.map(\.name), ["now.txt"])
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
            directory: .root,
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderPollingCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let changes = try await core.enumerateChanges(from: requested.anchor)

        XCTAssertEqual(changes.updated, [updated])
        XCTAssertEqual(
            changes.deleted,
            [FileProviderItemIdentifierCodec().identifier(for: removed.path)]
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
        let coordinator = FileProviderPollingCoordinator()
        let primaryCore = FileProviderEnumeratorCore(
            directory: .root,
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
            directory: .root,
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
        XCTAssertEqual(newerPage.items, [newItem])
        XCTAssertEqual(persisted, [newItem])
    }

    func testPollingRefreshSignalsDirectoryAndWorkingSetWhenSnapshotChanges() async throws {
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
            directory: .root,
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderPollingCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        try await core.refreshAndSignalChanges()

        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(signals, [.rootContainer, .workingSet])
    }

    func testPollingRefreshDoesNotSignalWhenSnapshotIsUnchanged() async throws {
        let home = "/home/reader"
        let metadata = RemuxSFTPFileMetadata(
            size: 1,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 700)
        )
        let listing = [RemuxSFTPDirectoryEntry(name: "same.txt", metadata: metadata)]
        let client = FileProviderSequencedSFTPClient(
            home: home,
            listings: [listing, listing]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let signaler = FileProviderTestSignaler()
        let core = FileProviderEnumeratorCore(
            directory: .root,
            service: service,
            snapshots: FileProviderSnapshotStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            coordinator: FileProviderPollingCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        try await core.refreshAndSignalChanges()

        let signals = await signaler.signaledIdentifiers()
        XCTAssertTrue(signals.isEmpty)
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

    func testItemProjectionExposesReadOnlyFileProviderMetadata() throws {
        let remoteItem = try FileProviderRemoteItem(
            path: FileProviderRemotePath(relative: "folder/report.txt"),
            metadata: RemuxSFTPFileMetadata(
                size: 42,
                permissions: 0o100640,
                modificationDate: Date(timeIntervalSince1970: 800)
            )
        )

        let projection = FileProviderItemProjection(
            remoteItem: remoteItem,
            rootDisplayName: "Server"
        )

        XCTAssertEqual(
            projection.itemIdentifier,
            FileProviderItemIdentifierCodec().identifier(for: remoteItem.path)
        )
        XCTAssertEqual(
            projection.parentItemIdentifier,
            FileProviderItemIdentifierCodec().identifier(for: remoteItem.parent)
        )
        XCTAssertEqual(projection.filename, "report.txt")
        XCTAssertEqual(projection.contentType, .plainText)
        XCTAssertEqual(projection.documentSize, 42)
        XCTAssertEqual(projection.contentModificationDate, Date(timeIntervalSince1970: 800))
        XCTAssertEqual(projection.capabilities, [.allowsReading])
        XCTAssertEqual(
            projection.itemVersion.contentVersion,
            remoteItem.contentVersion
        )
        XCTAssertEqual(
            projection.itemVersion.metadataVersion,
            remoteItem.metadataVersion
        )
        XCTAssertNil(projection.symlinkTargetPath)
    }
}

private actor FileProviderTestRequestState {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationObserved = false

    func run() async throws -> Int {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(for: .seconds(60))
            return 1
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }
}

private actor FileProviderTestCompletionRecorder<Value: Sendable> {
    private var recordedResults: [Result<Value, NSError>] = []
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ result: Result<Value, NSError>) {
        recordedResults.append(result)
        let waiters = firstWaiters
        firstWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForFirst() async {
        guard recordedResults.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }

    func results() -> [Result<Value, NSError>] {
        recordedResults
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

private actor FileProviderRecordingRemoteService: FileProviderRemoteServicing {
    private let returnedItem: FileProviderRemoteItem
    private var recordedItemPaths: [FileProviderRemotePath] = []
    private var recordedFetchURLs: [URL] = []

    init(item: FileProviderRemoteItem) {
        self.returnedItem = item
    }

    func item(at path: FileProviderRemotePath) -> FileProviderRemoteItem {
        recordedItemPaths.append(path)
        return returnedItem
    }

    func list(directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        []
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderRemoteItem {
        recordedFetchURLs.append(localURL)
        try Data("contents".utf8).write(to: localURL)
        await progress(8)
        return returnedItem
    }

    func itemPaths() -> [FileProviderRemotePath] {
        recordedItemPaths
    }

    func fetchURLs() -> [URL] {
        recordedFetchURLs
    }

    func totalCallCount() -> Int {
        recordedItemPaths.count + recordedFetchURLs.count
    }

    func invalidate() {
    }
}

private actor FileProviderTestSequencedRemoteService: FileProviderRemoteServicing {
    private let listings: [[FileProviderRemoteItem]]
    private let firstRefreshGate: FileProviderTestRefreshGate
    private var nextListingIndex = 0

    init(
        listings: [[FileProviderRemoteItem]],
        firstRefreshGate: FileProviderTestRefreshGate
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
        if index == 0 {
            await firstRefreshGate.beginAndWait()
        }
        return listings[index]
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func invalidate() {
    }

    func listCallCount() -> Int {
        nextListingIndex
    }
}

private final class FileProviderBlockingGate: @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func wait() {
        releaseSemaphore.wait()
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
    size: UInt64
) throws -> FileProviderRemoteItem {
    try FileProviderRemoteItem(
        path: FileProviderRemotePath(relative: relative),
        metadata: RemuxSFTPFileMetadata(
            size: size,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(size))
        )
    )
}

private func fileProviderTestRefresh(
    items: [FileProviderRemoteItem]
) -> FileProviderPollingRefresh {
    FileProviderPollingRefresh(
        items: items,
        anchor: NSFileProviderSyncAnchor(rawValue: Data()),
        delta: FileProviderSnapshotDelta(updated: items, deleted: [])
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
        let continuation: CheckedContinuation<Void, Error>
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                durations.append(duration)
                waiters.append(Waiter(id: id, continuation: continuation))
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

    func advance() {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
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
