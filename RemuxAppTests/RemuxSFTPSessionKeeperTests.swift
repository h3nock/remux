import Foundation
import Synchronization
import XCTest
@testable import Remux

final class RemuxSFTPSessionKeeperTests: XCTestCase {
    private typealias Keeper = RemuxSFTPSessionKeeper<String, Int>

    func testUsersOfOneKeyShareOneSession() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions()

        let first = try await keeper.lease(for: "server", open: sessions.opener())
        let second = try await keeper.lease(for: "server", open: sessions.opener())
        try await first.close()
        let third = try await keeper.lease(for: "server", open: sessions.opener())

        XCTAssertEqual([first.client, second.client, third.client], [1, 1, 1])
        XCTAssertEqual(sessions.openCount, 1)
        let other = try await keeper.lease(for: "other server", open: sessions.opener())
        XCTAssertEqual(other.client, 2, "each key has its own session")
    }

    func testUsersArrivingWhileTheSessionOpensWaitForTheSameOpen() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions(openDelay: .milliseconds(100))

        async let first = keeper.lease(for: "server", open: sessions.opener())
        async let second = keeper.lease(for: "server", open: sessions.opener())
        let clients = try await [first.client, second.client]

        XCTAssertEqual(clients, [1, 1])
        XCTAssertEqual(sessions.openCount, 1)
    }

    func testSessionClosesOnceItHasHadNoUsersForTheIdleTimeout() async throws {
        let clock = ManualClock()
        let keeper = Keeper(idleTimeout: .seconds(60), clock: clock)
        let sessions = FakeSFTPSessions()

        try await keeper.lease(for: "server", open: sessions.opener()).close()
        clock.advance(by: .seconds(59))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sessions.closeCount(of: 1), 0)

        clock.advance(by: .seconds(1))
        try await waitUntil { sessions.closeCount(of: 1) == 1 }
        let count = await keeper.sessionCountForTesting
        XCTAssertEqual(count, 0)

        let next = try await keeper.lease(for: "server", open: sessions.opener())
        XCTAssertEqual(next.client, 2, "the next user opens a new session")
    }

    func testSessionWithAUserStaysOpenPastTheIdleTimeout() async throws {
        let clock = ManualClock()
        let keeper = Keeper(idleTimeout: .seconds(60), clock: clock)
        let sessions = FakeSFTPSessions()

        let held = try await keeper.lease(for: "server", open: sessions.opener())
        try await keeper.lease(for: "server", open: sessions.opener()).close()
        clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(sessions.closeCount(of: 1), 0)
        try await held.close()
        clock.advance(by: .seconds(60))
        try await waitUntil { sessions.closeCount(of: 1) == 1 }
    }

    func testANewUserRestartsTheIdleTimeout() async throws {
        let clock = ManualClock()
        let keeper = Keeper(idleTimeout: .seconds(60), clock: clock)
        let sessions = FakeSFTPSessions()

        try await keeper.lease(for: "server", open: sessions.opener()).close()
        clock.advance(by: .seconds(40))
        try await Task.sleep(for: .milliseconds(30))
        try await keeper.lease(for: "server", open: sessions.opener()).close()
        clock.advance(by: .seconds(40))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(sessions.closeCount(of: 1), 0)
        XCTAssertEqual(sessions.openCount, 1)
        clock.advance(by: .seconds(20))
        try await waitUntil { sessions.closeCount(of: 1) == 1 }
    }

    func testClosingALeaseTwiceGivesBackOnePlace() async throws {
        let clock = ManualClock()
        let keeper = Keeper(idleTimeout: .seconds(60), clock: clock)
        let sessions = FakeSFTPSessions()

        let held = try await keeper.lease(for: "server", open: sessions.opener())
        let closedTwice = try await keeper.lease(for: "server", open: sessions.opener())
        try await closedTwice.close()
        try await closedTwice.close()
        clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(sessions.closeCount(of: 1), 0, "the other lease still holds the session")
        try await held.close()
    }

    func testUnusableSessionIsDroppedAndNeverHandedOutAgain() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions()

        let first = try await keeper.lease(for: "server", open: sessions.opener())
        sessions.makeUnusable(1)
        let second = try await keeper.lease(for: "server", open: sessions.opener())
        let third = try await keeper.lease(for: "server", open: sessions.opener())

        XCTAssertEqual(first.client, 1)
        XCTAssertEqual([second.client, third.client], [2, 2])
        try await waitUntil { sessions.closeCount(of: 1) == 1 }
        // Its last user's lease still closes normally.
        try await first.close()
        XCTAssertEqual(sessions.closeCount(of: 1), 1)
        XCTAssertEqual(sessions.closeCount(of: 2), 0)
    }

    func testFailedOpenIsNotKept() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions(failingOpens: 1)

        do {
            _ = try await keeper.lease(for: "server", open: sessions.opener())
            XCTFail("Expected the open to fail")
        } catch is FakeSFTPSessions.OpenFailure {
        }
        let lease = try await keeper.lease(for: "server", open: sessions.opener())

        XCTAssertEqual(lease.client, 2)
        XCTAssertEqual(sessions.openCount, 2)
    }

    func testCloseIdleSessionsClosesOnlyMatchingSessionsWithoutUsers() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions()

        try await keeper.lease(for: "edited", open: sessions.opener()).close()
        let held = try await keeper.lease(for: "edited busy", open: sessions.opener())
        try await keeper.lease(for: "other", open: sessions.opener()).close()
        await keeper.closeIdleSessions { $0.hasPrefix("edited") }

        XCTAssertEqual(sessions.closeCount(of: 1), 1)
        XCTAssertEqual(sessions.closeCount(of: 2), 0)
        XCTAssertEqual(sessions.closeCount(of: 3), 0)
        try await held.close()
    }

    func testUploadsOnOneKeyRunOneAtATimeInTheOrderTheyBegan() async throws {
        let keeper = Keeper()
        let log = EventLog()
        let firstGate = AsyncSignal()

        let first = Task {
            try await keeper.withUploadTurn(for: "server") {
                log.append("first start")
                await firstGate.wait()
                log.append("first end")
            }
        }
        try await waitUntil { log.events == ["first start"] }
        let second = Task {
            try await keeper.withUploadTurn(for: "server") { log.append("second") }
        }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task {
            try await keeper.withUploadTurn(for: "server") { log.append("third") }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(log.events, ["first start"], "later uploads wait their turn")

        await firstGate.open()
        try await first.value
        try await second.value
        try await third.value
        XCTAssertEqual(log.events, ["first start", "first end", "second", "third"])
    }

    func testOtherKeysAndSessionUsersDontWaitForAnUpload() async throws {
        let keeper = Keeper()
        let sessions = FakeSFTPSessions()
        let gate = AsyncSignal()
        let started = AsyncSignal()

        let upload = Task {
            try await keeper.withUploadTurn(for: "server") {
                await started.open()
                await gate.wait()
            }
        }
        await started.wait()

        try await keeper.withUploadTurn(for: "other server") {}
        let preview = try await keeper.lease(for: "server", open: sessions.opener())
        try await preview.close()

        await gate.open()
        try await upload.value
    }

    func testCancelledWaitLeavesTheLine() async throws {
        let keeper = Keeper()
        let log = EventLog()
        let gate = AsyncSignal()
        let started = AsyncSignal()

        let first = Task {
            try await keeper.withUploadTurn(for: "server") {
                await started.open()
                await gate.wait()
                log.append("first")
            }
        }
        await started.wait()
        let cancelled = Task {
            try await keeper.withUploadTurn(for: "server") { log.append("cancelled") }
        }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task {
            try await keeper.withUploadTurn(for: "server") { log.append("third") }
        }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()

        do {
            try await cancelled.value
            XCTFail("Expected the cancelled wait to throw")
        } catch is CancellationError {
        }
        await gate.open()
        try await first.value
        try await third.value
        XCTAssertEqual(log.events, ["first", "third"])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }
}

/// Sessions numbered in the order they open, each recording its closes.
private final class FakeSFTPSessions: Sendable {
    struct OpenFailure: Error {}

    private struct State {
        var openCount = 0
        var failingOpens: Int
        var unusable: Set<Int> = []
        var closes: [Int: Int] = [:]
    }

    private let state: Mutex<State>
    private let openDelay: Duration?

    init(openDelay: Duration? = nil, failingOpens: Int = 0) {
        self.openDelay = openDelay
        self.state = Mutex(State(failingOpens: failingOpens))
    }

    var openCount: Int {
        state.withLock { $0.openCount }
    }

    func closeCount(of session: Int) -> Int {
        state.withLock { $0.closes[session, default: 0] }
    }

    func makeUnusable(_ session: Int) {
        state.withLock { _ = $0.unusable.insert(session) }
    }

    func opener() -> @Sendable () async throws -> RemuxSFTPSessionKeeper<String, Int>.Session {
        { [self] in
            if let openDelay {
                try await Task.sleep(for: openDelay)
            }
            let (number, fails) = state.withLock { state -> (Int, Bool) in
                state.openCount += 1
                guard state.failingOpens == 0 else {
                    state.failingOpens -= 1
                    return (state.openCount, true)
                }
                return (state.openCount, false)
            }
            if fails {
                throw OpenFailure()
            }
            return RemuxSFTPSessionKeeper<String, Int>.Session(
                client: number,
                isUsable: { [self] in state.withLock { !$0.unusable.contains(number) } },
                close: { [self] in state.withLock { $0.closes[number, default: 0] += 1 } }
            )
        }
    }
}

private final class EventLog: Sendable {
    private let entries = Mutex<[String]>([])

    var events: [String] {
        entries.withLock { $0 }
    }

    func append(_ event: String) {
        entries.withLock { $0.append(event) }
    }
}

private actor AsyncSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
