import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Selection on a Herdr pane: the screen's selection kept in Herdr's history rows as Herdr's viewport
/// moves, and its text read by Herdr (`pane.selection.read`), over a scripted bridge with real renderers.
@MainActor
final class HerdrSelectionTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for harness in harnesses {
            await harness.model.stop()
        }
        harnesses.removeAll()
    }

    // MARK: - Where a history selection shows

    /// On screen, each endpoint shows at its own cell; the row counts from the viewport's top.
    func testASelectionOnScreenShowsAtItsCells() {
        let selection = GhosttyHistorySelection(start: cell(41, 2), end: cell(42, 5))
        let shown = selection.shown(top: 40, rows: 3, columns: 10)
        XCTAssertEqual(shown?.start, .init(cell: cell(1, 2), isOnScreen: true))
        XCTAssertEqual(shown?.end, .init(cell: cell(2, 5), isOnScreen: true))
    }

    /// The part on screen is highlighted from the viewport's first cell, or to its last, and the endpoint
    /// off screen has no handle; Ghostty's roles stay, so a backwards selection clamps the same way.
    func testAnEndpointOffScreenShowsAtTheViewportsEdge() {
        let above = GhosttyHistorySelection(start: cell(38, 4), end: cell(41, 1))
        XCTAssertEqual(above.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(0, 0), isOnScreen: false))
        XCTAssertEqual(above.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(1, 1), isOnScreen: true))

        let below = GhosttyHistorySelection(start: cell(45, 0), end: cell(41, 7))
        XCTAssertEqual(below.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(2, 9), isOnScreen: false))
        XCTAssertEqual(below.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(1, 7), isOnScreen: true))

        let across = GhosttyHistorySelection(start: cell(10, 3), end: cell(90, 3))
        XCTAssertEqual(across.shown(top: 40, rows: 3, columns: 10)?.start, .init(cell: cell(0, 0), isOnScreen: false))
        XCTAssertEqual(across.shown(top: 40, rows: 3, columns: 10)?.end, .init(cell: cell(2, 9), isOnScreen: false))
    }

    /// None of it on screen, it doesn't show at all; a column past a narrower viewport's last shows there.
    func testASelectionOffScreenDoesntShow() {
        XCTAssertNil(GhosttyHistorySelection(start: cell(30, 0), end: cell(39, 9)).shown(top: 40, rows: 3, columns: 10))
        XCTAssertNil(GhosttyHistorySelection(start: cell(43, 0), end: cell(50, 9)).shown(top: 40, rows: 3, columns: 10))
        XCTAssertEqual(
            GhosttyHistorySelection(start: cell(40, 30), end: cell(40, 31)).shown(top: 40, rows: 3, columns: 10)?.end,
            .init(cell: cell(0, 9), isOnScreen: true)
        )
    }

    /// A selection may go on in another row when it starts at a row's first column or ends at its last;
    /// a surface without columns, as a failed one reports, has no edge.
    func testASelectionReachesARowEdgeAtItsFirstOrLastColumn() {
        XCTAssertTrue(GhosttyHistorySelection(start: cell(40, 0), end: cell(40, 4)).reachesRowEdge(columns: 10))
        XCTAssertTrue(GhosttyHistorySelection(start: cell(40, 9), end: cell(40, 3)).reachesRowEdge(columns: 10))
        XCTAssertTrue(GhosttyHistorySelection(start: cell(40, 2), end: cell(41, 8)).reachesRowEdge(columns: 10))
        XCTAssertFalse(GhosttyHistorySelection(start: cell(40, 2), end: cell(41, 7)).reachesRowEdge(columns: 10))
        XCTAssertFalse(GhosttyHistorySelection(start: cell(40, 2), end: cell(40, 8)).reachesRowEdge(columns: 0))
    }

    /// Herdr's client sends a selection in reading order, rows from the top of the history.
    func testTheReadSendsTheSelectionInReadingOrder() throws {
        let read = HerdrSelectionRead(
            paneID: "w1:p1",
            selection: GhosttyHistorySelection(start: cell(41, 4), end: cell(39, 0))
        )
        XCTAssertEqual(
            try JSONDecoder().decode(SentRead.self, from: JSONEncoder().encode(read)),
            SentRead(paneID: "w1:p1", anchor: .init(row: 39, col: 0), cursor: .init(row: 41, col: 4))
        )
        XCTAssertEqual(
            try HerdrSelectionRead.text(fromReply: Data(#"{"id":"c1","result":{"type":"pane_selection","pane_id":"w1:p1","text":"a\nb"}}"#.utf8)),
            "a\nb"
        )
    }

    /// Server highlighting may be clipped, including one missing wide-wrap padding column.
    /// History extents distinguish a viewport edge from the actual start/end of terminal content.
    func testResolvedRegionsMustEstablishCompleteLinkBoundaries() throws {
        func request(top: UInt64, fromBottom: UInt64?) throws -> HerdrLinkResolve {
            let scroll: Any
            if let fromBottom {
                scroll = ["offset_from_bottom": fromBottom, "max_offset_from_bottom": top + fromBottom, "viewport_rows": UInt64(3)]
            } else {
                scroll = NSNull()
            }
            let rect: [String: Any] = ["x": 0, "y": 0, "width": 20, "height": 3]
            let json: [String: Any] = [
                "pane_id": "w1:p1", "content_revision": 2,
                "rect": rect, "inner_rect": rect, "scroll": scroll,
                "focused": true, "mouse_reporting": false, "sgr_pixel_mouse": false,
                "alternate_screen_active": false, "pixel_width": 160, "pixel_height": 48,
            ]
            let pane = try JSONDecoder().decode(HerdrSurfacePane.self, from: JSONSerialization.data(withJSONObject: json))
            let content = HerdrPaneContent(of: pane)
            return try XCTUnwrap(HerdrLinkResolve(paneID: "w1:p1", cell: cell(content.top, 8), content: content))
        }
        func reply(first: Int, row: Int, last: Int) throws -> Data {
            let regions = (0...row).map {
                ["row": $0, "start_col": $0 == 0 ? first : 0, "end_col": $0 == row ? last : 19]
            }
            return try JSONSerialization.data(withJSONObject: ["result": ["regions": regions]])
        }
        let history = try request(top: 39, fromBottom: 1)
        XCTAssertEqual(try history.link(fromReply: reply(first: 0, row: 1, last: 6))?.isComplete, false, "start may be above the viewport")
        XCTAssertEqual(try history.link(fromReply: reply(first: 4, row: 2, last: 19))?.isComplete, false, "end may be below the viewport")
        XCTAssertEqual(try history.link(fromReply: reply(first: 4, row: 2, last: 18))?.isComplete, false, "wide-wrap padding is not a URL delimiter")
        XCTAssertEqual(try history.link(fromReply: reply(first: 4, row: 1, last: 6))?.isComplete, true, "fully visible wrapped link")
        XCTAssertEqual(try request(top: 0, fromBottom: 40).link(fromReply: reply(first: 0, row: 1, last: 6))?.isComplete, true, "actual history beginning")
        XCTAssertEqual(try request(top: 40, fromBottom: 0).link(fromReply: reply(first: 4, row: 2, last: 19))?.isComplete, true, "actual terminal end")
        let unknown = try request(top: 0, fromBottom: nil)
        XCTAssertEqual(try unknown.link(fromReply: reply(first: 0, row: 1, last: 6))?.isComplete, false, "missing metrics do not prove a beginning")
        XCTAssertEqual(try unknown.link(fromReply: reply(first: 4, row: 2, last: 19))?.isComplete, false, "missing metrics do not prove an end")
    }

    // MARK: - On a shown session

    /// A word selected on screen is kept in Herdr's history rows, and Copy reads it from Herdr: its text
    /// is Herdr's, whatever the painted rows hold.
    func testCopyReadsTheSelectionFromHerdrByHistoryRows() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()

        let selected = surface.selectWord(at: session.point(row: 1, column: 1))
        XCTAssertTrue(isActive(selected))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let request = try await session.nextSelectionRead()
        XCTAssertEqual(
            request.params,
            SentRead(paneID: "w1:p1", anchor: .init(row: 41, col: 0), cursor: .init(row: 41, col: 4))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"gamma wrapped on"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "gamma wrapped on")
    }

    /// Herdr scrolling its history moves the highlight with the selection's lines.
    func testTheHighlightFollowsHerdrsViewport() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        try await session.serveScroll(fromBottom: 1, revision: 3)
        XCTAssertEqual(try session.shownCells(), [cell(2, 0), cell(2, 4)], "the highlight didn't move down a row")
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))
    }

    /// Scrolled wholly off screen, the selection stays, drawn nowhere and without handles, as Herdr's
    /// client keeps it; scrolled back, it is drawn at its cells again, and Copy reads it.
    func testASelectionScrolledOffScreenStays() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        try await session.serveScroll(fromBottom: 2, revision: 3)
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))
        XCTAssertEqual(surface.selectionSnapshot(), .snapshot(.offScreen), "a selection off screen ended or showed")
        XCTAssertEqual(try session.localCells(), [], "the terminal drew a selection off screen")

        try await session.serveScroll(fromBottom: 0, revision: 4)
        XCTAssertEqual(try session.shownCells(), [cell(1, 0), cell(1, 4)], "the selection wasn't drawn back")

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let request = try await session.nextSelectionRead()
        XCTAssertEqual(
            request.params,
            SentRead(paneID: "w1:p1", anchor: .init(row: 41, col: 0), cursor: .init(row: 41, col: 4))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"gamma"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "gamma")
    }

    /// Coming back on screen, a selection is drawn from its first cell on screen that has text, so one
    /// starting on blank cells is drawn from its blanks on.
    func testASelectionComingBackFromBlanksIsDrawnWhole() async throws {
        let session = try await shownSession(scroll: (0, 40, 3), lines: ["alpha     ", "   gamma  ", "epsil zeta"])
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 4))))
        XCTAssertTrue(isActive(surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START,
            at: session.point(row: 0, column: 7)
        )))

        try await session.serveScroll(fromBottom: 3, revision: 3)
        XCTAssertEqual(surface.selectionSnapshot(), .snapshot(.offScreen))
        try await session.serveScroll(fromBottom: 0, revision: 4)
        XCTAssertEqual(try session.shownCells(), [cell(0, 7), cell(1, 7)])
    }

    /// Scrolled into history, an endpoint moved there reaches rows the first frame never showed; scrolled
    /// back, that endpoint is off screen without a handle, and Copy still reads from it.
    func testASelectionReachesHistoryBeyondTheFrame() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        try await session.serveScroll(fromBottom: 2, revision: 3)
        XCTAssertEqual(surface.selectionSnapshot(), .snapshot(.offScreen))

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 2, column: 1))))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(40, 0), end: cell(40, 4)))
        let moved = surface.setSelectionEndpoint(
            GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START,
            at: session.point(row: 0, column: 0)
        )
        XCTAssertTrue(isActive(moved))
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(38, 0), end: cell(40, 4)))

        try await session.serveScroll(fromBottom: 0, revision: 4)
        guard case .snapshot(let snapshot) = surface.selectionSnapshot() else { return XCTFail("no snapshot") }
        XCTAssertTrue(snapshot.isActive)
        XCTAssertNil(snapshot.start, "the endpoint scrolled off screen kept its handle")
        XCTAssertNotNil(snapshot.end)
        XCTAssertEqual(try session.localCells(), [cell(0, 0), cell(0, 4)], "the highlight didn't cover the rows on screen")

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let request = try await session.nextSelectionRead()
        XCTAssertEqual(
            request.params,
            SentRead(paneID: "w1:p1", anchor: .init(row: 38, col: 0), cursor: .init(row: 40, col: 4))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"history"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "history")
    }

    /// A read Herdr refuses copies nothing and says so, as Herdr's client does; content that changed
    /// meanwhile says nothing.
    func testARefusedReadSaysCopyFailed() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        let stale = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let first = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, error: ("stale_content", "pane content changed")))
        let staleCopy = await stale.value
        XCTAssertNil(staleCopy)
        XCTAssertNil(session.adapter.commandFailureEvent)

        let refused = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let second = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: second.id,
            error: ("selection_unavailable", "selection text is unavailable")
        ))
        let refusedCopy = await refused.value
        XCTAssertNil(refusedCopy)
        XCTAssertEqual(session.adapter.commandFailureEvent?.message, "Herdr: copy failed")
    }

    func testOptionalSelectionInspectionDoesNotReportACopyFailure() async throws {
        var session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        let inspection = Task { await session.adapter.selectedText(in: session.surfaceID, reportResult: false) }
        let first = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: first.id, error: ("selection_unavailable", "selection text is unavailable")
        ))
        let inspected = await inspection.value
        XCTAssertNil(inspected)
        XCTAssertNil(session.adapter.commandFailureEvent)

        // Optional inspection must not consume the failure notice intended for an explicit Copy.
        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let second = try await session.nextSelectionRead()
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: second.id, error: ("selection_unavailable", "selection text is unavailable")
        ))
        let copied = await copy.value
        XCTAssertNil(copied)
        XCTAssertEqual(session.adapter.commandFailureEvent?.message, "Herdr: copy failed")
    }

    /// Typing ends the pane's selection, as on a tmux pane; a key's release, which Herdr doesn't get,
    /// doesn't.
    func testTypingEndsTheSelection() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))

        let release = GhosttySurfaceKeyEvent(action: .release, keyCode: .arrowUp)
        XCTAssertEqual(session.adapter.sendKeyEventToFocusedSurface(release), .accepted)
        XCTAssertTrue(isActive(surface.selectionSnapshot()))

        XCTAssertEqual(session.adapter.sendInputToFocusedSurface("x"), .accepted)
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
        XCTAssertNil(surface.historySelection)

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        XCTAssertEqual(session.adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .arrowUp)), .accepted)
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
    }

    /// A paste ends the pane's selection, as Herdr's client ends its own on pasted text, and so do the
    /// composer's paste and Enter, which go to the pane they were written for; a wheel step doesn't.
    func testAnyInputEndsTheSelection() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        let adapter = session.adapter

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        _ = adapter.sendMousePosition(to: session.surfaceID, session.point(row: 1, column: 1), mods: [])
        let cellHeight = Double(try XCTUnwrap(session.harness.model.measurement).cellMetrics.pixelHeight)
        let wheel = GhosttySurfaceMouseScrollEvent(
            deltaX: 0,
            deltaY: 1.2 * cellHeight,
            mods: .init(precision: true, momentum: .began)
        )
        XCTAssertEqual(adapter.sendMouseScroll(to: session.surfaceID, wheel), .sent)
        XCTAssertTrue(isActive(surface.selectionSnapshot()), "a wheel step ended the selection")

        XCTAssertEqual(adapter.sendPasteToFocusedSurface("pasted"), .accepted)
        XCTAssertFalse(isActive(surface.selectionSnapshot()), "a paste kept the selection")
        XCTAssertNil(surface.historySelection)

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("message", to: session.surfaceID) }
        try await session.harness.waitUntil("the composer's paste kept the selection") { surface.historySelection == nil }
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
        paste.cancel()

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: session.surfaceID)
        }
        try await session.harness.waitUntil("the composer's Enter kept the selection") { surface.historySelection == nil }
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
        enter.cancel()
    }

    /// Herdr rewraps a pane's lines at a new width, and a program switching screens shows other lines, so
    /// either ends the selection, as in Herdr's client. A new height keeps the rows, and the selection.
    func testAWidthOrScreenChangeEndsTheSelection() async throws {
        let session = try await shownSession(scroll: (0, 40, 3))
        let surface = try session.surface()
        let model = session.harness.model

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        try await session.serve(.init(id: "w1:p1", x: 0, width: 10, height: 2, focused: true, scroll: (0, 40, 2)), revision: 3)
        try await session.harness.waitUntil("the pane didn't get shorter") { surface.scrollState.len == 2 }
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 0), end: cell(41, 4)))
        XCTAssertTrue(isActive(surface.selectionSnapshot()), "a new height ended the selection")

        try await session.serve(.init(id: "w1:p1", x: 0, width: 9, height: 2, focused: true, scroll: (0, 40, 2)), revision: 4)
        try await session.harness.waitUntil("the pane didn't get narrower") {
            model.layout?.panes.first?.innerRect?.width == 9
        }
        XCTAssertNil(surface.historySelection, "a new width kept the selection")
        XCTAssertFalse(isActive(surface.selectionSnapshot()))

        XCTAssertTrue(isActive(surface.selectWord(at: session.point(row: 1, column: 1))))
        var alternate = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: 9, height: 2, focused: true, scroll: (0, 40, 2))
        alternate.alternateScreen = true
        try await session.serve(alternate, revision: 5)
        try await session.harness.waitUntil("the program didn't switch screens") { surface.scrollRoute == .altScreenCursor }
        XCTAssertNil(surface.historySelection, "switching screens kept the selection")
        XCTAssertFalse(isActive(surface.selectionSnapshot()))
    }

    // MARK: - Links

    /// A long-press on a plain-text link the pane wraps finds only the row's part of it in the pane's
    /// terminal; Herdr finds the whole link, asked about the cell pressed in the frame on screen, and the
    /// selection grows to it.
    func testAWrappedLinkGrowsToWhatHerdrFinds() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        let selected = try XCTUnwrap(session.longPress(at: press))
        XCTAssertEqual(selected, .link)
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(39, 4), end: cell(39, 19)))

        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: selected) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        XCTAssertEqual(
            request.params,
            SentResolve(paneID: "w1:p1", viewportRow: 0, col: 8, contentRevision: 2, offsetFromBottom: 1)
        )
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":6}]}"#
        ))
        let grew = await completion.value
        XCTAssertTrue(grew)
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(39, 4), end: cell(40, 6)))
        XCTAssertEqual(try session.shownCells(), [cell(0, 4), cell(1, 6)])
    }

    /// A clipped link still expands to Herdr's visible regions for Copy, without authorizing Open.
    func testAClippedLinkKeepsTheWiderVisibleSelection() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        let selected = try XCTUnwrap(session.longPress(at: press))
        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: selected) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":19},{"row":2,"start_col":0,"end_col":19}]}"#
        ))
        let ready = await completion.value
        XCTAssertFalse(ready, "visible regions do not establish the off-screen destination")
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(39, 4), end: cell(41, 19)))
        XCTAssertEqual(try session.shownCells(), [cell(0, 4), cell(2, 19)])

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let read = try await session.nextSelectionRead()
        XCTAssertEqual(read.params, SentRead(paneID: "w1:p1", anchor: .init(row: 39, col: 4), cursor: .init(row: 41, col: 19)))
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: read.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"visible link portion"}"#
        ))
        let copied = await copy.value
        XCTAssertEqual(copied, "visible link portion")
    }

    /// A long-press on a wrapped link's later row, where the pane's terminal may find only a word, grows
    /// the same way.
    func testAWrappedLinksLaterRowGrows() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 1, column: 2)
        let selected = try XCTUnwrap(session.longPress(at: press))
        XCTAssertEqual(surface.historySelection?.start, cell(40, 0))

        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: selected) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        XCTAssertEqual(request.params.viewportRow, 1)
        XCTAssertEqual(request.params.col, 2)
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":6}]}"#
        ))
        let grew = await completion.value
        XCTAssertTrue(grew)
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(39, 4), end: cell(40, 6)))
    }

    /// A link inside a row is whole in the pane's terminal, and an OSC 8 link's id marks all of its cells,
    /// so neither asks Herdr: the next command Herdr gets is the copy's read.
    func testALinkInsideARowOrAnOSC8LinkAsksNothing() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()

        let inside = session.point(row: 2, column: 6)
        XCTAssertEqual(session.longPress(at: inside), .link)
        XCTAssertEqual(surface.historySelection, GhosttyHistorySelection(start: cell(41, 2), end: cell(41, 13)))
        let insideReady = await session.adapter.completeLinkSelection(in: session.surfaceID, at: inside, selected: .link)
        XCTAssertTrue(insideReady)

        let edge = session.point(row: 0, column: 8)
        XCTAssertEqual(session.longPress(at: edge), .link)
        let explicitReady = await session.adapter.completeLinkSelection(in: session.surfaceID, at: edge, selected: .explicitLink)
        XCTAssertTrue(explicitReady)

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let read = try await session.nextCommand()
        XCTAssertEqual(read.method, HerdrScreenModel.paneSelectionReadMethod, "a link asked Herdr")
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: read.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"x"}"#
        ))
        _ = await copy.value
    }

    func testAResolvedLinkEqualToTheSelectionIsComplete() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        XCTAssertEqual(session.longPress(at: press), .link)
        let selection = surface.historySelection
        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19}]}"#
        ))
        let ready = await completion.value
        XCTAssertTrue(ready)
        XCTAssertEqual(surface.historySelection, selection)
    }

    func testCancelledLinkCompletionDoesNotReplaceTheSelection() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        XCTAssertEqual(session.longPress(at: press), .link)
        let selection = surface.historySelection
        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        completion.cancel()
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":6}]}"#
        ))
        let ready = await completion.value
        XCTAssertFalse(ready)
        XCTAssertEqual(surface.historySelection, selection)
    }

    /// A selection the user changes while Herdr looks for the link stays as the user left it; Herdr finding
    /// no link, or a region off the cell pressed, leaves the selection too.
    func testALinkFoundTooLateOrNotAtAllChangesNothing() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        let regions = #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":6}]}"#

        XCTAssertEqual(session.longPress(at: press), .link)
        let typed = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link) }
        let first = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        XCTAssertEqual(session.adapter.sendInputToFocusedSurface("x"), .accepted)
        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: regions))
        let typedGrew = await typed.value
        XCTAssertFalse(typedGrew)
        XCTAssertNil(surface.historySelection, "a link found after typing came back")

        for reply in [
            #"{"type":"pane_link_resolved","regions":[]}"#,
            #"{"type":"pane_link_resolved","regions":[{"row":1,"start_col":0,"end_col":6}]}"#,
        ] {
            XCTAssertEqual(session.longPress(at: press), .link)
            let selection = surface.historySelection
            let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link) }
            let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
            await session.bridge.serve(HerdrConnectionTests.reply(id: request.id, json: reply))
            let grew = await completion.value
            XCTAssertFalse(grew, reply)
            XCTAssertEqual(surface.historySelection, selection, reply)
        }
    }

    /// Output that replaces the pane's rows while Herdr looks for the link makes Herdr's answer stale, since
    /// it was found in the frame before: it is dropped, as Herdr's client drops one, and the selection
    /// stays as it was.
    func testALinkFoundInRowsReplacedMeanwhileChangesNothing() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20)
        let surface = try session.surface()
        let press = session.point(row: 0, column: 8)
        XCTAssertEqual(session.longPress(at: press), .link)
        let selection = surface.historySelection

        let completion = Task { await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link) }
        let request = try await session.nextRequest(HerdrScreenModel.paneLinkResolveMethod, as: SentResolve.self)
        var replaced = session.pane
        replaced.contentRevision = 4
        let output = ["new output here     ", "and more of it      ", "and the last row    "]
        try await session.serve(replaced, revision: 3, lines: output)
        try await session.harness.waitUntil("the new output wasn't painted") {
            guard let renderer = session.harness.model.paneSurface("w1:p1")?.renderer else { return false }
            return RendererText.rows(of: renderer, columns: 20, rows: 3).first == "new output here"
        }
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: request.id,
            json: #"{"type":"pane_link_resolved","regions":[{"row":0,"start_col":4,"end_col":19},{"row":1,"start_col":0,"end_col":6}]}"#
        ))
        let grew = await completion.value
        XCTAssertFalse(grew, "a link found in the rows before the output was applied over it")
        XCTAssertEqual(surface.historySelection, selection)
    }

    /// Herdr's client doesn't ask about content Herdr is still changing, which has an odd revision.
    func testALinkInContentHerdrIsChangingAsksNothing() async throws {
        var session = try await shownSession(scroll: (1, 40, 3), lines: Self.linkLines, width: 20, contentRevision: 5)
        let press = session.point(row: 0, column: 8)
        XCTAssertEqual(session.longPress(at: press), .link)
        let grew = await session.adapter.completeLinkSelection(in: session.surfaceID, at: press, selected: .link)
        XCTAssertFalse(grew)

        let copy = Task { await session.adapter.selectedText(in: session.surfaceID) }
        let read = try await session.nextCommand()
        XCTAssertEqual(read.method, HerdrScreenModel.paneSelectionReadMethod, "content Herdr was changing asked Herdr")
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: read.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"x"}"#
        ))
        _ = await copy.value
    }

    // MARK: - Support

    private func cell(_ row: UInt64, _ column: UInt16) -> GhosttyTerminalCell {
        GhosttyTerminalCell(row: row, column: column)
    }

    /// What a `pane.selection.read` asks for.
    private struct SentRead: Decodable, Equatable {
        struct Point: Decodable, Equatable {
            let row: Int
            let col: Int
        }

        let paneID: String
        let anchor: Point
        let cursor: Point

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case anchor, cursor
        }
    }

    private struct SentRequest<Params: Decodable>: Decodable {
        let params: Params?
    }

    /// What a `pane.link.resolve` asks for.
    private struct SentResolve: Decodable, Equatable {
        let paneID: String
        let viewportRow: Int
        let col: Int
        let contentRevision: UInt64
        let offsetFromBottom: UInt64?

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case viewportRow = "viewport_row"
            case col
            case contentRevision = "content_revision"
            case offsetFromBottom = "offset_from_bottom"
        }
    }

    /// A plain-text link the 20-column pane wraps from its first row into its second, and one inside its
    /// third row.
    private static let linkLines = [
        "see http://example.c",
        "om/path and more    ",
        "x http://a.b/c y    ",
    ]

    private func isActive(_ outcome: GhosttyLocalSelectionOutcome) -> Bool {
        if case .snapshot(let snapshot) = outcome { snapshot.isActive } else { false }
    }

    @MainActor
    private struct Session {
        let harness: HerdrModelHarness
        let bridge: FakeBridgeTransport
        let surfaceID: UUID
        var adapter: HerdrTerminalScreenAdapter { harness.model.terminalScreenAdapter }
        let lines: [String]
        let pane: HerdrServerScript.Pane
        var next: Int

        func surface() throws -> GhosttyManagedSurface {
            try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        }

        /// The middle of a cell of the pane, in its points.
        func point(row: Int, column: Int) -> CGPoint {
            let metrics = harness.model.measurement!.cellMetrics
            return CGPoint(
                x: (CGFloat(column) + 0.5) * metrics.pointWidth,
                y: (CGFloat(row) + 0.5) * metrics.pointHeight
            )
        }

        /// The viewport cells the terminal's selection covers, whether its handles show or not.
        func localCells() throws -> [GhosttyTerminalCell] {
            let control = try surface().controlSurface
            guard case .snapshot(let snapshot) = control.selectionSnapshot(), snapshot.isActive else { return [] }
            return [snapshot.start, snapshot.end].compactMap { $0.flatMap(control.viewportCell(of:)) }
        }

        /// The viewport cells of the endpoints the screen shows.
        func shownCells() throws -> [GhosttyTerminalCell] {
            let surface = try surface()
            guard case .snapshot(let snapshot) = surface.selectionSnapshot(), snapshot.isActive else { return [] }
            return [snapshot.start, snapshot.end].compactMap { $0.flatMap(surface.controlSurface.viewportCell(of:)) }
        }

        func serve(_ pane: HerdrServerScript.Pane, revision: UInt64, lines: [String]? = nil) async throws {
            await bridge.serve(try harness.shownSurface(
                projection: 1,
                revision: revision,
                lines: lines ?? self.lines,
                panes: [pane]
            ))
        }

        /// What the screen does on a long-press: selects the link there, else the word.
        func longPress(at point: CGPoint) -> GhosttyLongPressSelection? {
            guard let surface = try? surface() else { return nil }
            switch surface.selectLink(at: point) {
            case .match(_, let explicitTarget):
                return explicitTarget == nil ? .link : .explicitLink
            case .noMatch:
                guard case .snapshot(let snapshot) = surface.selectWord(at: point), snapshot.isActive else { return nil }
                return .word
            case .unavailable:
                return nil
            }
        }

        /// The same lines with Herdr's viewport `fromBottom` lines up a history of 40, once the pane has it.
        func serveScroll(fromBottom: UInt64, revision: UInt64) async throws {
            var pane = pane
            pane.scroll = (fromBottom, 40, 3)
            await bridge.serve(try harness.shownSurface(
                projection: 1,
                revision: revision,
                lines: lines,
                panes: [pane]
            ))
            let surface = try surface()
            try await harness.waitUntil("Herdr's viewport didn't reach the pane") {
                surface.scrollState.offset == 40 - fromBottom
            }
        }

        /// The next `pane.selection.read`: its id and what it asks for.
        mutating func nextSelectionRead() async throws -> (id: String, params: SentRead) {
            try await nextRequest(HerdrScreenModel.paneSelectionReadMethod, as: SentRead.self)
        }

        /// The next request for `method`: its id and what it asks for.
        mutating func nextRequest<Params: Decodable>(
            _ method: String,
            as: Params.Type
        ) async throws -> (id: String, params: Params) {
            while true {
                let command = try await nextCommand()
                guard command.method == method else { continue }
                let request = try JSONDecoder().decode(SentRequest<Params>.self, from: command.json)
                return (command.id, try XCTUnwrap(request.params))
            }
        }

        /// The next endpoint request the session sends.
        mutating func nextCommand() async throws -> (id: String, method: String, json: Data) {
            struct Request: Decodable {
                let id: String
                let method: String
            }
            while true {
                let frame = try await bridge.written(next)
                next += 1
                var reader = HerdrWireReader(Array(frame.dropFirst(4)))
                guard try reader.variant() == 15 else { continue }
                _ = try reader.string()
                let json = Data(try reader.string().utf8)
                let request = try JSONDecoder().decode(Request.self, from: json)
                return (request.id, request.method, json)
            }
        }
    }

    /// A session shown with one three-row pane, `w1:p1`, of `lines` `width` columns wide, whose history
    /// Herdr scrolls as `scroll` says, drawn in a window as on the screen.
    private func shownSession(
        scroll: (UInt64, UInt64, UInt64),
        lines: [String] = ["alpha beta", "gamma delt", "epsil zeta"],
        width: UInt16 = 10,
        contentRevision: UInt64 = 2
    ) async throws -> Session {
        let harness = await HerdrModelHarness()
        harnesses.append(harness)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        var pane = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: width, height: 3, focused: true, scroll: scroll)
        pane.contentRevision = contentRevision
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: lines, panes: [pane]))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: lines, panes: [pane]))
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        if let view = harness.model.paneSurface("w1:p1")?.renderer.view {
            viewController.view.addSubview(view)
        }
        window.isHidden = false
        windows.append(window)
        try await harness.waitUntil("the pane didn't draw") { harness.model.presentation(ofPane: "w1:p1") == .ready }
        try await harness.waitUntil("the session wasn't shown") { harness.model.isInputAvailable }

        let surfaceID = try XCTUnwrap(harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.viewport.panes.first?.id)
        let surface = try XCTUnwrap(harness.model.terminalScreenAdapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("Herdr's viewport didn't reach the pane") { surface.scrollState.offset == 40 - scroll.0 }
        return Session(harness: harness, bridge: bridge, surfaceID: surfaceID, lines: lines, pane: pane, next: index)
    }
}
