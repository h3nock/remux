import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// The engine against real GhosttyKit: producers, renderers created through `HerdrPaneRendererFence`,
/// and the terminals' text read back through Ghostty's own selection.
@MainActor
final class HerdrTerminalEngineTests: XCTestCase {
    private var runtime: GhosttyKitRuntime!
    private var measurement: GhosttyTerminalViewportMeasurement!
    private var renderers: [TerminalPaneRenderer] = []
    /// Holds the renderers' views, as on screen, while a test reads their pixels.
    private var window: UIWindow?

    override func setUp() async throws {
        runtime = try GhosttyKitRuntime(terminalSettings: .default)
        measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: 844), scale: 3))
    }

    override func tearDown() async throws {
        for renderer in renderers {
            await close(renderer)
        }
        window?.isHidden = true
        window = nil
        measurement = nil
        runtime = nil
    }

    // MARK: - Painting

    /// A pane's terminal is painted before any renderer exists; a renderer created later shows it.
    func testPanesArePaintedBeforeTheirRenderersExist() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["left 1    right 1", "left 2    right 2"],
            panes: [Self.pane("L", x: 0, width: 8, height: 2, focused: true), Self.pane("R", x: 10, width: 7, height: 2)]
        )))

        let terminals = try await updates.terminals(count: 2)
        XCTAssertEqual(Set(terminals.keys), ["L", "R"])
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["L", "R"])

        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 2)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 7, rows: 2)
        XCTAssertEqual(rows(of: left, columns: 8, rows: 2), ["left 1", "left 2"])
        XCTAssertEqual(rows(of: right, columns: 7, rows: 2), ["right 1", "right 2"])
        await engine.stop()
    }

    /// A patch repaints only what changed; the rest of the pane, and the other pane, keep their text.
    func testAPatchChangesOnlyTheRowsItTouches() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("L", x: 0, width: 8, height: 2), Self.pane("R", x: 10, width: 7, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["left 1    right 1", "left 2    right 2"], panes: panes)))
        let terminals = try await updates.terminals(count: 2)
        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 2)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 7, rows: 2)

        await feed.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 1, cells: Self.cells("LEFT 2  "))],
            panes: panes
        )))

        XCTAssertEqual(rows(of: left, columns: 8, rows: 2), ["left 1", "LEFT 2"])
        XCTAssertEqual(rows(of: right, columns: 7, rows: 2), ["right 1", "right 2"])
        await engine.stop()
    }

    // MARK: - Showing

    /// As in Herdr's client, a show completes on a frame painted after it began, at or after the
    /// projection revision Herdr acknowledged, and at the size asked for. Frames are held meanwhile: one
    /// below the floor and one at another size aren't drawn and don't complete it; the next at the floor
    /// and size does, though none of its cells changed.
    func testAShowCompletesOnAFrameAfterItAtTheAcknowledgedRevisionAndSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        let show = try await start(feed, updates, Self.show())
        try await acknowledgeShow(feed, outbox, floor: 2)
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 3, lines: ["one  ", "two  "], panes: panes)))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 4, lines: ["one ", "two "], panes: panes)))

        guard case .activated(let request, let connection) = try await updates.next() else {
            return XCTFail("a frame was drawn before the show completed")
        }
        XCTAssertEqual(request, show)
        XCTAssertEqual(connection, feed.connection)
        let before = try await updates.nextPresented()
        let shown = try await updates.nextPresented()
        XCTAssertEqual([before.projectionRevision, shown.projectionRevision], [1, 2], "the show completed below its floor")
        await engine.stop()
    }

    /// What the screen shows, for counting agents as seen: each frame drawn against a new snapshot reports
    /// that snapshot's revision and its panes once, and a frame waiting for its snapshot reports nothing
    /// until that snapshot is in.
    func testAFrameOfANewSnapshotReportsThePanesItShows() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let two = [Self.pane("A", x: 0, width: 2, height: 1), Self.pane("B", x: 3, width: 2, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["ab cd"], panes: two)))
        let first = try await updates.nextPresented()
        XCTAssertEqual(first.projectionRevision, 1)
        XCTAssertEqual(first.paneIDs, ["A", "B"])

        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["xy cd"], panes: two)))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 3,
            lines: ["three"],
            panes: [Self.pane("C", x: 0, width: 5, height: 1)]
        )))
        await feed.receive(try Self.snapshot(revision: 2))
        let second = try await updates.nextPresented()
        XCTAssertEqual(second.projectionRevision, 2)
        XCTAssertEqual(second.paneIDs, ["C"])
        await engine.stop()
    }

    /// A frame can arrive before Herdr's answer to the show; the answer then completes it on that frame.
    /// A resize while the show is in progress needs a frame at the new size, as Herdr's client drops its
    /// evidence.
    func testAFrameBeforeTheAnswerCountsAndAResizeNeedsAFrameAtTheNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        let panes = [Self.pane("P", x: 0, width: 4, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))

        let first = try await start(feed, updates, Self.show())
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        try await acknowledgeShow(feed, outbox, floor: 1)
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        guard case .activated(first, _) = try await updates.next() else {
            return XCTFail("the answer didn't complete the show its frame came before")
        }

        _ = try await start(feed, updates, .hidden)
        let second = try await start(feed, updates, Self.show())
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["one ", "two "], panes: panes)))
        await feed.resize(columns: 5, rows: 2)
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(revision: 3, lines: ["one  ", "two  "], panes: panes)))
        guard case .layout(let resized) = try await updates.next(),
              case .activated(second, _) = try await updates.next()
        else { return XCTFail("a frame from before the resize completed the show") }
        XCTAssertEqual(resized.columns, 5)
        await engine.stop()
    }

    /// As in Herdr's client, the frame completing a show is drawn against the newest snapshot: a snapshot
    /// that arrives after the received frame, before Herdr's answer, waits for its own frame.
    func testAShowWaitsForTheFrameOfASnapshotNewerThanThePaintedOne() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.snapshot(revision: 1))

        let show = try await start(feed, updates, Self.show())
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2)]
        )))
        await feed.receive(try Self.snapshot(revision: 2))
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, scroll: (fromBottom: 0, max: 5, rows: 2))]
        )))

        _ = try await updates.nextLayout()
        guard case .paneScroll(let scrolls) = try await updates.next(),
              case .activated(show, _) = try await updates.next()
        else { return XCTFail("the show completed on a frame its snapshot had replaced") }
        XCTAssertEqual(scrolls["P"]?.maxLinesFromBottom, 5)
        await engine.stop()
    }

    /// Frames Herdr sends after a hide, such as the one showing a zoom the leave undid, aren't drawn: the
    /// frame from before the hide stays until the next show completes, whose frame is drawn.
    func testFramesAfterAHideWaitForTheNextShow() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        let one = [Self.pane("P", x: 0, width: 4, height: 2)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2), Self.pane("Q", x: 2, width: 2, height: 2)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: one)))
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        _ = try await start(feed, updates, .hidden)
        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: two)))
        let show = try await start(feed, updates, Self.show())
        try await acknowledgeShow(feed, outbox, floor: 3)
        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["one ", "two "], panes: one)))

        guard case .activated(show, _) = try await updates.next() else {
            return XCTFail("a frame that came after the hide was drawn")
        }
        await engine.stop()
    }

    /// A show the setting zooms sends the zoom of the pane Herdr has focused, and completes once Herdr has
    /// answered it, on a frame showing it: Herdr's frame for the show from before the zoom isn't drawn,
    /// whether the answer comes before the zoomed frame or after it. A hide takes Remux's zoom off first,
    /// and a zoom that fails holds nothing.
    func testAShowCarryingAZoomCompletesOnAFrameFromAfterTheZoom() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        let one = [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        let two = [Self.pane("P", x: 0, width: 2, height: 2, focused: true), Self.pane("Q", x: 2, width: 2, height: 2)]

        await feed.receive(try Self.places(revision: 1))
        let first = try await start(feed, updates, Self.show(zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands(), ["zoom P on"])
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["o t ", "w o "], panes: two)))
        try await answerZoom(feed, outbox, zoomed: true)
        await feed.receive(try Self.places(revision: 2, zoomed: ["t1"]))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["one ", "two "], panes: one)))
        guard case .paneTerminal("P", _) = try await updates.next(),
              case .layout(let shown) = try await updates.next()
        else { return XCTFail("the show's frame from before the zoom was drawn") }
        XCTAssertEqual(shown.tab?.zoomed, true)
        _ = try await updates.nextPaneScroll()
        guard case .activated(first, _) = try await updates.next() else { return XCTFail("the show didn't complete") }

        _ = try await start(feed, updates, .hidden)
        XCTAssertEqual(try outbox.commands().last, "zoom P off", "the hide left Remux's zoom")
        try await answerZoom(feed, outbox, zoomed: false)
        await feed.receive(try Self.places(revision: 3))
        let second = try await start(feed, updates, Self.show(zoom: Self.zooming))
        try await acknowledgeShow(feed, outbox, floor: 4)
        await feed.receive(try Self.places(revision: 4, zoomed: ["t1"]))
        await feed.receive(.surface(try Self.surface(projection: 4, revision: 4, lines: ["one ", "two "], panes: one)))
        try await answerZoom(feed, outbox, zoomed: true)
        guard case .activated(second, _) = try await updates.next() else {
            return XCTFail("an answer after the zoomed frame didn't complete the show")
        }

        _ = try await start(feed, updates, .hidden)
        try await answerZoom(feed, outbox, zoomed: false)
        await feed.receive(try Self.places(revision: 5))
        let third = try await start(feed, updates, Self.show(zoom: Self.zooming))
        try await acknowledgeShow(feed, outbox, floor: 6)
        await feed.receive(try Self.places(revision: 6))
        await feed.receive(.surface(try Self.surface(projection: 6, revision: 6, lines: ["o t ", "w o "], panes: two)))
        try await answer(feed, outbox, error: ("pane_not_found", "pane not found"))
        try await activation(third, updates)
        await engine.stop()
    }

    /// A move to another tab sends its steps in order: Remux's zoom off the tab left, the setting's zoom
    /// of the pane, which takes the session there, and the pane's focus. It holds the frames until one
    /// showing where its last step took the session: the tab left as its zoom comes off isn't drawn, only
    /// the tab reached. A move whose focus fails stays where Herdr has the session, and shows the newest
    /// frame once it ends there.
    func testAMoveToAnotherTabShowsOnlyTheTabItReaches() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        let two = [Self.pane("P", x: 0, width: 2, height: 2, focused: true), Self.pane("Q", x: 2, width: 2, height: 2)]
        try await shownZoomed(feed, updates, outbox)

        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands().last, "zoom P off")
        try await answerZoom(feed, outbox, zoomed: false)
        await feed.receive(try Self.places(revision: 3))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["o t ", "w o "], panes: two)))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        await feed.receive(try Self.places(revision: 4, focusedPane: "R", zoomed: ["t2"]))
        await feed.receive(.surface(try Self.surface(
            projection: 4,
            revision: 4,
            lines: ["new ", "tab "],
            panes: [Self.pane("R", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answer(feed, outbox)
        guard case .paneTerminal("R", _) = try await updates.next(),
              case .layout(let reached) = try await updates.next()
        else { return XCTFail("a frame from before the move's last step was drawn") }
        XCTAssertEqual(reached.tab?.tabID, "t2")
        _ = try await updates.nextPaneScroll()
        guard case .activated(move, _) = try await updates.next() else {
            return XCTFail("the move didn't complete on the tab it reached")
        }
        XCTAssertEqual(try outbox.commands().suffix(3), ["zoom P off", "zoom R on", "focus R"])

        let failing = try await start(feed, updates, Self.move("S"))
        await feed.receive(try Self.places(revision: 5, focusedPane: "R"))
        await feed.receive(.surface(try Self.surface(
            projection: 5,
            revision: 5,
            lines: ["o t ", "w o "],
            panes: [Self.pane("R", x: 0, width: 2, height: 2, focused: true), Self.pane("S", x: 2, width: 2, height: 2)]
        )))
        try await answer(feed, outbox, error: ("pane_not_found", "pane not found"))
        _ = try await updates.terminal(for: "S")
        try await activation(failing, updates)
        XCTAssertEqual(updates.focusAnswers.map(\.request), [move, failing])
        XCTAssertNil(updates.focusAnswers.first?.failure)
        XCTAssertNotNil(updates.focusAnswers.last?.failure)
        await engine.stop()
    }

    /// As in Herdr's client, a move completes once its focus is answered on a frame showing its pane, also
    /// one that came before the answer: Herdr can send the snapshot and frame first, and sends nothing
    /// more for a move it has already made.
    func testAMoveCompletesOnAFrameShowingItsPaneThatCameBeforeTheAnswer() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let move = try await start(feed, updates, Self.move("Q"))
        XCTAssertEqual(try outbox.commands(), ["focus Q"])
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q"))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: Self.atQ)))
        try await Task.sleep(for: .milliseconds(50))
        try await answer(feed, outbox)
        guard case .activated(move, _) = try await updates.next() else {
            return XCTFail("the move waited for a frame Herdr had already sent")
        }
        await engine.stop()
    }

    /// A request is current from its start, which holds the frames in the same turn, also when the newest
    /// snapshot's frame hasn't come yet. A move that replaces another drops the steps that one hadn't sent
    /// and carries on its zoom; the answer to the one it sent completes nothing.
    func testARequestHoldsFromItsStartAndAReplacedOneCompletesNothing() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)

        // The next snapshot is in, its frame not yet.
        await feed.receive(try Self.places(revision: 3, zoomed: ["t1"]))
        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        let newer = try await start(feed, updates, Self.move("Q", zoom: Self.zooming))
        try await answerZoom(feed, outbox, zoomed: false)
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 3,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answerZoom(feed, outbox, zoomed: true, panes: ["Q", "P"])
        await feed.receive(try Self.places(revision: 4, focusedPane: "Q", zoomed: ["t1"]))
        await feed.receive(.surface(try Self.surface(
            projection: 4,
            revision: 4,
            lines: ["thr ", "fou "],
            panes: [Self.pane("Q", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answer(feed, outbox)
        guard case .paneTerminal("Q", _) = try await updates.next(),
              case .layout(let shown) = try await updates.next()
        else { return XCTFail("a frame was drawn before the newer request completed") }
        XCTAssertEqual(shown.panes.filter { $0.innerRect != nil }.map(\.paneID), ["Q"])
        _ = try await updates.nextPaneScroll()
        guard case .activated(newer, _) = try await updates.next() else { return XCTFail("the newer request didn't complete") }
        XCTAssertEqual(try outbox.commands().suffix(3), ["zoom P off", "zoom Q on", "focus Q"], "a replaced step went")
        XCTAssertEqual(updates.focusAnswers.map(\.request), [newer])
        await engine.stop()
    }

    /// A move that replaces another takes off the zoom that one made as it leaves the tab, though Herdr
    /// answered that zoom after the replacement: its leave waits for the snapshot showing the zoom, which
    /// has the session on that tab.
    func testAMoveTakesOffTheZoomOfTheMoveItReplacedAsItLeaves() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        _ = try await start(feed, updates, Self.move("Q", zoom: Self.zooming))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "the leave went before Herdr showed the zoom")
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "zoom R off"])
        try await answerZoom(feed, outbox, zoomed: false, tab: "t2", panes: ["R", "S"])
        XCTAssertEqual(try outbox.commands().last, "zoom Q on")
        await engine.stop()
    }

    /// A move's focus goes from where its zoom took the session, once a snapshot shows it there: Herdr can
    /// answer before it sends that snapshot. A snapshot showing that another client took the session
    /// elsewhere instead overtakes the move, and its focus, which would take the session back, doesn't go.
    func testAMovesFocusWaitsForTheSnapshotShowingItsZoom() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "the focus went before Herdr showed the zoom")
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "focus R"])
        try await answer(feed, outbox)

        let back = try await start(feed, updates, Self.move("P", fromAnotherTab: true, zoom: Self.zooming))
        try await answerZoom(feed, outbox, zoomed: false, tab: "t2", panes: ["R", "S"])
        try await answerZoom(feed, outbox, zoomed: true)
        // Another client takes the session to S before Herdr's snapshot of the move back.
        await feed.receive(try Self.places(revision: 3, focusedPane: "S"))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 2,
            lines: ["else", "wher"],
            panes: [Self.pane("S", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await activation(back, updates)
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "focus R", "zoom R off", "zoom P on"], "the overtaken move's focus went")
        await engine.stop()
    }

    /// A move whose target tab another client closes after its zoom went ends at once as Herdr shows the
    /// session: a tab that is gone doesn't come back, so the move doesn't wait out its time for it.
    func testAMoveWhoseTargetTabIsClosedEndsAtOnce() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming), within: .seconds(2))
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q", gone: ["t2"]))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["else", "wher"],
            panes: [Self.pane("Q", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        while true {
            switch try await updates.next() {
            case .activated(move, _):
                XCTAssertEqual(try outbox.commands(), ["zoom R on"])
                return await engine.stop()
            case .timedOut:
                return XCTFail("the move waited out its time for a tab that is gone")
            default:
                continue
            }
        }
    }

    /// A move waiting behind a command whose pane another client closes before it can go sends nothing,
    /// not even Remux's zoom off the tab on screen, and ends as Herdr shows the session.
    func testAMoveWaitingBehindACommandWhosePaneClosesSendsNothing() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming), within: .seconds(2))
        await feed.receive(try Self.places(revision: 3, zoomed: ["t1"], closed: ["R"]))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 2,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.commands(), ["zoom P on", "worktree.list"], "the move to a closed pane sent its steps")
        while true {
            switch try await updates.next() {
            case .activated(move, _):
                return await engine.stop()
            case .timedOut:
                return XCTFail("the move waited out its time for a pane that is gone, after \(try outbox.commands())")
            default:
                continue
            }
        }
    }

    /// A move to a pane already gone from the snapshot it starts on, as another client closed it after the
    /// screen last showed it, sends nothing and ends as Herdr shows the session.
    func testAMoveToAPaneClosedBeforeItStartsSendsNothing() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)

        await feed.receive(try Self.places(revision: 3, zoomed: ["t1"], closed: ["R"]))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 2,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming), within: .seconds(2))
        while true {
            switch try await updates.next() {
            case .activated(move, _):
                XCTAssertEqual(try outbox.commands(), ["zoom P on"], "the move to a closed pane sent its steps")
                return await engine.stop()
            case .timedOut:
                return XCTFail("the move waited out its time for a pane that is gone, after \(try outbox.commands())")
            default:
                continue
            }
        }
    }

    /// Leaving takes Remux's zoom off only the tab Herdr shows: an unzoom focuses its target, so one of a
    /// tab another client has since left would take the session back there. A zoom answered after another
    /// client took the session to the other tab stays.
    func testLeavingDoesNotUnzoomATabAnotherClientLeft() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        // Another client takes the session back to the first tab before Herdr's answer to the zoom.
        await feed.receive(try Self.places(revision: 3, focusedPane: "Q", zoomed: ["t2"]))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        _ = try await start(feed, updates, .hidden)
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "leaving unzoomed a tab off screen")
        guard case .surfaceSet(_, false)? = try outbox.writes().last else { return XCTFail("the hide didn't go") }
        await engine.stop()
    }

    /// A zoom another client undid after Herdr showed it isn't Remux's to undo, though Herdr's answer to it
    /// comes after: ownership agrees with the snapshots already seen.
    func testAZoomAnotherClientUndidBeforeItsAnswerIsNotRemuxs() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        // Another client unzooms the tab before Herdr's answer to the zoom.
        await feed.receive(try Self.places(revision: 3, focusedPane: "R"))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        _ = try await start(feed, updates, .hidden)
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "leaving undid a zoom another client had undone")
        await engine.stop()
    }

    /// A hide with a command in flight goes at once and leaves Remux's zoom: an unzoom would have to wait
    /// for the lane, and the leave doesn't wait. Nothing follows the command's answer.
    func testAHideWithACommandInFlightGoesAtOnceAndLeavesTheZoom() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        let before = try outbox.writes().count
        _ = try await start(feed, updates, .hidden)
        XCTAssertFalse(outbox.isSurfaceActive)
        let leave = Array(try outbox.writes().dropFirst(before))
        XCTAssertEqual(leave.count, 2, "\(leave)")
        guard leave.first == .focus(false), case .surfaceSet(_, false)? = leave.last else {
            return XCTFail("the hide didn't go at once: \(leave)")
        }
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.writes().count, before + 2, "something went after the hide")
        await engine.stop()
    }

    /// A hide on an idle lane, with Herdr's snapshot showing the tab Remux zoomed, takes the zoom off first,
    /// then focus and the hide go at once.
    func testAHideOnAnIdleLaneTakesRemuxsZoomOffFirst() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)

        let before = try outbox.writes().count
        _ = try await start(feed, updates, .hidden)
        let leave = Array(try outbox.writes().dropFirst(before))
        XCTAssertEqual(leave.count, 3, "\(leave)")
        guard case .paneZoom(_, "P", "off")? = leave.first, leave.dropFirst().first == .focus(false),
              case .surfaceSet(_, false)? = leave.last
        else { return XCTFail("the hide didn't take Remux's zoom off first: \(leave)") }
        await engine.stop()
    }

    /// A close with a command in flight goes at once and leaves Remux's zoom, as a hide does.
    func testACloseWithACommandInFlightGoesAtOnceAndLeavesTheZoom() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)
        let answers = Answers()
        let closed = Closed()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.unzoomBeforeClosing(done: closed.close)
        XCTAssertTrue(closed.isClosed, "the close waited for the command in flight")
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.commands(), ["zoom P on", "worktree.list"], "an unzoom went after the close")
        await engine.stop()
    }

    /// A close on an idle lane, with Herdr's snapshot showing the tab Remux zoomed, takes the zoom off first
    /// and closes once Herdr has answered it.
    func testACloseOnAnIdleLaneTakesRemuxsZoomOffFirst() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)
        let closed = Closed()

        await feed.unzoomBeforeClosing(done: closed.close)
        XCTAssertEqual(try outbox.commands().last, "zoom P off")
        XCTAssertFalse(closed.isClosed, "closed before Herdr answered the unzoom")
        try await answerZoom(feed, outbox, zoomed: false)
        XCTAssertTrue(closed.isClosed)
        await engine.stop()
    }

    /// A close before the snapshot showing a move's answered zoom goes at once and leaves that zoom: which
    /// tab is on screen isn't known yet, and an unzoom of another tab would take the session there.
    func testACloseBeforeTheSnapshotShowingAMovesZoomLeavesIt() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let closed = Closed()

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        await feed.unzoomBeforeClosing(done: closed.close)
        XCTAssertTrue(closed.isClosed, "the close waited for the snapshot")
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "the close's unzoom went before Herdr showed the zoom")
        await engine.stop()
    }

    /// A move that takes over a show keeps the show's time, as Herdr's client keeps an activation's deadline
    /// through a retarget: it times out when the show would have.
    func testAMoveThatTakesOverAShowKeepsItsTime() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, _) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))

        let began = ContinuousClock.now
        _ = try await start(feed, updates, Self.show(), within: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(300))
        let move = try await start(feed, updates, Self.move("Q"), within: .milliseconds(400))
        guard case .timedOut(let request, _) = try await updates.next() else { return XCTFail("the move didn't time out") }
        XCTAssertEqual(request, move)
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(600), "the move started the show's time over")
        await engine.stop()
    }

    /// A move that takes over a move on a shown session has its own time: only a show's carries on.
    func testAMoveThatTakesOverAMoveHasItsOwnTime() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        _ = try await start(feed, updates, Self.move("Q"), within: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(300))
        let movedAgain = ContinuousClock.now
        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true), within: .milliseconds(400))
        guard case .timedOut(let request, _) = try await updates.next() else { return XCTFail("the move didn't time out") }
        XCTAssertEqual(request, move)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - movedAgain, .milliseconds(350), "the move kept the time of the move it took over")
        await engine.stop()
    }

    /// The pane sheet's question for a zoomed tab's layout, waiting for the lane, doesn't go once another
    /// client has unzoomed the tab: it asks for the zoom the tab has, so it would zoom it again for everyone.
    func testALayoutQuestionForATabAnotherClientUnzoomedDoesNotGo() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.askLayout(ofPane: "P")
        // Another client unzooms the tab while the question waits.
        await feed.receive(try Self.places(revision: 3))
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.commands(), ["zoom P on", "worktree.list"], "the question zoomed the tab again")
        await engine.stop()
        _ = await updates.drain()
        XCTAssertEqual(updates.zoomAnswers.last?.failure, .notSent)
        XCTAssertEqual(updates.zoomAnswers.last?.reportsFailure, false)
    }

    /// A command's caller hears when the connection ends, whether its command was in flight or waiting.
    func testACommandsCallerHearsTheConnectionEnd() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.command("tab.focus", params: ["tab_id": "t2"], answered: answers.record)
        await engine.endConnection(feed.connection)
        let inFlight = try await answers.next()
        let waiting = try await answers.next()
        XCTAssertEqual([inFlight.failure, waiting.failure], [.connectionEnded, .connectionEnded])
        await engine.stop()
    }

    /// Herdr's refusal of a show a newer one replaced changes nothing: the newer show completes, and
    /// nothing goes out to undo either.
    func testAnOlderShowsRefusalDoesNotUndoANewerShow() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))
        _ = try await start(feed, updates, Self.show())
        _ = try await start(feed, updates, .hidden)
        let newer = try await start(feed, updates, Self.show())
        let sets = try outbox.surfaceSets()
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: sets[0].id, error: ("refused", "refused"))))
        await feed.receive(try Self.chunk(HerdrServerScript.surfaceSetReply(id: sets[2].id, active: true, projection: 1)))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: Self.atP)))
        try await activation(newer, updates)
        XCTAssertEqual(try outbox.surfaceSets().map(\.active), [true, false, true], "something went to undo a show")
        await engine.stop()
        let rest = await updates.drain()
        XCTAssertFalse(rest.contains { if case .showRefused = $0 { true } else { false } }, "\(rest)")
    }

    /// A move whose focus Herdr answered, after which another client takes the session elsewhere before
    /// any frame at the pane, ends there as Herdr shows it.
    func testAMoveOvertakenElsewhereEndsAsHerdrShowsIt() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true))
        try await answer(feed, outbox)
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q"))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["else", "wher"],
            panes: [Self.pane("Q", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await activation(move, updates)
        XCTAssertEqual(try outbox.commands(), ["focus R"])
        await engine.stop()
    }

    /// As in Herdr's client, the frame completing a move must draw its pane focused, not only the snapshot
    /// say so: a frame drawn against a snapshot at the pane that still shows another pane focused doesn't
    /// complete it.
    func testAMoveCompletesOnlyOnAFrameDrawingItsPaneFocused() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let move = try await start(feed, updates, Self.move("Q"))
        try await answer(feed, outbox)
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q"))
        // A frame against that snapshot that draws only P, focused, as the tab looked before.
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await Task.sleep(for: .milliseconds(50))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 3, lines: ["o t ", "w o "], panes: Self.atQ)))
        // The completing frame lays the tab out as before the move, so it brings no new layout.
        guard case .activated(move, _) = try await updates.next() else {
            return XCTFail("the move completed on a frame that didn't draw its pane focused")
        }
        await engine.stop()
    }

    /// A move whose pane another client leaves after the move's zoom took the session there is overtaken:
    /// its focus, which would take the session back, doesn't go, and it ends as Herdr shows the session.
    func testAMoveWhosePaneAnotherClientLeavesAfterItsZoomIsOvertaken() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let move = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        // Herdr reaches R, and another client focuses S, before Herdr's answer to the zoom.
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        await feed.receive(try Self.places(revision: 3, focusedPane: "S", zoomed: ["t2"]))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 2,
            lines: ["else", "wher"],
            panes: [Self.pane("S", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        try await activation(move, updates)
        XCTAssertEqual(try outbox.commands(), ["zoom R on"], "the overtaken move's focus went")
        await engine.stop()
    }

    /// A show at a pane goes there even when Herdr has it focused already, and completes only on a frame
    /// that draws it focused.
    func testAShowAtThePaneHerdrHasFocusedStillChecksTheFrame() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))

        let show = try await start(feed, updates, Self.show("P"))
        XCTAssertEqual(try outbox.commands(), ["focus P"])
        try await acknowledgeShow(feed, outbox, floor: 1)
        try await answer(feed, outbox)
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("Q", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await Task.sleep(for: .milliseconds(50))
        await feed.receive(.surface(try Self.surface(revision: 2, lines: ["o t ", "w o "], panes: Self.atP)))
        let drawn = try await updates.nextLayout()
        XCTAssertEqual(
            drawn.panes.filter { $0.innerRect != nil }.map(\.paneID),
            ["P", "Q"],
            "the show completed on a frame drawing another pane focused"
        )
        _ = try await updates.nextPaneScroll()
        guard case .activated(show, _) = try await updates.next() else { return XCTFail("the show didn't complete") }
        await engine.stop()
    }

    /// Herdr's refusal of a show is reported only while that show is the current request's, in order with
    /// its other events; a refusal of a show a hide replaced isn't.
    func testOnlyTheCurrentShowsRefusalIsReported() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))
        _ = try await start(feed, updates, Self.show())
        _ = try await start(feed, updates, .hidden)
        await feed.receive(try Self.chunk(HerdrServerScript.surfaceSetReply(id: try outbox.surfaceSets()[0].id, active: false)))
        _ = try await start(feed, updates, Self.show())
        let move = try await start(feed, updates, Self.move("Q"))
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: try outbox.surfaceSets()[2].id, error: ("refused", "refused"))))
        await engine.stop()
        let refused = await updates.drain().compactMap { update -> UInt64? in
            if case .showRefused(let request, _, _) = update { request } else { nil }
        }
        XCTAssertEqual(refused, [move])
    }

    /// A request that doesn't complete in its time says so, once; a replaced one and a hide don't.
    func testOnlyTheCurrentRequestInProgressTimesOut() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)

        let replaced = try await start(feed, updates, Self.move("Q"), within: .milliseconds(100))
        let current = try await start(feed, updates, Self.move("R", fromAnotherTab: true), within: .milliseconds(300))
        guard case .timedOut(let request, _) = try await updates.next() else { return XCTFail("the request didn't time out") }
        XCTAssertEqual(request, current)
        XCTAssertNotEqual(request, replaced)

        _ = try await start(feed, updates, .hidden, within: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try outbox.surfaceSets().last?.active, false, "the hide waited for the command in flight past its time")
        await engine.stop()
        let rest = await updates.drain()
        XCTAssertFalse(rest.contains { if case .timedOut = $0 { true } else { false } }, "\(rest)")
    }

    /// A move its owner asks for that changes nothing isn't a request: one before any show, and one to the
    /// pane the move in progress goes to.
    func testAMoveWithNothingToDoIsNotStarted() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, _) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))
        await feed.start(Self.move("Q"), within: .seconds(5))
        let show = try await start(feed, updates, Self.show())
        let move = try await start(feed, updates, Self.move("Q"))
        await feed.start(Self.move("Q"), within: .seconds(5))
        await engine.stop()
        _ = await updates.drain()
        XCTAssertEqual(updates.started.map(\.request), [show, move])
    }

    // MARK: - Commands

    /// A show sends the size, `surface.set(true)` and focus, in Herdr's client order, asking for at least
    /// one cell each way; a hide sends focus first, then `surface.set(false)`. Input goes only between.
    func testAShowAndAHideFollowHerdrsOrder() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1))
        let geometry = HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 0, rows: 12)
        _ = try await start(feed, updates, .shown(geometry, to: nil, zoom: Self.notZooming))
        let shown = try outbox.writes()
        XCTAssertEqual(shown.count, 3, "\(shown)")
        XCTAssertEqual(shown.first, .resize(cols: 1, rows: 12, cellWidth: 9, cellHeight: 18))
        guard case .surfaceSet(_, true)? = shown.dropFirst().first else { return XCTFail("\(shown)") }
        XCTAssertEqual(shown.last, .focus(true))
        XCTAssertTrue(outbox.isSurfaceActive)

        _ = try await start(feed, updates, .hidden)
        let hidden = Array(try outbox.writes().dropFirst(3))
        XCTAssertEqual(hidden.count, 2, "\(hidden)")
        XCTAssertEqual(hidden.first, .focus(false))
        guard case .surfaceSet(_, false)? = hidden.last else { return XCTFail("\(hidden)") }
        XCTAssertFalse(outbox.isSurfaceActive)
        await engine.stop()
    }

    /// One command at a time, in the order asked; the next goes once the last chunk of the reply in
    /// flight arrives, and the chunks join into one reply.
    func testCommandsGoOneAtATimeAndJoinChunks() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.command("tab.focus", params: ["tab_id": "t2"], answered: answers.record)
        XCTAssertEqual(try outbox.commands(), ["worktree.list"])
        let first = try outbox.lastCommand()
        let body = Array(#"{"id":"\#(first.id)","result":{"type":"ok"}}"#.utf8)
        await feed.receive(try Self.chunk(HerdrConnectionTests.chunk(id: first.id, data: Array(body.prefix(10)), final: false)))
        XCTAssertEqual(try outbox.commands(), ["worktree.list"])
        await feed.receive(try Self.chunk(HerdrConnectionTests.chunk(id: first.id, data: Array(body.dropFirst(10)), final: true)))
        let firstReply = try await answers.next().get()
        XCTAssertEqual(firstReply.json, Data(body))

        XCTAssertEqual(try outbox.commands(), ["worktree.list", "tab.focus"])
        try await answer(feed, outbox, error: ("not_found", "no tab"))
        let second = try await answers.next()
        XCTAssertEqual(second.failure, .failed(code: "not_found", message: "no tab"))
        await engine.stop()
    }

    /// As in Herdr's client, a command that isn't answered in time fails and frees the lane for the next
    /// one, and its late reply is dropped instead of answering anything else.
    func testATimedOutCommandFreesTheLaneAndItsLateReplyIsDropped() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine, commandTimeout: .milliseconds(100))
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        let slow = try outbox.lastCommand()
        let timedOut = try await answers.next()
        XCTAssertEqual(timedOut.failure, .timedOut(method: "worktree.list"))
        await feed.command("tab.focus", params: ["tab_id": "t2"], answered: answers.record)
        let next = try outbox.lastCommand()
        XCTAssertEqual(next.method, "tab.focus")
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: slow.id, json: #"{"type":"late"}"#)))
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: next.id, json: #"{"type":"ok"}"#)))
        let answer = try await answers.next().get()
        XCTAssertEqual(String(decoding: answer.json, as: UTF8.self), #"{"id":"\#(next.id)","result":{"type":"ok"}}"#)
        await engine.stop()
    }

    /// A hide fails the commands waiting, since Herdr refuses commands from a hidden session, and the steps
    /// not yet sent don't go; the command in flight is still answered.
    func testAHideFailsTheCommandsWaitingAndDropsTheSteps() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        let first = try outbox.lastCommand()
        _ = try await start(feed, updates, Self.move("Q"))
        await feed.command("tab.focus", params: ["tab_id": "t2"], answered: answers.record)
        _ = try await start(feed, updates, .hidden)
        let dropped = try await answers.next()
        XCTAssertEqual(dropped.failure, .notSent)
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#)))
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.commands(), ["worktree.list"], "a command went after the hide")
        await engine.stop()
    }

    /// The zoom button's zoom goes only while no request is in progress and its pane is still the focused
    /// one as it goes: a zoom focuses its target, so one for a pane another client has since moved away
    /// from would take the session back. It is reported as not sent, whether it waited or not.
    func testAZoomForAPaneNoLongerFocusedIsNotSent() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.setZoom(true, ofPane: "P")
        // Another client focuses the tab's other pane.
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q"))
        try await answer(feed, outbox)
        await feed.setZoom(true, ofPane: "P")
        XCTAssertEqual(try outbox.commands(), ["worktree.list"])
        await engine.stop()
        _ = await updates.drain()
        XCTAssertEqual(updates.zoomAnswers.map(\.failure), [.notSent, .notSent])
        XCTAssertEqual(updates.zoomAnswers.map(\.reportsFailure), [true, true])
    }

    /// A command's reply says where it fell among the snapshots: the newest one when it went out, for a
    /// command that waited for the lane the newest as the lane freed, and the newest when its reply came.
    func testACommandsReplySaysWhichSnapshotsCameBeforeItWentAndBeforeItsReply() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        await feed.command("tab.focus", params: ["tab_id": "t2"], answered: answers.record)
        await feed.receive(try Self.places(revision: 5))
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        XCTAssertEqual(try outbox.lastCommand().method, "tab.focus")
        await feed.receive(try Self.places(revision: 6))
        try await answer(feed, outbox)
        let reply = try await answers.next().get()
        XCTAssertEqual([reply.sentAfter, reply.answeredAfter], [5, 6])
        await engine.stop()
    }

    /// A method the server doesn't offer fails alone; the lane goes on.
    func testAMethodTheServerDoesNotOfferFailsAlone() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        await feed.command("pane.read", params: [String: String](), answered: answers.record)
        let unsupported = try await answers.next()
        XCTAssertEqual(unsupported.failure, .unsupported(method: "pane.read"))
        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        XCTAssertEqual(try outbox.commands(), ["worktree.list"])
        await engine.stop()
    }

    /// Every command shares the one lane: a command asked while a request's steps are under way goes after
    /// them, and a move that replaces the request drops only the steps that one hadn't sent. The command
    /// still goes, after the new move's steps.
    func testACommandWaitsBehindTheRequestsStepsAndOutlivesItsReplacement() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shown(feed, updates, outbox, panes: Self.atP)
        let answers = Answers()

        _ = try await start(feed, updates, Self.move("R", fromAnotherTab: true, zoom: Self.zooming))
        await feed.command("worktree.list", params: [String: String](), answered: answers.record)
        _ = try await start(feed, updates, Self.move("S", zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands(), ["zoom R on"])
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        await feed.receive(try Self.places(revision: 2, focusedPane: "R", zoomed: ["t2"]))
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "zoom S on"])
        try await answerZoom(feed, outbox, zoomed: true, changed: false, tab: "t2", panes: ["S", "R"])
        await feed.receive(try Self.places(revision: 3, focusedPane: "S", zoomed: ["t2"]))
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "zoom S on", "focus S"])
        try await answer(feed, outbox)
        XCTAssertEqual(try outbox.commands(), ["zoom R on", "zoom S on", "focus S", "worktree.list"])
        try await answer(feed, outbox)
        _ = try await answers.next().get()
        await engine.stop()
    }

    /// A pane whose text area changes size is resized and repainted at once: none of its old text
    /// survives beside the new content.
    func testAResizedPaneIsRepaintedAtItsNewSize() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["0123456789AB", "second line ", "third line  "],
            panes: [Self.pane("P", x: 0, width: 12, height: 3)]
        )))
        let terminal = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 12, rows: 3)

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: ["abcde", "fghij"],
            panes: [Self.pane("P", x: 0, width: 5, height: 2)]
        )))

        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.first?.innerRect, HerdrSurfaceRect(x: 0, y: 0, width: 5, height: 2))
        XCTAssertEqual(rows(of: renderer, columns: 12, rows: 2), ["abcde", "fghij"])
        await engine.stop()
    }

    /// Every recorded stream, decoded and painted, leaves each pane's terminal showing its cells in the
    /// last frame drawn.
    func testRecordedStreamsLeaveEveryPaneShowingTheLastDrawnFrame() async throws {
        var comparedRows = 0
        for fixture in try HerdrWireTests.goldenFixtures() {
            guard let negotiated = fixture.golden.negotiated else { continue }
            let engine = makeEngine()
            let updates = UpdateLog(engine)
            let feed = await engine.beginConnection(1)
            var decoder = HerdrSurfaceDecoder(deltaNegotiated: negotiated.delta, scrollNegotiated: negotiated.scroll)
            var reference = HerdrPresentation()
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)
            while let payload = try splitter.nextPayload() {
                let message = try HerdrServerMessage.decode(payload)
                if case .control(let kind, let data) = message,
                   case .snapshot(let snapshot) = try HerdrEndpointControl.parse(kind: kind, data: data) {
                    reference.receive(snapshot)
                    await feed.receive(snapshot)
                    continue
                }
                guard let surfaceMessage = try HerdrSurfaceDecoderTests.surfaceMessage(message) else { continue }
                let output = try decoder.decode(surfaceMessage)
                switch output {
                case .surface(let surface): try reference.receive(surface)
                case .patch(let patch): _ = reference.receive(patch)
                }
                await feed.receive(output)
            }
            await engine.stop()
            guard let surface = reference.presented?.surface else { continue }
            var terminals: [String: HerdrRetainedTerminal] = [:]
            for update in await updates.drain() {
                switch update {
                case .paneTerminal(let paneID, let terminal): terminals[paneID] = terminal
                case .paneTerminalFailed, .rendererWakeFailed, .failed: XCTFail("\(fixture.name): \(update)")
                case .layout, .paneScroll, .started, .activated, .timedOut, .answered, .zoomAnswered, .showRefused, .presented: break
                }
            }
            for pane in surface.panes where pane.innerRect.width > 0 && pane.innerRect.height > 0 {
                let terminal = try XCTUnwrap(terminals[pane.paneID], fixture.name)
                let columns = Int(pane.innerRect.width)
                let height = Int(pane.innerRect.height)
                let renderer = try await makeRenderer(engine: nil, paneID: pane.paneID, terminal: terminal, columns: columns, rows: height)
                let shown = rows(of: renderer, columns: columns, rows: height)
                for (y, expected) in Self.expectedRows(of: surface.frame, area: pane.innerRect).enumerated() {
                    guard let expected else { continue }
                    XCTAssertEqual(shown[y], expected, "\(fixture.name) pane \(pane.paneID) row \(y)")
                    comparedRows += 1
                }
                await close(renderer)
            }
        }
        XCTAssertGreaterThan(comparedRows, 100)
    }

    /// Panes the next frame doesn't list are dropped; their renderers can't register any more.
    func testAPaneMissingFromTheNextFrameIsDropped() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["a  b"],
            panes: [Self.pane("A", x: 0, width: 1, height: 1), Self.pane("B", x: 3, width: 1, height: 1)]
        )))
        let terminals = try await updates.terminals(count: 2)
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["a   "], panes: [Self.pane("A", x: 0, width: 4, height: 1)])))
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["A"])

        let error = await registrationError(engine: engine, paneID: "B", terminal: try XCTUnwrap(terminals["B"]))
        XCTAssertEqual(error, .terminalGone)
        await engine.stop()
    }

    /// A pane's scrolling goes out on its own whenever it changes, never with a new layout: the history
    /// grows with every line a program prints.
    func testAPanesScrollingGoesOutWhenItChanges() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        func surface(_ revision: UInt64, max: Int, mouse: Bool = false) throws -> HerdrSurfaceDecoder.Output {
            .surface(try Self.surface(
                revision: revision,
                lines: ["one"],
                panes: [Self.pane("P", x: 0, width: 3, height: 1, scroll: (0, max, 1), mouseReporting: mouse)]
            ))
        }
        await feed.receive(try surface(1, max: 5))
        _ = try await updates.nextLayout()
        let first = try await updates.nextPaneScroll()
        XCTAssertEqual(first, ["P": HerdrPaneScroll(
            linesFromBottom: 0,
            maxLinesFromBottom: 5,
            rows: 1,
            mouseReporting: false,
            alternateScreenActive: false
        )])

        await feed.receive(try surface(2, max: 6))
        guard case .paneScroll(let grown) = try await updates.next() else {
            return XCTFail("the grown history didn't go out on its own")
        }
        XCTAssertEqual(grown["P"]?.maxLinesFromBottom, 6)

        await feed.receive(try surface(3, max: 6))
        await feed.receive(try surface(4, max: 6, mouse: true))
        guard case .paneScroll(let reporting) = try await updates.next() else {
            return XCTFail("an unchanged frame sent the scrolling again")
        }
        XCTAssertEqual(reporting["P"]?.mouseReporting, true)
        await engine.stop()
    }

    /// A listed pane with no text area has no terminal; with room again it gets a new one.
    func testAPaneWithoutRoomGetsANewTerminalWhenItHasRoomAgain() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["ab"], panes: [Self.pane("P", x: 0, width: 2, height: 1)])))
        let first = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["ab"], panes: [Self.pane("P", x: 0, width: 0, height: 1)])))
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.panes.map(\.paneID), ["P"])
        let stale = await registrationError(engine: engine, paneID: "P", terminal: first)
        XCTAssertEqual(stale, .terminalGone)

        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(projection: 3, revision: 3, lines: ["cd"], panes: [Self.pane("P", x: 0, width: 2, height: 1)])))
        let second = try await updates.terminal(for: "P")
        XCTAssertFalse(first === second)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: second, columns: 2, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 2, rows: 1), ["cd"])
        await engine.stop()
    }

    /// A new server boot's panes get new terminals, even under the same ids.
    func testANewBootGivesItsPanesNewTerminals() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1, boot: "one"))
        await feed.receive(.surface(try Self.surface(boot: "one", revision: 1, lines: ["one"], panes: [Self.pane("P", x: 0, width: 3, height: 1)])))
        let first = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()

        await feed.receive(try Self.snapshot(revision: 1, boot: "two"))
        await feed.receive(.surface(try Self.surface(boot: "two", revision: 1, lines: ["two"], panes: [Self.pane("P", x: 0, width: 3, height: 1)])))
        let second = try await updates.terminal(for: "P")
        XCTAssertFalse(first === second)
        let layout = try await updates.nextLayout()
        XCTAssertEqual(layout.bootID, "two")

        let stale = await registrationError(engine: engine, paneID: "P", terminal: first)
        XCTAssertEqual(stale, .terminalGone)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: second, columns: 3, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["two"])
        await engine.stop()
    }

    /// A later connection's feed takes over: the earlier one's late events are dropped, and the same
    /// boot's next frame is painted into the same terminals, so the last frame stays until then.
    func testALaterConnectionDropsTheEarlierOnesEventsAndKeepsThePanes() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let first = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let layout = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 3, rows: 1)

        let second = await engine.beginConnection(2)
        await first.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("old"))],
            panes: panes
        )))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        // Revisions restart with each connection.
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["two"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["two"])
        await engine.stop()
        let rest = await updates.drain()
        XCTAssertTrue(rest.isEmpty, "the same panes need no new terminals or layout: \(rest)")
        // After the first connection's frame, only the new connection's is reported as what the screen shows.
        XCTAssertEqual(updates.unreadPresented.map(\.connection), [first.connection, second.connection])
        XCTAssertEqual(layout.tab, nil)
    }

    /// The owner numbers its connections in the order it makes them. Once it ends one, that connection's
    /// events are dropped and the last frame stays; a connection that begins after a newer one began or
    /// ended, as a given-up opening's late one does, changes nothing.
    func testAnEndedConnectionsEventsAreDroppedAndAnOlderOneCannotBeginAgain() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        let second = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 3, rows: 1)

        let first = await engine.beginConnection(1)
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["old"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        await engine.endConnection(2)
        await second.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("two"))],
            panes: panes
        )))
        _ = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 2))
        await second.receive(.surface(try Self.surface(revision: 2, lines: ["two"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["one"])

        let third = await engine.beginConnection(3)
        await third.receive(try Self.snapshot(revision: 1))
        await third.receive(.surface(try Self.surface(revision: 1, lines: ["new"], panes: panes)))
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["new"])
        await engine.stop()
    }

    /// A pane Ghostty couldn't paint stays unpainted for the rest of its connection, and gets a new
    /// terminal from the next connection's first frame.
    func testAFailedPaneGetsANewTerminalFromTheNextConnection() async throws {
        let producerFailure = ProducerFailure()
        let engine = makeEngine(producerFailure: producerFailure)
        let updates = UpdateLog(engine)
        let panes = [Self.pane("P", x: 0, width: 3, height: 1)]
        let first = await engine.beginConnection(1)
        await first.receive(try Self.snapshot(revision: 1))
        await first.receive(.surface(try Self.surface(revision: 1, lines: ["one"], panes: panes)))
        let failed = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()

        producerFailure.isOn = true
        await first.receive(.patch(try Self.patch(
            base: 1,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("two"))],
            panes: panes
        )))
        guard case .paneTerminalFailed("P") = try await updates.next() else {
            return XCTFail("expected the pane's failure")
        }
        producerFailure.isOn = false
        await first.receive(.patch(try Self.patch(
            base: 2,
            rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells("six"))],
            panes: panes
        )))

        let second = await engine.beginConnection(2)
        await second.receive(try Self.snapshot(revision: 1))
        await second.receive(.surface(try Self.surface(revision: 1, lines: ["new"], panes: panes)))
        guard case .paneTerminal("P", let fresh) = try await updates.next() else {
            return XCTFail("expected a new terminal from the next connection, not an update on the failed one")
        }
        XCTAssertFalse(fresh === failed)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: fresh, columns: 3, rows: 1)
        XCTAssertEqual(rows(of: renderer, columns: 3, rows: 1), ["new"])
        await engine.stop()
    }

    /// A grid Remux can't index ends the engine as a wire failure; nothing after it is painted.
    func testAnUnindexableSurfaceIsAWireFailure() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["abcd"],
            panes: [Self.pane("P", x: 2, width: 5, height: 1)]
        )))
        guard case .failed(.wire, _) = try await updates.next() else {
            return XCTFail("expected a wire failure")
        }
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: [Self.pane("P", x: 0, width: 4, height: 1)])))
        await engine.stop()
        let after = await updates.drain()
        XCTAssertTrue(after.isEmpty, "\(after)")
    }

    // MARK: - Images

    /// An image Herdr places in a pane is drawn by that pane's terminal at its cells, counted from the
    /// pane's own text area, and by no other pane's.
    func testAnImageIsDrawnInItsPaneAtItsCells() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "R")
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["left 1    right 1 ", "left 2    right 2 ", "                  ", "                  "],
            panes: [Self.pane("L", x: 0, y: 1, width: 8, height: 3), Self.pane("R", x: 10, y: 1, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 13, y: 2, columns: 3, rows: 2)], sendingBytes: true)
        )))
        let terminals = try await updates.terminals(count: 2)
        let left = try await makeRenderer(engine: engine, paneID: "L", terminal: try XCTUnwrap(terminals["L"]), columns: 8, rows: 3)
        let right = try await makeRenderer(engine: engine, paneID: "R", terminal: try XCTUnwrap(terminals["R"]), columns: 8, rows: 3)

        let drawn = try await cellColor(of: right, column: 4, row: 1.5, until: \.isRed)
        XCTAssertTrue(drawn.isRed, "the image's cells in its pane: \(drawn)")
        let outside = try await cellColor(of: right, column: 1, row: 0, until: { !$0.isRed })
        XCTAssertFalse(outside.isRed, "a cell of the pane the image doesn't cover: \(outside)")
        let otherPane = try await cellColor(of: left, column: 4, row: 1.5, until: { !$0.isRed })
        XCTAssertFalse(otherPane.isRed, "the same cells in the other pane: \(otherPane)")
        await engine.stop()
    }

    /// Herdr sends an image's bytes once and then only places it. A pane whose terminal is new, here
    /// back after another tab was shown while Herdr kept the image, draws it from the bytes Herdr sent
    /// before.
    func testAPaneBackFromAnotherTabDrawsTheImageHerdrKept() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "P")
        let lines = ["first   ", "second  ", "third   "]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: [Self.pane("P", x: 0, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 2, y: 0, columns: 4, rows: 2)], sendingBytes: true)
        )))
        let first = try await updates.terminal(for: "P")

        await feed.receive(try Self.snapshot(revision: 2))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 2,
            lines: lines,
            panes: [Self.pane("Q", x: 0, width: 8, height: 3)],
            graphics: Self.scene(retaining: image)
        )))
        await feed.receive(try Self.snapshot(revision: 3))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 3,
            lines: lines,
            panes: [Self.pane("P", x: 0, width: 8, height: 3)],
            graphics: Self.scene(placing: image, at: [(x: 2, y: 0, columns: 4, rows: 2)], sendingBytes: false)
        )))
        let back = try await updates.terminal(for: "P")
        XCTAssertFalse(first === back)
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: back, columns: 8, rows: 3)
        let drawn = try await cellColor(of: renderer, column: 4, row: 1, until: \.isRed)
        XCTAssertTrue(drawn.isRed, "the kept image in the pane's new terminal: \(drawn)")
        await engine.stop()
    }

    /// Each frame's scene is the whole of what is placed: a placement Herdr moves is drawn at its new
    /// cells and not at its old ones, and one it no longer lists is gone.
    func testAPlacementFollowsEachFramesScene() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let image = Self.redImage(pane: "P")
        let lines = ["one     ", "two     ", "three   ", "four    "]
        let panes = [Self.pane("P", x: 0, width: 8, height: 4)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: panes,
            graphics: Self.scene(placing: image, at: [(x: 4, y: 0, columns: 3, rows: 1)], sendingBytes: true)
        )))
        let renderer = try await makeRenderer(
            engine: engine, paneID: "P", terminal: try await updates.terminal(for: "P"), columns: 8, rows: 4
        )
        let placed = try await cellColor(of: renderer, column: 5, row: 0, until: \.isRed)
        XCTAssertTrue(placed.isRed, "\(placed)")

        await feed.receive(.surface(try Self.surface(
            revision: 2,
            lines: lines,
            panes: panes,
            graphics: Self.scene(placing: image, at: [(x: 4, y: 2, columns: 3, rows: 1)], sendingBytes: false)
        )))
        let moved = try await cellColor(of: renderer, column: 5, row: 2, until: \.isRed)
        XCTAssertTrue(moved.isRed, "the new cells: \(moved)")
        let left = try await cellColor(of: renderer, column: 5, row: 0, until: { !$0.isRed })
        XCTAssertFalse(left.isRed, "the old cells: \(left)")

        await feed.receive(.surface(try Self.surface(revision: 3, lines: lines, panes: panes)))
        let gone = try await cellColor(of: renderer, column: 5, row: 2, until: { !$0.isRed })
        XCTAssertFalse(gone.isRed, "a placement the scene no longer lists: \(gone)")
        await engine.stop()
    }

    /// Herdr can send a replaced image's bytes in a later frame, past its per-message budget. Until they
    /// arrive, a placement that is otherwise the same keeps showing the image it had, as in Herdr's
    /// client; then it shows the new one.
    func testAReplacedImageShowsTheOldOneUntilItsBytesArrive() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let old = Self.image(pane: "P", version: 7)
        let new = Self.image(pane: "P", version: 8)
        let marker = Self.image(pane: "P", id: 9)
        let lines = ["one     ", "two     ", "three   ", "four    "]
        let panes = [Self.pane("P", x: 0, width: 8, height: 4)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: lines,
            panes: panes,
            graphics: Self.scene([(image: old, x: 2, y: 0, columns: 4, rows: 2, pixel: Self.red)])
        )))
        let renderer = try await makeRenderer(
            engine: engine, paneID: "P", terminal: try await updates.terminal(for: "P"), columns: 8, rows: 4
        )
        let before = try await cellColor(of: renderer, column: 4, row: 1, until: \.isRed)
        XCTAssertTrue(before.isRed, "\(before)")

        // The marker, whose bytes come with this frame, shows once the frame is drawn.
        await feed.receive(.surface(try Self.surface(
            revision: 2,
            lines: lines,
            panes: panes,
            graphics: Self.scene([
                (image: new, x: 2, y: 0, columns: 4, rows: 2, pixel: nil),
                (image: marker, x: 0, y: 3, columns: 2, rows: 1, pixel: Self.green),
            ])
        )))
        let drawn = try await cellColor(of: renderer, column: 1, row: 3, until: \.isGreen)
        XCTAssertTrue(drawn.isGreen, "the frame with the replacement: \(drawn)")
        let waiting = try await cellColor(of: renderer, column: 4, row: 1, until: { _ in true })
        XCTAssertTrue(waiting.isRed, "the old image while the new bytes are on their way: \(waiting)")

        await feed.receive(.surface(try Self.surface(
            revision: 3,
            lines: lines,
            panes: panes,
            graphics: Self.scene([
                (image: new, x: 2, y: 0, columns: 4, rows: 2, pixel: Self.green),
                (image: marker, x: 0, y: 3, columns: 2, rows: 1, pixel: nil),
            ])
        )))
        let replaced = try await cellColor(of: renderer, column: 4, row: 1, until: \.isGreen)
        XCTAssertTrue(replaced.isGreen, "the new image once its bytes arrive: \(replaced)")
        await engine.stop()
    }

    // MARK: - Fence and stop

    /// One registered surface per pane; a closed renderer is unregistered before its surface is freed,
    /// and the engine never wakes it again.
    func testRegistrationGoesThroughTheEngineAndUnregistrationFencesWakes() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)

        // Ghostty gives a terminal one renderer at a time, so only the same surface can come back.
        let surface = HerdrRendererSurface(handle: try XCTUnwrap(renderer.rawSurface))
        guard case .failure(.alreadyRegistered) = await engine.register(surface, paneID: "P", terminal: terminal) else {
            return XCTFail("expected the second registration to be refused")
        }

        await close(renderer)
        // The surface is freed: painting the pane now must not wake it.
        for revision in UInt64(2)...UInt64(20) {
            await feed.receive(.patch(try Self.patch(
                base: revision - 1,
                rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells(String(format: "%04d", revision)))],
                panes: panes
            )))
        }
        let again = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)
        XCTAssertEqual(rows(of: again, columns: 4, rows: 1), ["0020"])
        await engine.stop()
    }

    /// Frames and cell sizes still arriving while the engine stops are either applied before the stop
    /// or dropped; after it, registration fails, an unregistration still completes, and the updates end.
    func testStopWithWorkInFlight() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let feed = await engine.beginConnection(1)
        let panes = [Self.pane("P", x: 0, width: 4, height: 1)]
        await feed.receive(try Self.snapshot(revision: 1))
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["abcd"], panes: panes)))
        let terminal = try await updates.terminal(for: "P")
        _ = try await updates.nextLayout()
        _ = try await updates.nextPaneScroll()
        let renderer = try await makeRenderer(engine: engine, paneID: "P", terminal: terminal, columns: 4, rows: 1)

        let patches = try (UInt64(2)...UInt64(400)).map { revision in
            try Self.patch(
                base: revision - 1,
                rows: [HerdrPatchRow(x: 0, y: 0, cells: Self.cells(String(format: "%04d", revision)))],
                panes: panes
            )
        }
        let feeding = Task.detached {
            for patch in patches { await feed.receive(.patch(patch)) }
        }
        let resizing = Task.detached {
            for size in UInt32(10)...UInt32(60) { await engine.setCellSize(widthPx: size, heightPx: size * 2) }
        }
        await Task.yield()
        await engine.stop()
        await feeding.value
        await resizing.value

        await close(renderer)
        let afterStop = await registrationError(engine: engine, paneID: "P", terminal: terminal)
        XCTAssertEqual(afterStop, .engineEnded)
        let rest = await updates.drain()
        XCTAssertTrue(rest.isEmpty, "\(rest)")
    }

    // MARK: - Fixtures

    private func makeEngine(producerFailure: ProducerFailure? = nil) -> HerdrTerminalEngine {
        let cellWidth = measurement.cellMetrics.pixelWidth
        let cellHeight = measurement.cellMetrics.pixelHeight
        guard let producerFailure else {
            return HerdrTerminalEngine(cellWidthPx: cellWidth, cellHeightPx: cellHeight)
        }
        return HerdrTerminalEngine(
            cellWidthPx: cellWidth,
            cellHeightPx: cellHeight,
            makeProducer: SwitchableProducer.factory(producerFailure)
        )
    }

    /// A renderer of `columns` × `rows` cells over `terminal`, registered through the engine's fence,
    /// or through a fence that admits it as is for a stopped engine's terminal.
    private func makeRenderer(
        engine: HerdrTerminalEngine?,
        paneID: String,
        terminal: HerdrRetainedTerminal,
        columns: Int,
        rows: Int
    ) async throws -> TerminalPaneRenderer {
        let fence: any TerminalPaneRendererFence = engine.map { HerdrPaneRendererFence(engine: $0, paneID: paneID, terminal: terminal) }
            ?? AdmittingFence()
        let metrics = try XCTUnwrap(measurement.displayMetrics(columns: UInt32(columns), rows: UInt32(rows)))
        let renderer = try await withCheckedThrowingContinuation { continuation in
            TerminalPaneRenderer.create(
                app: runtime.appHandleForTesting,
                terminal: terminal,
                fence: fence,
                writeInput: nil,
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
                metrics: metrics,
                theme: .ghosttyDefault,
                diagnosticName: "test pane=\(paneID)",
                onRendererFailure: {}
            ) { result in continuation.resume(with: result) }
        }
        renderers.append(renderer)
        return renderer
    }

    private func close(_ renderer: TerminalPaneRenderer) async {
        renderers.removeAll { $0 === renderer }
        await withCheckedContinuation { continuation in
            renderer.close { continuation.resume() }
        }
    }

    private func registrationError(
        engine: HerdrTerminalEngine,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) async -> HerdrRendererRegistrationError? {
        do {
            let renderer = try await makeRenderer(engine: engine, paneID: paneID, terminal: terminal, columns: 1, rows: 1)
            await close(renderer)
            return nil
        } catch TerminalPaneRenderer.CreateError.registrationFailed(let error) {
            return error as? HerdrRendererRegistrationError
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    private func rows(of renderer: TerminalPaneRenderer, columns: Int, rows: Int) -> [String] {
        RendererText.rows(of: renderer, columns: columns, rows: rows)
    }

    /// The colour Ghostty draws at a point of the renderer's grid, given in cells (the middle of cell
    /// `column` is `column + 0.5`), from frames it draws on request: the first that satisfies `done`, or
    /// the last one after 10 s.
    private func cellColor(
        of renderer: TerminalPaneRenderer,
        column: Double,
        row: Double,
        until done: (RendererColor) -> Bool
    ) async throws -> RendererColor {
        let surface = try XCTUnwrap(renderer.rawSurface)
        if renderer.view.window == nil {
            let window = self.window ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = window.rootViewController ?? UIViewController()
            window.isHidden = false
            window.rootViewController?.view.addSubview(renderer.view)
            self.window = window
        }
        var size = ghostty_surface_size_s()
        XCTAssertEqual(ghostty_terminal_surface_size(surface, &size), GHOSTTY_TERMINAL_SURFACE_RESULT_OK)
        let point = CGRect(
            x: (column + 0.5) * Double(size.cell_width_px),
            y: (row + 0.5) * Double(size.cell_height_px),
            width: 1,
            height: 1
        )
        let deadline = Date().addingTimeInterval(10)
        var last: RendererColor?
        repeat {
            _ = ghostty_terminal_surface_request_frame(surface)
            ghostty_app_tick(runtime.appHandleForTesting)
            try await Task.sleep(for: .milliseconds(50))
            if let layer = GhosttyIOSurfaceFrame.rendererLayer(in: renderer.view.layer),
               let frame = try? GhosttyIOSurfaceFrame.read(from: layer, sourceRect: point) {
                let pixel = Array(frame.bytes.prefix(4))
                let color = RendererColor(red: pixel[2], green: pixel[1], blue: pixel[0])
                last = color
                if done(color) { return color }
            }
        } while Date() < deadline
        return try XCTUnwrap(last, "the renderer published no frame")
    }

    /// Each row of the area as text without surrounding blanks; nil for a row this check can't predict
    /// (anything but printable ASCII).
    private static func expectedRows(of frame: HerdrFrame, area: HerdrSurfaceRect) -> [String?] {
        (0..<Int(area.height)).map { y in
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            let symbols = frame.cells[start..<(start + Int(area.width))].map(\.symbol)
            guard symbols.allSatisfy({ $0.unicodeScalars.count == 1 && $0.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) } })
            else { return nil }
            return symbols.joined().trimmingCharacters(in: .whitespaces)
        }
    }

    static func snapshot(revision: UInt64, boot: String = "boot") throws -> HerdrSnapshot {
        try HerdrPresentationTests.snapshot(revision: revision, boot: boot)
    }

    /// A snapshot at `focusedPane`, on its tab, of tab `t1` with panes P and Q and tab `t2` with R and S;
    /// `zoomed` names the zoomed tabs, a tab `gone` names isn't listed, nor are its panes, and a pane
    /// `closed` names isn't listed.
    static func places(
        revision: UInt64,
        focusedPane: String = "P",
        zoomed: Set<String> = [],
        gone: Set<String> = [],
        closed: Set<String> = []
    ) throws -> HerdrSnapshot {
        let tabs = [(id: "t1", panes: ["P", "Q"]), (id: "t2", panes: ["R", "S"])]
            .filter { !gone.contains($0.id) }
            .map { (id: $0.id, panes: $0.panes.filter { !closed.contains($0) }) }
        let focusedTab = try XCTUnwrap(tabs.first { $0.panes.contains(focusedPane) }).id
        let tabEntries = tabs.enumerated().map { index, tab in
            """
            {"tab_id":"\(tab.id)","workspace_id":"w1","number":\(index + 1),"label":"\(tab.id)","custom_label":true,
             "zoomed":\(zoomed.contains(tab.id)),"focused":\(tab.id == focusedTab),"agent_status":"idle"}
            """
        }
        let paneEntries = tabs.flatMap { tab in
            tab.panes.map { HerdrServerScript.snapshotPane($0, tab: tab.id) }
        }
        let json = """
        {"boot_id":"boot","revision":\(revision),"focused_workspace_id":"w1","focused_tab_id":"\(focusedTab)",
         "focused_pane_id":"\(focusedPane)","workspaces":[],"tabs":[\(tabEntries.joined(separator: ","))],
         "panes":[\(paneEntries.joined(separator: ","))],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// Tab `t1` drawn with P focused, or Q.
    static let atP = [pane("P", x: 0, width: 2, height: 2, focused: true), pane("Q", x: 2, width: 2, height: 2)]
    static let atQ = [pane("P", x: 0, width: 2, height: 2), pane("Q", x: 2, width: 2, height: 2, focused: true)]

    static let zooming = HerdrZoomPolicy(zoomsMultipaneTabs: true, unzoomedByUser: [])
    static let notZooming = HerdrZoomPolicy(zoomsMultipaneTabs: false, unzoomedByUser: [])

    /// The session on screen at 4 × 2, taken to `pane` when given.
    static func show(_ pane: String? = nil, zoom: HerdrZoomPolicy = notZooming) -> HerdrView {
        .shown(HerdrSurfaceGeometry(cellWidthPx: 9, cellHeightPx: 18, cols: 4, rows: 2), to: pane.map { .place(.pane($0)) }, zoom: zoom)
    }

    static func move(_ pane: String, fromAnotherTab: Bool = false, zoom: HerdrZoomPolicy = notZooming) -> HerdrView {
        .moved(.place(.pane(pane)), fromAnotherTab: fromAnotherTab, columns: 4, rows: 2, zoom: zoom)
    }

    /// A move to another tab focuses the tab with Herdr's client's `tab.focus` after Remux's zoom comes off
    /// the tab left; the pane the tab shows is known only once the session is there, so the setting's zoom
    /// of the tab follows on it. Only the tab reached, zoomed, is drawn.
    func testATabMoveFocusesTheTabThenZoomsThePaneItShows() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)

        let move = try await start(feed, updates, .moved(.place(.tab("t2")), fromAnotherTab: true, columns: 4, rows: 2, zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands().last, "zoom P off")
        try await answerZoom(feed, outbox, zoomed: false)
        XCTAssertEqual(try outbox.commands().last, "tab.focus")
        XCTAssertEqual(try outbox.lastParams(), ["tab_id": "t2"])
        try await answer(feed, outbox)
        XCTAssertEqual(try outbox.commands().last, "tab.focus", "the zoom went before the tab was on screen")
        await feed.receive(try Self.places(revision: 4, focusedPane: "S"))
        XCTAssertEqual(try outbox.commands().last, "zoom S on")
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["S", "R"])
        await feed.receive(try Self.places(revision: 5, focusedPane: "S", zoomed: ["t2"]))
        await feed.receive(.surface(try Self.surface(
            projection: 5,
            revision: 5,
            lines: ["new ", "tab "],
            panes: [Self.pane("S", x: 0, width: 4, height: 2, focused: true)]
        )))
        guard case .paneTerminal("S", _) = try await updates.next(),
              case .layout(let reached) = try await updates.next()
        else { return XCTFail("a frame from before the tab's zoom was drawn") }
        XCTAssertEqual(reached.tab?.tabID, "t2")
        XCTAssertEqual(reached.tab?.zoomed, true)
        _ = try await updates.nextPaneScroll()
        try await activation(move, updates)
        XCTAssertEqual(updates.focusAnswers.map(\.request), [move])
        await engine.stop()
    }

    /// A split is a request like a move, with Herdr's client's `pane.split`. Herdr focuses the pane it made,
    /// which only snapshots from after its answer list, and the setting zooms the new pane, as tmux zooms a
    /// window a split gives a second pane. Only the frame showing the new pane zoomed is drawn.
    func testASplitShowsOnlyThePaneItMadeZoomed() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1, closed: ["Q"]))
        let show = try await start(feed, updates, Self.show(zoom: Self.zooming))
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await activation(show, updates)
        XCTAssertEqual(try outbox.commands(), [], "a one-pane tab was zoomed")
        let split = HerdrCreation.split(pane: "P", workspaceID: "w1", direction: .right)

        let request = try await start(feed, updates, .moved(.creation(split), fromAnotherTab: false, columns: 4, rows: 2, zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands().last, "pane.split")
        XCTAssertEqual(
            try outbox.lastParams(),
            ["workspace_id": "w1", "target_pane_id": "P", "direction": "right", "focus": "true"]
        )
        try await answer(feed, outbox, json: #"{"type":"pane_info","pane":{"pane_id":"Q"}}"#)
        await feed.receive(try Self.places(revision: 2, focusedPane: "Q"))
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["o t ", "w o "], panes: Self.atQ)))
        XCTAssertEqual(try outbox.commands().last, "zoom Q on")
        try await answerZoom(feed, outbox, zoomed: true, panes: ["Q", "P"])
        await feed.receive(try Self.places(revision: 3, focusedPane: "Q", zoomed: ["t1"]))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 3,
            lines: ["new ", "pane"],
            panes: [Self.pane("Q", x: 0, width: 4, height: 2, focused: true)]
        )))
        guard case .paneTerminal("Q", _) = try await updates.next(),
              case .layout(let made) = try await updates.next()
        else { return XCTFail("a frame from before the new pane's zoom was drawn") }
        XCTAssertEqual(made.tab?.zoomed, true)
        _ = try await updates.nextPaneScroll()
        try await activation(request, updates)
        XCTAssertEqual(try outbox.commands(), ["pane.split", "zoom Q on"])
        XCTAssertEqual(updates.creationAnswers.map(\.request), [request])
        XCTAssertNil(updates.creationAnswers.first?.failure)
        await engine.stop()
    }

    /// A snapshot Herdr sent before it made the split's pane can come while the split is in flight. It
    /// doesn't list the pane, which isn't gone for that: the setting's zoom still goes once a snapshot shows
    /// the session on the new pane.
    func testASplitZoomsItsPaneAfterASnapshotFromBeforeHerdrMadeIt() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        await feed.receive(try Self.places(revision: 1, closed: ["Q"]))
        let show = try await start(feed, updates, Self.show(zoom: Self.zooming))
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await activation(show, updates)
        let split = HerdrCreation.split(pane: "P", workspaceID: "w1", direction: .right)

        _ = try await start(feed, updates, .moved(.creation(split), fromAnotherTab: false, columns: 4, rows: 2, zoom: Self.zooming))
        XCTAssertEqual(try outbox.commands().last, "pane.split")
        await feed.receive(try Self.places(revision: 2, closed: ["Q"]))
        try await answer(feed, outbox, json: #"{"type":"pane_info","pane":{"pane_id":"Q"}}"#)
        XCTAssertEqual(try outbox.commands().last, "pane.split", "the zoom went before the new pane was on screen")
        await feed.receive(try Self.places(revision: 3, focusedPane: "Q"))
        XCTAssertEqual(try outbox.commands().last, "zoom Q on", "the new pane wasn't zoomed")
        await engine.stop()
    }

    /// Closing the tab on screen holds the frames until a snapshot no longer lists it, then the setting zooms
    /// the tab Herdr shows: the tab left isn't drawn again, nor the tab reached unzoomed. The closed tab
    /// takes Remux's zoom with it, so nothing is unzoomed first.
    func testClosingTheTabOnScreenShowsOnlyTheTabHerdrShowsThen() async throws {
        let engine = makeEngine()
        let updates = UpdateLog(engine)
        let (feed, outbox) = await connect(engine)
        try await shownZoomed(feed, updates, outbox)

        let close = try await start(
            feed, updates, .moved(.closing(.tab("t1"), group: false), fromAnotherTab: false, columns: 4, rows: 2, zoom: Self.zooming)
        )
        XCTAssertEqual(try outbox.commands().last, "tab.close")
        XCTAssertEqual(try outbox.lastParams(), ["tab_id": "t1"])
        await feed.receive(.surface(try Self.surface(projection: 2, revision: 2, lines: ["old ", "tab "], panes: Self.atP)))
        try await answer(feed, outbox)
        XCTAssertEqual(try outbox.commands().last, "tab.close", "the zoom went before the tab was gone")
        await feed.receive(try Self.places(revision: 3, focusedPane: "R", gone: ["t1"]))
        await feed.receive(.surface(try Self.surface(
            projection: 3,
            revision: 3,
            lines: ["o t ", "w o "],
            panes: [Self.pane("R", x: 0, width: 2, height: 2, focused: true), Self.pane("S", x: 2, width: 2, height: 2)]
        )))
        XCTAssertEqual(try outbox.commands().last, "zoom R on")
        try await answerZoom(feed, outbox, zoomed: true, tab: "t2", panes: ["R", "S"])
        await feed.receive(try Self.places(revision: 4, focusedPane: "R", zoomed: ["t2"], gone: ["t1"]))
        await feed.receive(.surface(try Self.surface(
            projection: 4,
            revision: 4,
            lines: ["new ", "tab "],
            panes: [Self.pane("R", x: 0, width: 4, height: 2, focused: true)]
        )))
        guard case .paneTerminal("R", _) = try await updates.next(),
              case .layout(let reached) = try await updates.next()
        else { return XCTFail("a frame from before the close's zoom was drawn") }
        XCTAssertEqual(reached.tab?.tabID, "t2")
        XCTAssertEqual(reached.tab?.zoomed, true)
        _ = try await updates.nextPaneScroll()
        try await activation(close, updates)
        XCTAssertEqual(try outbox.commands().suffix(2), ["tab.close", "zoom R on"])
        XCTAssertEqual(updates.closeAnswers.map(\.request), [close])
        XCTAssertNil(updates.closeAnswers.first?.failure)
        await engine.stop()
    }

    /// A connection whose requests go to an outbox the test reads, opened as the model opens one.
    private func connect(
        _ engine: HerdrTerminalEngine,
        commandTimeout: Duration = .seconds(60)
    ) async -> (HerdrEngineFeed, RecordingOutbox) {
        let outbox = RecordingOutbox()
        let feed = await engine.beginConnection(1, outbox: outbox)
        await feed.opened(
            methods: [
                HerdrScreenModel.paneFocusMethod, HerdrScreenModel.paneZoomMethod, "worktree.list", "tab.focus",
                "pane.split", "tab.close",
            ],
            commandTimeout: commandTimeout
        )
        return (feed, outbox)
    }

    /// Starts `view`; the request the engine reported started.
    private func start(
        _ feed: HerdrEngineFeed,
        _ updates: UpdateLog,
        _ view: HerdrView,
        within deadline: Duration = .seconds(5)
    ) async throws -> UInt64 {
        await feed.start(view, within: deadline)
        return try await updates.nextStarted()
    }

    private func activation(_ request: UInt64, _ updates: UpdateLog) async throws {
        while true {
            if case .activated(request, _) = try await updates.next() { return }
        }
    }

    /// The session shown at P on tab `t1`, drawn as `panes`, its show complete; the newest snapshot is
    /// revision 1.
    private func shown(_ feed: HerdrEngineFeed, _ updates: UpdateLog, _ outbox: RecordingOutbox, panes: [String]) async throws {
        await feed.receive(try Self.places(revision: 1))
        let show = try await start(feed, updates, Self.show())
        try await acknowledgeShow(feed, outbox, floor: 1)
        await feed.receive(.surface(try Self.surface(revision: 1, lines: ["one ", "two "], panes: panes)))
        try await activation(show, updates)
    }

    /// The session shown at P on tab `t1`, which the setting zoomed, its show complete; the newest
    /// snapshot is revision 2.
    private func shownZoomed(_ feed: HerdrEngineFeed, _ updates: UpdateLog, _ outbox: RecordingOutbox) async throws {
        await feed.receive(try Self.places(revision: 1))
        let show = try await start(feed, updates, Self.show(zoom: Self.zooming))
        try await acknowledgeShow(feed, outbox, floor: 1)
        try await answerZoom(feed, outbox, zoomed: true)
        await feed.receive(try Self.places(revision: 2, zoomed: ["t1"]))
        await feed.receive(.surface(try Self.surface(
            projection: 2,
            revision: 1,
            lines: ["one ", "two "],
            panes: [Self.pane("P", x: 0, width: 4, height: 2, focused: true)]
        )))
        try await activation(show, updates)
    }

    /// Herdr's answer to the newest show, with the floor its frame must reach.
    private func acknowledgeShow(_ feed: HerdrEngineFeed, _ outbox: RecordingOutbox, floor: UInt64) async throws {
        let show = try XCTUnwrap(outbox.surfaceSets().last { $0.active }, "no show went out")
        await feed.receive(try Self.chunk(HerdrServerScript.surfaceSetReply(id: show.id, active: true, projection: floor)))
    }

    /// Herdr's reply to the command in flight.
    private func answer(
        _ feed: HerdrEngineFeed,
        _ outbox: RecordingOutbox,
        json result: String = #"{"type":"ok"}"#
    ) async throws {
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: try outbox.lastCommand().id, json: result)))
    }

    private func answer(
        _ feed: HerdrEngineFeed,
        _ outbox: RecordingOutbox,
        error: (code: String, message: String)
    ) async throws {
        await feed.receive(try Self.chunk(HerdrConnectionTests.reply(id: try outbox.lastCommand().id, error: error)))
    }

    /// Herdr's answer to the zoom in flight: `tab` zoomed or not, with the first of `panes` focused.
    private func answerZoom(
        _ feed: HerdrEngineFeed,
        _ outbox: RecordingOutbox,
        zoomed: Bool,
        changed: Bool = true,
        tab: String = "t1",
        panes: [String] = ["P", "Q"]
    ) async throws {
        let places = panes.enumerated().map { index, pane in
            (id: pane, x: UInt16(index * 2), y: UInt16(0), width: UInt16(2), height: UInt16(2))
        }
        let reply = HerdrServerScript.zoomReply(
            id: try outbox.lastCommand().id,
            changed: changed,
            zoomed: zoomed,
            tab: tab,
            panes: places
        )
        await feed.receive(try Self.chunk(reply))
    }

    /// A reply frame as the connection hands it over.
    static func chunk(_ frame: [UInt8]) throws -> HerdrResponseChunk {
        guard case .responseChunk(let chunk) = try HerdrServerMessage.decode(Array(frame.dropFirst(4))) else {
            throw NotAReply()
        }
        return chunk
    }

    private struct NotAReply: Error {}

    static func cells(_ text: String) -> [HerdrCell] {
        text.map {
            HerdrCell(symbol: String($0), fg: HerdrColor(raw: 0), bg: HerdrColor(raw: 0), modifier: 0, skip: false, hyperlink: nil)
        }
    }

    /// `scroll` is the viewport's lines from the bottom, the most it can be, and the program's rows.
    static func pane(
        _ id: String,
        x: Int,
        y: Int = 0,
        width: Int,
        height: Int,
        focused: Bool = false,
        scroll: (fromBottom: Int, max: Int, rows: Int)? = nil,
        mouseReporting: Bool = false
    ) -> String {
        let scrollJSON = scroll.map {
            #"{"offset_from_bottom":\#($0.fromBottom),"max_offset_from_bottom":\#($0.max),"viewport_rows":\#($0.rows)}"#
        } ?? "null"
        return """
        {"pane_id":"\(id)","content_revision":1,"rect":{"x":\(x),"y":\(y),"width":\(width),"height":\(height)},
         "inner_rect":{"x":\(x),"y":\(y),"width":\(width),"height":\(height)},"scrollbar_rect":null,"scroll":\(scrollJSON),
         "focused":\(focused),"mouse_reporting":\(mouseReporting),"sgr_pixel_mouse":false,
         "alternate_screen_active":false,"pixel_width":0,"pixel_height":0}
        """
    }

    /// A surface of the given lines, all of one width, with `graphics` as its scene.
    static func surface(
        boot: String = "boot",
        projection: UInt64 = 1,
        revision: UInt64,
        lines: [String],
        panes: [String],
        graphics: String = #"{"assets":[],"placements":[],"retained_assets":[]}"#
    ) throws -> HerdrPaneSurfaceFrame {
        let width = lines.first?.count ?? 0
        precondition(lines.allSatisfy { $0.count == width })
        let cells = lines.joined().map {
            #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
        }
        let json = """
        {"boot_id":"\(boot)","projection_revision":\(projection),"surface_revision":\(revision),
         "frame":{"cells":[\(cells.joined(separator: ","))],"width":\(width),"height":\(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]},
         "panes":[\(panes.joined(separator: ","))],"splits":[],"popup":null,"graphics":\(graphics)}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    static func patch(base: UInt64, rows: [HerdrPatchRow], panes: [String]) throws -> HerdrPaneSurfacePatch {
        try HerdrPresentationTests.patch(base: base, rows: rows, panes: panes)
    }

    /// The key of a solid red 2×2 RGBA image from terminal image 7 of pane `pane`.
    static func redImage(pane: String) -> String {
        image(pane: pane)
    }

    /// The key of a solid 2×2 RGBA image from terminal image `id` of pane `pane`. A new `version` is
    /// that image replaced: the same source with other contents.
    static func image(pane: String, id: Int = 7, version: Int = 7) -> String {
        #"{"source":{"Terminal":{"target":{"Pane":{"pane_id":"\#(pane)"}},"image_id":\#(id)}},"#
            + #""image_width":2,"image_height":2,"format":"Rgba","data_len":16,"data_fingerprint":\#(version)}"#
    }

    static let red = "255,0,0,255"
    static let green = "0,255,0,255"

    /// A scene placing the red `image` at each of `cells` (in the frame's cells), carrying its bytes or not.
    static func scene(
        placing image: String,
        at cells: [(x: Int, y: Int, columns: Int, rows: Int)],
        sendingBytes: Bool
    ) -> String {
        scene(cells.map { (image: image, x: $0.x, y: $0.y, columns: $0.columns, rows: $0.rows, pixel: sendingBytes ? red : nil) })
    }

    /// A scene placing each image at its cells, carrying the bytes of those given a `pixel` colour.
    static func scene(_ placed: [(image: String, x: Int, y: Int, columns: Int, rows: Int, pixel: String?)]) -> String {
        var sent = Set<String>()
        let assets = placed.compactMap { item -> String? in
            guard let pixel = item.pixel, sent.insert(item.image).inserted else { return nil }
            return #"{"key":\#(item.image),"data":[\#(Array(repeating: pixel, count: 4).joined(separator: ","))]}"#
        }
        let placements = placed.enumerated().map { index, item in
            #"{"asset":\#(item.image),"logical_placement_id":\#(index + 1),"x":\#(item.x),"y":\#(item.y),"#
                + #""cols":\#(item.columns),"rows":\#(item.rows),"source_x":0,"source_y":0,"source_width":0,"#
                + #""source_height":0,"x_offset":0,"y_offset":0,"z":0,"scrollback_offset":0}"#
        }
        return #"{"assets":[\#(assets.joined(separator: ","))],"placements":[\#(placements.joined(separator: ","))],"#
            + #""retained_assets":[]}"#
    }

    /// A scene that places nothing and keeps `image`, as Herdr keeps an image whose pane is out of view.
    static func scene(retaining image: String) -> String {
        #"{"assets":[],"placements":[],"retained_assets":[\#(image)]}"#
    }
}

/// A colour read from a renderer's frame.
struct RendererColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    /// The red of the test images, through Ghostty's colour handling.
    var isRed: Bool { red > 200 && green < 80 && blue < 80 }
    var isGreen: Bool { green > 200 && red < 80 && blue < 80 }
}

/// The engine's updates in order. `next` leaves out what a frame shows, a request's start and the
/// answers the engine reports, which `nextPresented`, `nextStarted` and the answer lists read.
@MainActor
private final class UpdateLog {
    private var iterator: AsyncStream<HerdrEngineUpdate>.AsyncIterator
    /// Updates `next` hasn't returned yet, read while looking for another kind.
    private var held: [HerdrEngineUpdate] = []
    private var presented: [(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, connection: UInt64)] = []
    /// The frames reported as presented that `nextPresented` hasn't returned, in order.
    var unreadPresented: [(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, connection: UInt64)] {
        presented
    }
    /// Every request the engine started, in order, and how many `nextStarted` has returned.
    private(set) var started: [(request: UInt64, kind: HerdrViewKind)] = []
    private var startsRead = 0
    /// The focus answers the engine reported, in order.
    private(set) var focusAnswers: [(request: UInt64, failure: HerdrCommandError?)] = []
    /// The creation answers the engine reported, in order.
    private(set) var creationAnswers: [(request: UInt64, creation: HerdrCreation, failure: HerdrCommandError?)] = []
    /// The close answers the engine reported, in order.
    private(set) var closeAnswers: [(request: UInt64, place: HerdrPlace, failure: HerdrCommandError?)] = []
    /// The zoom answers the engine reported, in order.
    private(set) var zoomAnswers: [(zoom: HerdrPaneZoomResult?, failure: HerdrCommandError?, reportsFailure: Bool)] = []

    init(_ engine: HerdrTerminalEngine) {
        iterator = engine.updates.makeAsyncIterator()
    }

    func next() async throws -> HerdrEngineUpdate {
        if !held.isEmpty { return held.removeFirst() }
        while true {
            if let update = try await read() { return update }
        }
    }

    /// The next request reported started.
    func nextStarted() async throws -> UInt64 {
        while startsRead == started.count {
            if let update = try await read() { held.append(update) }
        }
        startsRead += 1
        return started[startsRead - 1].request
    }

    /// The next frame reported as presented.
    func nextPresented() async throws -> (bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, connection: UInt64) {
        while presented.isEmpty {
            if let update = try await read() { held.append(update) }
        }
        return presented.removeFirst()
    }

    /// The rest of the updates `next` would return, once the engine has stopped.
    func drain() async -> [HerdrEngineUpdate] {
        var rest = held
        held.removeAll()
        while true {
            do {
                if let update = try await read() { rest.append(update) }
            } catch {
                return rest
            }
        }
    }

    func terminals(count: Int) async throws -> [String: HerdrRetainedTerminal] {
        var terminals: [String: HerdrRetainedTerminal] = [:]
        while terminals.count < count {
            guard case .paneTerminal(let paneID, let terminal) = try await next() else { continue }
            terminals[paneID] = terminal
        }
        return terminals
    }

    func terminal(for paneID: String) async throws -> HerdrRetainedTerminal {
        while true {
            if case .paneTerminal(paneID, let terminal) = try await next() { return terminal }
        }
    }

    func nextLayout() async throws -> HerdrPaneLayout {
        while true {
            if case .layout(let layout) = try await next() { return layout }
        }
    }

    func nextPaneScroll() async throws -> [String: HerdrPaneScroll] {
        while true {
            if case .paneScroll(let scrolls) = try await next() { return scrolls }
        }
    }

    /// The engine's next update, or nil for one filed with its kind.
    private func read() async throws -> HerdrEngineUpdate? {
        var iterator = self.iterator
        defer { self.iterator = iterator }
        guard let update = await iterator.next(isolation: #isolation) else { throw UpdateLogError.finished }
        switch update {
        case .presented(let bootID, let revision, let paneIDs, _, let connection):
            presented.append((bootID, revision, paneIDs, connection))
        case .started(let request, let kind, _, _):
            started.append((request, kind))
        case .answered(let request, .focus, let failure, _):
            focusAnswers.append((request, failure))
        case .answered(let request, .create(let creation), let failure, _):
            creationAnswers.append((request, creation, failure))
        case .answered(let request, .close(let place, _), let failure, _):
            closeAnswers.append((request, place, failure))
        case .zoomAnswered(let zoom, _, let failure, let reportsFailure, _):
            zoomAnswers.append((zoom, failure, reportsFailure))
        default:
            return update
        }
        return nil
    }
}

private enum UpdateLogError: Error {
    case finished
}

/// The engine's outbox in a test: what it sends, in order, and whether the session is shown.
private final class RecordingOutbox: HerdrOutbound, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private var active = false

    var isSurfaceActive: Bool {
        lock.withLock { active }
    }

    func send(_ messages: [HerdrClientMessage]) {
        lock.withLock { frames += messages.map(\.frame) }
    }

    func setSurfaceActive(_ active: Bool) {
        lock.withLock { self.active = active }
    }

    @MainActor
    func writes() throws -> [ClientWrite] {
        try lock.withLock { frames }.map(ClientWrite.decode)
    }

    /// The commands sent, shows and hides left out: a zoom or focus by its pane, anything else by its
    /// method.
    @MainActor
    func commands() throws -> [String] {
        try writes().compactMap { write in
            switch write {
            case .paneZoom(_, let pane, let mode): "zoom \(pane) \(mode)"
            case .paneFocus(_, let pane): "focus \(pane)"
            case .command(_, let method, _): method
            default: nil
            }
        }
    }

    /// The newest command sent, not a show or hide.
    @MainActor
    func lastCommand() throws -> HerdrConnectionTests.Request {
        let requests = try lock.withLock { frames }.filter(Self.isRequest).map(HerdrConnectionTests.request)
        return try XCTUnwrap(requests.last { $0.method != HerdrConnection.surfaceSetMethod }, "no command went out")
    }

    /// The params of the newest command other than a focus or zoom.
    @MainActor
    func lastParams() throws -> [String: String] {
        let params = try writes().compactMap { write in
            if case .command(_, _, let params) = write { params } else { nil }
        }
        return try XCTUnwrap(params.last, "no command went out")
    }

    @MainActor
    func surfaceSets() throws -> [(id: String, active: Bool)] {
        try writes().compactMap { write in
            if case .surfaceSet(let id, let active) = write { (id, active) } else { nil }
        }
    }

    private static func isRequest(_ frame: [UInt8]) -> Bool {
        var reader = HerdrWireReader(Array(frame.dropFirst(4)))
        return (try? reader.variant()) == 15
    }
}

/// Whether the engine let a close go.
private final class Closed: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.withLock { closed }
    }

    var close: @Sendable () -> Void {
        { [self] in lock.withLock { closed = true } }
    }
}

/// The answers a test's commands get, in order.
@MainActor
private final class Answers {
    let record: @Sendable (Result<HerdrCommandReply, HerdrCommandError>) -> Void
    private var iterator: AsyncStream<Result<HerdrCommandReply, HerdrCommandError>>.AsyncIterator

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Result<HerdrCommandReply, HerdrCommandError>.self)
        record = { continuation.yield($0) }
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Result<HerdrCommandReply, HerdrCommandError> {
        var iterator = self.iterator
        defer { self.iterator = iterator }
        guard let answer = await iterator.next(isolation: #isolation) else { throw UpdateLogError.finished }
        return answer
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

/// Admits renderers over a stopped engine's terminals, which nothing feeds any more.
@MainActor
private final class AdmittingFence: TerminalPaneRendererFence {
    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        completion(.success(()))
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        completion()
    }
}
