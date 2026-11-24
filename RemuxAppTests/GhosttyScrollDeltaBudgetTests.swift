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

final class GhosttyViewportShiftTests: XCTestCase {
    /// A header, rows `first...`, and an input box: what a full-screen agent shows.
    private func frame(first: Int, body: Int = 12) -> [Substring] {
        var rows = ["Agent v1"] + (first..<(first + body)).map { "R\($0)  text \($0 * 7919)" }
        rows += ["", "> type here", "", ""]
        return rows.map { Substring($0) }
    }

    func testRowsMovedDownAndUpAreCountedPastTheHeaderAndInputBox() {
        var staticRows: Set<Int> = []
        XCTAssertEqual(GhosttyViewportShift.between(frame(first: 100), frame(first: 97), staticRows: &staticRows), .moved(3))
        XCTAssertEqual(GhosttyViewportShift.between(frame(first: 97), frame(first: 98), staticRows: &staticRows), .moved(-1))
        XCTAssertEqual(GhosttyViewportShift.between(frame(first: 98), frame(first: 98), staticRows: &staticRows), .unchanged)
    }

    /// Half of the rows already show the new position and half the old: counting that as movement and then
    /// counting the finished frame again would double the distance.
    func testHalfRepaintedFrameIsNotCountedAsMovement() {
        var staticRows: Set<Int> = []
        let old = frame(first: 100)
        let done = frame(first: 98)
        let half = Array(done[..<7] + old[7...])
        XCTAssertEqual(GhosttyViewportShift.between(old, half, staticRows: &staticRows), .unclear)
        XCTAssertEqual(GhosttyViewportShift.between(old, done, staticRows: &staticRows), .moved(2))
    }

    func testARowRedrawnInPlaceIsNotMovement() {
        var staticRows: Set<Int> = []
        var spinner = frame(first: 100)
        spinner[14] = "> type here |"
        XCTAssertEqual(GhosttyViewportShift.between(frame(first: 100), spinner, staticRows: &staticRows), .redrawn)
    }

    func testRepeatedAndBlankRowsDoNotVote() {
        var staticRows: Set<Int> = []
        let old = (0..<10).map { Substring($0 < 4 ? "R\($0)" : "same") }
        let new = (0..<10).map { Substring($0 < 4 ? "R\($0 + 1)" : "same") }
        // Three numbered rows moved up by one; the six equal rows say nothing.
        XCTAssertEqual(GhosttyViewportShift.between(old, new, staticRows: &staticRows), .moved(-1))
    }

    /// A pane restored from tmux's `capture-pane -N`, where erased cells come back as spaces, and the same pane
    /// after the program's first one-row scroll frame, which erases to the end of each row it shortens.
    func testRowsRestoredFromTmuxWithSpacesAfterTheirTextStillMatchTheRepaintedRows() {
        var staticRows: Set<Int> = []
        let restored: [String] = [
            "  R0567 ################ ",
            "  R0568 #######################                   ",
            "  R0569 #######                                   ",
            "  R0570 ##############                            ",
            "  R0571 #####################                     ",
            "  R0572 #####            ",
            "  R0573 ############                              ",
            "  R0574 ###################                       ",
            "  R0575 ### ",
            "  R0576 ##########       ",
            "  R0577 #################                         ",
            "  R0578 ########################                  ",
            "  R0579 ########         ",
            "  R0580 ###############  ",
            "  R0581 ######################                    ",
            "  R0582 ######           ",
            "  R0583 #############    ",
            "  R0584 ####################                      ",
            "  R0585 ####",
            "  R0586 ###########      ",
            "  R0587 ##################                        ",
            "  R0588 #########################                 ",
            "  R0589 #########        ",
            "  R0590 ################ ",
            "  R0591 #######################                   ",
            "  R0592 #######          ",
            "  R0593 ##############   ",
            "  R0594 #####################                     ",
            "  R0595 #####            ",
            "  R0596 ############     ",
            "  R0597 ###################                       ",
            "  R0598 ### ",
            "  R0599 ##########       ",
            "  R0600 #################                         ",
            "",
            "✻ Sautéed for 0s · done 11:24 PM                  ",
            "                                                  ",
            "──────────────────────────────────────────────────",
            "❯                                                 ",
            "──────────────────────────────────────────────────",
            "  ⏵⏵ auto mode on (shift+tab to cycle)            ",
        ]
        let scrolled: [String] = [
            "  R0566 #########",
            "  R0567 ################",
            "  R0568 #######################                   ",
            "  R0569 #######",
            "  R0570 ##############",
            "  R0571 #####################",
            "  R0572 #####",
            "  R0573 ############",
            "  R0574 ###################",
            "  R0575 ###",
            "  R0576 ##########",
            "  R0577 #################",
            "  R0578 ########################",
            "  R0579 ########",
            "  R0580 ###############",
            "  R0581 ######################",
            "  R0582 ######",
            "  R0583 #############",
            "  R0584 ####################",
            "  R0585 ####",
            "  R0586 ###########",
            "  R0587 ##################",
            "  R0588 #########################",
            "  R0589 #########",
            "  R0590 ################",
            "  R0591 #######################",
            "  R0592 #######",
            "  R0593 ##############",
            "  R0594 #####################",
            "  R0595 #####",
            "  R0596 ############",
            "  R0597 ###################",
            "  R0598 ###",
            "  R0599 ##########",
            "  R0600 #################",
            "",
            "                                                  ",
            "──────────────────────────────────────────────────",
            "❯                                                 ",
            "──────────────────────────────────────────────────",
            "  ⏵⏵ auto mode on (shift+tab to cycle)            ",
        ]
        XCTAssertEqual(
            GhosttyViewportShift.between(restored.map { Substring($0) }, scrolled.map { Substring($0) }, staticRows: &staticRows),
            .moved(1)
        )
    }

    func testAnUnrelatedFrameIsUnclear() {
        var staticRows: Set<Int> = []
        let other = (0..<16).map { Substring("other \($0)") }
        XCTAssertEqual(GhosttyViewportShift.between(frame(first: 100), other, staticRows: &staticRows), .unclear)
    }
}

final class GhosttyScrollFollowTests: XCTestCase {
    /// A program that scrolls a numbered list by `rows(gap)` per report, `latency` after the report is sent.
    private struct Program {
        var first = 5000
        var lastReportAt: TimeInterval = -1
        var limit: ClosedRange<Int> = 0...10_000
        let rows: (TimeInterval) -> Int

        mutating func receive(direction: Int, at now: TimeInterval) {
            let step = rows(now - lastReportAt)
            lastReportAt = now
            first = min(max(first - direction * step, limit.lowerBound), limit.upperBound)
        }

        var viewport: String {
            (["Agent"] + (first..<(first + 30)).map { "R\($0)" } + ["", "> input"]).joined(separator: "\n")
        }
    }

    /// Drag 14 rows in 0.4 s, then coast as UIKit does (speed x 0.998 per millisecond), 31.7 rows in all.
    private func target(at t: TimeInterval) -> Double {
        let dragRows = 14.0, dragTime = 0.4
        guard t > dragTime else { return dragRows * max(t, 0) / dragTime }
        let decay = -log(0.998) * 1000
        return dragRows + dragRows / dragTime / decay * (1 - exp(-decay * (t - dragTime)))
    }

    private func run(
        _ program: inout Program,
        latency: TimeInterval,
        pictureDelay: TimeInterval = 0,
        seconds: TimeInterval = 4,
        reportsPerSecond: Double = 60,
        target: ((TimeInterval) -> Double)? = nil
    ) -> (follow: GhosttyScrollFollow, moved: Int, furthestAhead: Double) {
        let target = target ?? self.target(at:)
        var follow = GhosttyScrollFollow(reportsPerSecond: reportsPerSecond, burstSeconds: 0.08, latency: 0.08)
        let start = program.first
        var arrivals: [(at: TimeInterval, direction: Int)] = []
        var visible: [(at: TimeInterval, text: String)] = []
        var shown = program.viewport
        var furthestAhead = 0.0
        var last = 0.0
        follow.observe(viewportRows: shown, at: 0)
        for tick in 1...Int(seconds * 120) {
            let now = Double(tick) / 120
            while let next = arrivals.first, next.at <= now {
                arrivals.removeFirst()
                program.receive(direction: next.direction, at: next.at)
                visible.append((next.at + latency / 2 + pictureDelay, program.viewport))
            }
            while let next = visible.first, next.at <= now {
                visible.removeFirst()
                shown = next.text
            }
            follow.moveTarget(byRows: target(now) - last)
            last = target(now)
            follow.observe(viewportRows: shown, at: now)
            var direction = follow.nextReport(at: now)
            while direction != 0 {
                arrivals.append((now + latency / 2, direction))
                direction = follow.nextReport(at: now)
            }
            furthestAhead = max(furthestAhead, Double(start - program.first) - follow.targetRows)
        }
        return (follow, start - program.first, furthestAhead)
    }

    func testOneRowPerReportEndsOnTheTarget() {
        var program = Program { _ in 1 }
        let result = run(&program, latency: 0.03)
        XCTAssertEqual(Double(result.moved), result.follow.targetRows, accuracy: 1)
        XCTAssertEqual(result.follow.reportCount, result.moved)
    }

    func testThreeRowsPerReportEndsOnTheTargetWithAThirdOfTheReports() {
        var program = Program { _ in 3 }
        let result = run(&program, latency: 0.03)
        XCTAssertEqual(Double(result.moved), result.follow.targetRows, accuracy: 2)
        XCTAssertEqual(result.follow.rowsPerReport, 3, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result.follow.reportCount, 12)
    }

    /// A program that moves further per report when reports come close together would run away from a rule that
    /// sends one report per row.
    func testAProgramThatSpeedsUpWithCloseReportsStillEndsNearTheTarget() {
        var gain = 1.0
        var program = Program { gap in
            gain = gap > 0.04 ? 1 : min(6, gain + 0.3)
            return Int(gain)
        }
        let result = run(&program, latency: 0.03)
        XCTAssertEqual(Double(result.moved), result.follow.targetRows, accuracy: 3)
        XCTAssertLessThan(result.furthestAhead, 4)
    }

    func testANetworkDelayDoesNotMultiplyReports() {
        var program = Program { _ in 1 }
        let result = run(&program, latency: 0.2)
        XCTAssertEqual(Double(result.moved), result.follow.targetRows, accuracy: 1)
        XCTAssertEqual(result.follow.reportCount, result.moved)
    }

    /// A link that delivers the picture a second late leaves the content unseen for longer than any round trip
    /// the follow has timed. It must fall back to a report per row, not send more.
    func testALatePictureNeverCostsMoreThanAReportPerRow() {
        var program = Program { _ in 1 }
        let result = run(&program, latency: 0.03, pictureDelay: 1.0, seconds: 6)
        XCTAssertLessThanOrEqual(Double(result.follow.reportCount), result.follow.targetRows)
        XCTAssertLessThanOrEqual(Double(result.moved), result.follow.targetRows)
        XCTAssertGreaterThan(Double(result.moved), result.follow.targetRows - 3)
    }

    /// At its first row a program moves nothing. That must not turn into a flood of reports.
    func testAProgramAtItsEndGetsNoMoreReportsThanRowsOfTravel() {
        var program = Program { _ in 1 }
        program.limit = 4995...10_000
        let result = run(&program, latency: 0.03)
        XCTAssertEqual(result.moved, 5)
        XCTAssertLessThanOrEqual(Double(result.follow.reportCount), result.follow.targetRows + 4)
    }

    /// Reports whose movement was seen before their round trip ran out moved the content: when they run out during a
    /// pause, they must not count as reports that moved nothing, or the drag that follows owes them back.
    func testADragThatPausesFollowsTheFingerOnceItMovesAgain() {
        var program = Program { _ in 1 }
        // A quick 30 rows in 0.1 s, a pause, then 5 rows more.
        let result = run(&program, latency: 0.03, seconds: 2, reportsPerSecond: 600) { t in
            switch t {
            case ..<0.1: 30 * t / 0.1
            case ..<1.1: 30
            case ..<1.35: 30 + 5 * (t - 1.1) / 0.25
            default: 35
            }
        }
        XCTAssertEqual(result.moved, 35)
    }

    /// The first reports of a drag that starts over a program's input box move nothing. Once the finger has been
    /// there longer than any round trip, the round trip is timed from a report that moves the content.
    func testIgnoredReportsDoNotLengthenTheRoundTrip() {
        var sent = 0
        var program = Program { _ in
            sent += 1
            return sent <= 6 ? 0 : 1
        }
        // A slow drag: 12 rows in 1.2 s, its first 0.6 s over the input box.
        let result = run(&program, latency: 0.03, seconds: 2) { t in min(t, 1.2) * 10 }
        XCTAssertLessThan(result.follow.latency, 0.1)
    }

    /// A slow link's round trip is learnt, also when it is longer than the first guess by more than the guess.
    func testASlowLinksRoundTripIsLearnt() {
        var program = Program { _ in 1 }
        let result = run(&program, latency: 0.3, seconds: 3)
        XCTAssertGreaterThan(result.follow.latency, 0.25)
    }

    func testContentAheadOfTheTargetIsNotPulledBack() {
        var follow = GhosttyScrollFollow(reportsPerSecond: 60, burstSeconds: 0.08, latency: 0.03)
        let rows = { (first: Int) in (first..<(first + 20)).map { "R\($0)" }.joined(separator: "\n") }
        follow.observe(viewportRows: rows(100), at: 0)
        follow.moveTarget(byRows: 1)
        XCTAssertEqual(follow.nextReport(at: 0.01), 1)
        // The program jumped six rows for that one report.
        follow.observe(viewportRows: rows(94), at: 0.05)
        follow.moveTarget(byRows: 0.5)
        XCTAssertEqual(follow.nextReport(at: 0.2), 0)
        // The finger turns round and passes where the content is.
        follow.moveTarget(byRows: -8)
        XCTAssertEqual(follow.nextReport(at: 0.3), -1)
    }
}
