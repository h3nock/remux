import FileProvider
import XCTest

@testable import Remux

final class FileProviderDomainOperationCoordinatorTests: XCTestCase {
    func testMutationWaitsForRefreshAndNextRefreshWaitsForMutation() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let refreshGate = FileProviderBlockingGate()
        let mutationGate = FileProviderBlockingGate()

        let firstRefresh = Task {
            try await coordinator.performRefresh(directory: .root) {
                await events.record("refresh-1-start")
                await refreshGate.wait()
                await events.record("refresh-1-end")
                return fileProviderTestRefresh()
            }
        }
        await refreshGate.waitUntilEntered()
        let mutation = Task {
            try await coordinator.performMutation {
                await events.record("mutation-start")
                await mutationGate.wait()
                await events.record("mutation-end")
                return 2
            }
        }
        await coordinator.waitUntilMutationIsQueued()
        let secondRefresh = Task {
            try await coordinator.performRefresh(directory: .root) {
                await events.record("refresh-2")
                return fileProviderTestRefresh()
            }
        }

        await refreshGate.release()
        await mutationGate.waitUntilEntered()
        let eventsBeforeMutationCompletes = await events.values()
        XCTAssertEqual(
            eventsBeforeMutationCompletes,
            ["refresh-1-start", "refresh-1-end", "mutation-start"]
        )
        await mutationGate.release()
        _ = try await (firstRefresh.value, mutation.value, secondRefresh.value)
        let completedEvents = await events.values()
        XCTAssertEqual(
            completedEvents,
            [
                "refresh-1-start", "refresh-1-end", "mutation-start",
                "mutation-end", "refresh-2",
            ]
        )
    }

    func testDifferentDirectoryRefreshesQueue() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let gate = FileProviderBlockingGate()
        let directory = try FileProviderRemotePath(relative: "nested")

        let first = Task {
            try await coordinator.performRefresh(directory: .root) {
                await events.record("root-start")
                await gate.wait()
                await events.record("root-end")
                return fileProviderTestRefresh()
            }
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await coordinator.performRefresh(directory: directory) {
                await events.record("nested")
                return fileProviderTestRefresh()
            }
        }

        let eventsBeforeRelease = await events.values()
        XCTAssertEqual(eventsBeforeRelease, ["root-start"])
        await gate.release()
        _ = try await (first.value, second.value)
        let completedEvents = await events.values()
        XCTAssertEqual(completedEvents, ["root-start", "root-end", "nested"])
    }

    func testMutationsRunInFirstInFirstOutOrder() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let firstGate = FileProviderBlockingGate()
        let secondGate = FileProviderBlockingGate()

        let first = Task {
            try await coordinator.performMutation {
                await events.record("first-start")
                await firstGate.wait()
                await events.record("first-end")
                return 1
            }
        }
        await firstGate.waitUntilEntered()
        let second = Task {
            try await coordinator.performMutation {
                await events.record("second-start")
                await secondGate.wait()
                await events.record("second-end")
                return 2
            }
        }

        await firstGate.release()
        await secondGate.waitUntilEntered()
        let eventsBeforeSecondCompletes = await events.values()
        XCTAssertEqual(
            eventsBeforeSecondCompletes,
            ["first-start", "first-end", "second-start"]
        )
        await secondGate.release()
        _ = try await (first.value, second.value)
        let completedEvents = await events.values()
        XCTAssertEqual(
            completedEvents,
            ["first-start", "first-end", "second-start", "second-end"]
        )
    }

    func testCancelledQueuedMutationDetachesBeforeItsTurn() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let gate = FileProviderBlockingGate()

        let active = Task {
            try await coordinator.performMutation {
                await events.record("active")
                await gate.wait()
                return 1
            }
        }
        await gate.waitUntilEntered()
        let cancelled = Task {
            try await coordinator.performMutation {
                await events.record("cancelled")
                return 2
            }
        }

        cancelled.cancel()
        await XCTAssertThrowsCancellationAsync { try await cancelled.value }
        await gate.release()
        _ = try await active.value
        let eventsAfterCancellation = await events.values()
        XCTAssertEqual(eventsAfterCancellation, ["active"])
    }

    func testCancellingLastActiveWaiterCancelsItsOperation() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()

        let operation = Task {
            try await coordinator.performMutation {
                await events.record("started")
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        await events.waitUntilRecorded("started")

        operation.cancel()
        await XCTAssertThrowsCancellationAsync { try await operation.value }
    }

    func testRefreshQueuedAfterCancelledActiveRefreshRunsIndependently() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let firstGate = FileProviderBlockingGate()
        let secondGate = FileProviderBlockingGate()

        let first = Task {
            try await coordinator.performRefresh(directory: .root) {
                await events.record("first-start")
                await firstGate.wait()
                try Task.checkCancellation()
                return fileProviderTestRefresh()
            }
        }
        await firstGate.waitUntilEntered()

        first.cancel()
        await XCTAssertThrowsCancellationAsync { try await first.value }

        let second = Task {
            try await coordinator.performRefresh(directory: .root) {
                await events.record("second-start")
                await secondGate.wait()
                return fileProviderTestRefresh()
            }
        }
        await coordinator.waitUntilRefreshIsQueued(directory: .root)

        await firstGate.release()
        await secondGate.waitUntilEntered()
        await secondGate.release()
        _ = try await second.value
        let completedEvents = await events.values()
        XCTAssertEqual(completedEvents, ["first-start", "second-start"])
    }
}

private func fileProviderTestRefresh() -> FileProviderPollingRefresh {
    FileProviderPollingRefresh(
        items: [],
        anchor: NSFileProviderSyncAnchor(Data()),
        delta: FileProviderSnapshotDelta(updated: [], deleted: [])
    )
}

private actor FileProviderTestEventRecorder {
    private var events: [String] = []
    private var recordWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: String) {
        events.append(event)
        recordWaiters.removeValue(forKey: event)?.forEach { $0.resume() }
    }

    func values() -> [String] {
        events
    }

    func waitUntilRecorded(_ event: String) async {
        guard !events.contains(event) else { return }
        await withCheckedContinuation {
            recordWaiters[event, default: []].append($0)
        }
    }
}

private actor FileProviderBlockingGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func XCTAssertThrowsCancellationAsync<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected cancellation", file: file, line: line)
    } catch {
        XCTAssertTrue(error is CancellationError, file: file, line: line)
    }
}
