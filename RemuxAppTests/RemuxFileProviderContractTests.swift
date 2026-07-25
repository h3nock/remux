import FileProvider
import Foundation
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
                return firstItems
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return secondItems
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        await gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(firstResult, firstItems)
        XCTAssertEqual(secondResult, firstItems)
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
                return firstItems
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: secondDirectory) {
                await gate.recordUnexpectedOperation()
                return secondItems
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        await gate.release()

        _ = try await first.value
        let secondResult = try await second.value
        let operationCount = await gate.operationCount()
        XCTAssertEqual(secondResult, secondItems)
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
                return items
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
                return items
            }
        }
        await gate.waitUntilStarted()
        let second = Task {
            try await coordinator.refresh(directory: directory) {
                await gate.recordUnexpectedOperation()
                return []
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
        XCTAssertEqual(firstResult, items)
        XCTAssertFalse(networkWasCancelled)
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
