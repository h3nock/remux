import XCTest
@testable import Remux

final class GhosttyScrollFollowerTests: XCTestCase {
    // MARK: The design's reference model

    /// `Fixtures/ScrollFollower/scroll-follower-parity.json` holds traces of the design's reference model (`follow.py`
    /// and `ledger.py`, driven by `parity.py`, in remux-docs evidence/scroll-follower-20261125/reference) against a
    /// simulated program that moves one, three, or an accelerating number of rows per report, ignores reports over its
    /// input box, drops the first report after a change of direction, draws some answers in two pieces or two
    /// repaints, once freezes, streams a reply at the live edge, sends its frames on a 16 ms cadence as Herdr does,
    /// reads its input only every 30 ms, takes reports and draws them only later, as Codex was seen to, falls behind on
    /// its input while the server hands it keys late, as opencode was seen to, or moves much less in the last stretch of
    /// its transcript, as Claude Code was seen to. Some traces
    /// are in a pane like the rig's, where a steady program is proven and its batches extended, and Claude Code's
    /// stand-in is refused after its trial. Each trace is every call the follower got, in order, and what each tick
    /// returned; the port has to return the same.
    func testMakesTheReferenceModelsDecisions() throws {
        let fixture = try Self.parityFixture()
        let traces = try XCTUnwrap(fixture["traces"] as? [[String: Any]])
        XCTAssertEqual(traces.count, 23)
        for (traceIndex, trace) in traces.enumerated() {
            let touch = try XCTUnwrap(trace["touch"] as? Int)
            let body = try XCTUnwrap(trace["body"] as? Int)
            let gridRows = body + 4
            let screen = { (spec: (offset: Int, previous: Int, drawn: Int)) in Self.screen(spec, body: body) }
            var current = try Self.spec(trace["first"])
            var follower = GhosttyScrollFollower(gridRows: gridRows)
            var sends = 0
            let calls = try XCTUnwrap(trace["calls"] as? [[Any]])
            for (callIndex, call) in calls.enumerated() {
                let label = "trace \(traceIndex) (\(trace["kind"] ?? "") \(trace["gestures"] ?? "")) call \(callIndex)"
                switch call[0] as? String {
                case "receipt":
                    follower.receipt(rows: screen(try Self.spec(call[2])), now: try Self.number(call[1]))
                case "frame":
                    current = try Self.spec(call[2])
                    follower.frame(screen(current), now: try Self.number(call[1]))
                case "caught":
                    follower.caught(target: try Self.number(call[1]))
                case "tick":
                    let step = follower.tick(
                        target: try Self.number(call[2]),
                        active: try Self.number(call[3]) != 0,
                        touchRow: touch,
                        now: try Self.number(call[1]),
                        rows: screen(current)
                    )
                    let expected = try Self.expectedStep(call[4])
                    guard step == expected else {
                        XCTFail("\(label): \(step), the reference model \(expected)")
                        return
                    }
                    if case .live(.some) = step { sends += 1 }
                default:
                    XCTFail("\(label): unknown call \(call)")
                    return
                }
            }
            XCTAssertGreaterThan(sends, 0)
            let memory = try XCTUnwrap(trace["memory"] as? [String: Any])
            let yields = try XCTUnwrap(memory["yields"] as? [String: Double])
            XCTAssertEqual(
                follower.memory.yields,
                Dictionary(uniqueKeysWithValues: yields.map { (Int($0.key)!, $0.value) }),
                "trace \(traceIndex)"
            )
            let band = try XCTUnwrap(memory["band"] as? [Int])
            XCTAssertEqual(follower.memory.band, band[0]...band[1], "trace \(traceIndex)")
            XCTAssertEqual(follower.memory.pipe, memory["pipe"] as? Bool, "trace \(traceIndex)")
            XCTAssertEqual(follower.memory.held, try XCTUnwrap(memory["held"] as? Int), "trace \(traceIndex)")
        }
    }

    /// The traces cover each way an extended batch ends, so the port is checked on all of them.
    func testTracesCoverEveryWayABatchIsExtendedOrEnds() throws {
        let traces = try XCTUnwrap(Self.parityFixture()["traces"] as? [[String: Any]])
        let pipes = traces.compactMap { ($0["memory"] as? [String: Any])?["pipe"] as? Bool }
        XCTAssertTrue(pipes.contains(true))
        XCTAssertTrue(pipes.contains(false))
    }

    // MARK: The ledger

    func testHalfDrawnCopyIsNotCountedTwice() {
        var ledger = GhosttyScrollLedger(band: nil)
        let rows = (0..<20).map { "line \($0)" }
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 0)))
        // A copy whose top half has moved by three rows and whose bottom half is still the old picture.
        let half = Array(Self.window(rows, at: 3).prefix(4)) + Array(Self.window(rows, at: 0).suffix(4))
        _ = ledger.locate(half)
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 3)))
        XCTAssertEqual(ledger.offset, 3)
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 3)))
        XCTAssertEqual(ledger.offset, 3)
    }

    func testBandLearnedFromAHalfDrawnCopyGrowsToEveryRowThatSlid() {
        var ledger = GhosttyScrollLedger(band: nil)
        let screen = { (offset: Int, drawn: Int, previous: Int) -> [String] in
            ["HEADER"] + (0..<10).map { "line \(($0 < drawn ? offset : previous) + $0)" } + ["> type here"]
        }
        XCTAssertTrue(ledger.locate(screen(20, 10, 20)))
        // The first copy after a move of three rows toward earlier ones has only its top five rows redrawn.
        XCTAssertTrue(ledger.locate(screen(17, 5, 20)))
        XCTAssertEqual(ledger.offset, -3)
        XCTAssertEqual(ledger.band, 1...5)
        // The rest of the redraw shows every scrolling row shifted from where the copy before the move had it.
        XCTAssertTrue(ledger.locate(screen(17, 10, 17)))
        XCTAssertEqual(ledger.band, 1...10)
        XCTAssertTrue(ledger.locate(screen(14, 10, 14)))
        XCTAssertEqual(ledger.offset, -6)
    }

    func testRowsThatRecurDecideNothing() {
        var ledger = GhosttyScrollLedger(band: nil)
        // Every other line is the same, so only the numbered ones can place a copy.
        let rows = (0..<40).map { $0.isMultiple(of: 2) ? "}" : "line \($0)" }
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 10)))
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 12)))
        XCTAssertEqual(ledger.offset, 2)
    }

    func testViewportTextBecomesOneTrimmedRowPerGridRow() {
        XCTAssertEqual(
            GhosttyScrollLedger.rows(fromViewportText: "one  \n   \n two", gridRows: 5),
            ["one", "", " two", "", ""]
        )
        XCTAssertEqual(GhosttyScrollLedger.rows(fromViewportText: "a\nb\nc", gridRows: 2), ["a", "b"])
    }

    func testBlankViewportCannotBePlaced() {
        var ledger = GhosttyScrollLedger(band: nil)
        let rows = (0..<20).map { "line \($0)" }
        XCTAssertTrue(ledger.locate(Self.window(rows, at: 0)))
        XCTAssertFalse(ledger.locate(Array(repeating: "", count: 8)))
        XCTAssertEqual(ledger.offset, 0)
    }

    func testFollowerStartsOnlyWithAGestureAndAPicture() {
        var follower = GhosttyScrollFollower(gridRows: 8)
        XCTAssertEqual(follower.tick(target: 0, active: false, touchRow: 3, now: 0, rows: Array(repeating: "x", count: 8)), .ended)
        XCTAssertEqual(follower.tick(target: 0, active: true, touchRow: 3, now: 0, rows: nil), .ended)
        XCTAssertFalse(follower.isLive)
        XCTAssertEqual(
            follower.tick(target: 0, active: true, touchRow: 3, now: 0, rows: (0..<8).map { "row \($0)" }),
            .live(nil)
        )
        XCTAssertTrue(follower.isLive)
    }

    func testBandKeepsItsMarginsOnResize() {
        var memory = GhosttyScrollFollower.Memory()
        memory.band = 1...40
        memory.resize(fromRows: 44, toRows: 20)
        XCTAssertEqual(memory.band, 1...16)
        memory.resize(fromRows: 20, toRows: 3)
        XCTAssertNil(memory.band)
    }

    // MARK: Helpers

    private static func window(_ rows: [String], at offset: Int) -> [String] {
        Array(rows[offset..<(offset + 8)])
    }

    /// The simulated program's screen, as `parity.py` draws it: a header, `body` transcript rows of which the first
    /// `drawn` are at `offset` and the rest still at `previous`, a blank row, the input box and a status line.
    private static func screen(_ spec: (offset: Int, previous: Int, drawn: Int), body: Int) -> [String] {
        let rows = (0..<body).map { row in line((row < spec.drawn ? spec.offset : spec.previous) + row + 1) }
        return ["HEADER"] + rows + ["", "> type here", "status 42"]
    }

    private static func line(_ index: Int) -> String {
        if index.isMultiple(of: 7) { return "}" }
        if index.isMultiple(of: 11) { return "" }
        return String(format: "R%04d", index)
    }

    private static func parityFixture() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle(for: GhosttyScrollFollowerTests.self).url(
                forResource: "scroll-follower-parity",
                withExtension: "json"
            )
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func number(_ value: Any) throws -> Double {
        try XCTUnwrap((value as? NSNumber)?.doubleValue, "\(value)")
    }

    private static func spec(_ value: Any?) throws -> (offset: Int, previous: Int, drawn: Int) {
        let values = try XCTUnwrap(value as? [Int])
        return (values[0], values[1], values[2])
    }

    private static func expectedStep(_ value: Any) throws -> GhosttyScrollFollower.Step {
        if value is NSNull { return .live(nil) }
        if let ended = value as? NSNumber, ended.intValue == 0 { return .ended }
        let send = try XCTUnwrap(value as? [Any])
        return .live(GhosttyScrollFollower.Send(
            reports: try XCTUnwrap((send[0] as? NSNumber)?.intValue),
            up: try XCTUnwrap((send[1] as? NSNumber)?.boolValue),
            row: try XCTUnwrap((send[2] as? NSNumber)?.intValue)
        ))
    }
}
