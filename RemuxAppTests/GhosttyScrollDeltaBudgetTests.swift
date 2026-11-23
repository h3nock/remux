import XCTest
@testable import Remux

final class GhosttyScrollDeltaBudgetTests: XCTestCase {
    func testDefaultBurstBoundsInstantDump() {
        // At the pager cap (150 ticks/s equivalent) the default burst
        // must not allow a screenful teleport at gesture start.
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 150)
        let instantDump = budget.clamp(10_000, at: 0)
        XCTAssertLessThanOrEqual(instantDump, 150 * 0.1)
    }

    func testRouteForwardedGainDefaultsToOneStepPerRowOfTravel() {
        // No env override in the test process: the resolved gain is
        // the shipped default.
        XCTAssertEqual(GhosttyScrollTuning.routeForwardedGain, 1)
        XCTAssertEqual(GhosttyScrollTuning.routeForwardedDefaultGain, 1)
    }

    func testClampPassesDeltaWithinBudget() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.5)

        XCTAssertEqual(budget.clamp(30, at: 0), 30)
        XCTAssertEqual(budget.clamp(-20, at: 0.01), -20, accuracy: 1)
    }

    func testClampPreservesSign() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.1)

        XCTAssertEqual(budget.clamp(-500, at: 0), -10)
    }

    func testClampDropsExcessBeyondBurstCapacity() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        // Burst capacity is 25 units; a violent first delta saturates.
        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)
        XCTAssertEqual(budget.clamp(1_000, at: 0), 0)
    }

    func testBudgetRefillsWithElapsedTime() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)
        // 100 ms later: 10 more units became available.
        XCTAssertEqual(budget.clamp(1_000, at: 0.1), 10, accuracy: 0.000_1)
        // Refill never exceeds burst capacity even after long idle.
        XCTAssertEqual(budget.clamp(1_000, at: 60), 25, accuracy: 0.000_1)
    }

    func testSustainedRateConvergesToConfiguredThroughput() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        // Simulate a 2-second deceleration delivering far more delta
        // than the budget allows, in 60Hz callbacks.
        var emitted = 0.0
        var now = 0.0
        while now < 2.0 {
            emitted += budget.clamp(50, at: now)
            now += 1.0 / 60.0
        }

        // Burst (25) + 2s of refill (200), within one frame's tolerance.
        XCTAssertEqual(emitted, 225, accuracy: 50.0 / 60.0 + 0.001)
    }

    func testZeroDeltaConsumesNothing() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)

        XCTAssertEqual(budget.clamp(0, at: 0), 0)
        XCTAssertEqual(budget.clamp(25, at: 0), 25)
    }

    func testRearmResetsAvailabilityAndRate() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 100, burstSeconds: 0.25)
        XCTAssertEqual(budget.clamp(1_000, at: 0), 25)

        budget.rearm(unitsPerSecond: 200)

        // Fresh burst at the new rate, with no stale refill timestamp:
        // capacity is 200 * 0.25 = 50 immediately.
        XCTAssertEqual(budget.clamp(1_000, at: 0), 50)
    }

    func testTailCutoffStopsBelowQuantizationFloor() {
        var cutoff = GhosttyScrollTailCutoff(smoothing: 1)
        let cell = 20.0

        // 10 cells/s: well above the floor, keep coasting.
        XCTAssertFalse(cutoff.shouldStop(delta: 0, at: 0, cellHeightPoints: cell))
        XCTAssertFalse(cutoff.shouldStop(delta: 3.33, at: 1.0 / 60, cellHeightPoints: cell))

        // Decayed to ~1 cell/s: below the 6 cells/s floor.
        XCTAssertTrue(cutoff.shouldStop(delta: 0.33, at: 2.0 / 60, cellHeightPoints: cell))
    }

    func testTailCutoffSmoothingIgnoresSingleShortFrame() {
        var cutoff = GhosttyScrollTailCutoff(smoothing: 0.3)
        let cell = 20.0

        _ = cutoff.shouldStop(delta: 0, at: 0, cellHeightPoints: cell)
        // Sustained fast coast builds a high smoothed speed.
        var now = 0.0
        for _ in 0..<10 {
            now += 1.0 / 60
            XCTAssertFalse(cutoff.shouldStop(delta: 10, at: now, cellHeightPoints: cell))
        }
        // One near-zero frame (display-link hiccup) must not stop it.
        now += 1.0 / 60
        XCTAssertFalse(cutoff.shouldStop(delta: 0.2, at: now, cellHeightPoints: cell))
    }

    func testTailCutoffResetForgetsHistory() {
        var cutoff = GhosttyScrollTailCutoff(smoothing: 1)
        let cell = 20.0
        _ = cutoff.shouldStop(delta: 0, at: 0, cellHeightPoints: cell)
        XCTAssertTrue(cutoff.shouldStop(delta: 0.1, at: 1.0 / 60, cellHeightPoints: cell))

        cutoff.reset()
        // After reset the first sample only seeds the clock.
        XCTAssertFalse(cutoff.shouldStop(delta: 0.1, at: 1, cellHeightPoints: cell))
    }

    func testZeroRateBudgetBlocksEverything() {
        var budget = GhosttyScrollDeltaBudget(unitsPerSecond: 0)

        XCTAssertEqual(budget.clamp(100, at: 0), 0)
        XCTAssertEqual(budget.clamp(100, at: 10), 0)
    }
}
