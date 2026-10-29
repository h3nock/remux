import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// Herdr's popup in Remux: the engine paints it into a terminal of its own, the screen shows it over the
/// whole terminal area at the font that fills it, and it takes every input while it is open over the tab
/// on screen, as in Herdr's client, which also keeps the tab's tabs and panes inert under it.
@MainActor
final class HerdrPopupTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []
    private var windows: [UIWindow] = []
    private var renderers: [TerminalPaneRenderer] = []
    private var runtime: GhosttyKitRuntime?

    private static let popupID = "popup-terminal"
    private static let panes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 3, height: 1),
    ]

    override func tearDown() async throws {
        for renderer in renderers {
            await withCheckedContinuation { continuation in renderer.close { continuation.resume() } }
        }
        renderers.removeAll()
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for harness in harnesses {
            for bridge in await harness.bridges.opened {
                await bridge.finishServing()
            }
            await harness.model.stop()
        }
        harnesses.removeAll()
        runtime = nil
    }

    // MARK: - Engine

    /// The popup's frame is painted into a terminal of its own, which comes before the layout that lists
    /// the popup with its title and grid; its next frames repaint it, and once it closes the layout drops
    /// it and the engine its terminal.
    func testThePopupIsPaintedIntoATerminalOfItsOwn() async throws {
        let engine = HerdrTerminalEngine(cellWidthPx: 18, cellHeightPx: 38)
        var updates = engine.updates.makeAsyncIterator()
        let feed = await engine.beginConnection(1)
        await feed.receive(try HerdrTerminalEngineTests.snapshot(revision: 1))
        await feed.receive(.surface(try Self.engineSurface(revision: 1, popup: ("T", "notes", ["hi  ", "ok  "]))))

        var terminal: HerdrRetainedTerminal?
        var layout: HerdrPaneLayout?
        while layout == nil {
            switch await updates.next() {
            case .popupTerminal(let terminalID, let popupTerminal)?:
                XCTAssertEqual(terminalID, "T")
                terminal = popupTerminal
            case .layout(let next)?:
                XCTAssertNotNil(terminal, "the layout listed the popup before its terminal came")
                layout = next
            case nil:
                return XCTFail("the engine ended")
            default:
                continue
            }
        }
        XCTAssertEqual(layout?.popup, HerdrPaneLayout.Popup(terminalID: "T", title: "notes", columns: 4, rows: 2))
        let popupTerminal = try XCTUnwrap(terminal)
        let renderer = try await makeRenderer(engine: engine, terminalID: "T", terminal: popupTerminal, columns: 4, rows: 2)
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 4, rows: 2), ["hi", "ok"])

        await feed.receive(.surface(try Self.engineSurface(revision: 2, popup: ("T", "notes", ["hi  ", "yes "]))))
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 4, rows: 2), ["hi", "yes"])

        await feed.receive(.surface(try Self.engineSurface(revision: 3, popup: nil)))
        while true {
            guard case .layout(let next)? = await updates.next() else { continue }
            XCTAssertNil(next.popup)
            break
        }
        // Ghostty gives a terminal one renderer at a time.
        renderers.removeAll { $0 === renderer }
        await withCheckedContinuation { continuation in renderer.close { continuation.resume() } }
        let registration = await registrationError(engine: engine, terminalID: "T", terminal: popupTerminal)
        XCTAssertEqual(registration, .terminalGone)
        await engine.stop()
    }

    /// A new grid for the popup, as Herdr gives when the screen's size changes, resizes its terminal in
    /// place; another popup gets a terminal of its own.
    func testANewGridResizesThePopupsTerminalAndAnotherPopupGetsItsOwn() async throws {
        let engine = HerdrTerminalEngine(cellWidthPx: 18, cellHeightPx: 38)
        var updates = engine.updates.makeAsyncIterator()
        let feed = await engine.beginConnection(1)
        await feed.receive(try HerdrTerminalEngineTests.snapshot(revision: 1))
        await feed.receive(.surface(try Self.engineSurface(revision: 1, popup: ("T", "popup", ["ab", "cd"]))))
        var terminals: [String] = []
        var grid: [UInt16] = []
        func note(_ update: HerdrEngineUpdate) {
            switch update {
            case .popupTerminal(let terminalID, _): terminals.append(terminalID)
            case .layout(let layout): grid = layout.popup.map { [$0.columns, $0.rows] } ?? []
            default: break
            }
        }
        while grid != [2, 2], let update = await updates.next() { note(update) }
        await feed.receive(.surface(try Self.engineSurface(revision: 2, popup: ("T", "popup", ["abc", "def", "ghi"]))))
        while grid != [3, 3], let update = await updates.next() { note(update) }
        XCTAssertEqual(terminals, ["T"], "a new grid made a new terminal")

        await feed.receive(.surface(try Self.engineSurface(revision: 3, popup: ("U", "popup", ["xy", "zw"]))))
        while grid != [2, 2], let update = await updates.next() { note(update) }
        XCTAssertEqual(terminals, ["T", "U"])
        await engine.stop()
    }

    // MARK: - Input

    /// While a popup is open over the tab on screen, typing, pastes and keys go into it, none to a pane;
    /// once it closes, the pane takes them again.
    func testTypingPastesAndKeysGoIntoThePopup() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)

        XCTAssertTrue(adapter.sendInputToFocusedSurface("l").isAccepted)
        XCTAssertTrue(adapter.sendPasteToFocusedSurface("echo hi").isAccepted)
        let enter = GhosttySurfaceKeyEvent(keyCode: .enter)
        XCTAssertTrue(adapter.sendKeyEventToFocusedSurface(enter).isAccepted)
        let typed = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(typed, popupInput(HerdrInputTranslator.events(forText: "l", reportsAllKeys: false)))
        let pasted = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(pasted, popupInput([.paste("echo hi")]))
        let keyed = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(keyed, popupInput([try XCTUnwrap(HerdrInputTranslator.event(for: enter))]))

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 4, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup didn't close") { harness.model.layout?.popup == nil }
        XCTAssertTrue(adapter.sendInputToFocusedSurface("l").isAccepted)
        let afterwards = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(
            afterwards,
            HerdrClientMessage.paneInput(
                paneID: "w1:p1",
                events: HerdrInputTranslator.events(forText: "l", reportsAllKeys: false)
            ).frame
        )
    }

    /// The composer's message and its Enter go into the popup, and each counts as sent once Herdr has it,
    /// as for a pane.
    func testTheComposersMessageGoesIntoThePopup() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }

        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: pane) }
        let pasteInput = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(pasteInput, popupInput([.paste("fix it")]))
        let pastePing = try await nextPing(session.bridge, from: &index)
        await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
        let pasteSent = await paste.value
        XCTAssertTrue(pasteSent)

        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        }
        let enterInput = try await nextInput(session.bridge, from: &index)
        XCTAssertEqual(enterInput, popupInput([.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterPing = try await nextPing(session.bridge, from: &index)
        await session.bridge.serve(HerdrConnectionTests.pong(enterPing))
        let entered = await enter.value
        XCTAssertTrue(entered)
    }

    // MARK: - Screen

    /// The screen shows the popup with its title and Herdr's grid, and follows both while it is shown;
    /// once it closes, the panes are back.
    func testTheScreenFollowsThePopupsTitleAndGridWhileItIsShown() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        func popup() -> GhosttyTerminalViewportPresentationProjection.Popup? {
            adapter.terminalScreenPresentationProjection.viewport.popup
        }
        await session.bridge.serve(popupSurface(revision: 3, title: "popup", lines: ["abcd", "efgh"]))
        try await harness.waitUntil("the popup wasn't shown") { popup() != nil }
        XCTAssertEqual(popup()?.title, "popup")
        XCTAssertEqual([popup()?.columns, popup()?.rows], [4, 2])
        let id = try XCTUnwrap(popup()?.id)

        await session.bridge.serve(popupSurface(revision: 4, title: "notes", lines: ["abcdef", "ghijkl", "mnopqr"]))
        try await harness.waitUntil("the popup's new title and grid weren't shown") {
            popup()?.title == "notes" && popup()?.columns == 6 && popup()?.rows == 3
        }
        XCTAssertEqual(popup()?.id, id, "the same popup became another surface")

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 5, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup stayed after it closed") { popup() == nil }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.panes.count, 2)
    }

    /// The popup's renderer draws Herdr's grid at the largest font its area holds, larger than the panes'
    /// for a grid half the screen's; a smaller area while it is shown, or a new grid, refits it.
    func testThePopupsFontFillsItsAreaAndFollowsIt() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        let paneCell = try XCTUnwrap(model.measurement?.cellMetrics)
        await session.bridge.serve(popupSurface(revision: 3, lines: Self.lines(columns: 10, rows: 4)))
        try await harness.waitUntil("the popup wasn't laid out") { model.layout?.popup != nil }

        adapter.preparePopupArea(size: CGSize(width: 390, height: 500), scale: 3)
        try await harness.waitUntil("the popup's renderer wasn't made") { model.popupSurface != nil }
        // On screen, as the popup's view is: a new font's renderer is in once it has drawn.
        show(try XCTUnwrap(model.popupSurface?.renderer.view))
        try await harness.waitUntil("the popup didn't draw") { model.popupPresentation == .ready }
        let fit = try XCTUnwrap(model.popupSurface?.fit)
        XCTAssertLessThanOrEqual(10 * fit.cell.pixelWidth, 1170)
        XCTAssertLessThanOrEqual(4 * fit.cell.pixelHeight, 1500)
        XCTAssertGreaterThan(fit.cell.pixelWidth, paneCell.pixelWidth)
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.popup?.cell, fit.cell)

        adapter.preparePopupArea(size: CGSize(width: 390, height: 100), scale: 3)
        try await harness.waitUntil("the popup wasn't refitted to its smaller area") {
            (model.popupSurface?.fit.fontSize ?? .infinity) < fit.fontSize && model.popupPresentation == .ready
        }
        let smaller = try XCTUnwrap(model.popupSurface?.fit)
        XCTAssertLessThanOrEqual(4 * smaller.cell.pixelHeight, 300)
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.popup?.cell, smaller.cell)

        await session.bridge.serve(popupSurface(revision: 4, lines: Self.lines(columns: 40, rows: 4)))
        try await harness.waitUntil("the popup wasn't refitted to its new grid") {
            guard let next = model.popupSurface?.fit else { return false }
            return 40 * next.cell.pixelWidth <= 1170 && next.fontSize < smaller.fontSize
        }
    }

    /// The keyboard coming up and going as the popup is shown: its area shrinks, and grows back before the
    /// renderer at the smaller font has drawn, while Herdr's new grids and text come. The popup ends drawn at
    /// the font of its last area and grid, showing Herdr's newest text.
    func testThePopupKeepsUpWithItsAreaChangingWhileItsFontIsReplaced() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3, lines: Self.lines(columns: 20, rows: 10)))
        try await harness.waitUntil("the popup wasn't laid out") { model.layout?.popup != nil }
        adapter.preparePopupArea(size: CGSize(width: 390, height: 600), scale: 3)
        try await harness.waitUntil("the popup's renderer wasn't made") { model.popupSurface != nil }
        show(try XCTUnwrap(model.popupSurface?.renderer.view))
        try await harness.waitUntil("the popup didn't draw") { model.popupPresentation == .ready }
        let first = try XCTUnwrap(model.popupSurface?.fit)

        adapter.preparePopupArea(size: CGSize(width: 390, height: 250), scale: 3)
        adapter.preparePopupArea(size: CGSize(width: 390, height: 600), scale: 3)
        await session.bridge.serve(popupSurface(revision: 4, lines: Self.lines(columns: 20, rows: 5)))
        adapter.preparePopupArea(size: CGSize(width: 390, height: 250), scale: 3)
        let newest = ["newest text"] + Self.lines(columns: 20, rows: 4).map { _ in String(repeating: " ", count: 20) }
        await session.bridge.serve(popupSurface(
            revision: 5,
            lines: newest.map { $0.padding(toLength: 20, withPad: " ", startingAt: 0) }
        ))

        try await harness.waitUntil("the popup didn't settle at its last area and grid", timeout: .seconds(10)) {
            guard let fit = model.popupSurface?.fit, model.popupPresentation == .ready,
                  model.layout?.popup?.rows == 5
            else { return false }
            return 5 * fit.cell.pixelHeight <= 750 && 20 * fit.cell.pixelWidth <= 1170
        }
        let renderer = try XCTUnwrap(model.popupSurface?.renderer)
        XCTAssertEqual(RendererText.rows(of: renderer, columns: 20, rows: 1), ["newest text"])
        XCTAssertEqual(model.popupSurface?.fit.fontSize, first.fontSize, "a grid as wide is drawn at the same font")
    }

    /// Herdr's new grid while the popup's renderer is being replaced for a new font, as when the keyboard
    /// comes up: the renderer takes the grid at the font it is being replaced to, so it draws at the size the
    /// screen's popup view gives it, and the replacement completes; the popup then fits its new grid.
    func testANewGridWhileAFontIsReplacedIsDrawnAtTheSizeOnScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        await session.bridge.serve(popupSurface(revision: 3, lines: Self.lines(columns: 22, rows: 16)))
        try await harness.waitUntil("the popup wasn't laid out") { model.layout?.popup != nil }
        adapter.preparePopupArea(size: CGSize(width: 390, height: 600), scale: 3)
        try await harness.waitUntil("the popup's renderer wasn't made") { model.popupSurface != nil }
        let host = GhosttyTerminalPopupHostView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        show(host)
        // As the screen's popup view does on each update.
        func sync() {
            guard let popup = adapter.terminalScreenPresentationProjection.viewport.popup else { return }
            host.update(popup: popup, surface: adapter.terminalManagedSurfaceLookup.managedSurface(for: popup.id), displayScale: 3)
            host.layoutIfNeeded()
        }
        try await harness.waitUntil("the popup didn't draw") { sync(); return model.popupPresentation == .ready }
        let renderer = try XCTUnwrap(model.popupSurface?.renderer)

        renderer.suppressReplacementPublicationForTesting = true
        adapter.preparePopupArea(size: CGSize(width: 390, height: 250), scale: 3)
        try await harness.waitUntil("the popup's font wasn't replaced for its smaller area") {
            sync()
            return renderer.isAwaitingReplacementFrameForTesting
        }
        await session.bridge.serve(popupSurface(revision: 4, lines: Self.lines(columns: 22, rows: 6)))
        try await harness.waitUntil("Herdr's new grid wasn't laid out") {
            sync()
            return model.layout?.popup?.rows == 6
        }
        renderer.suppressReplacementPublicationForTesting = false
        XCTAssertTrue(try XCTUnwrap(renderer.managedSurface).controlSurface.requestFrame())
        try await harness.waitUntil("the popup didn't draw at the size on screen", timeout: .seconds(10)) {
            sync()
            guard model.popupPresentation == .ready, model.popupSurface?.isReplacingFont == false,
                  let fit = model.popupSurface?.fit
            else { return false }
            return 22 * fit.cell.pixelWidth <= 1170 && 6 * fit.cell.pixelHeight <= 750
        }
        XCTAssertEqual(model.popupPresentation, .ready)
    }

    /// Under a popup the tab's tabs and panes are inert, as in Herdr's client: the screen's moves,
    /// creations, splits, zoom and closes don't go. Once the popup closes they do.
    func testTabsAndPanesAreInertUnderThePopup() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = adapter.terminalScreenPresentationProjection.viewport.panes[1].id
        await session.bridge.serve(popupSurface(revision: 3))
        try await harness.waitUntil("the popup wasn't laid out") { harness.model.layout?.popup != nil }

        XCTAssertFalse(adapter.focusPane(other).isHandled)
        XCTAssertFalse(adapter.createTopLevel(inGroup: nil).isHandled)
        XCTAssertFalse(adapter.createTopLevelGroup(from: nil).isHandled)
        XCTAssertFalse(adapter.splitFocusedPane(GHOSTTY_SPLIT_DIRECTION_RIGHT).isHandled)
        XCTAssertFalse(adapter.setFocusedPaneZoomed(true).isHandled)
        XCTAssertFalse(adapter.closePane(other).isHandled)

        await session.bridge.serve(HerdrServerScript.surface(projection: 1, revision: 4, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the popup didn't close") { harness.model.layout?.popup == nil }
        XCTAssertTrue(adapter.focusPane(other).isHandled)
        let focus = try await nextCommand(session.bridge, from: &index)
        guard case .paneFocus(_, let paneID) = focus else {
            return XCTFail("a command went while the popup was open: \(focus)")
        }
        XCTAssertEqual(paneID, "w1:p2")
    }

    // MARK: - Support

    private func makeHarness() async -> HerdrModelHarness {
        let harness = await HerdrModelHarness()
        harnesses.append(harness)
        return harness
    }

    /// A session shown with panes `w1:p1` and `w1:p2`, both drawn, `w1:p1` focused; returns its bridge and
    /// the index of the first write after the show.
    private func shownSession(_ harness: HerdrModelHarness) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(
                    revision: 1,
                    focusedPane: "w1:p1",
                    panes: ["w1:p1", "w1:p2"].map { HerdrServerScript.snapshotPane($0) }
                )
        )
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: Self.panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: Self.panes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        for pane in Self.panes {
            if let view = harness.model.paneSurface(pane.id)?.renderer.view {
                viewController.view.addSubview(view)
            }
        }
        window.isHidden = false
        windows.append(window)
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    private func show(_ view: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.isHidden = false
        windows.append(window)
    }

    private func popupSurface(revision: UInt64, title: String = "popup", lines: [String] = ["ab", "cd"]) -> [UInt8] {
        HerdrServerScript.surface(
            projection: 1,
            revision: revision,
            lines: ["one two"],
            panes: Self.panes,
            popup: Self.popupID,
            popupTitle: title,
            popupLines: lines
        )
    }

    private static func lines(columns: Int, rows: Int) -> [String] {
        (0..<rows).map { String(repeating: "x", count: columns - 1) + "\($0 % 10)" }
    }

    private func popupInput(_ events: [HerdrInputEvent]) -> [UInt8] {
        HerdrClientMessage.popupInput(terminalID: Self.popupID, events: events).frame
    }

    /// The next pane or popup input from `index` on, as framed; `index` moves past it.
    private func nextInput(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> [UInt8] {
        while true {
            let frame = try await bridge.written(index)
            index += 1
            var reader = HerdrWireReader(Array(frame.dropFirst(4)))
            let tag = try reader.variant()
            if tag == 13 || tag == 14 { return frame }
        }
    }

    private func nextPing(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> String {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if case .ping(let data) = write { return data }
        }
    }

    /// The next command from `index` on; pane input in between fails the test.
    private func nextCommand(_ bridge: FakeBridgeTransport, from index: inout Int) async throws -> ClientWrite {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            switch write {
            case .paneFocus, .paneZoom, .command: return write
            default: continue
            }
        }
    }

    /// A frame of pane `P` and, when given, a popup of terminal `id`, titled `title`, of `lines`.
    private static func engineSurface(
        revision: UInt64,
        popup: (id: String, title: String, lines: [String])?
    ) throws -> HerdrPaneSurfaceFrame {
        func frame(_ lines: [String]) -> String {
            let width = lines.first?.count ?? 0
            let cells = lines.joined().map {
                #"{"symbol":"\#($0)","fg":0,"bg":0,"modifier":0,"skip":false,"hyperlink":null}"#
            }
            return #"{"cells":[\#(cells.joined(separator: ","))],"width":\#(width),"height":\#(lines.count),"cursor":null,"hyperlinks":[],"graphics":[]}"#
        }
        let popupJSON = popup.map {
            #"{"terminal_id":"\#($0.id)","title":"\#($0.title)","width":null,"height":null,"frame":\#(frame($0.lines)),"mouse_reporting":false,"sgr_pixel_mouse":false,"pixel_width":0,"pixel_height":0}"#
        } ?? "null"
        let json = """
        {"boot_id":"boot","projection_revision":1,"surface_revision":\(revision),
         "frame":\(frame(["pane    "])),
         "panes":[\(HerdrTerminalEngineTests.pane("P", x: 0, width: 8, height: 1, focused: true))],"splits":[],
         "popup":\(popupJSON),"graphics":{"assets":[],"placements":[],"retained_assets":[]}}
        """
        return try JSONDecoder().decode(HerdrPaneSurfaceFrame.self, from: Data(json.utf8))
    }

    private func makeRenderer(
        engine: HerdrTerminalEngine,
        terminalID: String,
        terminal: HerdrRetainedTerminal,
        columns: Int,
        rows: Int
    ) async throws -> TerminalPaneRenderer {
        let runtime = try self.runtime ?? GhosttyKitRuntime(terminalSettings: .default)
        self.runtime = runtime
        let measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(size: CGSize(width: 390, height: 844), scale: 3))
        let metrics = try XCTUnwrap(measurement.displayMetrics(columns: UInt32(columns), rows: UInt32(rows)))
        let renderer = try await withCheckedThrowingContinuation { continuation in
            TerminalPaneRenderer.create(
                app: runtime.appHandleForTesting,
                terminal: terminal,
                fence: HerdrPaneRendererFence(engine: engine, target: .popup(terminalID), terminal: terminal),
                writeInput: nil,
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
                metrics: metrics,
                theme: .ghosttyDefault,
                diagnosticName: "test popup=\(terminalID)",
                onRendererFailure: {}
            ) { result in continuation.resume(with: result) }
        }
        renderers.append(renderer)
        return renderer
    }

    private func registrationError(
        engine: HerdrTerminalEngine,
        terminalID: String,
        terminal: HerdrRetainedTerminal
    ) async -> HerdrRendererRegistrationError? {
        do {
            let renderer = try await makeRenderer(engine: engine, terminalID: terminalID, terminal: terminal, columns: 1, rows: 1)
            renderers.removeAll { $0 === renderer }
            await withCheckedContinuation { continuation in renderer.close { continuation.resume() } }
            return nil
        } catch TerminalPaneRenderer.CreateError.registrationFailed(let error) {
            return error as? HerdrRendererRegistrationError
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }
}
