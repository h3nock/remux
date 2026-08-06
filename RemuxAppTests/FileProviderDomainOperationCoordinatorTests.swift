import XCTest

@testable import Remux

final class FileProviderDomainOperationCoordinatorTests: XCTestCase {
    func testOperationsRunInFirstInFirstOutOrder() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let firstGate = FileProviderBlockingGate()

        let first = Task {
            try await coordinator.perform {
                await events.record("first-start")
                await firstGate.wait()
                await events.record("first-end")
                return 1
            }
        }
        await firstGate.waitUntilEntered()

        let secondSubmitter = FileProviderOperationSubmitter<Int>()
        let second = Task {
            try await secondSubmitter.submit(to: coordinator) {
                await events.record("second")
                return 2
            }
        }
        await secondSubmitter.waitUntilSubmitted()

        let thirdSubmitter = FileProviderOperationSubmitter<Int>()
        let third = Task {
            try await thirdSubmitter.submit(to: coordinator) {
                await events.record("third")
                return 3
            }
        }
        await thirdSubmitter.waitUntilSubmitted()

        await firstGate.release()
        _ = try await (first.value, second.value, third.value)

        let completedEvents = await events.values()
        XCTAssertEqual(
            completedEvents,
            ["first-start", "first-end", "second", "third"]
        )
    }

    func testPerformReturnsTheOperationValue() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()

        let value = try await coordinator.perform {
            "value"
        }

        XCTAssertEqual(value, "value")
    }

    func testFailureReleasesTheNextOperation() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let firstGate = FileProviderBlockingGate()

        let first = Task {
            try await coordinator.perform { () -> Int in
                await events.record("first")
                await firstGate.wait()
                throw FileProviderCoordinatorTestError.expected
            }
        }
        await firstGate.waitUntilEntered()

        let secondSubmitter = FileProviderOperationSubmitter<Int>()
        let second = Task {
            try await secondSubmitter.submit(to: coordinator) {
                await events.record("second")
                return 2
            }
        }

        await secondSubmitter.waitUntilSubmitted()
        await firstGate.release()
        await XCTAssertThrowsCoordinatorTestErrorAsync { try await first.value }
        let secondValue = try await second.value

        XCTAssertEqual(secondValue, 2)
        let completedEvents = await events.values()
        XCTAssertEqual(completedEvents, ["first", "second"])
    }

    func testCancelledQueuedOperationNeverStarts() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let activeGate = FileProviderBlockingGate()

        let active = Task {
            try await coordinator.perform {
                await events.record("active")
                await activeGate.wait()
                return 1
            }
        }
        await activeGate.waitUntilEntered()

        let cancelledSubmitter = FileProviderOperationSubmitter<Int>()
        let cancelled = Task {
            try await cancelledSubmitter.submit(to: coordinator) {
                await events.record("cancelled")
                return 2
            }
        }
        await cancelledSubmitter.waitUntilSubmitted()
        cancelled.cancel()

        await XCTAssertThrowsCancellationAsync { try await cancelled.value }
        await activeGate.release()
        _ = try await active.value

        let eventsAfterCancellation = await events.values()
        XCTAssertEqual(eventsAfterCancellation, ["active"])
    }

    func testCancellingActiveOperationCancelsItsBody() async throws {
        let coordinator = FileProviderDomainOperationCoordinator()
        let events = FileProviderTestEventRecorder()
        let cancellation = FileProviderCancellationRecorder()

        let operation = Task {
            try await coordinator.perform {
                await events.record("started")
                return try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(60))
                    return 1
                } onCancel: {
                    Task { await cancellation.record() }
                }
            }
        }
        await events.waitUntilRecorded("started")

        operation.cancel()
        await cancellation.wait()
        await XCTAssertThrowsCancellationAsync { try await operation.value }
    }
}

private enum FileProviderCoordinatorTestError: Error {
    case expected
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

private actor FileProviderCancellationRecorder {
    private var wasRecorded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        wasRecorded = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !wasRecorded else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor FileProviderOperationSubmitter<Value: Sendable> {
    private var hasSubmitted = false
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []

    func submit(
        to coordinator: FileProviderDomainOperationCoordinator,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        hasSubmitted = true
        submissionWaiters.forEach { $0.resume() }
        submissionWaiters.removeAll()
        return try await coordinator.perform(operation)
    }

    func waitUntilSubmitted() async {
        guard !hasSubmitted else { return }
        await withCheckedContinuation { submissionWaiters.append($0) }
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

private func XCTAssertThrowsCoordinatorTestErrorAsync<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected coordinator test error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? FileProviderCoordinatorTestError, .expected)
    }
}
