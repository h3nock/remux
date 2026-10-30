import Combine
import GhosttyKit
import UIKit
import XCTest
@testable import Remux

/// `HerdrScreenModel` over scripted bridges, with a real connection, engine and Ghostty renderers.
@MainActor
final class HerdrScreenModelTests: XCTestCase {
    private var harnesses: [HerdrModelHarness] = []
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for harness in harnesses {
            // A scripted server answers nothing more, so a stop's unzoom would wait out Herdr's time for it.
            for bridge in await harness.bridges.opened {
                await bridge.finishServing()
            }
            await harness.model.stop()
        }
        harnesses.removeAll()
    }

    private func makeHarness(
        settings: TerminalSettings = .default,
        timing: HerdrConnection.Timing = HerdrConnection.Timing(),
        recovery: HerdrScreenModel.RecoveryTiming = HerdrScreenModel.RecoveryTiming(),
        failingOpenWith error: Error? = nil,
        bridgeOpeningTakes: Duration = .zero,
        producerFailure: ProducerFailure? = nil,
        rendererFenceGate: RendererFenceGate? = nil,
        switchingCueDelay: Duration = HerdrScreenModel.switchingCueDelay,
        zoomKeepers: HerdrZoomKeepers = HerdrZoomKeepers(store: InMemoryHerdrOwnedZoomStore()),
        server: SavedServer = SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")
    ) async -> HerdrModelHarness {
        let harness = await HerdrModelHarness(
            settings: settings,
            timing: timing,
            recovery: recovery,
            failingOpenWith: error,
            bridgeOpeningTakes: bridgeOpeningTakes,
            producerFailure: producerFailure,
            rendererFenceGate: rendererFenceGate,
            switchingCueDelay: switchingCueDelay,
            zoomKeepers: zoomKeepers,
            server: server
        )
        harnesses.append(harness)
        return harness
    }

    // MARK: - Opening

    /// The bridge opens with the session; the hello waits for the screen's size and asks for the
    /// session hidden.
    func testTheBridgeOpensAtOnceAndTheHelloWaitsForTheScreensSize() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        try await Task.sleep(for: .milliseconds(100))
        let earlyWrites = await bridge.writtenCount
        XCTAssertEqual(earlyWrites, 0)

        harness.setScreenSize()
        let hello = try await harness.writes(bridge, count: 1)
        let measurement = try XCTUnwrap(harness.model.measurement)
        XCTAssertEqual(hello, [.hello(
            cols: Int(measurement.controlViewport.columns),
            rows: Int(measurement.controlViewport.rows),
            cellWidth: Int(measurement.cellMetrics.pixelWidth),
            cellHeight: Int(measurement.cellMetrics.pixelHeight),
            surfaceActive: false
        )])
        let opened = await harness.bridges.opened.count
        let closed = await bridge.isClosed
        XCTAssertEqual(opened, 1, "a size in time needs no second bridge")
        XCTAssertFalse(closed)
    }

    /// Herdr's server drops a connection that sends no hello within 4 s of the bridge reaching it, which
    /// can be well before a slow opening returns. A bridge still waiting for the screen's size is closed
    /// within 4 s of its opening's start, once, keeping its SSH connection for reuse, and a new one opens
    /// once the size arrives; the hello goes on it.
    func testABridgeWaitingTooLongForTheSizeIsClosedAndOpenedAgain() async throws {
        let beforeOpening = ContinuousClock.now
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(1500))
        let first = try await harness.bridge(0)
        let openingStarts = await harness.bridges.openingsStartedAt
        let openingStarted = try XCTUnwrap(openingStarts.first)

        try await harness.waitUntil("the waiting bridge wasn't closed", timeout: .seconds(5)) { await first.isClosed }
        let closedAt = ContinuousClock.now
        XCTAssertLessThan(closedAt - openingStarted, .seconds(4), "closed after Herdr's server would have given up")
        XCTAssertGreaterThanOrEqual(closedAt - beforeOpening, HerdrScreenModel.helloDeadline)
        let closes = await first.closes
        let firstWrites = await first.writtenCount
        XCTAssertEqual(closes, [.finished])
        XCTAssertEqual(firstWrites, 0)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")

        harness.setScreenSize()
        let second = try await harness.bridge(1)
        let hello = try await harness.writes(second, count: 1)
        guard case .hello(_, _, _, _, false) = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
    }

    /// The phone's theme goes out right after the hello, before any show, as Herdr's client reports its
    /// terminal: light or dark, then the Ghostty colours. It goes out again in full when the theme
    /// changes.
    func testTheThemeIsReportedBeforeTheFirstShowAndAgainWhenItChanges() async throws {
        let harness = await makeHarness(settings: TerminalSettings(fontSize: nil, theme: .remuxDark))
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)

        let writes = try await harness.writes(bridge, count: 8)
        XCTAssertEqual(writes[1], .theme(.appearance(.dark)))
        XCTAssertEqual(writes[2], .theme(.defaultColor(.foreground, HerdrRGB(red: 0xCD, green: 0xD6, blue: 0xF4))))
        XCTAssertEqual(writes[3], .theme(.defaultColor(.background, HerdrRGB(red: 0x1E, green: 0x1E, blue: 0x2E))))
        guard case .theme(.paletteColors(let palette)) = writes[4] else {
            return XCTFail("expected the palette, got \(writes[4])")
        }
        XCTAssertEqual(palette.count, 256)
        XCTAssertEqual(palette[1], HerdrRGB(red: 0xF3, green: 0x8B, blue: 0xA8))
        // Ghostty's own colour cube above the 16 the theme sets.
        XCTAssertEqual(palette[196], HerdrRGB(red: 0xFF, green: 0x00, blue: 0x00))
        XCTAssertTrue(writes[5...].contains { $0.isSurfaceSet }, "\(writes)")

        try harness.model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        let changed = try await harness.writes(bridge, from: 8, count: 4)
        XCTAssertEqual(changed[0], .theme(.appearance(.light)))
        XCTAssertEqual(changed[1], .theme(.defaultColor(.foreground, HerdrRGB(red: 0x4C, green: 0x4F, blue: 0x69))))
        XCTAssertEqual(changed[2], .theme(.defaultColor(.background, HerdrRGB(red: 0xEF, green: 0xF1, blue: 0xF5))))
        guard case .theme(.paletteColors) = changed[3] else { return XCTFail("expected the palette, got \(changed[3])") }
    }

    // MARK: - Showing

    /// Connected hidden, the session is shown once the root selects it and a snapshot is in, and hidden
    /// in the background: focus with the show, focus off before the hide.
    func testShowsOnceSelectedAndHidesInTheBackground() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome())
        harness.setScreenSize()
        harness.model.setSelected(true)
        _ = try await harness.writes(bridge, count: 5)
        try await Task.sleep(for: .milliseconds(100))
        let beforeSnapshot = await bridge.writtenCount
        XCTAssertEqual(beforeSnapshot, 5, "nothing is shown before a snapshot")

        await bridge.serve(HerdrServerScript.snapshot(revision: 1))
        let show = try await harness.writes(bridge, from: 5, count: 3)
        guard case .resize = show[0], case .surfaceSet(let showID, true) = show[1] else {
            return XCTFail("expected a show, got \(show)")
        }
        XCTAssertEqual(show[2], .focus(true))
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: showID, active: true))

        harness.model.handleAppLifecyclePhase(.inactive)
        try await Task.sleep(for: .milliseconds(100))
        let afterInactive = await bridge.writtenCount
        XCTAssertEqual(afterInactive, 8, "an inactive app stays shown")

        harness.model.handleAppLifecyclePhase(.background)
        let hide = try await harness.writes(bridge, from: 8, count: 2)
        XCTAssertEqual(hide[0], .focus(false))
        guard case .surfaceSet(_, false) = hide[1] else { return XCTFail("expected a hide, got \(hide)") }
    }

    /// Herdr takes the newest of a show and a hide: a hide goes out while the show is unanswered, and
    /// the show that follows it too.
    func testEachVisibilityChangeGoesOutAtOnceInOrder() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let first = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.setSelected(false)
        harness.model.setSelected(true)

        let second = try await harness.nextSurfaceSet(bridge, from: &index)
        let third = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertEqual([first.active, second.active, third.active], [true, false, true])
        for request in [first, second, third] {
            await bridge.serve(HerdrServerScript.surfaceSetReply(id: request.id, active: request.active))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Calls made together reach Herdr in the order they were made, each in full before the next: a
    /// resize, a theme change, a hide, a show, and the background's hide.
    func testABurstOfCallsReachesHerdrInTheOrderTheyWereMade() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        let model = harness.model
        model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        try model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        model.setSelected(false)
        model.setSelected(true)
        model.handleAppLifecyclePhase(.background)

        let measurement = try XCTUnwrap(model.measurement)
        let resize = ClientWrite.resize(
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows,
            cellWidth: measurement.cellMetrics.pixelWidth,
            cellHeight: measurement.cellMetrics.pixelHeight
        )
        let burst = try await harness.writes(bridge, from: index, count: 12)
        XCTAssertEqual(burst[0], resize)
        XCTAssertEqual(burst[1], .theme(.appearance(.light)))
        guard case .theme(.defaultColor(.foreground, _)) = burst[2],
              case .theme(.defaultColor(.background, _)) = burst[3],
              case .theme(.paletteColors) = burst[4],
              case .surfaceSet(_, false) = burst[6],
              case .surfaceSet(_, true) = burst[8],
              case .surfaceSet(_, false) = burst[11]
        else { return XCTFail("out of order: \(burst)") }
        XCTAssertEqual(burst[5], .focus(false))
        XCTAssertEqual(burst[7], resize)
        XCTAssertEqual(burst[9], .focus(true))
        XCTAssertEqual(burst[10], .focus(false))
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index + 12)
    }

    /// A show Herdr doesn't answer ends the connection, and the session reconnects by itself. The path
    /// may be dead, so its bridge closes as unresponsive, once, and the reconnect doesn't get the same SSH
    /// connection, which it would wait on.
    func testAShowHerdrDoesNotAnswerEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(200)
        let harness = await makeHarness(timing: timing)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)

        try await harness.waitUntil("the failed show didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.unresponsive])
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Shown again, the session keeps its last frame and reads as connected, but takes no input until
    /// the show completes: Herdr's answer alone doesn't, a frame Herdr sends after it does, as Herdr's
    /// client freezes input while a show is in progress.
    func testAShownAgainSessionTakesInputOnlyOnceTheShowCompletes() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        harness.model.setSelected(false)
        harness.model.setSelected(true)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertEqual([hide.active, show.active], [false, true])
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .ready, "the last frame left the screen")
        XCTAssertEqual(harness.states.last, .connected)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)

        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(harness.model.isInputAvailable, "Herdr's answer completed the show without a frame")

        await session.bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 3,
            lines: ["one two"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
                .init(id: "w1:p2", x: 4, width: 3, height: 1),
            ]
        ))
        try await harness.waitUntil("input wasn't offered once the show's frame came") {
            adapter.terminalInteractionProjection.isInputAvailable
        }
        XCTAssertEqual(harness.states.last, .connected)
    }

    /// A show Herdr answers without sending a frame in time ends the connection within the same time, and
    /// the session reconnects, as for a show Herdr doesn't answer.
    func testAShowWithoutAFrameInTimeEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(300)
        let harness = await makeHarness(timing: timing)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))

        try await harness.waitUntil("the show that didn't complete didn't end the connection") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    // MARK: - Panes

    /// Each pane with a text area gets a renderer showing its cells; the tab is the screen's one
    /// top-level, named by the snapshot.
    func testPanesAreRenderedAndTheTabIsTheTopLevel() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, tabLabel: "build"))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1  | right 1", "left 2  | right 2"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 8, height: 2, focused: true),
                .init(id: "w1:p2", x: 10, width: 7, height: 2),
            ]
        ))
        harness.setScreenSize()

        try await harness.waitUntil("renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["left 1", "left 2"], "w1:p2": ["right 1", "right 2"]])

        let adapter = harness.model.terminalScreenAdapter
        let projection = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection(group: nil).windows.map(\.displayName), ["build"])
        XCTAssertEqual(projection.viewport.windowGrid, GhosttyTerminalGridSize(columns: 17, rows: 2))
        XCTAssertEqual(projection.viewport.panes.map(\.normalFrame), [
            GhosttyTerminalGridRect(x: 0, y: 0, columns: 8, rows: 2),
            GhosttyTerminalGridRect(x: 10, y: 0, columns: 7, rows: 2),
        ])
        let focused = try XCTUnwrap(projection.viewport.panes.first(where: \.isFocused))
        XCTAssertEqual(projection.viewport.focusedSurfaceID, focused.id)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: focused.id))
        XCTAssertTrue(managed.view === harness.model.paneSurface("w1:p1")?.renderer.view)
        XCTAssertEqual(adapter.topLevelNoun, .tab)
    }

    /// The screen draws Herdr's pane borders where Herdr's frame has them, in the colours Herdr gave them
    /// as the phone's terminal shows them: here a named colour from the phone's palette. The ends of a
    /// box's sides meet in its corners.
    func testTheScreenDrawsHerdrsBordersInHerdrsColours() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["┌──┐┌──┐", "│ab││cd│", "└──┘└──┘"],
            panes: [
                .init(id: "w1:p1", x: 1, y: 1, width: 2, height: 1, focused: true, rect: (0, 0, 4, 3)),
                .init(id: "w1:p2", x: 5, y: 1, width: 2, height: 1, rect: (4, 0, 4, 3)),
            ],
            // ratatui's named Blue.
            foreground: Dictionary(uniqueKeysWithValues: "┌┐└┘─│".map { ($0, UInt32(5)) })
        ))
        harness.setScreenSize()
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the borders weren't laid out") {
            !adapter.terminalScreenPresentationProjection.viewport.paneLines.isEmpty
        }

        let blue = try XCTUnwrap(harness.model.terminalColors?.palette[4])
        func line(_ orientation: GhosttyPaneLine.Orientation, _ position: CGFloat, _ start: CGFloat, _ end: CGFloat)
            -> GhosttyPaneLine
        {
            GhosttyPaneLine(
                orientation: orientation, position: position, start: start, end: end,
                ink: .color(red: blue.red, green: blue.green, blue: blue.blue), width: 1, cap: .square
            )
        }
        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertEqual(viewport.paneLines, [
            line(.horizontal, 0.5, 0.5, 3.5), line(.horizontal, 0.5, 4.5, 7.5),
            line(.horizontal, 2.5, 0.5, 3.5), line(.horizontal, 2.5, 4.5, 7.5),
            line(.vertical, 0.5, 0.5, 2.5), line(.vertical, 3.5, 0.5, 2.5),
            line(.vertical, 4.5, 0.5, 2.5), line(.vertical, 7.5, 0.5, 2.5),
        ])
        XCTAssertEqual(viewport.panes.map(\.normalFrame), [
            GhosttyTerminalGridRect(x: 1, y: 1, columns: 2, rows: 1),
            GhosttyTerminalGridRect(x: 5, y: 1, columns: 2, rows: 1),
        ])
    }

    /// With Herdr's borders and gaps off, panes touch, and the pane picker's map still has a tile for
    /// each.
    func testThePanePickerMapsTouchingPanes() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["leftright", "left down"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 4, height: 2, focused: true),
                .init(id: "w1:p2", x: 4, width: 5, height: 1),
                .init(id: "w1:p3", x: 4, y: 1, width: 5, height: 1),
            ]
        ))
        harness.setScreenSize()
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the panes weren't laid out") {
            adapter.terminalScreenPresentationProjection.viewport.panes.count == 3
        }

        let tab = try XCTUnwrap(adapter.selectedPaneSheetPresentationProjection()).topLevelID
        let picker = adapter.paneSelectionSheetRenderProjection(topLevelID: tab)
        let map = try XCTUnwrap(PaneTopologyLayout.frames(
            panes: try picker.panes.map { PaneTopologyLayout.Pane(id: $0.id, frame: try XCTUnwrap($0.frame)) },
            size: CGSize(width: 300, height: 200)
        ))
        XCTAssertEqual(picker.panes.map { map.frame(for: $0.id) }, [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 100, y: 0, width: 200, height: 100),
            CGRect(x: 100, y: 100, width: 200, height: 100),
        ])
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.paneLines, [])
    }

    /// The pane sheet shows, as for a tmux pane, the folder of the pane's foreground program, and names
    /// each pane as Herdr's pane navigator does within a tab: its manual label or agent's name, else
    /// its title, else its agent's kind, else "terminal", numbered by its place among the tab's panes
    /// in the snapshot when the tab has more than one.
    func testPanesAreNamedAsHerdrsPaneNavigatorListsThem() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let snapshot = HerdrServerScript.snapshot(
            revision: 1,
            panes: [
                HerdrServerScript.snapshotPane("w1:p1", label: "editor", cwd: "/repo", foregroundCWD: "/repo/src"),
                HerdrServerScript.snapshotPane("w1:p2", cwd: "/home"),
                HerdrServerScript.snapshotPane("w1:q1", tab: "t2"),
                HerdrServerScript.snapshotPane("w1:p3", cwd: "/srv", foregroundCWD: "/srv/app"),
                HerdrServerScript.snapshotPane("w1:p4"),
                HerdrServerScript.snapshotPane("w1:p5"),
                HerdrServerScript.snapshotPane("w1:p6"),
            ],
            agents: [
                HerdrServerScript.snapshotAgent("w1:p1", name: "fixer", title: "Fixing tests", agent: "claude"),
                HerdrServerScript.snapshotAgent("w1:p2", name: "reviewer", title: "Reviewing", agent: "codex"),
                HerdrServerScript.snapshotAgent(
                    "w1:p3", title: "Fixing tests", terminalTitleStripped: "claude", displayAgent: "Claude Code"
                ),
                HerdrServerScript.snapshotAgent("w1:p4", terminalTitleStripped: "vim notes.md"),
                HerdrServerScript.snapshotAgent("w1:p5", agent: "codex", displayAgent: "Codex"),
            ]
        )
        await bridge.serve(try HerdrServerScript.welcome() + snapshot)
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["a b c d e f"],
            panes: (0..<6).map { .init(id: "w1:p\($0 + 1)", x: UInt16($0 * 2), width: 1, height: 1, focused: $0 == 0) }
        ))
        harness.setScreenSize()

        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the panes weren't laid out") {
            adapter.terminalScreenPresentationProjection.viewport.panes.count == 6
        }
        var panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.map(\.currentCommand), [
            "editor · 1", "reviewer · 2", "Fixing tests · 3", "vim notes.md · 4", "codex · 5", "terminal · 6",
        ])
        XCTAssertEqual(panes.map(\.currentPath), ["/repo/src", "/home", "/srv/app", "", "", ""])

        // A tab's only pane has no number.
        await bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            panes: [HerdrServerScript.snapshotPane("w1:p6"), HerdrServerScript.snapshotPane("w1:q1", tab: "t2")]
        ))
        await bridge.serve(HerdrServerScript.surface(
            projection: 2,
            revision: 2,
            lines: ["a"],
            panes: [.init(id: "w1:p6", x: 0, width: 1, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the tab's only pane wasn't laid out") {
            adapter.terminalScreenPresentationProjection.viewport.panes.count == 1
        }
        panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.map(\.currentCommand), ["terminal"])
    }

    /// A frame left behind by a lost connection shows no live cursor: the focused pane is unfocused
    /// while the session reconnects, as Herdr's client hides its cursor while its session is offline,
    /// and focused again once the new connection is open.
    func testThePaneIsUnfocusedWhileTheConnectionIsDown() async throws {
        let harness = await makeHarness()
        let first = try await harness.bridge(0)
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        let frame = HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        )
        await first.serve(frame)
        harness.setScreenSize()
        harness.model.setSelected(true)
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID != nil
        }
        let surfaceID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("the pane wasn't focused while connected") { managed.isFocused }

        await first.finishServing()
        try await harness.waitUntil("the lost connection didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        XCTAssertFalse(managed.isFocused)

        let second = try await harness.bridge(1)
        XCTAssertFalse(managed.isFocused, "nothing is live before the new connection opens")
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1) + frame)
        try await harness.waitUntil("the pane wasn't focused again") { managed.isFocused }
    }

    /// A size that only arrives after the hello deadline is too late, even while the bridge's opening is
    /// still under way: Herdr may already have dropped the bridge. It is closed, keeping its SSH
    /// connection, and another opens; the hello goes on that one.
    func testASizeArrivingAfterTheDeadlineDuringASlowOpeningOpensAnotherBridge() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .seconds(4))
        try await harness.waitUntil("the opening didn't start") {
            await harness.bridges.openingsStartedAt.count == 1
        }
        let openingStarts = await harness.bridges.openingsStartedAt
        let openingStarted = try XCTUnwrap(openingStarts.first)
        try await Task.sleep(until: openingStarted + .milliseconds(3400), clock: .continuous)
        harness.setScreenSize()

        let first = try await harness.bridge(0)
        let second = try await harness.bridge(1, timeout: .seconds(6))
        let hello = try await harness.writes(second, count: 1)
        guard case .hello = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
        let firstWrites = await first.writtenCount
        let closes = await first.closes
        XCTAssertEqual(firstWrites, 0)
        XCTAssertEqual(closes, [.finished])
    }

    /// A size known before the bridge's opening started is in time however long the opening takes: the
    /// hello goes as soon as the bridge is open, and no other bridge opens.
    func testASizeKnownBeforeASlowOpeningIsInTime() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(3500))
        harness.setScreenSize()
        let first = try await harness.bridge(0, timeout: .seconds(6))
        _ = try await harness.writes(first, count: 1)

        harness.model.reconnect()
        let second = try await harness.bridge(1, timeout: .seconds(6))
        let hello = try await harness.writes(second, count: 1)
        guard case .hello = hello[0] else { return XCTFail("expected the hello, got \(hello)") }
        try await Task.sleep(for: .seconds(1))
        let opened = await harness.bridges.opened.count
        let closed = await second.isClosed
        XCTAssertEqual(opened, 2)
        XCTAssertFalse(closed)
    }

    /// Only the selected session's panes are presented and focused: deselecting hides them from Ghostty
    /// and takes their focus, and selecting the session again brings both back.
    func testOnlyTheSelectedSessionsPanesArePresentedAndFocused() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        harness.model.setSelected(true)
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID != nil
        }
        let surfaceID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let managed = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: surfaceID))
        try await harness.waitUntil("the selected pane wasn't presented and focused") {
            managed.isVisible && managed.isFocused
        }

        harness.model.setSelected(false)
        XCTAssertFalse(managed.isVisible)
        XCTAssertFalse(managed.isFocused)

        harness.model.setSelected(true)
        XCTAssertTrue(managed.isVisible)
        XCTAssertTrue(managed.isFocused)
    }

    /// Ghostty requires its app to outlive every surface, so a stop releases the runtime only once every
    /// renderer is freed: one closed because its pane left the layout, one whose creation lands after the
    /// stop began, and the one the stop closes itself.
    func testStopReleasesGhosttyOnlyOnceEveryRendererIsFreed() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        let first = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one two"],
            panes: [first, .init(id: "w1:p2", x: 4, width: 3, height: 1)]
        ))
        harness.setScreenSize()
        let model = harness.model
        try await harness.waitUntil("the panes' renderers weren't created") {
            model.paneSurface("w1:p1") != nil && model.paneSurface("w1:p2") != nil
        }

        gate.holdsCloses = true
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 2,
            lines: ["one two"],
            panes: [first]
        ))
        try await harness.waitUntil("the pane that left wasn't closed") {
            model.paneSurface("w1:p2") == nil && gate.heldCloseCount == 1
        }
        gate.holdsRegistrations = true
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 3,
            lines: ["one six"],
            panes: [first, .init(id: "w1:p3", x: 4, width: 3, height: 1)]
        ))
        try await harness.waitUntil("the new pane's renderer wasn't being registered") {
            gate.heldRegistrationCount == 1
        }

        let stopped = Task { @MainActor in
            await model.stop()
            gate.record("stopped")
        }
        try await Task.sleep(for: .milliseconds(200))
        gate.releaseRegistrations()
        try await harness.waitUntil("the late renderer wasn't closed") { gate.heldCloseCount == 3 }
        // The stop's own close completes; the pane that left and the late renderer are still closing.
        gate.releaseCloses(of: "w1:p1")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(gate.log.contains("stopped"), "the stop returned with renderers still closing: \(gate.log)")
        gate.releaseCloses()
        await stopped.value
        XCTAssertEqual(gate.log.last, "stopped")
        XCTAssertEqual(Set(gate.log.dropLast()), ["closed w1:p1", "closed w1:p2", "closed w1:p3"])
    }

    /// A session ready on screen offers the keyboard: both of the screen's projections say input is
    /// available.
    func testAReadySessionOffersInput() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one"], panes: panes))
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }
        showInWindow(harness, panes: ["w1:p1"])

        try await harness.waitUntil("the session wasn't ready") { harness.states.last == .connected }
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        let adapter = harness.model.terminalScreenAdapter
        // The screen reads input availability from both projections.
        for interaction in [adapter.terminalInteractionProjection, adapter.terminalScreenPresentationProjection.interaction] {
            XCTAssertTrue(interaction.hasFocusedSurface)
            XCTAssertTrue(interaction.isInputAvailable)
        }
    }

    /// A pane's screen surface is made when its renderer is admitted, so the screen's lookups only read:
    /// it looks a surface up from inside that surface's own callbacks, such as a selection's.
    func testAPanesSurfaceIsMadeWhenItsRendererIsAdmittedSoLookupsOnlyRead() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1"],
            panes: [.init(id: "w1:p1", x: 0, width: 6, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }

        let adapter = harness.model.terminalScreenAdapter
        let managed = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer.managedSurface)
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        XCTAssertEqual(managed.id, id)
        let lookup = adapter.terminalManagedSurfaceLookup
        var callbacks = 0
        managed.onLocalSelectionGeometryChange = {
            callbacks += 1
            // Bounded, so a lookup that notifies fails here instead of overflowing the stack.
            if callbacks <= 3 { _ = lookup.managedSurface(for: id) }
        }
        managed.onScrollStateChange = { callbacks += 1 }

        XCTAssertTrue(lookup.managedSurface(for: id) === managed)
        XCTAssertEqual(callbacks, 0)
    }

    /// A session the root doesn't show draws nothing, so it reads as connected once its focused pane is
    /// live, without input. Showing it draws the pane and offers input.
    func testASessionThatIsNotShownIsConnectedBeforeItsPaneDraws() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }
        showInWindow(harness, panes: ["w1:p1"])

        try await harness.waitUntil("the hidden session wasn't connected") { harness.states.last == .connected }
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .awaitingFrame)
        let adapter = harness.model.terminalScreenAdapter
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)

        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 2,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the shown pane didn't draw") {
            harness.model.presentation(ofPane: "w1:p1") == .ready
        }
        XCTAssertEqual(harness.states.last, .connected)
        try await harness.waitUntil("input wasn't offered once the show completed") {
            adapter.terminalInteractionProjection.isInputAvailable
        }
    }

    /// While shown, a new screen size goes to Herdr at once; a hidden session gets it with its show.
    func testAResizeIsSentWhileShown() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        harness.model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        let measurement = try XCTUnwrap(harness.model.measurement)
        let resize = try await harness.writes(bridge, from: index, count: 1)
        XCTAssertEqual(resize, [.resize(
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows,
            cellWidth: measurement.cellMetrics.pixelWidth,
            cellHeight: measurement.cellMetrics.pixelHeight
        )])
    }

    /// A new size goes to Herdr while its show is still unanswered, as Herdr's client sends every resize to
    /// the session it shows, which the show made this one.
    func testAResizeGoesBeforeTheShowIsAnswered() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        let model = harness.model
        model.setSelected(true)
        var index = 0
        _ = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1

        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        let resized = try XCTUnwrap(model.measurement)
        let sent = try await harness.writes(bridge, from: index, count: 1)
        XCTAssertEqual(sent[0], .resize(
            cols: resized.controlViewport.columns,
            rows: resized.controlViewport.rows,
            cellWidth: resized.cellMetrics.pixelWidth,
            cellHeight: resized.cellMetrics.pixelHeight
        ))
    }

    /// Only the newest size goes out: sizes changing faster than the queue sends them replace the one
    /// waiting, while other calls keep their order.
    func testOnlyTheNewestOfSeveralQueuedSizesIsSent() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.setScreenSize()
        let model = harness.model
        model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        index += 1

        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 500), scale: 3)
        try model.applyTerminalSettings(TerminalSettings(fontSize: nil, theme: .remuxLight))
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 600), scale: 3)
        model.terminalScreenAdapter.prepareInitialViewport(size: CGSize(width: 390, height: 700), scale: 3)
        let newest = try XCTUnwrap(model.measurement)

        let sent = try await harness.writes(bridge, from: index, count: 5)
        XCTAssertEqual(sent[0], .theme(.appearance(.light)))
        XCTAssertEqual(sent[4], .resize(
            cols: newest.controlViewport.columns,
            rows: newest.controlViewport.rows,
            cellWidth: newest.cellMetrics.pixelWidth,
            cellHeight: newest.cellMetrics.pixelHeight
        ))
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index + 5, "the older sizes went out too")
    }

    // MARK: - Failures

    /// A grid Remux can't index ends the connection Remux-side; the model closes it, and a session that
    /// hasn't connected yet says why instead of reconnecting.
    func testAnUnindexableSurfaceClosesTheConnectionAndIsReported() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let bridge = try await harness.bridge()
        // Herdr's surfaces are checked before the snapshot they're drawn against.
        await bridge.serve(try HerdrServerScript.welcome())
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["abcd"],
            panes: [.init(id: "w1:p1", x: 2, width: 5, height: 1)]
        ))
        harness.setScreenSize()

        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(reason.kind, .runtime)
        XCTAssertEqual(reason.message, HerdrWireError.invalidSurfaceUpdate("surface pane lies outside the frame").errorDescription)
        XCTAssertEqual(harness.stateLog.updates.last?.source, .runtime)
        try await harness.waitUntil("the connection wasn't closed") { await bridge.isClosed }
        try await Task.sleep(for: .milliseconds(300))
        let opened = await harness.bridges.opened.count
        XCTAssertEqual(opened, 1, "a session that never connected reconnected")
    }

    /// A connection that ends before its first snapshot is reported once, with its reason, also when it
    /// ends while `open` is still returning; the session doesn't reconnect by itself.
    func testAConnectionThatEndsIsReported() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome())
        await bridge.finishServing()
        harness.setScreenSize()

        try await harness.waitUntil("the end wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(HerdrConnectionError.closed.terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")))
        )
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.states.filter { $0.disconnectedReason != nil }.count, 1)
        let opened = await harness.bridges.opened.count
        XCTAssertEqual(opened, 1, "a session that never connected reconnected")
    }

    func testABridgeThatCannotStartIsReported() async throws {
        let harness = await makeHarness(failingOpenWith: HerdrBridgeError.program(.notFound))
        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        XCTAssertEqual(
            harness.states.last,
            .disconnected(TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
            ))
        )
    }

    /// The live bridge opens, then its first read reports Herdr missing: the session shows Herdr Unavailable,
    /// which doesn't reconnect on its own, not a lost connection.
    func testABridgeThatReportsHerdrMissingOnItsFirstReadIsHerdrUnavailable() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        harness.setScreenSize()
        await bridge.finishServing(throwing: HerdrBridgeError.program(.notFound))
        try await harness.waitUntil("the failure wasn't reported") {
            harness.states.last?.disconnectedReason != nil
        }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(reason, TerminalDisconnectReason(
            kind: .backendUnavailable(.herdr),
            message: "Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."
        ))
        XCTAssertFalse(reason.allowsAutomaticReconnect)
    }

    // MARK: - Stop and reconnect

    /// Stopped before the screen has a size: the bridge closes, no hello goes out, and nothing more is
    /// reported.
    func testStopBeforeTheScreenHasASizeClosesTheBridge() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        let reportsBeforeStop = harness.states.count
        await harness.model.stop()
        // The opening may still be returning the bridge when the stop comes; the stop waits for it.
        let closes = await bridge.closes
        let written = await bridge.writtenCount
        XCTAssertEqual(closes, [.finished])
        XCTAssertEqual(written, 0)
        harness.setScreenSize()
        XCTAssertEqual(harness.states.count, reportsBeforeStop)
    }

    /// Stopped while renderers are still being created: they're drained, every renderer is closed,
    /// and nothing is reported after the stop.
    func testStopWithRendererCreationsInFlight() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["abcd efgh"],
            panes: [.init(id: "w1:p1", x: 0, width: 4, height: 1), .init(id: "w1:p2", x: 5, width: 4, height: 1)]
        ))
        // Renderers are created as the panes are laid out and admitted later, through the engine: the
        // screen sees the panes before their renderers. Stop right then.
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        var stopping: Task<Void, Never>?
        let watch = adapter.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard stopping == nil else { return }
                let panes = adapter.terminalScreenPresentationProjection.viewport.panes
                guard panes.count == 2,
                      panes.allSatisfy({ adapter.terminalManagedSurfaceLookup.managedSurface(for: $0.id) == nil })
                else { return }
                stopping = Task { await model.stop() }
            }
        }
        defer { watch.cancel() }
        harness.setScreenSize()
        try await harness.waitUntil("the panes weren't laid out") { stopping != nil }
        let reportsBeforeStop = harness.states.count
        await stopping?.value

        XCTAssertNil(harness.model.paneSurface("w1:p1"))
        XCTAssertNil(harness.model.paneSurface("w1:p2"))
        let closed = await bridge.isClosed
        XCTAssertTrue(closed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.states.count, reportsBeforeStop)
    }

    /// Pane failures say to reconnect, and a reconnect brings both kinds back: a pane Ghostty couldn't
    /// paint gets a new terminal and renderer from the new connection, and a failed renderer is
    /// replaced over its terminal.
    func testAReconnectPaintsAFailedPaneAgainAndReplacesAFailedRenderer() async throws {
        let producerFailure = ProducerFailure()
        let harness = await makeHarness(producerFailure: producerFailure)
        let model = harness.model
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p2", x: 4, width: 3, height: 1),
        ]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: panes))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"], "w1:p2": ["two"]]
        }
        let failedTerminal = try XCTUnwrap(model.paneSurface("w1:p1")?.terminal)
        let failedRenderer = try XCTUnwrap(model.paneSurface("w1:p2")?.renderer)

        // Ghostty can't apply the first pane's next paint; the second pane's renderer fails.
        producerFailure.isOn = true
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 2, lines: ["uno two"], panes: panes))
        try await harness.waitUntil("the first pane's paint didn't fail") {
            model.presentation(ofPane: "w1:p1") != .pending
        }
        producerFailure.isOn = false
        failedRenderer.reportRendererFailure()
        try await harness.waitUntil("the failures weren't shown") {
            model.presentation(ofPane: "w1:p1") != .pending && model.presentation(ofPane: "w1:p2") != .pending
        }
        guard case .failed = model.presentation(ofPane: "w1:p1"), case .failed = model.presentation(ofPane: "w1:p2") else {
            return XCTFail("expected both panes to fail")
        }

        model.reconnect()
        try await harness.waitUntil("the failed renderer wasn't replaced") {
            model.paneSurface("w1:p2").map { $0.renderer !== failedRenderer } == true
        }
        XCTAssertEqual(harness.shownRows()["w1:p2"], ["two"])
        XCTAssertEqual(model.presentation(ofPane: "w1:p2"), .pending)

        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await second.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["ONE TWO"], panes: panes))
        try await harness.waitUntil("the panes weren't painted again") {
            harness.shownRows() == ["w1:p1": ["ONE"], "w1:p2": ["TWO"]]
        }
        XCTAssertFalse(model.paneSurface("w1:p1")?.terminal === failedTerminal)
        XCTAssertEqual(model.presentation(ofPane: "w1:p1"), .pending)
    }

    // MARK: - Reconnecting by itself

    /// A session that has connected reconnects by itself when its connection drops, shown or hidden, as
    /// Herdr's client retries every endpoint: it reads as reconnecting with its last frame, each failure
    /// in a row doubles the delay up to the longest, and the next connection brings it back.
    func testADroppedConnectionReconnectsByItselfWithGrowingDelays() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(200)
        recovery.longestRetry = .milliseconds(400)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        var droppedAt = ContinuousClock.now
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["one"]])
        var delays: [Duration] = []
        for index in 1...3 {
            let bridge = try await harness.bridge(index)
            let starts = await harness.bridges.openingsStartedAt
            delays.append(starts[index] - droppedAt)
            droppedAt = ContinuousClock.now
            await bridge.finishServing()
        }
        XCTAssertGreaterThanOrEqual(delays[0], .milliseconds(200))
        XCTAssertGreaterThanOrEqual(delays[1], .milliseconds(400))
        XCTAssertGreaterThanOrEqual(delays[2], .milliseconds(400))
        XCTAssertLessThan(delays[2], .milliseconds(800), "the delay grew past the longest")

        let last = try await harness.bridge(4)
        await last.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await last.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["two"], panes: Self.onePane))
        try await harness.waitUntil("the session didn't come back") {
            harness.shownRows() == ["w1:p1": ["two"]] && harness.model.stateTraceLabel == "hidden"
        }
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// Delays start over once a connection has stayed up a while, as in Herdr's client: a drop after
    /// that waits the first delay again, not the one the earlier failures had reached.
    func testDelaysStartOverOnceAConnectionStaysUp() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(300)
        recovery.stable = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        let second = try await harness.bridge(1)
        await second.finishServing()

        let third = try await harness.bridge(2)
        await third.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
        try await Task.sleep(for: .milliseconds(600))
        let droppedAt = ContinuousClock.now
        await third.finishServing()

        _ = try await harness.bridge(3)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertGreaterThanOrEqual(starts[3] - droppedAt, .milliseconds(300))
        XCTAssertLessThan(starts[3] - droppedAt, .milliseconds(1000), "the delays didn't start over")
    }

    /// Herdr's bridge exits by itself after a minute with nothing to carry, as it does while the app is
    /// in the background, with status 1 and nothing after the ready marker. Once the connection is open
    /// that is a drop: the session reconnects by itself, as Herdr's client does.
    func testABridgeThatExitsAfterTheConnectionOpenedReconnects() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        await first.finishServing(throwing: HerdrBridgeError.program(.failed("")))
        try await harness.waitUntil("the bridge's exit didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        _ = try await harness.bridge(1)
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    /// A server whose snapshot Remux can't read needs attention: the session says why, keeps saying it
    /// while the server is checked again every so often, and is back once a connection works.
    func testAServerThatNeedsAttentionSaysWhyAndIsCheckedAgain() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.recheck = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])

        await first.serve(Self.unreadableSnapshot())
        try await harness.waitUntil("the reason wasn't shown") { harness.states.last?.disconnectedReason != nil }
        let reason = try XCTUnwrap(harness.states.last?.disconnectedReason)
        XCTAssertEqual(
            reason,
            HerdrConnectionError.wire(.invalidControl(kind: HerdrControlKind.snapshot)).terminalDisconnectReason(on: SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder"))
        )

        let second = try await harness.bridge(1)
        XCTAssertEqual(harness.states.last?.disconnectedReason, reason, "the reason went away before the server was back")
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") {
            harness.model.stateTraceLabel == "hidden" && harness.states.last?.disconnectedReason == nil
        }
    }

    /// In the background a waiting reconnect stops, keeping its time; back in the foreground, one that
    /// came due meanwhile runs at once.
    func testTheBackgroundHoldsAReconnectAndTheForegroundRunsItAtOnce() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(500)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(800))
        let openedInTheBackground = await harness.bridges.opened.count
        XCTAssertEqual(openedInTheBackground, 1)

        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        _ = try await harness.bridge(1)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[1] - foregroundAt, .milliseconds(400), "the due reconnect waited")
    }

    /// Back in the foreground a waiting reconnect runs at once even before it is due, as Herdr's client
    /// does after a resume.
    func testTheForegroundRunsAWaitingReconnectBeforeItIsDue() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .seconds(30)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(100))
        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        _ = try await harness.bridge(1)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[1] - foregroundAt, .milliseconds(400), "the reconnect waited for its delay")
    }

    /// Time in the background doesn't count as a connection staying up, as in Herdr's client: a drop
    /// soon after coming back keeps the delay the failures before had reached.
    func testTimeInTheBackgroundDoesNotCountAsStayingUp() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(200)
        recovery.stable = .milliseconds(300)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        let second = try await harness.bridge(1)
        await second.finishServing()

        let third = try await harness.bridge(2)
        await third.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(600))
        harness.model.handleAppLifecyclePhase(.active)
        let droppedAt = ContinuousClock.now
        await third.finishServing()

        _ = try await harness.bridge(3)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertGreaterThanOrEqual(starts[3] - droppedAt, .milliseconds(700), "the background counted as staying up")
    }

    /// Going to the background gives up a reconnect still opening, as Herdr's client does; the
    /// foreground opens it again at once.
    func testTheBackgroundGivesUpAReconnectStillOpening() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery, bridgeOpeningTakes: .milliseconds(500))
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the reconnect didn't start opening") {
            await harness.bridges.openingsStartedAt.count == 2
        }

        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(800))
        let openedInTheBackground = await harness.bridges.opened.count
        let openingsInTheBackground = await harness.bridges.openingsStartedAt.count
        XCTAssertEqual(openedInTheBackground, 1, "the opening wasn't given up")
        XCTAssertEqual(openingsInTheBackground, 2)

        let foregroundAt = ContinuousClock.now
        harness.model.handleAppLifecyclePhase(.active)
        try await harness.waitUntil("the foreground didn't open it again") {
            await harness.bridges.openingsStartedAt.count == 3
        }
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[2] - foregroundAt, .milliseconds(400), "the reconnect waited")
        XCTAssertFalse(harness.states.contains { $0.disconnectedReason != nil }, "\(harness.states)")
    }

    // MARK: - Ownership handoffs

    /// Going to the background while a connection waits for Herdr's welcome gives it up: its bridge closes
    /// once, as an opening given up, so its SSH connection isn't offered to the next one.
    func testTheBackgroundGivesUpAnOpeningWithoutReusingItsConnection() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge(0)
        _ = try await harness.writes(bridge, count: 1)

        harness.model.handleAppLifecyclePhase(.background)
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A connection whose welcome came as the app goes to the background, before the model has taken it,
    /// is given up the same way, once.
    func testTheBackgroundGivesUpAConnectionOpenedMeanwhileWithoutReusingIt() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge(0)
        _ = try await harness.writes(bridge, count: 1)

        // Once the connection reads past the welcome its opening has returned, and the model resumes only
        // after the background is handled.
        await bridge.serve(try HerdrServerScript.welcome())
        XCTAssertTrue(Self.holdMainActor { await bridge.reads >= 2 })
        harness.model.handleAppLifecyclePhase(.background)

        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A bridge whose opening returns after the background gave its attempt up is closed once, as an
    /// opening given up.
    func testABridgeOpenedAfterTheBackgroundGaveItsAttemptUpIsNotReused() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(200))
        harness.setScreenSize()
        let bridges = harness.bridges
        try await harness.waitUntil("the opening didn't start") { await bridges.openingsStartedAt.count == 1 }

        XCTAssertTrue(Self.holdMainActor { await bridges.opened.count == 1 })
        harness.model.handleAppLifecyclePhase(.background)

        let bridge = try await harness.bridge(0)
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A bridge whose opening returns after a reconnect replaced its attempt keeps its SSH connection for
    /// the next opening, as that attempt's own bridge would.
    func testABridgeOpenedAfterAReconnectReplacedItsAttemptIsReused() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(200))
        harness.setScreenSize()
        let bridges = harness.bridges
        try await harness.waitUntil("the opening didn't start") { await bridges.openingsStartedAt.count == 1 }

        XCTAssertTrue(Self.holdMainActor { await bridges.opened.count == 1 })
        XCTAssertTrue(harness.model.reconnect())

        let bridge = try await harness.bridge(0)
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.finished])
    }

    /// A reconnect while the bridge is still opening cancels that opening, which makes no bridge.
    func testAReconnectWhileTheBridgeOpensCancelsThatOpening() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(300))
        harness.setScreenSize()
        let bridges = harness.bridges
        try await harness.waitUntil("the opening didn't start") { await bridges.openingsStartedAt.count == 1 }

        XCTAssertTrue(harness.model.reconnect())
        let bridge = try await harness.bridge(0)
        try await Task.sleep(for: .milliseconds(400))
        let opened = await bridges.opened.count
        let closed = await bridge.isClosed
        XCTAssertEqual(opened, 1, "the cancelled opening made a bridge")
        XCTAssertFalse(closed)
    }

    /// A reconnect the user asks for while the bridge waits for Herdr's welcome closes that bridge once,
    /// as an opening given up.
    func testAReconnectDuringTheWelcomeClosesTheBridgeOnceAsGivenUp() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge(0)
        _ = try await harness.writes(bridge, count: 1)

        XCTAssertTrue(harness.model.reconnect())
        _ = try await harness.bridge(1)
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// The welcome came and the opening returned, but the model hasn't taken the connection yet when a
    /// reconnect gives the attempt up: its bridge closes once, as an opening given up.
    func testAReconnectAfterTheWelcomeBeforeTheModelTakesTheConnectionClosesItOnce() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge(0)
        _ = try await harness.writes(bridge, count: 1)
        await bridge.serve(try HerdrServerScript.welcome())
        XCTAssertTrue(Self.holdMainActor { await bridge.reads >= 2 })

        XCTAssertTrue(harness.model.reconnect())
        _ = try await harness.bridge(1)
        let closes = try await allCloses(of: bridge, harness)
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A stop while the bridge waits for Herdr's welcome closes it once, as an opening given up, before the
    /// stop returns.
    func testAStopDuringTheWelcomeClosesTheBridgeOnceBeforeReturning() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge(0)
        _ = try await harness.writes(bridge, count: 1)

        await harness.model.stop()
        let closedByStop = await bridge.closes
        XCTAssertEqual(closedByStop, [.givenUpWhileOpening])
        try await Task.sleep(for: .milliseconds(200))
        let closes = await bridge.closes
        XCTAssertEqual(closes, [.givenUpWhileOpening])
    }

    /// A stop while the bridge opens waits for the opening: a bridge it still returns is closed once before
    /// the stop returns, keeping its SSH connection, since nothing was written to it.
    func testAStopWhileTheBridgeOpensClosesTheLateBridgeBeforeReturning() async throws {
        let harness = await makeHarness(bridgeOpeningTakes: .milliseconds(200))
        harness.setScreenSize()
        let bridges = harness.bridges
        try await harness.waitUntil("the opening didn't start") { await bridges.openingsStartedAt.count == 1 }
        // The opening returns while the model is busy, so the stop comes before the model takes the bridge.
        XCTAssertTrue(Self.holdMainActor { await bridges.opened.count == 1 })

        await harness.model.stop()
        let bridge = try await harness.bridge(0)
        let closes = await bridge.closes
        XCTAssertEqual(closes, [.finished])
    }

    /// A show Herdr refuses ends the connection, which takes the session off Herdr's screen; nothing is
    /// sent to undo the show first. Herdr answered, so the SSH connection serves the reconnect.
    func testAShowHerdrRefusesEndsTheConnectionWithoutUndoingIt() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        // The focus that follows the show.
        _ = try await bridge.written(index)

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: false))
        try await harness.waitUntil("the refused show didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        let closes = try await allCloses(of: bridge, harness)
        let written = await bridge.writtenCount
        XCTAssertEqual(closes, [.finished])
        XCTAssertEqual(written, index + 1, "something was sent after the show")
    }

    /// Herdr's late answer to a show the session has since left doesn't complete the newer show: only the
    /// newest show's answer and a frame after it do.
    func testALateAnswerToAnOlderShowDoesNotCompleteTheNewerShow() async throws {
        let harness = await makeHarness()
        harness.setScreenSize()
        let bridge = try await harness.bridge()
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: panes))
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }
        harness.model.setSelected(true)
        var index = 0
        let older = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.setSelected(false)
        harness.model.setSelected(true)
        _ = try await harness.nextSurfaceSet(bridge, from: &index)
        let newer = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertEqual([older.active, newer.active], [true, true])

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: older.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one"], panes: panes))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.model.stateTraceLabel, "showing")

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: newer.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 3, lines: ["one"], panes: panes))
        try await harness.waitUntil("the newer show didn't complete") { harness.model.stateTraceLabel == "shown" }
    }

    /// A reconnecting session that the user leaves once its new connection has a snapshot reads as hidden,
    /// not reconnecting: it is as ready as a hidden session gets.
    func testLeavingAReconnectingSessionWhoseSnapshotArrivedEndsReconnecting() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let session = try await shownSession(harness)
        await session.bridge.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        var index = 0
        _ = try await harness.nextSurfaceSet(second, from: &index)

        harness.model.setSelected(false)
        XCTAssertEqual(harness.model.stateTraceLabel, "hidden")
        XCTAssertNotEqual(harness.states.last, .reconnecting(.transportLoss), "\(harness.states)")
    }

    /// Every close `bridge` got: it waits for the first, then long enough for any other in flight to land.
    private func allCloses(of bridge: FakeBridgeTransport, _ harness: HerdrModelHarness) async throws -> [HerdrBridgeCloseCause] {
        try await harness.waitUntil("the bridge wasn't closed") { await bridge.isClosed }
        try await Task.sleep(for: .milliseconds(200))
        return await bridge.closes
    }

    /// Back from the background, a connection that stayed open is shown again at once and checks itself
    /// with a ping meanwhile, as Herdr's client does after a resume: neither waits for the other.
    func testComingBackShowsTheSessionAtOnceAndPingsTheConnection() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        harness.model.handleAppLifecyclePhase(.background)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertFalse(hide.active)

        harness.model.handleAppLifecyclePhase(.active)
        var pinged = false
        var shown = false
        while !(pinged && shown) {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            index += 1
            if ping(write) != nil { pinged = true }
            if write.isSurfaceSet { shown = true }
        }
    }

    /// A connection that doesn't answer on the way back is gone: the session reconnects.
    func testComingBackReconnectsWhenTheConnectionDoesNotAnswer() async throws {
        var timing = HerdrConnection.Timing()
        timing.unansweredPing = .milliseconds(300)
        let harness = await makeHarness(timing: timing)
        let session = try await shownSession(harness)
        var index = session.next
        harness.model.handleAppLifecyclePhase(.background)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)

        harness.model.handleAppLifecyclePhase(.active)
        try await harness.waitUntil("the silent connection didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        _ = try await harness.bridge(1)
    }

    /// A shown session that reconnects reads as reconnecting, and takes no input, until the new
    /// connection completes its show: until then the panes show the last connection's frame.
    func testAReconnectReadsAsReconnectingUntilTheNewConnectionIsShown() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(50)
        let harness = await makeHarness(recovery: recovery)
        let session = try await shownSession(harness)
        await session.bridge.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        var index = 0
        let show = try await harness.nextSurfaceSet(second, from: &index)
        XCTAssertTrue(show.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(harness.states.last, .reconnecting(.transportLoss), "\(harness.states)")
        XCTAssertFalse(harness.model.isInputAvailable)

        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p2", x: 4, width: 3, height: 1),
        ]
        await second.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await second.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: panes))
        try await harness.waitUntil("the session didn't come back") { harness.states.last == .connected }
        XCTAssertTrue(harness.model.isInputAvailable)
    }

    /// A reconnect the user asks for also starts the delays over, as in Herdr's client: when it fails,
    /// the next try waits the first delay, not the one the failures before had reached.
    func testAReconnectTheUserAsksForStartsTheDelaysOver() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .milliseconds(100)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        for index in 1...3 {
            try await harness.bridge(index).finishServing()
        }
        // Four failures in a row: the next try would wait 0.8 s.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(harness.model.reconnect())
        let asked = try await harness.bridge(4)
        let failedAt = ContinuousClock.now
        await asked.finishServing()
        _ = try await harness.bridge(5)
        let starts = await harness.bridges.openingsStartedAt
        XCTAssertLessThan(starts[5] - failedAt, .milliseconds(500), "the delays didn't start over")
    }

    /// A reconnect the user asks for runs at once instead of waiting out the delay.
    func testAReconnectTheUserAsksForSkipsTheWait() async throws {
        var recovery = HerdrScreenModel.RecoveryTiming()
        recovery.firstRetry = .seconds(30)
        let harness = await makeHarness(recovery: recovery)
        let first = try await connectedSession(harness, lines: ["one"])
        await first.finishServing()
        try await harness.waitUntil("the drop didn't start a reconnect") {
            harness.states.last == .reconnecting(.transportLoss)
        }

        XCTAssertTrue(harness.model.reconnect())
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        try await harness.waitUntil("the session didn't come back") { harness.model.stateTraceLabel == "hidden" }
    }

    private static let onePane: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]

    /// A hidden session on its first bridge, connected, its one pane painted with `lines`.
    private func connectedSession(_ harness: HerdrModelHarness, lines: [String]) async throws -> FakeBridgeTransport {
        let bridge = try await harness.bridge(0)
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: lines, panes: Self.onePane))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") {
            harness.shownRows() == ["w1:p1": lines] && harness.model.stateTraceLabel == "hidden"
        }
        return bridge
    }

    /// Keeps the main actor busy, as other work on it would, until `condition` holds or three seconds
    /// pass; returns whether it held. Whatever resumes on the main actor meanwhile runs only after the
    /// caller's next synchronous steps.
    private nonisolated static func holdMainActor(until condition: @escaping @Sendable () async -> Bool) -> Bool {
        let held = DispatchSemaphore(value: 0)
        let poll = Task.detached {
            while !(await condition()) {
                try await Task.sleep(for: .milliseconds(10))
            }
            held.signal()
        }
        guard held.wait(timeout: .now() + 3) == .success else {
            poll.cancel()
            return false
        }
        return true
    }

    /// A snapshot whose data Remux can't read.
    private static func unreadableSnapshot() -> [UInt8] {
        var writer = HerdrWireWriter()
        writer.variant(20)
        writer.string(HerdrControlKind.snapshot)
        writer.string("{}")
        return HerdrWire.frame(writer.bytes)
    }

    // MARK: - Input

    /// Typing, keys and a paste go to the snapshot's focused pane in the order they were typed. A key's
    /// release isn't sent.
    func testInputGoesToTheFocusedPaneInOrder() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)

        XCTAssertEqual(adapter.sendInputToFocusedSurface("l\u{03}"), .accepted)
        XCTAssertEqual(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .enter)), .accepted)
        XCTAssertEqual(
            adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(action: .release, keyCode: .enter)),
            .accepted
        )
        XCTAssertEqual(adapter.sendPasteToFocusedSurface("a\nb"), .accepted)

        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [typed("l"), .key(HerdrKeyEvent(code: .character("c"), modifiers: .control, tracksRelease: true))]),
            frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]),
            frame("w1:p1", [.paste("a\nb")]),
        ])
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the release was sent")
    }

    /// Input is offered only while the session is shown; typed while hidden, nothing is sent.
    func testInputIsOfferedOnlyWhileShown() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }
        showInWindow(harness, panes: ["w1:p1"])
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)

        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(
            projection: 1,
            revision: 2,
            lines: ["one"],
            panes: [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("input wasn't offered once shown") {
            adapter.terminalInteractionProjection.isInputAvailable
        }

        harness.model.setSelected(false)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .transportUnavailable)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertFalse(hide.active)
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        XCTAssertEqual(written, index, "input typed while hidden was sent")
    }

    /// The snapshot's focused pane takes the keys and the highlight, as in Herdr's client, also while a
    /// frame still marks another pane; both follow the next snapshot.
    func testTheSnapshotsFocusedPaneTakesKeysAndTheHighlight() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, focusedPane: "w1:p2")
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let panes = adapter.terminalScreenPresentationProjection.viewport.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.filter(\.isFocused).map(\.id), [panes[1].id])
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID, panes[1].id)

        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        let first = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(first, frame("w1:p2", [typed("x")]))

        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p1"))
        try await harness.waitUntil("the highlight didn't follow the snapshot") {
            adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID == panes[0].id
        }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("y"), .accepted)
        let second = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(second, frame("w1:p1", [typed("y")]))
    }

    /// A tap on another pane asks Herdr to focus it, as Herdr's client does. Taps made before Herdr
    /// answers wait, and only the newest is sent; a tap on the focused pane sends nothing.
    func testATapAsksHerdrToFocusThePane() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        XCTAssertEqual(ids.count, 2)

        XCTAssertEqual(adapter.focusPane(ids[0]), .queued)
        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        let first = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(first.paneID, "w1:p2")

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        XCTAssertEqual(adapter.focusPane(ids[0]), .queued)
        try await Task.sleep(for: .milliseconds(100))
        let waiting = await session.bridge.writtenCount
        XCTAssertEqual(waiting, index, "a tap was sent before Herdr answered the last one")

        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 10, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])
        ))
        let second = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(second.paneID, "w1:p1")
        await session.bridge.serve(HerdrConnectionTests.reply(id: second.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))
        let answered = await session.bridge.writtenCount
        XCTAssertEqual(answered, index, "an older waiting tap was sent")
    }

    /// As in Herdr's client, a tap Herdr answers as no longer applying, because the pane changed
    /// meanwhile, shows no notice. A refused tap does, but not again while the same refusal is on screen.
    /// A refused tap ends where the session is, so the next tap on the same pane goes again.
    func testAFocusFailureShowsANoticeOnlyWhenItMeansSomething() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id).last)

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let stale = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: stale.id, error: ("stale_target", "the pane moved")))
        try await harness.waitUntil("the stale tap didn't end") { harness.model.stateTraceLabel == "shown" }
        XCTAssertNil(adapter.commandFailureEvent, "a tap on a pane that changed was reported")

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let refused = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: refused.id, error: ("pane_not_found", "pane not found")))
        try await harness.waitUntil("the refused tap didn't end") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: select pane failed")
        let shown = adapter.commandFailureEvent?.token

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let repeated = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: repeated.id, error: ("pane_not_found", "pane not found")))
        try await harness.waitUntil("the repeated tap didn't end") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(adapter.commandFailureEvent?.token, shown, "the same refusal was shown again while on screen")
    }

    /// A tap Herdr doesn't answer in time says so once; another timeout is shown only after a tap has
    /// worked, as Herdr's client clears its timeout notice on success.
    func testAFocusTimeoutIsShownOnceUntilAFocusWorks() async throws {
        var timing = HerdrConnection.Timing()
        timing.command = .milliseconds(200)
        let harness = await makeHarness(timing: timing)
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        let other = try XCTUnwrap(ids.last)

        XCTAssertEqual(adapter.focusPane(other), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        try await harness.waitUntil("the timeout wasn't shown") {
            adapter.commandFailureEvent != nil && harness.model.stateTraceLabel == "shown"
        }
        let first = adapter.commandFailureEvent?.token

        XCTAssertEqual(adapter.focusPane(other), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        try await Task.sleep(for: .milliseconds(300))
        try await harness.waitUntil("the second tap didn't end") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(adapter.commandFailureEvent?.token, first, "a second timeout was shown")

        XCTAssertEqual(adapter.focusPane(other), .queued)
        let worked = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: worked.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2"))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 3, lines: ["one two"], panes: [
            .init(id: "w1:p1", x: 0, width: 3, height: 1),
            .init(id: "w1:p2", x: 4, width: 3, height: 1, focused: true),
        ]))
        try await harness.waitUntil("the tap that worked didn't end") {
            harness.model.focusedPaneID == "w1:p2" && harness.model.stateTraceLabel == "shown"
        }

        XCTAssertEqual(adapter.focusPane(try XCTUnwrap(ids.first)), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        try await harness.waitUntil("a timeout after a tap that worked wasn't shown") {
            adapter.commandFailureEvent?.token != first
        }
    }

    /// Once Herdr reports that the focused pane asks for every key, non-ASCII text goes to it as a commit.
    func testAReportAllPaneGetsNonASCIITextAsACommit() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        // The model takes events in wire order, so once it has the snapshot it has the keyboard mode.
        await session.bridge.serve(
            HerdrServerScript.keyboardReportAll(true) + HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2")
        )
        try await harness.waitUntil("the snapshot wasn't taken") { harness.model.focusedPaneID == "w1:p2" }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("日a"), .accepted)
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p2", [.text("日"), typed("a")]))
    }

    /// A paste over Herdr's byte limit isn't sent, and input Herdr refuses shows Herdr's failure
    /// notice.
    func testInputThatCantGoThroughShowsAFailureNotice() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        let tooLarge = String(repeating: "a", count: HerdrConnection.maxInputBytes + 1)
        XCTAssertEqual(adapter.sendPasteToFocusedSurface(tooLarge), .surfaceRejected)
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: input failed")
        let firstToken = adapter.commandFailureEvent?.token
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [typed("x")]), "the oversized paste was sent")

        await session.bridge.serve(HerdrServerScript.inputRefused("Paste rejected"))
        try await harness.waitUntil("the refusal wasn't shown") { adapter.commandFailureEvent?.token != firstToken }
        XCTAssertEqual(adapter.commandFailureEvent?.message, "Herdr: input failed")
    }

    /// Herdr's refusal of input is shown for each new reason, but not again while the same refusal is on
    /// screen, as Herdr's client repeats a notice only once the last one is gone.
    func testARepeatedInputRefusalIsNotShownAgainWhileOnScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter

        await session.bridge.serve(HerdrServerScript.inputRefused("paste too large"))
        try await harness.waitUntil("the refusal wasn't shown") { adapter.commandFailureEvent != nil }
        let first = try XCTUnwrap(adapter.commandFailureEvent?.token)
        await session.bridge.serve(HerdrServerScript.inputRefused("paste too large"))
        await session.bridge.serve(HerdrServerScript.inputRefused("pane closed"))
        try await harness.waitUntil("the new reason wasn't shown") { adapter.commandFailureEvent?.token != first }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(adapter.commandFailureEvent?.token, first &+ 1, "the same refusal was shown again")
    }

    // MARK: - Zoom

    /// With "Zoom multipane windows" on, showing the session zooms the tab on screen on its focused pane,
    /// right behind the show. Herdr says it made the zoom, and leaving the screen keeps it, as tmux keeps a
    /// window's zoom while the session is off screen: focus off, then the hide, and no unzoom.
    func testATabIsZoomedWhenShownAndKeepsItsZoomWhenTheSessionLeaves() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        let index = session.next
        let show = try await harness.writes(session.bridge, from: index - 3, count: 3)
        guard case .surfaceSet(_, true) = show[0], show[1] == .focus(true), case .paneZoom(_, "w1:p1", "on") = show[2]
        else { return XCTFail("the zoom didn't follow the show: \(show)") }

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 2)
        XCTAssertEqual(leave[0], .focus(false), "\(leave)")
        guard case .surfaceSet(_, false) = leave[1] else { return XCTFail("the hide didn't go on its own: \(leave)") }
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index + 2, "something went after the hide")
    }

    /// The setting zooms only a tab with more than one pane, and only while it's on.
    func testOnlyAMultiPaneTabIsZoomedAndOnlyWithTheSetting() async throws {
        for (settings, panes) in [(TerminalSettings.default, ["w1:p1", "w1:p2"]), (Self.zooming, ["w1:p1"])] {
            let harness = await makeHarness(settings: settings)
            let session = try await shownTab(harness, panes: panes)
            try await Task.sleep(for: .milliseconds(150))
            let written = await session.bridge.writtenCount
            XCTAssertEqual(written, session.next, "\(panes.count) pane(s), setting \(settings.zoomMultipaneWindowsByDefault)")
        }
    }

    /// Back on screen after another client undid the zoom Remux made while the session was away, the session
    /// zooms the tab again and shows the frame from before it left until Herdr's zoomed frame: neither the
    /// frame showing the unzoom nor Herdr's frame for the show from before the zoom is drawn, and the tab's
    /// other pane never gets a renderer. Input comes back with the zoomed frame.
    func testAReturnShowsTheZoomedTabWithoutItsUnzoomedFrames() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let zoomedPane = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        // Another client unzooms the tab, and Herdr's frame showing it comes before the hide's answer.
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the frame showing the unzoom was drawn")

        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 4, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 4, lines: ["one two"], panes: Self.twoPanes))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the show's frame from before the zoom was drawn")
        XCTAssertFalse(harness.model.isInputAvailable)

        await session.bridge.serve(HerdrServerScript.snapshot(revision: 5, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 5, revision: 5, lines: ["one"], panes: [Self.zoomedPane]))
        await session.bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        try await harness.waitUntil("input didn't come back with the zoomed frame") { harness.model.isInputAvailable }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"])
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID, zoomedPane)
        XCTAssertNil(harness.model.paneSurface("w1:p2"), "the undrawn pane got a renderer")
    }

    /// Herdr's answer to the show's zoom can come before the zoomed frame; the show then completes on that
    /// frame, not on the one from before the zoom.
    func testAZoomAnsweredBeforeItsFrameCompletesTheShowOnThatFrame() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.model.layout, "the show's frame from before the zoom was drawn")
        XCTAssertNotEqual(harness.model.stateTraceLabel, "shown")

        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the zoomed frame didn't complete the show") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"])
        XCTAssertNil(harness.model.paneSurface("w1:p2"))
    }

    /// Back on screen with the tab still zoomed, as Remux's zoom stays while the session is away, the show
    /// sends no zoom: leaving and coming back send none at all, and the show completes on Herdr's zoomed
    /// frame.
    func testAReturnToATabStillZoomedSendsNoZoom() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next

        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        try await harness.waitUntil("the session didn't leave") { !harness.model.isInputAvailable }
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        let focus = try await harness.writes(session.bridge, from: index, count: 1)
        XCTAssertEqual(focus, [.focus(true)])
        index += 1
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true, projection: 3))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the return didn't complete") { harness.model.isInputAvailable }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"])
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "leaving and coming back sent a zoom")
    }

    /// A return's zoom waiting for the lane, behind a command in flight, doesn't go once the session has left
    /// again: Herdr refuses commands from a hidden session, and the next return sends its own.
    func testAWaitingZoomDoesNotGoOnceTheSessionLeavesAgain() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        // Another client unzooms the tab, so a return zooms it again.
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)
        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)

        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(false)
        let leave = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertFalse(leave.active)

        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the zoom went after the session left")
    }

    /// A session that leaves before Herdr has answered its show's zoom, and comes back, completes the new
    /// show on Herdr's frame for it: the frames Herdr drew for the first show, before and after its zoom,
    /// and that zoom's answer don't complete it. The new show sends no zoom of its own, as the tab is zoomed
    /// by then.
    func testAReturnAfterLeavingDuringAShowCompletesOnTheNewShowsFrame() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let first = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.setSelected(true)
        let second = try await harness.nextSurfaceSet(bridge, from: &index)

        // Herdr takes the first show and its zoom, then the hide and the second show.
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: first.id, active: true, projection: 1))
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        await bridge.serve(HerdrServerScript.snapshot(revision: 3, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one"], panes: [Self.zoomedPane]))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: second.id, active: true, projection: 4))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.model.layout, "a frame Herdr drew for the first show was drawn")

        await bridge.serve(HerdrServerScript.snapshot(revision: 5, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 5, revision: 4, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the second show didn't complete") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"])
        let written = await bridge.writtenCount
        let zooms = try await harness.writes(bridge, from: index, count: written - index).compactMap(paneZoom)
        XCTAssertTrue(zooms.isEmpty, "the second show zoomed the tab zoomed already: \(zooms)")
    }

    /// A show whose zoom another client undoes before Herdr draws it, as a split does, completes on
    /// Herdr's newer frame instead of waiting for a zoomed frame that never comes.
    func testAShowCompletesOnHerdrsNewerFrameWhenItsZoomIsUndoneElsewhere() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        // Herdr zooms and answers, but draws nothing before another client splits a pane.
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        let three = ["w1:p1", "w1:p2", "w1:p3"]
        await bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(three)))
        await bridge.serve(try harness.shownSurface(
            projection: 3,
            revision: 3,
            lines: ["one two thr"],
            panes: three.enumerated().map { .init(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $0 == 0) }
        ))

        try await harness.waitUntil("the show waited for a zoomed frame") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), three)
    }

    /// Herdr answers commands through a separate thread, so its answer to the zoom can come after the
    /// snapshot and frame of a split another client made since; the show completes on that frame all the
    /// same, which came after the zoom.
    func testAShowCompletesOnAFrameFromAfterItsZoomThatCameBeforeTheAnswer() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        let three = ["w1:p1", "w1:p2", "w1:p3"]
        await bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(three)))
        await bridge.serve(try harness.shownSurface(
            projection: 3,
            revision: 3,
            lines: ["one two thr"],
            panes: three.enumerated().map { .init(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $0 == 0) }
        ))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))

        try await harness.waitUntil("the show waited for a zoomed frame") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), three)
        // A snapshot showed the zoom before the one showing the split undo it, so the zoom isn't Remux's
        // any more: leaving sends no unzoom.
        let leaving = index
        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertFalse(hide.active)
        let leave = try await harness.writes(bridge, from: leaving, count: index - leaving)
        XCTAssertFalse(leave.contains { paneZoom($0) != nil }, "leaving undid a zoom the split had undone: \(leave)")
    }

    /// When another client's split lands together with the zoom, no snapshot shows the zoom; the show
    /// completes on the first frame after Herdr's answer, which came after the zoom, and not on the
    /// show's frame from before it.
    func testAShowCompletesOnTheFirstFrameAfterItsZoomsAnswerWhenNoneShowsTheZoom() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.model.layout, "the show's frame from before the zoom was drawn")

        let three = ["w1:p1", "w1:p2", "w1:p3"]
        await bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(three)))
        await bridge.serve(try harness.shownSurface(
            projection: 3,
            revision: 3,
            lines: ["one two thr"],
            panes: three.enumerated().map { .init(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $0 == 0) }
        ))
        try await harness.waitUntil("the show waited for a zoomed frame") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), three)
    }

    /// A tab zoomed already, by another client, gets no zoom from the show, and the session's end leaves it:
    /// the zoom isn't Remux's.
    func testAZoomRemuxDidNotMakeStaysWhenTheSessionEnds() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomed: true)
        try await Task.sleep(for: .milliseconds(100))
        let shown = await session.bridge.writtenCount
        XCTAssertEqual(shown, session.next, "the show zoomed a tab zoomed already")

        await harness.model.stop()
        let written = await session.bridge.writtenCount
        let end = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
        XCTAssertFalse(end.contains { paneZoom($0) != nil }, "the end undid a zoom Remux didn't make: \(end)")
    }

    /// Leaving while a command is in flight hides at once, with nothing behind the hide: leaving never waits,
    /// and it leaves Remux's zoom.
    func testLeavingWhileACommandIsInFlightHidesAtOnceAndLeavesTheZoom() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)
        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 2)
        XCTAssertEqual(leave[0], .focus(false), "\(leave)")
        guard case .surfaceSet(_, false) = leave[1] else { return XCTFail("expected the hide, got \(leave)") }
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index + 2, "something went out behind the hide")
    }

    /// Back on screen while a command is still in flight, with the zoom the leave left, the show sends no
    /// zoom and completes on Herdr's zoomed frame, which shows the pane Herdr focused meanwhile.
    func testAReturnToATabStillZoomedCompletesOnItsZoomedFrame() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)
        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)

        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        // Herdr focuses the pane, which the zoomed tab now shows, and its snapshot comes while hidden.
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])
        ))
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: hide.id, active: false))
        try await harness.waitUntil("the focus didn't move") { harness.model.focusedPaneID == "w1:p2" }

        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 4, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])
        ))
        await session.bridge.serve(try harness.shownSurface(
            projection: 4, revision: 4, lines: ["two"], panes: [.init(id: "w1:p2", x: 0, width: 7, height: 1, focused: true)]
        ))
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the show didn't complete on its zoomed frame") {
            harness.model.stateTraceLabel == "shown"
        }
        try await harness.waitUntil("the zoomed frame wasn't drawn") { self.drawnPanes(harness) == ["w1:p2"] }
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        let sent = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(sent.contains { paneZoom($0) != nil }, "the show zoomed a tab still zoomed: \(sent)")
    }

    /// A zoom that ended without Remux, as when someone unzooms the tab or splits a pane, isn't undone as the
    /// session ends.
    func testAZoomThatEndedElsewhereIsNotUndone() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)

        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }

        await harness.model.stop()
        let written = await session.bridge.writtenCount
        let end = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
        XCTAssertFalse(end.contains { paneZoom($0) != nil }, "the zoom was undone: \(end)")
    }

    /// While the tab is zoomed, a tap moves the focus to another pane, which Herdr then shows zoomed; the
    /// session's end unzooms the pane focused then, since an unzoom focuses its target.
    func testTheUnzoomGoesOnThePaneFocusedWhenTheSessionEnds() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let sheet = adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness))
        XCTAssertEqual(adapter.focusPane(try XCTUnwrap(sheet.panes.last).id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])
        ))
        await session.bridge.serve(try harness.shownSurface(
            projection: 3, revision: 3, lines: ["two"], panes: [.init(id: "w1:p2", x: 0, width: 3, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the focused pane wasn't drawn") { harness.model.paneSurface("w1:p2") != nil }
        XCTAssertEqual(
            adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).selectedPaneID,
            sheet.panes.last?.id
        )

        let stopping = Task { await harness.model.stop() }
        let unzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p2", "off"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: unzoom.id, changed: true, zoomed: false, panes: Self.places(2)))
        await stopping.value
    }

    /// The pane sheet's zoom button zooms the focused pane's tab, also with the setting off, and the zoom
    /// it makes is Remux's: leaving the screen keeps it, and the session's end, off screen, makes the
    /// surface active again and undoes it.
    func testTheZoomButtonsZoomIsUndoneWhenTheSessionEnds() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        var index = session.next

        XCTAssertEqual(harness.model.terminalScreenAdapter.setFocusedPaneZoomed(true), .queued)
        let on = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([on.paneID, on.mode], ["w1:p1", "on"])
        try await zoomTab(harness, session.bridge, answering: on.id)

        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertFalse(hide.active)
        let stopping = Task { await harness.model.stop() }
        let active = try await harness.nextSurfaceSet(session.bridge, from: &index)
        XCTAssertTrue(active.active, "the end didn't make the surface active for its unzoom")
        let undo = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([undo.paneID, undo.mode], ["w1:p1", "off"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: undo.id, changed: true, zoomed: false, panes: Self.places(2)))
        await stopping.value
    }

    /// A tab the user unzooms with the zoom button stays as the user left it, as tmux keeps a user's
    /// choice for a window: leaving doesn't take the zoom off again, and coming back doesn't zoom it.
    func testATabTheUserUnzoomedStaysUnzoomed() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next

        XCTAssertEqual(harness.model.terminalScreenAdapter.setFocusedPaneZoomed(false), .queued)
        let off = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([off.paneID, off.mode], ["w1:p1", "off"])
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        await session.bridge.serve(HerdrServerScript.zoomReply(id: off.id, changed: true, zoomed: false, panes: Self.places(2)))
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }
        try await Task.sleep(for: .milliseconds(100))

        harness.model.setSelected(false)
        let leave = try await harness.writes(session.bridge, from: index, count: 1)
        XCTAssertEqual(leave[0], .focus(false), "the zoom the user took off was taken off again")
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)

        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        let focus = try await harness.writes(session.bridge, from: index, count: 1)
        XCTAssertEqual(focus, [.focus(true)])
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 4, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 4, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the session wasn't shown again") { harness.model.stateTraceLabel == "shown" }
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index + 1, "the tab the user unzoomed was zoomed again")
    }

    /// While the tab is zoomed, the screen draws the zoomed pane alone, and the pane sheet maps every
    /// pane of the tab from Herdr's answer to the zoom, the focused one selected, with the zoom on.
    func testThePaneSheetMapsEveryPaneOfAZoomedTab() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, panes: ["w1:p1", "w1:p2", "w1:p3"], zoomingOnShow: true)
        var index = session.next

        let adapter = harness.model.terminalScreenAdapter
        let sheet = adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness))
        XCTAssertTrue(sheet.isServerZoomed)
        XCTAssertEqual(sheet.panes.map(\.frame), Self.places(3).map {
            Optional(GhosttyTerminalGridRect(x: UInt32($0.x), y: UInt32($0.y), columns: UInt32($0.width), rows: UInt32($0.height)))
        })
        XCTAssertEqual(sheet.selectedPaneID, sheet.panes.first?.id)
        // The sheet lays the map out by its splits, each pane an equal share.
        let map = try XCTUnwrap(PaneTopologyLayout.frames(
            panes: try sheet.panes.map { PaneTopologyLayout.Pane(id: $0.id, frame: try XCTUnwrap($0.frame)) },
            size: CGSize(width: 300, height: 200)
        ), "the map couldn't lay the panes out")
        XCTAssertEqual(map.frame(for: sheet.panes[0].id), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(map.frame(for: sheet.panes[2].id), CGRect(x: 100, y: 100, width: 200, height: 100))

        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertEqual(viewport.panes.filter { $0.visibleFrame != nil }.map(\.id), [sheet.panes[0].id])
        XCTAssertEqual(viewport.focusedSurfaceID, sheet.panes[0].id)
        XCTAssertEqual(adapter.terminalInteractionProjection.paneCount, 3)
    }

    /// A tab zoomed elsewhere, shown with the setting off, has no places for the panes its frame doesn't
    /// draw. Opening the pane sheet asks Herdr for the zoom the tab has, on the pane it shows; the answer
    /// changes nothing and maps every pane, and opening the sheet again asks nothing more.
    func testThePaneSheetMapsATabZoomedElsewhere() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let topLevel = try topLevel(harness)
        XCTAssertEqual(adapter.paneSelectionSheetRenderProjection(topLevelID: topLevel).panes.map { $0.frame != nil }, [true, false])

        adapter.refreshPaneMetadata(inTopLevel: topLevel)
        let asked = index
        try await harness.waitUntil("the sheet didn't ask for the tab's layout") { await session.bridge.writtenCount > asked }
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p1", "on"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: false, zoomed: true, panes: Self.places(2)))
        try await waitForMap(harness)

        adapter.refreshPaneMetadata(inTopLevel: topLevel)
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the sheet asked again")
    }

    /// The sheet asks nothing when the map places every pane already, here from the show's zoom.
    func testThePaneSheetAsksNothingWhenTheMapIsComplete() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next

        harness.model.terminalScreenAdapter.refreshPaneMetadata(inTopLevel: try topLevel(harness))
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the sheet asked for a layout it had")
    }

    /// While a command is in flight the sheet asks nothing, as Herdr would refuse it; an opening after
    /// the command is answered asks.
    func testThePaneSheetAsksForTheMapOnlyWhenNoCommandIsInFlight() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let topLevel = try topLevel(harness)
        XCTAssertTrue(harness.model.setFocusedPaneZoomed(true))
        let button = try await nextWrite(session.bridge, from: &index, paneZoom)

        adapter.refreshPaneMetadata(inTopLevel: topLevel)
        try await Task.sleep(for: .milliseconds(150))
        let waiting = await session.bridge.writtenCount
        XCTAssertEqual(waiting, index, "the sheet asked while a command was in flight")

        await session.bridge.serve(
            HerdrConnectionTests.reply(id: button.id, error: ("pane_layout_unavailable", "pane layout unavailable"))
        )
        let asked = index
        try await harness.waitUntil("the next opening didn't ask") {
            adapter.refreshPaneMetadata(inTopLevel: topLevel)
            return await session.bridge.writtenCount > asked
        }
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p1", "on"])
    }

    /// A failed answer leaves the map as it was, and the same missing panes aren't asked for again.
    func testAFailedMapAnswerLeavesTheMapAndIsNotAskedAgain() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let topLevel = try topLevel(harness)

        adapter.refreshPaneMetadata(inTopLevel: topLevel)
        let asked = index
        try await harness.waitUntil("the sheet didn't ask for the tab's layout") { await session.bridge.writtenCount > asked }
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(
            HerdrConnectionTests.reply(id: zoom.id, error: ("pane_layout_unavailable", "pane layout unavailable"))
        )
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(adapter.paneSelectionSheetRenderProjection(topLevelID: topLevel).panes.map { $0.frame != nil }, [true, false])

        adapter.refreshPaneMetadata(inTopLevel: topLevel)
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        XCTAssertEqual(written, index, "the same missing panes were asked for again")
    }

    // MARK: - Moves to another tab

    /// A notification tapped while the session is on screen takes it to the pane's tab as one move: the tab
    /// left keeps Remux's zoom; the setting's zoom of the pane's tab takes the session there; and once Herdr
    /// shows it there, `pane.focus` marks the pane's agents seen. The session's end then undoes both zooms:
    /// the tab left first, focused for its unzoom, then the tab the session was on, focused again.
    func testAMoveToAnotherTabLeavesRemuxsZoomOnTheTabLeft() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let first = try await harness.writes(session.bridge, from: index, count: 1)
        guard case .paneZoom(let zoom, "w1:p3", "on") = first[0] else {
            return XCTFail("the move's zoom didn't go first: \(first)")
        }
        index += 1
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))

        let stopping = Task { await harness.model.stop() }
        let left = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(left.method, "tab.focus")
        XCTAssertEqual(left.params, ["tab_id": "t1"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: left.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 4, zoomed: true, otherTabs: ["t2"], zoomedOtherTabs: ["t2"], panes: Self.bothTabsPanes
        ))
        let firstUnzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([firstUnzoom.paneID, firstUnzoom.mode], ["w1:p1", "off"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: firstUnzoom.id, changed: true, zoomed: false, panes: Self.places(2)))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 5, otherTabs: ["t2"], zoomedOtherTabs: ["t2"], panes: Self.bothTabsPanes
        ))
        let back = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(back.method, "tab.focus")
        XCTAssertEqual(back.params, ["tab_id": "t2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: back.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.secondTabOnScreen(revision: 6, zoomed: true))
        let secondUnzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([secondUnzoom.paneID, secondUnzoom.mode], ["w1:p3", "off"])
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: secondUnzoom.id, changed: true, zoomed: false, tab: "t2", panes: Self.secondTabPlaces)
        )
        await stopping.value
    }

    /// The phone's zoom record is for the Herdr session as Remux reaches it: the server's address, the account and
    /// Herdr it runs as, and the session's name. A saved server edited to reach another machine finds no record
    /// there, so its end unzooms none of that machine's tabs, while another saved server that reaches the first
    /// machine finds the record and takes the zoom off.
    func testTheZoomRecordIsForTheHerdrSessionAsRemuxReachesIt() async throws {
        let keepers = HerdrZoomKeepers(store: InMemoryHerdrOwnedZoomStore())
        let server = SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")
        let zoomed = await makeHarness(settings: Self.zooming, zoomKeepers: keepers, server: server)
        _ = try await shownTab(zoomed, zoomingOnShow: true)
        // The app ends without ending the session, which keeps the zoom and its record.
        await zoomed.model.stop(.replacedByNewAttempt)

        let edited = SavedServer(id: server.id, displayName: "Herdr Host", host: "other.example.test", username: "builder")
        let elsewhere = await makeHarness(zoomKeepers: keepers, server: edited)
        let other = try await shownTab(elsewhere, zoomed: true)
        await elsewhere.model.stop()
        let written = await other.bridge.writtenCount
        let end = try await elsewhere.writes(other.bridge, from: other.next, count: written - other.next)
        XCTAssertFalse(end.contains { paneZoom($0) != nil }, "another machine's tab was unzoomed: \(end)")

        let sameMachine = SavedServer(displayName: "Same Host", host: "herdr.example.test", username: "builder")
        let again = await makeHarness(zoomKeepers: keepers, server: sameMachine)
        let session = try await shownTab(again, zoomed: true)
        var index = session.next
        let stopping = Task { await again.model.stop() }
        let unzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p1", "off"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: unzoom.id, changed: true, zoomed: false, panes: Self.places(2)))
        await stopping.value
    }

    /// The session opened again while its end still takes Remux's zooms off waits for that end before it opens
    /// its bridge, so none of Herdr's time for the hello goes on the wait: the end stops after its step in
    /// flight, goes back to the tab it started on, where Herdr starts the new model's session, and unzooms
    /// nothing under it.
    func testOpeningTheSessionAgainDuringItsEndWaitsForTheEndBeforeItsBridgeOpens() async throws {
        let keepers = HerdrZoomKeepers(store: InMemoryHerdrOwnedZoomStore())
        let server = SavedServer(displayName: "Herdr Host", host: "herdr.example.test", username: "builder")
        let harness = await makeHarness(settings: Self.zooming, zoomKeepers: keepers, server: server)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))

        let stopping = Task { await harness.model.stop() }
        let left = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(left.params, ["tab_id": "t1"])

        let reopened = await makeHarness(settings: Self.zooming, zoomKeepers: keepers, server: server)
        reopened.setScreenSize()
        try await Task.sleep(for: .milliseconds(200))
        let openedDuringTheStep = await reopened.bridges.openingsStartedAt.count
        XCTAssertEqual(openedDuringTheStep, 0, "the bridge opened while the end had a step in flight")
        await session.bridge.serve(HerdrConnectionTests.reply(id: left.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 4, zoomed: true, otherTabs: ["t2"], zoomedOtherTabs: ["t2"], panes: Self.bothTabsPanes
        ))
        let back = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(back.params, ["tab_id": "t2"], "the end didn't go back to the tab it started on")
        let openedBeforeTheEndWentBack = await reopened.bridges.openingsStartedAt.count
        XCTAssertEqual(openedBeforeTheEndWentBack, 0, "the bridge opened before the end went back")
        await session.bridge.serve(HerdrConnectionTests.reply(id: back.id, json: #"{"type":"ok"}"#))
        await stopping.value
        let written = await session.bridge.writtenCount
        let end = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(end.contains { paneZoom($0) != nil }, "the end unzoomed a tab under the new model: \(end)")

        let bridge = try await reopened.bridge()
        let hello = try await reopened.writes(bridge, count: 1)
        guard case .hello? = hello.first else { return XCTFail("the new model didn't say hello first: \(hello)") }
        let openings = await reopened.bridges.openingsStartedAt
        let opened = try XCTUnwrap(openings.first)
        XCTAssertLessThan(ContinuousClock.now - opened, .seconds(1), "the hello waited after the bridge opened")
    }

    /// Ending the session gives each step of taking Remux's zooms off Herdr's time for a show, from Herdr's
    /// answer before it, so a session with zooms on many tabs ends with all of them off over a slow link,
    /// however long that takes in all.
    func testEndingTheSessionGivesEachUnzoomStepHerdrsTimeForAShow() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .seconds(1)
        let slowAnswer: Duration = .milliseconds(400)
        let harness = await makeHarness(settings: Self.zooming, timing: timing)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))

        let started = ContinuousClock.now
        let stopping = Task { await harness.model.stop() }
        let left = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(left.params, ["tab_id": "t1"])
        try await Task.sleep(for: slowAnswer)
        await session.bridge.serve(HerdrConnectionTests.reply(id: left.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 4, zoomed: true, otherTabs: ["t2"], zoomedOtherTabs: ["t2"], panes: Self.bothTabsPanes
        ))
        let firstUnzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await Task.sleep(for: slowAnswer)
        await session.bridge.serve(HerdrServerScript.zoomReply(id: firstUnzoom.id, changed: true, zoomed: false, panes: Self.places(2)))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 5, otherTabs: ["t2"], zoomedOtherTabs: ["t2"], panes: Self.bothTabsPanes
        ))
        let back = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(back.params, ["tab_id": "t2"])
        try await Task.sleep(for: slowAnswer)
        await session.bridge.serve(HerdrConnectionTests.reply(id: back.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.secondTabOnScreen(revision: 6, zoomed: true))
        let secondUnzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        try await Task.sleep(for: slowAnswer)
        let closedEarly = await session.bridge.isClosed
        XCTAssertFalse(closedEarly, "the end closed the connection with each step in time")
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: secondUnzoom.id, changed: true, zoomed: false, tab: "t2", panes: Self.secondTabPlaces)
        )
        await stopping.value
        XCTAssertGreaterThan(ContinuousClock.now - started, timing.activation)
    }

    /// A notification tapped while the session is hidden shows it and takes it to the pane's tab as part
    /// of the show: the show doesn't zoom the tab it leaves; the setting's zoom of the pane's tab takes the
    /// session there, then the pane is focused.
    func testAShowWithAMoveBehindItZoomsTheTabTheMoveReaches() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + Self.firstTabOnScreen(revision: 1))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }

        var index = await bridge.writtenCount
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let next = index
        try await harness.waitUntil("the move didn't follow the show") { await bridge.writtenCount >= next + 2 }
        let writes = try await harness.writes(bridge, from: index, count: 2)
        guard writes[0] == .focus(true), let zoom = paneZoom(writes[1]) else {
            return XCTFail("the show zoomed the tab it leaves, or the move didn't follow it: \(writes)")
        }
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
        index += 2
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces))
        await bridge.serve(Self.secondTabOnScreen(revision: 2, zoomed: true))
        let focus = try await expectWrite(harness, bridge, from: &index, "the pane reached wasn't focused", paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
    }

    /// A move asked while a command is in flight waits behind it in the one lane, and for the snapshot
    /// showing it, then goes as any move does: the tab left keeps Remux's zoom, and the setting zooms the
    /// tab reached.
    func testAMoveWaitsForTheCommandInFlightThenGoes() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        XCTAssertTrue(harness.model.focusPane("w1:p2"))
        let busy = try await nextWrite(session.bridge, from: &index, paneFocus)

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        try await Task.sleep(for: .milliseconds(150))
        let waiting = await session.bridge.writtenCount
        XCTAssertEqual(waiting, index, "something went while the command was in flight")

        await session.bridge.serve(HerdrConnectionTests.reply(id: busy.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, zoomed: true, otherTabs: ["t2"], focusedPane: "w1:p2", panes: Self.bothTabsPanes
        ))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
    }

    /// Another client taking the session to another tab, zoomed elsewhere, changes nothing Remux undoes or
    /// redoes: coming back to that tab sends no zoom, and leaving it unzooms nothing.
    func testAnotherClientsTabSwitchLeavesNothingForRemuxToUndo() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        try await harness.waitUntil("the other tab didn't come on screen") { harness.model.focusedPaneID == "w1:p3" }
        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        try await Task.sleep(for: .milliseconds(100))
        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)

        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        let sent = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
        XCTAssertFalse(sent.contains { paneZoom($0) != nil }, "Remux zoomed or unzoomed a tab: \(sent)")
    }

    /// Going to another tab and back before Herdr has answered the first move's zoom ends on the first tab,
    /// still zoomed: the move back only focuses the pane, though the snapshot still shows the first tab, and
    /// the zoom the first move made stays on its tab.
    func testAQuickReturnToTheTabLeftFindsItStillZoomed() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let away = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([away.paneID, away.mode], ["w1:p3", "on"])

        XCTAssertTrue(harness.model.focusPane("w1:p1"))
        try await Task.sleep(for: .milliseconds(100))
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: away.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        let focus = try await expectWrite(harness, session.bridge, from: &index, "the pane returned to wasn't focused", paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p1")
        let written = await session.bridge.writtenCount
        let zooms = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
            .compactMap(paneZoom).map { [$0.paneID, $0.mode] }
        XCTAssertEqual(zooms, [["w1:p3", "on"]])
    }

    /// A newer move wins over an older one still on its way: the steps the older one hadn't sent don't go.
    /// Its zoom, already sent, takes the session to its tab, but its focus doesn't go, and the newer move
    /// brings the session back to a tab still zoomed, which it only focuses.
    func testANewerMoveDropsTheStepsAnOlderOneHadntSent() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let away = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([away.paneID, away.mode], ["w1:p3", "on"])
        XCTAssertTrue(harness.model.focusPane("w1:p2"))
        try await Task.sleep(for: .milliseconds(100))
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: away.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true, firstTabZoomed: true))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(300))
        let written = await session.bridge.writtenCount
        let all = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
        XCTAssertFalse(all.contains { paneFocus($0)?.paneID == "w1:p3" }, "the older move's focus went: \(all)")
        XCTAssertEqual(all.compactMap(paneZoom).map { [$0.paneID, $0.mode] }, [["w1:p3", "on"]])
    }

    /// A zoom left waiting behind the command in flight doesn't go once another client has taken the
    /// session to another tab: a zoom focuses its pane, so it would take the session back.
    func testAWaitingZoomDoesNotTakeTheSessionBackFromAnotherClientsTab() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        let read = try await unzoomedElsewhereWithAReadInFlight(harness, session.bridge, from: &index)

        // Coming back, the show's zoom waits for the read's answer.
        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        index += 1
        try await Task.sleep(for: .milliseconds(150))

        await session.bridge.serve(Self.secondTabOnScreen(revision: 4))
        try await harness.waitUntil("the other client's tab didn't come") { harness.model.focusedPaneID == "w1:p3" }
        await session.bridge.serve(Self.selectionReply(id: read))
        try await Task.sleep(for: .milliseconds(300))
        let written = await session.bridge.writtenCount
        let later = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(later.contains { paneZoom($0) != nil }, "the waiting zoom went: \(later)")
    }

    /// A return's zoom waiting behind a command in flight doesn't go once another client has moved the
    /// session, even when the session is back on the pane as the lane frees: the show is overtaken for
    /// good, and a zoom would take the session back if the other client moved again meanwhile.
    func testAWaitingZoomDoesNotGoAfterAnotherClientLeavesAndComesBack() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        let read = try await unzoomedElsewhereWithAReadInFlight(harness, session.bridge, from: &index)

        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        index += 1
        try await Task.sleep(for: .milliseconds(150))

        // Another client focuses the tab's other pane, then the first again, before Herdr answers the read.
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 4, otherTabs: ["t2"], focusedPane: "w1:p2", panes: Self.bothTabsPanes))
        try await harness.waitUntil("the other client's focus didn't come") { harness.model.focusedPaneID == "w1:p2" }
        await session.bridge.serve(Self.firstTabOnScreen(revision: 5))
        try await harness.waitUntil("the focus didn't come back") { harness.model.focusedPaneID == "w1:p1" }
        await session.bridge.serve(Self.selectionReply(id: read))
        try await Task.sleep(for: .milliseconds(300))
        let written = await session.bridge.writtenCount
        let later = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(later.contains { paneZoom($0) != nil }, "the overtaken show's zoom went: \(later)")
    }

    /// A show whose zoom Herdr hasn't answered doesn't complete, though another client takes the session to
    /// another pane meanwhile and Herdr's snapshot and frame agree on it: the zoom may still change what
    /// Herdr shows. It completes once Herdr answers the zoom.
    func testAShowWaitsForItsZoomsAnswerThoughAnotherClientMovesTheSession() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p1", "on"])
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true, projection: 2))
        await bridge.serve(
            HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        let atSecond: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1),
            .init(id: "w1:p2", x: 4, width: 3, height: 1, focused: true),
        ]
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 1, lines: ["one two"], panes: atSecond))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.model.stateTraceLabel, "showing", "the show completed before Herdr answered its zoom")

        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        try await harness.waitUntil("the show didn't complete once its zoom was answered") {
            harness.model.stateTraceLabel == "shown"
        }
    }

    /// A show whose zoomed tab another client closes ends at once as Herdr shows the session: a tab that is
    /// gone isn't shown, so the show doesn't wait for a frame of it until its time runs out.
    func testAShowWhoseZoomedTabIsClosedEndsWhereHerdrIs() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + Self.firstTabOnScreen(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true, projection: 2))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))

        // Another client closes the tab; Herdr shows the other one.
        await bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            focusedTab: "t2",
            focusedPane: "w1:p3",
            panes: Self.secondTab.map { HerdrServerScript.snapshotPane($0, tab: "t2") }
        ))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 1, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the show waited for a tab that is gone") { harness.model.stateTraceLabel == "shown" }
        XCTAssertEqual(drawnPanes(harness), Self.secondTab)
    }

    /// A show taken to the pane Herdr has focused already still goes there, and completes only on a frame
    /// that draws that pane focused.
    func testAShowToThePaneHerdrHasFocusedWaitsForAFrameDrawingIt() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }

        var index = await bridge.writtenCount
        harness.model.reveal(.pane("w1:p1"), bootID: "boot")
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        let atSecond: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1),
            .init(id: "w1:p2", x: 4, width: 3, height: 1, focused: true),
        ]
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: atSecond))
        try await Task.sleep(for: .milliseconds(150))
        let written = await bridge.writtenCount
        for write in try await harness.writes(bridge, from: index, count: written - index) {
            guard let focus = paneFocus(write) else { continue }
            XCTAssertEqual(focus.paneID, "w1:p1")
            await bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.model.stateTraceLabel, "showing", "the show completed on a frame drawing another pane focused")

        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the show didn't complete on its pane's frame") { harness.model.stateTraceLabel == "shown" }
    }

    /// A selection read asked while a move's steps are under way waits behind them in the one lane, as
    /// Herdr takes one command at a time, and goes once they are answered.
    func testASelectionReadWaitsBehindAMovesSteps() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        let selection = GhosttyHistorySelection(
            start: GhosttyTerminalCell(row: 0, column: 0),
            end: GhosttyTerminalCell(row: 0, column: 2)
        )
        let read = Task { await harness.model.readSelection(selection, inPane: "w1:p1") }
        try await Task.sleep(for: .milliseconds(150))
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))

        let next = index
        try await harness.waitUntil("the read didn't go once the move's steps were answered") {
            await session.bridge.writtenCount > next
        }
        let sent = try HerdrConnectionTests.request(try await session.bridge.written(index))
        XCTAssertEqual(sent.method, HerdrScreenModel.paneSelectionReadMethod)
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: sent.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"one"}"#
        ))
        let text = await read.value
        XCTAssertEqual(text, "one")
        let commands = try await harness.writes(session.bridge, from: session.next, count: index + 1 - session.next)
            .compactMap { write -> String? in
                switch write {
                case .paneZoom(_, let pane, let mode): (["zoom"] + [pane, mode].compactMap { $0 }).joined(separator: " ")
                case .paneFocus(_, let pane): "focus \(pane)"
                case .command(_, let method, _): method
                default: nil
                }
            }
        XCTAssertEqual(
            commands,
            ["zoom w1:p3 on", "focus w1:p3", HerdrScreenModel.paneSelectionReadMethod]
        )
    }

    /// A move whose tab another client reaches first still goes: the setting zooms the tab reached, and
    /// Remux's focus marks the pane's agents seen.
    func testAMoveToATabAnotherClientReachesFirstStillZoomsIt() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        let reads = await session.bridge.reads

        // Another client takes the session to the move's tab as the move is asked: its snapshot is read
        // first, and reaches the model before the move goes out.
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, firstTabZoomed: true))
        XCTAssertTrue(Self.holdMainActor { await session.bridge.reads > reads })
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")

        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 4, zoomed: true, firstTabZoomed: true))
        let focus = try await expectWrite(harness, session.bridge, from: &index, "the pane reached wasn't focused", paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
    }

    /// With the setting off, a move to another tab completes on the tab reached once Herdr has answered
    /// its focus, also when Herdr sent that tab's snapshot and frame before the answer, as it can: nothing
    /// more comes for a move Herdr has made.
    func testAMoveWhoseFrameCameBeforeItsAnswerCompletes() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(Self.secondTabOnScreen(revision: 2))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await Task.sleep(for: .milliseconds(100))
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))

        try await harness.waitUntil("the move kept the tab left on screen") { self.drawnPanes(harness) == Self.secondTab }
        try await harness.waitUntil("the move didn't complete") { harness.model.stateTraceLabel == "shown" }
    }

    /// A move taken over by a move to another pane of the tab it reaches completes there: the frames
    /// show the tab once Herdr has answered the newer move, and the older one's answer changes nothing.
    func testAMoveRetargetedWithinTheTabItReachesCompletes() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let first = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(Self.secondTabOnScreen(revision: 2))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the snapshot didn't reach the tab") { harness.model.focusedPaneID == "w1:p3" }
        XCTAssertTrue(harness.model.focusPane("w1:p4"))
        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#))
        let second = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(second.paneID, "w1:p4")
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, focusedPane: "w1:p4"))
        await session.bridge.serve(
            try harness.shownSurface(projection: 3, revision: 3, lines: ["thr fou"], panes: Self.secondTabDrawn(focused: "w1:p4"))
        )
        await session.bridge.serve(HerdrConnectionTests.reply(id: second.id, json: #"{"type":"ok"}"#))

        try await harness.waitUntil("the retargeted move kept the tab left on screen") { self.drawnPanes(harness) == Self.secondTab }
        try await harness.waitUntil("the retargeted move didn't complete") { harness.model.stateTraceLabel == "shown" }
    }

    /// A notification tapped as the session comes back takes the session to its pane's tab: the move takes
    /// the show over, its zoom goes at once, and the show's frame of the tab left isn't drawn, though another
    /// client unzoomed that tab meanwhile and Herdr draws it split; only the tab reached, zoomed, is.
    func testAMoveDuringAReturnShowsOnlyTheTabReached() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        index += 1
        try await Task.sleep(for: .milliseconds(100))
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])

        // Herdr takes the show: the tab left is on screen, split, as another client unzoomed it meanwhile.
        await session.bridge.serve(Self.firstTabOnScreen(revision: 3))
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the tab left was drawn split")
        XCTAssertFalse(harness.model.isInputAvailable, "the show's frame of the tab left completed the move")

        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 4, zoomed: true))
        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 4, lines: ["thr"], panes: [Self.secondTabZoomed]))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the tab reached wasn't drawn zoomed") { self.drawnPanes(harness) == ["w1:p3"] }
        try await harness.waitUntil("the move didn't complete") { harness.model.stateTraceLabel == "shown" }
    }

    /// A move asked while the newest snapshot's frame is still on its way holds the frames all the same: the
    /// tab left isn't drawn split as another client unzooms it, and only the tab reached, zoomed, is drawn.
    func testAMoveHoldsTheFramesWhileTheNewestSnapshotsFrameIsOnItsWay() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 3, zoomed: true, otherTabs: ["t2"], panes: Self.bothTabsPanes)
        )
        try await Task.sleep(for: .milliseconds(100))
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one"], panes: [Self.zoomedPane]))
        // Another client unzooms the tab left before Herdr answers the zoom.
        await session.bridge.serve(Self.firstTabOnScreen(revision: 4))
        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 4, lines: ["one two"], panes: Self.twoPanes))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the tab left was drawn split")

        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 5, zoomed: true))
        await session.bridge.serve(try harness.shownSurface(projection: 5, revision: 5, lines: ["thr"], panes: [Self.secondTabZoomed]))
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the tab reached wasn't drawn zoomed") { self.drawnPanes(harness) == ["w1:p3"] }
        try await harness.waitUntil("the move didn't complete") { harness.model.stateTraceLabel == "shown" }
    }

    /// A move whose tab never comes on screen ends the connection within a show's time, as a show that
    /// doesn't complete does, instead of keeping the tab left on screen; it reads as in progress meanwhile.
    func testAMoveThatDoesNotCompleteInTimeEndsTheConnection() async throws {
        var timing = HerdrConnection.Timing()
        timing.activation = .milliseconds(300)
        let harness = await makeHarness(timing: timing)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        try await harness.waitUntil("the move didn't read as in progress") { harness.model.stateTraceLabel == "showing" }
        try await harness.waitUntil("the move that didn't complete didn't end the connection") {
            harness.states.last == .reconnecting(.transportLoss)
        }
        let closes = try await allCloses(of: session.bridge, harness)
        XCTAssertEqual(closes, [.unresponsive])
    }

    /// A tap on a pane of the tab on screen, asked just as another client takes the session to another
    /// tab and unzooms the first, goes as a move back from that tab: the setting zooms the tab it reaches.
    func testATapThatGoesAfterAnotherClientsTabSwitchZoomsTheTabItReaches() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        let reads = await session.bridge.reads

        // The other client's snapshot is read first, and reaches the model before the tap's move goes out.
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3))
        XCTAssertTrue(Self.holdMainActor { await session.bridge.reads > reads })
        XCTAssertTrue(harness.model.focusPane("w1:p2"))

        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p2", "on"])
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Array(Self.places(2).reversed()))
        )
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 4, zoomed: true, otherTabs: ["t2"], focusedPane: "w1:p2", panes: Self.bothTabsPanes)
        )
        let focus = try await expectWrite(harness, session.bridge, from: &index, "the pane reached wasn't focused", paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
    }

    /// A move to another tab takes the keys from the moment it is asked: until the tab reached is on screen,
    /// keys are dropped, never sent to the pane left, nor to the pane reached that the user can't see yet,
    /// also once Herdr reports it reached, while the keyboard stays available throughout as the move holds
    /// the frames; once the tab reached is on screen, keys go there.
    func testKeysWaitForThePaneAMoveToAnotherTabGoesTo() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable, "the move froze the keyboard")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("a"), .transportUnavailable, "a key went before the pane was reached")

        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3, zoomed: true))
        let focus = try await expectWrite(harness, session.bridge, from: &index, "the pane reached wasn't focused", paneFocus)
        try await harness.waitUntil("the snapshot didn't reach the pane") { harness.model.focusedPaneID == "w1:p3" }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the move's frames weren't held")
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable, "the held move froze the keyboard")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("b"), .transportUnavailable, "a key went to the tab not on screen")

        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["thr"], panes: [Self.secondTabZoomed]))
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == ["w1:p3"] }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("c"), .accepted)
        let reached = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(reached, frame("w1:p3", [typed("c")]))
        let inputs = try await harness.writes(session.bridge, from: session.next, count: index - session.next).compactMap(paneInput)
        XCTAssertEqual(inputs, [frame("w1:p3", [typed("c")])], "a key went to the pane left or the tab not on screen")
    }

    /// A pane that leaves the screen keeps its picture until the screen lets go of its view, then its surface
    /// closes; the session leaving the screen closes it at once. A renderer's close tells the model its
    /// presentation changed, and the model takes that as it comes, also in the middle of closing surfaces.
    func testASurfaceLeavingTheScreenClosesOnceTheScreenLetsGoOfIt() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: ["w1:p1", "w1:p2", "w1:p3"])
        let third = try XCTUnwrap(harness.model.paneSurface("w1:p3")?.renderer)
        let second = try XCTUnwrap(harness.model.paneSurface("w1:p2")?.renderer)

        // Herdr closes the third pane: its picture stays until the screen lets go of its view.
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the pane didn't leave the layout") { self.drawnPanes(harness) == ["w1:p1", "w1:p2"] }
        XCTAssertFalse(third.isClosing, "the pane's picture went before the screen let go of it")
        third.view.removeFromSuperview()
        try await harness.waitUntil("the surface the screen let go of didn't close") { third.isClosing }

        // Herdr closes the second pane, then the session leaves the screen, which lets go of its view.
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: Self.tabPanes(["w1:p1"])))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the pane didn't leave the layout") { self.drawnPanes(harness) == ["w1:p1"] }
        XCTAssertFalse(second.isClosing, "the pane's picture went before the screen let go of it")
        harness.model.setSelected(false)
        XCTAssertTrue(second.isClosing, "the surface of a session off screen stayed")
    }

    /// A switch to another tab keeps the tab left on screen, whole, until every pane of the tab reached has
    /// drawn off screen, then shows that tab in one go: never "Opening session", the tab left's name, focus
    /// and readiness meanwhile, and neither keys nor the composer's message reach either tab.
    func testATabSwitchKeepsTheTabLeftOnScreenUntilTheTabReachedHasDrawn() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let leftTab = adapter.windowSelectionSheetRenderProjection(group: nil).selectedWindowID

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)

        let held = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"], "the tab left went before the tab reached drew")
        XCTAssertEqual(held.statusOverlay, .ready)
        XCTAssertEqual(held.viewport.focusedSurfaceID, left)
        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection(group: nil).selectedWindowID, leftTab)
        XCTAssertEqual(harness.states.last, .connected)
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable, "the switch froze the keyboard")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("a"), .transportUnavailable)
        let composed = await adapter.sendPasteAwaitingCommandCompletion("b", to: left)
        XCTAssertFalse(composed, "the composer's message went during the switch")

        gate.releaseRegistrations()
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == Self.secondTab }
        let shown = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(shown.statusOverlay, .ready)
        XCTAssertNotNil(shown.viewport.focusedSurfaceID)
        XCTAssertNotEqual(shown.viewport.focusedSurfaceID, left)
        XCTAssertNotEqual(adapter.windowSelectionSheetRenderProjection(group: nil).selectedWindowID, leftTab)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("c"), .accepted)
        let reached = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(reached, frame("w1:p3", [typed("c")]))
        let inputs = try await harness.writes(session.bridge, from: session.next, count: index - session.next).compactMap(paneInput)
        XCTAssertEqual(inputs, [frame("w1:p3", [typed("c")])], "a key went during the switch")
    }

    /// Input for the tab left, asked once a switch is asked but before Herdr's snapshot shows it, is refused:
    /// the switch reaches Herdr first, on the same connection, and Herdr drops input for a pane outside the tab
    /// it shows the phone. So the composer keeps its message, and keys typed meanwhile are dropped.
    func testInputForTheTabLeftIsRefusedOnceASwitchIsAsked() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        harness.model.reveal(.tab("t2"), bootID: "boot")
        let toSecond = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toSecond.params, ["tab_id": "t2"])
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went to the tab left")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("a"), .transportUnavailable, "a key went during the switch")
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneInput)
        XCTAssertEqual(inputs, [], "input went to the tab left")
        paste.cancel()
    }

    /// A switch asked between a composer message's paste and its Enter refuses the Enter, which Herdr would
    /// drop, so the composer keeps the message; the Enter goes to no other pane either.
    func testASwitchBetweenAComposerPasteAndItsEnterRefusesTheEnter() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(pasteInput, frame("w1:p1", [.paste("ship it")]))
        let pastePing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
        await paste.value
        let pasteAnswer = await pasted.value
        XCTAssertEqual(pasteAnswer, true)

        harness.model.reveal(.tab("t2"), bootID: "boot")
        _ = try await nextWrite(session.bridge, from: &index, command)
        let entered = AnswerBox()
        let enter = Task {
            await entered.set(
                await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: left)
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        let enterAnswer = await entered.value
        XCTAssertEqual(enterAnswer, false, "the Enter went to the tab left")
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
            .compactMap(paneInput)
        XCTAssertEqual(inputs, [frame("w1:p1", [.paste("ship it")])], "input other than the paste went")
        enter.cancel()
    }

    /// A move to another pane of an unzoomed tab keeps input going for the tab's panes, as Herdr takes input
    /// for every pane of the tab it shows: the composer's message for the pane left and the keys for the pane
    /// reached go as they are asked.
    func testAPaneMoveWithinAnUnzoomedTabKeepsInputForItsPanes() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        harness.model.reveal(.pane("w1:p2"), bootID: "boot")
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(pasteInput, frame("w1:p1", [.paste("ship it")]))
        let pastePing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
        await paste.value
        let pasteAnswer = await pasted.value
        XCTAssertEqual(pasteAnswer, true)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("a"), .accepted)
        let typedInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(typedInput, frame("w1:p2", [typed("a")]))
    }

    /// A new tab asked refuses input for the tab left until Herdr shows where the session went, as Herdr moves
    /// the phone to the tab it makes: the composer keeps its message.
    func testInputForTheTabLeftIsRefusedOnceANewTabIsAsked() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        XCTAssertTrue(harness.model.create(.tab(workspaceID: "w1"), bootID: "boot"))
        let created = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(created.method, "tab.create")
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went to the tab left")
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneInput)
        XCTAssertEqual(inputs, [], "input went to the tab left")
        paste.cancel()
    }

    /// A move to another pane of a zoomed tab refuses input for the pane left, which Herdr stops taking once it
    /// shows the pane reached zoomed: the composer keeps its message.
    func testAPaneMoveWithinAZoomedTabRefusesInputForThePaneLeft() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        harness.model.reveal(.pane("w1:p2"), bootID: "boot")
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went to the pane left")
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneInput)
        XCTAssertEqual(inputs, [], "input went to the pane left")
        paste.cancel()
    }

    /// A composer message for a pane goes while the close of another pane of its tab is on its way: Herdr
    /// unzooms the tab it takes a pane from and goes on taking input for the panes left, with the setting's
    /// zoom off, and with it on, where the zoom that follows has the pane left alone.
    func testAComposerMessageGoesWhileAnotherPaneOfItsTabCloses() async throws {
        for zooms in [false, true] {
            let harness = await makeHarness(settings: zooms ? Self.zooming : .default)
            let session = try await shownTab(harness, zoomingOnShow: zooms)
            var index = session.next
            let adapter = harness.model.terminalScreenAdapter
            let kept = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

            XCTAssertTrue(harness.model.ask(.close(.pane("w1:p2"), group: false), bootID: "boot"))
            let close = try await nextWrite(session.bridge, from: &index, command)
            XCTAssertEqual(close.method, "pane.close")
            let pasted = AnswerBox()
            let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: kept)) }
            let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
            XCTAssertEqual(pasteInput, frame("w1:p1", [.paste("ship it")]), "zoomed: \(zooms)")
            let pastePing = try await nextWrite(session.bridge, from: &index, ping)
            await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
            await paste.value
            let answer = await pasted.value
            XCTAssertEqual(answer, true, "the composer's message for the pane left was refused, zoomed: \(zooms)")
        }
    }

    /// A tap back on the tab left while the switch away is still on its way goes nowhere until Herdr is back
    /// there: Herdr applies the switch away first, then would drop input for the tab left, and only then
    /// applies the way back. So the composer keeps its message, and keys typed meanwhile are dropped; once
    /// Herdr's focus back is answered, keys go again.
    func testInputForATabReturnedToWaitsForHerdrToBeBack() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        harness.model.reveal(.tab("t2"), bootID: "boot")
        let away = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(away.params, ["tab_id": "t2"])
        harness.model.reveal(.pane("w1:p1"), bootID: "boot")
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: left)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went while Herdr was still switching away")
        _ = adapter.sendInputToFocusedSurface("a")

        await session.bridge.serve(HerdrConnectionTests.reply(id: away.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3))
        let back = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(back.paneID, "w1:p1")
        let focusedBack = index
        _ = adapter.sendInputToFocusedSurface("b")
        await session.bridge.serve(HerdrConnectionTests.reply(id: back.id, json: #"{"type":"pane_info","pane":{"pane_id":"w1:p1"}}"#))
        await session.bridge.serve(Self.firstTabOnScreen(revision: 4))
        // The model and the engine each take the snapshot; a key goes once both have.
        try await harness.waitUntil("input didn't go again once Herdr was back") {
            guard adapter.sendInputToFocusedSurface("c") == .accepted else { return false }
            try? await Task.sleep(for: .milliseconds(50))
            let written = await session.bridge.writtenCount
            let since = (try? await harness.writes(session.bridge, from: focusedBack, count: written - focusedBack)) ?? []
            return since.contains { paneInput($0) == self.frame("w1:p1", [self.typed("c")]) }
        }
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
            .enumerated().compactMap { offset, write in paneInput(write).map { (session.next + offset, $0) } }
        XCTAssertTrue(inputs.allSatisfy { $0.0 >= focusedBack }, "input went before Herdr's focus back: \(inputs)")
        XCTAssertFalse(inputs.contains { $0.1 == frame("w1:p1", [.paste("ship it")]) }, "the refused message went")
        paste.cancel()
    }

    /// With the setting's zoom on, a split hands Herdr's focus to the new pane, which the setting then zooms.
    /// While that zoom is on its way, input for the pane split is refused: Herdr applies the zoom first and
    /// would drop it, though the snapshot after the split still shows the tab unzoomed. The composer keeps
    /// its message. With the setting off, the message goes during the split.
    func testInputForAPaneSplitWaitsForTheSettingsZoomOfTheNewPane() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let split = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        XCTAssertTrue(harness.model.create(.split(pane: "w1:p1", workspaceID: "w1", direction: .right), bootID: "boot"))
        let made = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(made.method, "pane.split")
        await session.bridge.serve(HerdrConnectionTests.reply(id: made.id, json: #"{"type":"pane_info","pane":{"pane_id":"w1:p5"}}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, focusedPane: "w1:p5", panes: Self.tabPanes(["w1:p1", "w1:p2", "w1:p5"])
        ))
        let splitPanes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 2, height: 1),
            .init(id: "w1:p2", x: 3, width: 2, height: 1),
            .init(id: "w1:p5", x: 6, width: 1, height: 1, focused: true),
        ]
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["on tw f"], panes: splitPanes))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p5", "on"])
        XCTAssertEqual(drawnPanes(harness), ["w1:p1"], "the split's frame showed before the request completed")

        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: split)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went ahead of the zoom Herdr applies first")
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneInput)
        XCTAssertEqual(inputs, [], "input went to the pane split")
        paste.cancel()

        let unzoomed = await makeHarness()
        let plain = try await shownTab(unzoomed)
        var plainIndex = plain.next
        let plainAdapter = unzoomed.model.terminalScreenAdapter
        let plainPane = try XCTUnwrap(plainAdapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        XCTAssertTrue(unzoomed.model.create(.split(pane: "w1:p1", workspaceID: "w1", direction: .right), bootID: "boot"))
        let plainSplit = try await nextWrite(plain.bridge, from: &plainIndex, command)
        XCTAssertEqual(plainSplit.method, "pane.split")
        let plainPasted = AnswerBox()
        let plainPaste = Task {
            await plainPasted.set(await plainAdapter.sendPasteAwaitingCommandCompletion("ship it", to: plainPane))
        }
        let plainInput = try await nextWrite(plain.bridge, from: &plainIndex, paneInput)
        XCTAssertEqual(plainInput, frame("w1:p1", [.paste("ship it")]))
        let plainPing = try await nextWrite(plain.bridge, from: &plainIndex, ping)
        await plain.bridge.serve(HerdrConnectionTests.pong(plainPing))
        await plainPaste.value
        let plainAnswer = await plainPasted.value
        XCTAssertEqual(plainAnswer, true)
    }

    /// The composer says how far its message went when a switch cuts it off. Refused before anything went,
    /// it keeps the message to send again; once the paste went and only the Enter is refused, the text is in
    /// the pane already, so the composer says the send didn't finish and keeps no copy to paste twice.
    func testTheComposerSaysHowFarAMessageCutOffByASwitchWent() async throws {
        for pasteGoes in [false, true] {
            let harness = await makeHarness()
            let session = try await shownTab(harness, secondTab: Self.secondTab)
            var index = session.next
            let adapter = harness.model.terminalScreenAdapter
            let left = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
            if !pasteGoes {
                harness.model.reveal(.tab("t2"), bootID: "boot")
                _ = try await nextWrite(session.bridge, from: &index, command)
            }

            let composer = GhosttyComposerModel()
            composer.draft = "ship it"
            composer.submit(to: GhosttyComposerSubmissionDestination(
                workspaceID: harness.model.target.workspace.id,
                surfaceID: left,
                destinationLabel: nil,
                makeAttachmentTransferService: { FailingComposerAttachmentTransferService() },
                prepareTerminalInput: {},
                sendPaste: { await adapter.sendPasteAwaitingCommandCompletion($0, to: left) },
                sendEnter: {
                    await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(action: .press, keyCode: .enter), to: left)
                }
            ))
            if pasteGoes {
                let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
                XCTAssertEqual(pasteInput, frame("w1:p1", [.paste("ship it")]))
                let pastePing = try await nextWrite(session.bridge, from: &index, ping)
                harness.model.reveal(.tab("t2"), bootID: "boot")
                _ = try await nextWrite(session.bridge, from: &index, command)
                await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
            }
            try await harness.waitUntil("the composer didn't finish") { !composer.isSubmitting }
            if pasteGoes {
                XCTAssertEqual(composer.statusMessage, "Couldn’t finish sending. Check the terminal.")
                XCTAssertEqual(composer.draft, "")
            } else {
                XCTAssertEqual(composer.statusMessage, "Couldn’t send. Message kept.")
                XCTAssertEqual(composer.draft, "ship it")
            }
            let written = await session.bridge.writtenCount
            let inputs = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
                .compactMap(paneInput)
            XCTAssertEqual(inputs, pasteGoes ? [frame("w1:p1", [.paste("ship it")])] : [], "paste went: \(pasteGoes)")
        }
    }

    /// The zoom button's zoom, then a tap on the tab's other pane, both answered before a snapshot shows either:
    /// Herdr zoomed the first pane and then focused the one tapped, which its zoom now shows. Input for the pane
    /// tapped goes, and the composer's message for the pane zoomed first is refused.
    func testAZoomThenATapBothAnsweredLeaveInputToThePaneTapped() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let zoomedFirst = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)

        XCTAssertEqual(adapter.setFocusedPaneZoomed(true), .queued)
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p1", "on"])
        await session.bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        harness.model.reveal(.pane("w1:p2"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(adapter.sendInputToFocusedSurface("b"), .accepted)
        let typedInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(typedInput, frame("w1:p2", [typed("b")]))
        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion("ship it", to: zoomedFirst)) }
        try await Task.sleep(for: .milliseconds(200))
        let answer = await pasted.value
        XCTAssertEqual(answer, false, "the composer's message went to the pane zoomed before the tap")
        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneInput)
        XCTAssertEqual(inputs, [], "input went to the pane zoomed before the tap")
        paste.cancel()
    }

    /// The zoom button's zoom still in flight once snapshots have shown it and then another client focusing the
    /// tab's other pane: Herdr applied the zoom already, so input for the pane Herdr shows now goes.
    func testAZoomInFlightThatSnapshotsShowAlreadyLeavesInputToThePaneShownSince() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertEqual(adapter.setFocusedPaneZoomed(true), .queued)
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p1", "on"])
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 3, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        await session.bridge.serve(try harness.shownSurface(
            projection: 3, revision: 3, lines: ["two"], panes: [.init(id: "w1:p2", x: 0, width: 7, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the other client's focus wasn't drawn") { self.drawnPanes(harness) == ["w1:p2"] }

        try await harness.waitUntil("input for the pane shown didn't go") {
            adapter.sendInputToFocusedSurface("b") == .accepted
        }
        let typedInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(typedInput, frame("w1:p2", [typed("b")]))
    }

    /// The switching cue says where a switch goes only once it has taken longer than its delay from the tap,
    /// and goes as the tab reached comes on screen; a quick switch shows none.
    func testTheSwitchingCueShowsOnlyOnceASwitchTakesLong() async throws {
        let gate = RendererFenceGate()
        let delay: Duration = .milliseconds(400)
        let harness = await makeHarness(rendererFenceGate: gate, switchingCueDelay: delay)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var overlays: [GhosttyTerminalStatusOverlayProjection] = []
        let watch = adapter.objectWillChange.sink { [adapter] in
            overlays.append(adapter.terminalScreenPresentationProjection.statusOverlay)
        }
        defer { watch.cancel() }

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the quick switch wasn't drawn") { self.drawnPanes(harness) == Self.secondTab }
        try await Task.sleep(for: delay + .milliseconds(100))
        XCTAssertFalse(overlays.contains { if case .switching = $0 { true } else { false } }, "a quick switch showed the cue")

        gate.holdsRegistrations = true
        let asked = ContinuousClock.now
        harness.model.reveal(.pane("w1:p1"), bootID: "boot")
        let back = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(Self.firstTabOnScreen(revision: 4))
        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        await session.bridge.serve(HerdrConnectionTests.reply(id: back.id, json: #"{"type":"ok"}"#))
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready, "the cue showed at once")
        try await harness.waitUntil("the cue didn't show") {
            adapter.terminalScreenPresentationProjection.statusOverlay == .switching("main")
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - asked, delay)
        XCTAssertEqual(drawnPanes(harness), Self.secondTab)

        gate.releaseRegistrations()
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == ["w1:p1", "w1:p2"] }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready, "the cue stayed after the switch")
    }

    /// The newest move wins over a tab waiting off screen: a tab passed over whose panes finish drawing before
    /// the next tab's frame arrives never comes on screen, the cue names the tab the move goes to, and a swipe
    /// meanwhile goes on from there.
    func testATabPassedOverNeverComesOnScreen() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate, switchingCueDelay: .milliseconds(100))
        let session = try await shownFourTabs(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var drawnTabs: [String?] = []
        let watch = adapter.objectWillChange.sink { [harness] in drawnTabs.append(harness.model.layout?.tab?.tabID) }
        defer { watch.cancel() }

        gate.holdsRegistrations = true
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let toSecond = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toSecond.params, ["tab_id": "t2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: toSecond.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.fourTabs(revision: 2, focusedTab: "t2", focusedPane: "w1:p3"))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the second tab's panes weren't drawing off screen") { gate.heldRegistrationCount == 2 }

        // The user goes on to the third tab; the second tab's panes finish drawing before its frame arrives.
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let toThird = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toThird.params, ["tab_id": "t3"])
        gate.releaseRegistrations()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.model.layout?.tab?.tabID, "t1", "the tab passed over came on screen")
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .switching("t3"))

        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        await session.bridge.serve(HerdrConnectionTests.reply(id: toThird.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.fourTabs(revision: 3, focusedTab: "t3", focusedPane: "w1:p5"))
        let toFourth = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toFourth.params, ["tab_id": "t4"], "the swipe went on from the tab passed over")
        await session.bridge.serve(HerdrConnectionTests.reply(id: toFourth.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.fourTabs(revision: 4, focusedTab: "t4", focusedPane: "w1:p6"))
        await session.bridge.serve(try harness.shownSurface(
            projection: 4, revision: 3, lines: ["six"], panes: [.init(id: "w1:p6", x: 0, width: 7, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the fourth tab wasn't drawn") { harness.model.layout?.tab?.tabID == "t4" }
        XCTAssertFalse(drawnTabs.contains("t2"), "the tab passed over came on screen: \(drawnTabs)")
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready)
    }

    /// A move refused after a frame of another tab arrived leaves that frame the newest Herdr sent: it comes
    /// on screen once drawn, so the screen never stays behind Herdr.
    func testAFrameHeldForARefusedMoveComesOnScreen() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownFourTabs(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        gate.holdsRegistrations = true
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let toSecond = try await nextWrite(session.bridge, from: &index, command)
        await session.bridge.serve(HerdrConnectionTests.reply(id: toSecond.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.fourTabs(revision: 2, focusedTab: "t2", focusedPane: "w1:p3"))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the second tab's panes weren't drawing off screen") { gate.heldRegistrationCount == 2 }

        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let toThird = try await nextWrite(session.bridge, from: &index, command)
        gate.releaseRegistrations()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.model.layout?.tab?.tabID, "t1")
        await session.bridge.serve(HerdrConnectionTests.reply(id: toThird.id, error: ("tab_not_found", "tab not found")))
        try await harness.waitUntil("the frame Herdr sent last didn't come on screen") {
            harness.model.layout?.tab?.tabID == "t2"
        }
        XCTAssertEqual(drawnPanes(harness), Self.secondTab)
    }

    /// A resize while a tab waits off screen keeps it off screen until Herdr draws it at the new grid, also
    /// when its panes finish drawing before that frame arrives, so it never comes on screen at the grid
    /// before.
    func testAResizeWhileATabWaitsShowsItOnlyAtTheNewGrid() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var shownColumns: [UInt16] = []
        let watch = adapter.objectWillChange.sink { [harness] in
            if harness.model.layout?.tab?.tabID == "t2", let columns = harness.model.layout?.columns { shownColumns.append(columns) }
        }
        defer { watch.cancel() }

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)

        // The screen narrows, and the panes finish drawing before Herdr's frame at the new grid arrives.
        harness.setScreenSize(CGSize(width: 300, height: 844))
        gate.releaseRegistrations()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"], "the tab reached came on screen at the grid before")

        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["th fo"], panes: Self.secondTabNarrowed))
        try await harness.waitUntil("the tab reached wasn't drawn at the new grid") { self.drawnPanes(harness) == Self.secondTab }
        let grid = try XCTUnwrap(harness.model.measurement?.controlViewport.columns)
        XCTAssertEqual(Set(shownColumns), [grid], "the tab reached came on screen at another grid: \(shownColumns)")
    }

    /// A resize away and back while a tab waits off screen leaves it drawn at the grid the screen asks for: it
    /// waits while the grid is another, and comes on screen as it is once the grid is back, with no new frame
    /// from Herdr.
    func testAResizeAwayAndBackWhileATabWaitsShowsItAsItIs() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)

        harness.setScreenSize(CGSize(width: 300, height: 844))
        gate.releaseRegistrations()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"], "the tab reached came on screen at another grid")

        harness.setScreenSize()
        try await harness.waitUntil("the tab reached didn't come on screen at the grid asked for again") {
            self.drawnPanes(harness) == Self.secondTab
        }
    }

    /// Two resizes in a row while a tab waits off screen: Herdr's frame answering the first, arriving after
    /// the second, leaves the tab waiting, and its frame at the last grid brings it on screen.
    func testAFrameDrawnForAnEarlierResizeLeavesTheTabWaiting() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var shownColumns: [UInt16] = []
        let watch = adapter.objectWillChange.sink { [harness] in
            if harness.model.layout?.tab?.tabID == "t2", let columns = harness.model.layout?.columns { shownColumns.append(columns) }
        }
        defer { watch.cancel() }

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)
        let first = try XCTUnwrap(harness.model.measurement?.controlViewport.columns)

        // The panes finish drawing between the two resizes, and Herdr's frame answering the first arrives after
        // the second.
        harness.setScreenSize(CGSize(width: 300, height: 844))
        let between = try XCTUnwrap(harness.model.measurement?.controlViewport.columns)
        let answeringBetween = try harness.shownSurface(projection: 3, revision: 3, lines: ["th fo"], panes: Self.secondTabNarrowed)
        gate.releaseRegistrations()
        try await Task.sleep(for: .milliseconds(300))
        harness.setScreenSize(CGSize(width: 345, height: 844))
        let last = try XCTUnwrap(harness.model.measurement?.controlViewport.columns)
        XCTAssertEqual(Set([first, between, last]).count, 3, "the screen sizes give the same grid: \([first, between, last])")
        await session.bridge.serve(answeringBetween)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"], "the tab reached came on screen at the grid in between")

        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 4, lines: ["th fo"], panes: Self.secondTabNarrowed))
        try await harness.waitUntil("the tab reached wasn't drawn at the last grid") { self.drawnPanes(harness) == Self.secondTab }
        XCTAssertEqual(Set(shownColumns), [last], "the tab reached came on screen at another grid: \(shownColumns)")
    }

    /// A frame Herdr drew before a resize reached it, for a newer snapshot such as an agent's update on its
    /// way, leaves a tab waiting off screen; Herdr's next frame, at the new grid, brings it on screen.
    func testANewerFrameAtTheGridBeforeAResizeLeavesTheTabWaiting() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var shownColumns: [UInt16] = []
        let watch = adapter.objectWillChange.sink { [harness] in
            if harness.model.layout?.tab?.tabID == "t2", let columns = harness.model.layout?.columns { shownColumns.append(columns) }
        }
        defer { watch.cancel() }

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)
        let atGridBefore = try harness.shownSurface(projection: 4, revision: 3, lines: ["thr fou"], panes: Self.secondTabDrawn())

        harness.setScreenSize(CGSize(width: 300, height: 844))
        gate.releaseRegistrations()
        await session.bridge.serve(Self.secondTabOnScreen(revision: 4))
        await session.bridge.serve(atGridBefore)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"], "the tab reached came on screen at the grid before")

        await session.bridge.serve(try harness.shownSurface(projection: 4, revision: 4, lines: ["th fo"], panes: Self.secondTabNarrowed))
        try await harness.waitUntil("the tab reached wasn't drawn at the new grid") { self.drawnPanes(harness) == Self.secondTab }
        let grid = try XCTUnwrap(harness.model.measurement?.controlViewport.columns)
        XCTAssertEqual(Set(shownColumns), [grid], "the tab reached came on screen at another grid: \(shownColumns)")
    }

    /// The zoom button acts on the tab the pane sheet shows: while the screen still shows the tab before the
    /// one Herdr is on, it is refused, as keys are, so it zooms neither tab; once the tab reached is on
    /// screen, it zooms that one.
    func testTheZoomButtonIsRefusedWhileATabWaitsOffScreen() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        try await moveToSecondTabHeldOffScreen(harness, session.bridge, gate: gate, from: &index)

        XCTAssertEqual(adapter.setFocusedPaneZoomed(true), .missingTarget(.focusedPane), "the zoom went while the tab before was on screen")
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        let zooms = try await harness.writes(session.bridge, from: index, count: written - index).compactMap(paneZoom)
        XCTAssertTrue(zooms.isEmpty, "a zoom went to the tab not on screen: \(zooms)")
        index = written

        gate.releaseRegistrations()
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == Self.secondTab }
        XCTAssertEqual(adapter.setFocusedPaneZoomed(true), .queued)
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
    }

    /// The switching cue calls a tab without a name of the user's by its number, as the toolbar counts tabs:
    /// Herdr's own name for such a tab is its number alone.
    func testTheSwitchingCueCallsATabWithoutItsOwnNameByItsNumber() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate, switchingCueDelay: .milliseconds(100))
        let workspace = HerdrServerScript.Workspace(
            id: "w1", label: "work", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])]
        )
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(
            revision: 1, workspaces: [workspace], focusedTab: "t1", focusedPane: "w1:p1", customTabLabels: false
        ))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        let adapter = harness.model.terminalScreenAdapter

        gate.holdsRegistrations = true
        harness.model.reveal(.tab("t2"), bootID: "boot")
        try await harness.waitUntil("the cue didn't name the tab by its number") {
            adapter.terminalScreenPresentationProjection.statusOverlay == .switching("tab 2")
        }
        let focus = try await nextWrite(bridge, from: &index, command)
        await bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await bridge.serve(HerdrServerScript.snapshot(
            revision: 2, workspaces: [workspace], focusedTab: "t2", focusedPane: "w1:p3", customTabLabels: false
        ))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the tab reached wasn't held off screen") { gate.heldRegistrationCount == 2 }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .switching("tab 2"))

        gate.releaseRegistrations()
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == Self.secondTab }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready)
    }

    /// A switch on to a third tab before the second has drawn shows only the third: the second never comes on
    /// screen, and the cue follows the switch to the tab it goes to now.
    func testARapidSwitchOnToAThirdTabDrawsOnlyThatTab() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate, switchingCueDelay: .milliseconds(200))
        let session = try await shownThreeTabs(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        var drawnTabs: [String?] = []
        let watch = adapter.objectWillChange.sink { [harness] in drawnTabs.append(harness.model.layout?.tab?.tabID) }
        defer { watch.cancel() }

        gate.holdsRegistrations = true
        harness.model.reveal(.tab("t2"), bootID: "boot")
        let toSecond = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toSecond.params, ["tab_id": "t2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: toSecond.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2, workspaceLabel: "work", tabLabel: "t2", focusedTab: "t2", otherTabs: ["t1", "t3"], focusedPane: "w1:p3"
        ))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the cue didn't name the second tab") {
            adapter.terminalScreenPresentationProjection.statusOverlay == .switching("t2")
        }

        harness.model.reveal(.tab("t3"), bootID: "boot")
        let toThird = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toThird.params, ["tab_id": "t3"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: toThird.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, workspaceLabel: "work", tabLabel: "t3", focusedTab: "t3", otherTabs: ["t1", "t2"], focusedPane: "w1:p5"
        ))
        await session.bridge.serve(try harness.shownSurface(
            projection: 3, revision: 3, lines: ["fiv"], panes: [.init(id: "w1:p5", x: 0, width: 7, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the cue didn't follow the switch on") {
            adapter.terminalScreenPresentationProjection.statusOverlay == .switching("t3")
        }
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"])

        gate.releaseRegistrations()
        try await harness.waitUntil("the third tab wasn't drawn") { self.drawnPanes(harness) == ["w1:p5"] }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready)
        XCTAssertFalse(drawnTabs.contains("t2"), "the tab passed over came on screen: \(drawnTabs)")
        XCTAssertNil(harness.model.paneSurface("w1:p3"))
    }

    /// A swipe during a switch goes on from the tab the switch goes to, as quick swipes through tabs do, while
    /// the tab left is still on screen.
    func testASwipeDuringASwitchGoesOnFromTheTabItGoesTo() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownThreeTabs(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        gate.holdsRegistrations = true
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let toSecond = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toSecond.params, ["tab_id": "t2"])
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        // Herdr takes one command at a time: the second swipe's focus goes once the first is answered.
        await session.bridge.serve(HerdrConnectionTests.reply(id: toSecond.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2, workspaceLabel: "work", tabLabel: "t2", focusedTab: "t2", otherTabs: ["t1", "t3"], focusedPane: "w1:p3"
        ))
        let toThird = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(toThird.params, ["tab_id": "t3"], "the second swipe went from the tab on screen")
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"])
    }

    /// A resize during a switch draws the tab reached again at its new size off screen, so it comes on screen
    /// only at that size, never at the size from before.
    func testAResizeDuringASwitchShowsTheTabReachedOnlyAtItsNewSize() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        func publishedWidth(_ paneID: String) -> Int? {
            guard let view = harness.model.paneSurface(paneID)?.renderer.view,
                  let layer = GhosttyIOSurfaceFrame.rendererLayer(in: view.layer)
            else { return nil }
            return GhosttyIOSurfaceFrame.dimensions(in: layer)?.width
        }
        var firstShown: (columns: UInt16?, width: Int?)?
        let watch = adapter.objectWillChange.sink { [harness] in
            guard firstShown == nil, harness.model.layout?.tab?.tabID == "t2" else { return }
            let rect = harness.model.layout?.panes.first { $0.paneID == "w1:p3" }?.innerRect
            firstShown = (rect?.width, publishedWidth("w1:p3"))
        }
        defer { watch.cancel() }

        // The tab reached's first pane draws off screen while the second waits.
        gate.holdsRegistrationsOf = ["w1:p4"]
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(Self.secondTabOnScreen(revision: 3))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the second pane wasn't waiting") { gate.heldRegistrationCount == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(drawnPanes(harness), ["w1:p1", "w1:p2"])

        // The screen narrows; Herdr draws the tab reached at the new size, its first pane narrower.
        harness.setScreenSize(CGSize(width: 300, height: 844))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["th fo"], panes: Self.secondTabNarrowed))
        gate.releaseRegistrations()
        try await harness.waitUntil("the tab reached wasn't drawn") { self.drawnPanes(harness) == Self.secondTab }

        let metrics = try XCTUnwrap(harness.model.measurement?.displayMetrics(columns: 2, rows: 1))
        let shown = try XCTUnwrap(firstShown)
        XCTAssertEqual(shown.columns, 2, "the tab reached came on screen at the size from before")
        XCTAssertEqual(shown.width, Int(metrics.pixelWidth), "the tab reached's picture came on screen at the size from before")
    }

    /// A move a newer one replaced says nothing of how it ended: its focus's refusal, answered after the
    /// newer move was asked, shows no notice, as Herdr's client drops a replaced request's answer.
    func testAReplacedMovesRefusalShowsNoNotice() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertTrue(harness.model.focusPane("w1:p2"))
        let replaced = try await nextWrite(session.bridge, from: &index, paneFocus)
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        try await Task.sleep(for: .milliseconds(150))
        await session.bridge.serve(HerdrConnectionTests.reply(id: replaced.id, error: ("pane_not_found", "pane not found")))
        let newer = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(newer.paneID, "w1:p3")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(adapter.commandFailureEvent, "the replaced move's refusal was reported")
    }

    /// A hide is a request of its own: a show's zoom answered after the session left completes nothing,
    /// and the frames Herdr sent for that show aren't drawn.
    func testAnAnswerFromBeforeAHideCompletesNothing() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        let zoom = try await nextWrite(bridge, from: &index, paneZoom)
        harness.model.setSelected(false)
        let hide = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertFalse(hide.active)

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one"], panes: [Self.zoomedPane]))
        await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(harness.model.layout, "a frame for the show the session left was drawn")
        XCTAssertEqual(harness.model.stateTraceLabel, "hidden")
        XCTAssertFalse(harness.model.isInputAvailable)
    }

    /// A move another client overtakes after its zoom, taking the session to a third tab before Herdr
    /// shows the move's, ends where Herdr shows it: the move's focus, which would take the session back,
    /// doesn't go, and that tab is drawn as it is.
    func testAMoveOvertakenAfterItsZoomShowsWhereHerdrIsWithoutItsFocus() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        try await Task.sleep(for: .milliseconds(100))
        // Another client takes the session to a third tab before Herdr's snapshot of the move's.
        await session.bridge.serve(Self.thirdTabOnScreen(revision: 3))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["fiv"], panes: [Self.thirdTabPane]))
        try await harness.waitUntil("the overtaken move kept the tab left on screen") { self.drawnPanes(harness) == ["w1:p5"] }
        try await harness.waitUntil("the overtaken move didn't end") { harness.model.stateTraceLabel == "shown" }

        let written = await session.bridge.writtenCount
        let after = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(after.contains { paneFocus($0) != nil }, "the overtaken move's focus went: \(after)")
    }

    /// As in Herdr's client, a move completes only on a frame that draws its pane focused: a frame drawn
    /// against the snapshot at the pane that still shows the tab left doesn't complete it, and isn't
    /// drawn.
    func testAMoveCompletesOnlyOnAFrameDrawingItsPane() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.secondTabOnScreen(revision: 2))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.model.stateTraceLabel, "showing", "a frame that didn't draw the move's pane completed it")

        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 3, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the move didn't complete on its pane's frame") { self.drawnPanes(harness) == Self.secondTab }
        try await harness.waitUntil("the move didn't end") { harness.model.stateTraceLabel == "shown" }
    }

    /// A move whose pane another client leaves after the move's zoom took the session there, before Herdr
    /// answers the zoom, is overtaken: the focus, which would take the session back, doesn't go, and the
    /// move ends as Herdr shows the session.
    func testAMoveWhosePaneAnotherClientLeavesAfterItsZoomIsNotFocusedBack() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true, secondTab: Self.secondTab)
        var index = session.next

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)

        // Herdr reaches the pane, zoomed, and another client focuses the tab's other pane, before Herdr's
        // answer to the zoom.
        let otherPane = HerdrServerScript.Pane(id: "w1:p4", x: 0, width: 7, height: 1, focused: true)
        await session.bridge.serve(
            Self.secondTabOnScreen(revision: 3, zoomed: true)
                + Self.secondTabOnScreen(revision: 4, zoomed: true, focusedPane: "w1:p4")
                + (try harness.shownSurface(projection: 4, revision: 4, lines: ["fou"], panes: [otherPane]))
                + HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, tab: "t2", panes: Self.secondTabPlaces)
        )
        try await harness.waitUntil("the overtaken move didn't end") { harness.model.stateTraceLabel == "shown" }
        try await Task.sleep(for: .milliseconds(200))
        let written = await session.bridge.writtenCount
        let later = try await harness.writes(session.bridge, from: index, count: written - index)
        XCTAssertFalse(later.contains { paneFocus($0) != nil }, "the overtaken move's focus went: \(later)")
        XCTAssertEqual(drawnPanes(harness), ["w1:p4"])
    }

    /// The next write `match` takes, failing with `failure` unless it comes within the harness's wait.
    private func expectWrite<Value>(
        _ harness: HerdrModelHarness,
        _ bridge: FakeBridgeTransport,
        from index: inout Int,
        _ failure: String,
        _ match: (ClientWrite) -> Value?
    ) async throws -> Value {
        while true {
            let next = index
            try await harness.waitUntil(failure) { await bridge.writtenCount > next }
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if let value = match(write) { return value }
        }
    }

    /// Tab `t2`'s panes, beside `w1:p1` and `w1:p2` in tab `t1`.
    private static let secondTab = ["w1:p3", "w1:p4"]

    private static let secondTabPlaces: [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)] = [
        ("w1:p3", 0, 0, 40, 24), ("w1:p4", 40, 0, 40, 24),
    ]

    private static var bothTabsPanes: [String] {
        tabPanes(["w1:p1", "w1:p2"]) + secondTab.map { HerdrServerScript.snapshotPane($0, tab: "t2") }
    }

    /// Another client unzooms tab `t1`, which Remux zoomed, so a return to it zooms it again; then a
    /// selection read holds the lane. Returns the read's request id.
    private func unzoomedElsewhereWithAReadInFlight(
        _ harness: HerdrModelHarness,
        _ bridge: FakeBridgeTransport,
        from index: inout Int
    ) async throws -> String {
        await bridge.serve(Self.firstTabOnScreen(revision: 3))
        await bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the tab didn't read as unzoomed") { (try? isZoomed(harness)) == false }
        let selection = GhosttyHistorySelection(
            start: GhosttyTerminalCell(row: 0, column: 0),
            end: GhosttyTerminalCell(row: 0, column: 2)
        )
        Task { _ = await harness.model.readSelection(selection, inPane: "w1:p1") }
        return try await nextWrite(bridge, from: &index, command).id
    }

    private static func selectionReply(id: String) -> [UInt8] {
        HerdrConnectionTests.reply(id: id, json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"one"}"#)
    }

    /// The snapshot with tab `t1` on screen, `w1:p1` focused.
    private static func firstTabOnScreen(revision: UInt64) -> [UInt8] {
        HerdrServerScript.snapshot(revision: revision, otherTabs: ["t2"], panes: bothTabsPanes)
    }

    /// The snapshot with tab `t2` on screen, `focusedPane` focused.
    private static func secondTabOnScreen(
        revision: UInt64,
        zoomed: Bool = false,
        firstTabZoomed: Bool = false,
        focusedPane: String = "w1:p3"
    ) -> [UInt8] {
        HerdrServerScript.snapshot(
            revision: revision,
            zoomed: zoomed,
            focusedTab: "t2",
            otherTabs: ["t1"],
            zoomedOtherTabs: firstTabZoomed ? ["t1"] : [],
            focusedPane: focusedPane,
            panes: bothTabsPanes
        )
    }

    /// The snapshot with a third tab `t3` on screen, its one pane `w1:p5` focused.
    private static func thirdTabOnScreen(revision: UInt64) -> [UInt8] {
        HerdrServerScript.snapshot(
            revision: revision,
            focusedTab: "t3",
            otherTabs: ["t1", "t2"],
            focusedPane: "w1:p5",
            panes: bothTabsPanes + [HerdrServerScript.snapshotPane("w1:p5", tab: "t3")]
        )
    }

    /// `w1:p5` drawn across tab `t3`, its only pane.
    private static let thirdTabPane = HerdrServerScript.Pane(id: "w1:p5", x: 0, width: 7, height: 1, focused: true)

    /// Tab `t2`'s frame drawing both its panes, `focused` focused.
    private static func secondTabDrawn(focused: String = "w1:p3") -> [HerdrServerScript.Pane] {
        secondTab.enumerated().map { .init(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $1 == focused) }
    }

    /// Tab `t2`'s panes drawn on a narrower screen, `w1:p3` focused.
    private static let secondTabNarrowed: [HerdrServerScript.Pane] = [
        .init(id: "w1:p3", x: 0, width: 2, height: 1, focused: true),
        .init(id: "w1:p4", x: 3, width: 2, height: 1),
    ]

    /// `w1:p3` drawn alone across tab `t2`, zoomed.
    private static let secondTabZoomed = HerdrServerScript.Pane(id: "w1:p3", x: 0, width: 7, height: 1, focused: true)

    /// Ending the session on screen undoes the zoom Remux made first, and closes the connection once
    /// Herdr has answered, so the unzoom isn't lost with it.
    func testEndingTheSessionUndoesTheZoomBeforeClosing() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next

        let stopping = Task { await harness.model.stop() }
        let unzoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p1", "off"])
        try await Task.sleep(for: .milliseconds(100))
        let closedEarly = await session.bridge.isClosed
        XCTAssertFalse(closedEarly, "the connection closed before Herdr answered the unzoom")
        await session.bridge.serve(
            HerdrServerScript.zoomReply(id: unzoom.id, changed: true, zoomed: false, panes: Self.places(2))
        )
        await stopping.value
        let closed = await session.bridge.isClosed
        XCTAssertTrue(closed)
    }

    /// Ending a session whose connection has just ended doesn't wait for Herdr: the unzoom it would send
    /// behind the command in flight can't go, so the stop goes on at once.
    func testEndingASessionWhoseConnectionEndedDoesNotWait() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownTab(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)
        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        _ = try await nextWrite(session.bridge, from: &index, paneFocus)

        let started = ContinuousClock.now
        await session.bridge.finishServing()
        await harness.model.stop()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "the stop waited for a connection that had ended")
    }

    /// A reconnect keeps the zoom Remux made, also to a new boot, as after Herdr's server restarted: the show
    /// sends no zoom for the tab still zoomed, and the session's end undoes it. A tab of that id with none of
    /// its panes now is another tab, and isn't Remux's.
    func testAReconnectKeepsTheZoomOfATabThatStillHasItsPanes() async throws {
        for (boot, panes, undone) in [("boot", ["w1:p1", "w1:p2"], true), ("boot-2", ["w1:p1", "w1:p2"], true), ("boot-2", ["w1:p7", "w1:p8"], false)] {
            var recovery = HerdrScreenModel.RecoveryTiming()
            recovery.firstRetry = .milliseconds(50)
            let harness = await makeHarness(settings: Self.zooming, recovery: recovery)
            let session = try await shownTab(harness, zoomingOnShow: true)
            await session.bridge.finishServing()

            let second = try await harness.bridge(1)
            await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(
                revision: 1, boot: boot, zoomed: true, focusedPane: panes[0], panes: Self.tabPanes(panes)
            ))
            var next = 0
            let show = try await harness.nextSurfaceSet(second, from: &next)
            await second.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
            await second.serve(try harness.shownSurface(
                boot: boot, projection: 1, revision: 1, lines: ["one"],
                panes: [.init(id: panes[0], x: 0, width: 7, height: 1, focused: true)]
            ))
            try await harness.waitUntil("the session wasn't shown again") { harness.model.stateTraceLabel == "shown" }
            next = await second.writtenCount
            let shown = try await harness.writes(second, from: 0, count: next)
            XCTAssertFalse(shown.contains { paneZoom($0) != nil }, "\(boot): the show zoomed a tab still zoomed: \(shown)")

            let stopping = Task { await harness.model.stop() }
            if undone {
                let unzoom = try await nextWrite(second, from: &next, paneZoom)
                XCTAssertEqual([unzoom.paneID, unzoom.mode], ["w1:p1", "off"], boot)
                await second.serve(HerdrServerScript.zoomReply(id: unzoom.id, changed: true, zoomed: false, panes: Self.places(2)))
                await stopping.value
            } else {
                await stopping.value
                let written = await second.writtenCount
                let end = try await harness.writes(second, from: 0, count: written)
                XCTAssertFalse(end.contains { paneZoom($0) != nil }, "\(boot): another tab of that id was unzoomed: \(end)")
            }
        }
    }

    private static var zooming: TerminalSettings {
        var settings = TerminalSettings.default
        settings.zoomMultipaneWindowsByDefault = true
        return settings
    }

    private static func tabPanes(_ ids: [String]) -> [String] {
        ids.map { HerdrServerScript.snapshotPane($0) }
    }

    private static let twoPanes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 3, height: 1),
    ]

    /// `w1:p1` drawn alone across the tab, as a zoomed tab draws its focused pane.
    private static let zoomedPane = HerdrServerScript.Pane(id: "w1:p1", x: 0, width: 7, height: 1, focused: true)

    /// Where Herdr's zoom answer puts `count` panes `w1:p1`...: the first on the left half, the others
    /// stacked on the right, touching, as its layout gives them.
    private static func places(_ count: Int) -> [(id: String, x: UInt16, y: UInt16, width: UInt16, height: UInt16)] {
        let rest = UInt16(max(count - 1, 1))
        return [("w1:p1", 0, 0, 40, 24)]
            + (1..<count).map { ("w1:p\($0 + 1)", 40, UInt16($0 - 1) * 24 / rest, 40, 24 / rest) }
    }

    /// A session on tab `t1` with `panes`, the first focused, shown, drawn and taking input, its snapshot saying
    /// whether the tab is `zoomed`, and its frame drawing every pane, or only the first while zoomed. With
    /// `zoomingOnShow`, Herdr zooms the tab behind the show as it does: the zoomed snapshot and frame, then
    /// its answer, which changed the zoom unless the tab was zoomed already. `secondTab` lists the panes of
    /// a tab `t2` beside it. Returns its bridge and the index of the first write after the show's.
    private func shownTab(
        _ harness: HerdrModelHarness,
        panes: [String] = ["w1:p1", "w1:p2"],
        zoomed: Bool = false,
        zoomingOnShow: Bool = false,
        secondTab: [String] = []
    ) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        let otherTabs = secondTab.isEmpty ? [] : ["t2"]
        let listed = Self.tabPanes(panes) + secondTab.map { HerdrServerScript.snapshotPane($0, tab: "t2") }
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(revision: 1, zoomed: zoomed, otherTabs: otherTabs, panes: listed)
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        var drawn = zoomed || panes.count == 1
            ? [Self.zoomedPane]
            : panes.enumerated().map { HerdrServerScript.Pane(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $0 == 0) }
        if zoomingOnShow {
            let zoom = try await nextWrite(bridge, from: &index, paneZoom)
            drawn = [Self.zoomedPane]
            await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, otherTabs: otherTabs, panes: listed))
            await bridge.serve(try harness.shownSurface(projection: 2, revision: 1, lines: ["one"], panes: drawn))
            await bridge.serve(
                HerdrServerScript.zoomReply(id: zoom.id, changed: !zoomed, zoomed: true, panes: Self.places(panes.count))
            )
        } else {
            await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: drawn))
        }
        let drawnIDs = drawn.map(\.id)
        try await harness.waitUntil("the panes' renderers weren't created") {
            drawnIDs.allSatisfy { harness.model.paneSurface($0) != nil }
        }
        showInWindow(harness, panes: drawnIDs)
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        // Input is offered before the panes' first pictures are in; a test starts from a tab drawn whole.
        try await harness.waitUntil("the tab's panes didn't draw") {
            harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.statusOverlay == .ready
        }
        if zoomingOnShow { try await waitForMap(harness, panes: panes.count) }
        return (bridge, index)
    }

    /// Workspace `w1` with tab `t1` (`w1:p1`, `w1:p2`), `t2` (`w1:p3`, `w1:p4`), `t3` (`w1:p5`) and `t4` (`w1:p6`),
    /// each named after its id, this phone at `focusedTab` and `focusedPane`.
    private static func fourTabs(revision: UInt64, focusedTab: String = "t1", focusedPane: String = "w1:p1") -> [UInt8] {
        HerdrServerScript.snapshot(
            revision: revision,
            workspaces: [HerdrServerScript.Workspace(
                id: "w1", label: "work",
                tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"]), ("t3", ["w1:p5"]), ("t4", ["w1:p6"])]
            )],
            focusedTab: focusedTab,
            focusedPane: focusedPane
        )
    }

    /// A session on tab `t1` of `fourTabs`, shown and taking input.
    private func shownFourTabs(_ harness: HerdrModelHarness) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + Self.fourTabs(revision: 1))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        showInWindow(harness, panes: ["w1:p1", "w1:p2"])
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    /// A session on tab `t1` with `w1:p1` and `w1:p2`, beside tabs `t2` and `t3` of workspace `w1`, shown and
    /// taking input.
    private func shownThreeTabs(_ harness: HerdrModelHarness) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(
            revision: 1, workspaceLabel: "work", otherTabs: ["t2", "t3"]
        ))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        showInWindow(harness, panes: ["w1:p1", "w1:p2"])
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    /// Herdr zooms the tab on `w1:p1`, as it does: the snapshot and the frame drawing `w1:p1` alone, then
    /// its answer to the zoom `id`, which the model has taken once the pane sheet maps every pane.
    private func zoomTab(_ harness: HerdrModelHarness, _ bridge: FakeBridgeTransport, answering id: String) async throws {
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one"], panes: [Self.zoomedPane]))
        await bridge.serve(HerdrServerScript.zoomReply(id: id, changed: true, zoomed: true, panes: Self.places(2)))
        try await waitForMap(harness)
    }

    /// Moves a `shownTab(harness, secondTab: Self.secondTab)` session to tab `t2` while `gate` holds the
    /// renderers' first pictures: the move completes, Herdr's frame for `t2` is drawn at the screen's grid,
    /// and its panes are drawing off screen while the screen still shows `t1`. `index` moves past the move.
    private func moveToSecondTabHeldOffScreen(
        _ harness: HerdrModelHarness,
        _ bridge: FakeBridgeTransport,
        gate: RendererFenceGate,
        from index: inout Int
    ) async throws {
        gate.holdsRegistrations = true
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(bridge, from: &index, paneFocus)
        await bridge.serve(Self.secondTabOnScreen(revision: 3))
        await bridge.serve(try harness.shownSurface(projection: 3, revision: 2, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        await bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await harness.waitUntil("the move didn't complete") { harness.model.stateTraceLabel == "shown" }
        try await harness.waitUntil("the tab reached's panes weren't drawing off screen") { gate.heldRegistrationCount == 2 }
    }

    /// Waits until the pane sheet maps `panes` panes of the zoomed tab.
    private func waitForMap(_ harness: HerdrModelHarness, panes: Int = 2) async throws {
        try await harness.waitUntil("the pane sheet didn't map the zoomed tab") {
            guard let topLevel = try? topLevel(harness) else { return false }
            let sheet = harness.model.terminalScreenAdapter.paneSelectionSheetRenderProjection(topLevelID: topLevel)
            return sheet.isServerZoomed && sheet.panes.count == panes && sheet.panes.allSatisfy { $0.frame != nil }
        }
    }

    /// The panes the screen draws, by the model's newest drawn layout.
    private func drawnPanes(_ harness: HerdrModelHarness) -> [String] {
        harness.model.layout?.panes.filter(\.hasTextArea).map(\.paneID) ?? []
    }

    private func topLevel(_ harness: HerdrModelHarness) throws -> UUID {
        try XCTUnwrap(harness.model.terminalScreenAdapter.selectedPaneSheetPresentationProjection()).topLevelID
    }

    private func isZoomed(_ harness: HerdrModelHarness) throws -> Bool {
        harness.model.terminalScreenAdapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).isServerZoomed
    }

    private func paneZoom(_ write: ClientWrite) -> (id: String, paneID: String?, mode: String)? {
        if case .paneZoom(let id, let paneID, let mode) = write { (id, paneID, mode) } else { nil }
    }

    // MARK: - Composer

    /// The composer's paste and its Enter each count as sent once Herdr has them, so the composer's pause
    /// before Enter runs from there: Herdr acknowledges no input, but answers a ping only after reading
    /// what came before it.
    func testAComposedMessageCountsAsSentOnceHerdrHasIt() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        let message = "fix it\n'/tmp/a b.png'"

        let pasted = AnswerBox()
        let paste = Task { await pasted.set(await adapter.sendPasteAwaitingCommandCompletion(message, to: pane)) }
        let pasteInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(pasteInput, frame("w1:p1", [.paste(message)]))
        let pastePing = try await nextWrite(session.bridge, from: &index, ping)
        try await Task.sleep(for: .milliseconds(100))
        let early = await pasted.value
        XCTAssertNil(early, "the paste counted as sent before Herdr had it")
        await session.bridge.serve(HerdrConnectionTests.pong(pastePing))
        await paste.value
        let pasteAnswer = await pasted.value
        XCTAssertEqual(pasteAnswer, true)

        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        }
        let enterInput = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(enterInput, frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterPing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(enterPing))
        let entered = await enter.value
        XCTAssertTrue(entered)
    }

    /// A composed message goes as soon as the session takes input, as typing does, also before the pane's
    /// renderer has shown its first frame: Herdr takes input for the panes of the tab it shows, whatever
    /// Remux has drawn of them.
    func testAComposedMessageGoesBeforeThePaneHasDrawn() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }
        harness.model.paneSurface("w1:p1")?.renderer.suppressFirstPublicationForTesting = true
        showInWindow(harness, panes: ["w1:p1"])
        try await harness.waitUntil("the session didn't take input") { harness.model.isInputAvailable }
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .awaitingFrame)

        let adapter = harness.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.first?.id)
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("message", to: pane) }
        let sent = try await nextWrite(bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [.paste("message")]))
        let alive = try await nextWrite(bridge, from: &index, ping)
        await bridge.serve(HerdrConnectionTests.pong(alive))
        let delivered = await paste.value
        XCTAssertTrue(delivered)
    }

    /// A scroll goes as soon as the session takes input, as typing does, also before the pane's renderer
    /// has shown its first frame: the wheel needs only the pane's drawn area to say where it is.
    func testAScrollGoesBeforeThePaneHasDrawn() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(
            try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, panes: Self.tabPanes(["w1:p1"]))
        )
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one"], panes: [Self.zoomedPane]))
        try await harness.waitUntil("the pane's renderer wasn't created") { harness.model.paneSurface("w1:p1") != nil }
        harness.model.paneSurface("w1:p1")?.renderer.suppressFirstPublicationForTesting = true
        showInWindow(harness, panes: ["w1:p1"])
        try await harness.waitUntil("the session didn't take input") { harness.model.isInputAvailable }
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .awaitingFrame)

        let adapter = harness.model.terminalScreenAdapter
        let pane = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.first?.id)
        let cellHeight = Double(try XCTUnwrap(harness.model.measurement).cellMetrics.pixelHeight)
        XCTAssertEqual(adapter.sendMousePosition(to: pane, CGPoint(x: 2, y: 2), mods: []), .sent)
        let scroll = GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: cellHeight * 1.5, mods: .init(precision: true, momentum: .began))
        XCTAssertEqual(adapter.sendMouseScroll(to: pane, scroll), .sent)
        let sent = try await nextWrite(bridge, from: &index, paneInput)
        let wheel = HerdrMouseEvent(kind: .scrollUp, column: 0, row: 0, lines: HerdrScreenModel.wheelLines)
        XCTAssertEqual(sent, frame("w1:p1", [.mouse(wheel)]))
    }

    /// A composed message to a pane that isn't focused, on a tab Herdr shows zoomed, doesn't go, and the
    /// composer keeps it: Herdr takes input only for the focused pane of a zoomed tab and drops the rest
    /// while still answering the ping, so the message would be lost.
    func testAComposedMessageToAnUnfocusedPaneOfAZoomedTabIsKept() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness)
        let adapter = harness.model.terminalScreenAdapter
        let focused = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let other = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id).first { $0 != focused })
        // Another client zooms the tab on its focused pane; the frame drawing that hasn't come yet.
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 2, zoomed: true, panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        try await Task.sleep(for: .milliseconds(150))

        let composer = GhosttyComposerModel()
        composer.draft = "message"
        composer.submit(to: GhosttyComposerSubmissionDestination(
            workspaceID: harness.model.target.workspace.id,
            surfaceID: other,
            destinationLabel: nil,
            makeAttachmentTransferService: { FailingComposerAttachmentTransferService() },
            prepareTerminalInput: {},
            sendPaste: { await adapter.sendPasteAwaitingCommandCompletion($0, to: other) },
            sendEnter: {
                await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(action: .press, keyCode: .enter), to: other)
            }
        ))
        try await harness.waitUntil("the composer didn't finish") { !composer.isSubmitting }
        XCTAssertEqual(composer.statusMessage, "Couldn’t send. Message kept.")
        XCTAssertEqual(composer.draft, "message")
        let written = await session.bridge.writtenCount
        let later = try await harness.writes(session.bridge, from: session.next, count: written - session.next)
        XCTAssertFalse(later.contains { paneInput($0) != nil }, "the message went to a pane Herdr drops input for: \(later)")
    }

    /// A composed message goes to the pane it was written in after another pane takes the focus: Herdr
    /// takes input for every pane on the shown tab.
    func testAComposedMessageGoesToItsPaneAfterTheFocusMoves() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"]))
        )
        try await harness.waitUntil("the focus didn't move") { harness.model.focusedPaneID == "w1:p2" }

        let enter = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(GhosttySurfaceKeyEvent(keyCode: .enter), to: pane)
        }
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [.key(HerdrKeyEvent(code: .enter, tracksRelease: true))]))
        let enterPing = try await nextWrite(session.bridge, from: &index, ping)
        await session.bridge.serve(HerdrConnectionTests.pong(enterPing))
        let entered = await enter.value
        XCTAssertTrue(entered)
    }

    /// A composed message that can't go isn't sent, and the composer says so itself: over Herdr's byte
    /// limit, to a pane no longer on the tab, while a popup is open over the tab, or while the session is
    /// hidden. Herdr would refuse the first and drop the others without a word, still answering pings.
    func testAComposedMessageThatCantGoIsNotSent() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id

        let tooLarge = String(repeating: "a", count: HerdrConnection.maxInputBytes + 1)
        let oversized = await adapter.sendPasteAwaitingCommandCompletion(tooLarge, to: pane)
        XCTAssertFalse(oversized)
        let elsewhere = await adapter.sendPasteAwaitingCommandCompletion("x", to: UUID())
        XCTAssertFalse(elsewhere)
        await session.bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 3,
            lines: ["one two"],
            panes: [
                .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
                .init(id: "w1:p2", x: 4, width: 3, height: 1),
            ],
            popup: "popup-terminal"
        ))
        try await harness.waitUntil("the popup wasn't seen") { harness.model.layout?.popup != nil }
        let underPopup = await adapter.sendPasteAwaitingCommandCompletion("x", to: pane)
        XCTAssertFalse(underPopup)
        harness.model.setSelected(false)
        let hidden = await adapter.sendPasteAwaitingCommandCompletion("x", to: pane)
        XCTAssertFalse(hidden)

        XCTAssertNil(adapter.commandFailureEvent)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for index in session.next..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            XCTAssertNil(paneInput(write), "input that can't go was sent")
        }
    }

    /// A paste whose connection ends before Herdr has it isn't sent, so the composer keeps the message.
    func testAComposedMessageIsNotSentWhenTheConnectionEndsFirst() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id

        await session.bridge.stallWrites()
        let paste = Task { await adapter.sendPasteAwaitingCommandCompletion("fix it", to: pane) }
        await session.bridge.waitForStalledWrites(1)
        await session.bridge.finishServing()
        let pasted = await paste.value
        XCTAssertFalse(pasted)
    }

    // MARK: - Scrolling

    /// Herdr scrolls a pane's history and says where it is with each frame, so the pane's scroll view
    /// takes the position and where a scroll goes from Herdr, not from the painted terminal: history to
    /// Herdr with the indicator showing, a program that reads the mouse gets the wheel. Neither redraws
    /// the screen, since the history grows with every line a program prints.
    func testAPanesScrollingComesFromHerdrWithoutRedrawingTheScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        let lookup = adapter.terminalManagedSurfaceLookup
        func serve(_ revision: UInt64, history: UInt64) async {
            await session.bridge.serve(HerdrServerScript.surface(
                projection: 1,
                revision: revision,
                lines: ["one two"],
                panes: [
                    .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true, scroll: (6, history, 1)),
                    .init(id: "w1:p2", x: 4, width: 3, height: 1, mouseReporting: true, alternateScreen: true),
                ]
            ))
        }
        await serve(3, history: 40)
        try await harness.waitUntil("the scrolling didn't reach the panes") {
            lookup.managedSurface(for: ids[0])?.scrollRoute == .remoteHistory
                && lookup.managedSurface(for: ids[1])?.scrollRoute == .mouseReport
        }
        let history = try XCTUnwrap(lookup.managedSurface(for: ids[0]))
        XCTAssertEqual(history.scrollState, GhosttySurfaceScrollState(total: 41, offset: 34, len: 1, cellOffset: 0))

        var screenChanges = 0
        let watch = adapter.objectWillChange.sink { screenChanges += 1 }
        await serve(4, history: 41)
        try await harness.waitUntil("the grown history didn't reach the pane") {
            history.scrollState.total == 42
        }
        watch.cancel()
        XCTAssertEqual(screenChanges, 0, "a change of scrolling alone redrew the screen")

        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        _ = container.update(
            surface: history,
            displayScale: 3,
            submitRouteForwardedMouseScroll: { _, _ in .sent },
            submitRouteForwardedMousePosition: { _, _, _ in .sent }
        )
        container.layoutIfNeeded()
        let scrollView = try XCTUnwrap(
            container.subviews.compactMap { $0 as? UIScrollView }.first { !($0 is GhosttyScrollPhysicsView) }
        )
        XCTAssertFalse(scrollView.isScrollEnabled, "history scrolled locally instead of on Herdr")
        XCTAssertTrue(scrollView.showsVerticalScrollIndicator)
        XCTAssertGreaterThan(scrollView.contentSize.height, container.bounds.height)
    }

    /// A server reporting a history at the top of the range gets a capped history, not a crash, and a
    /// pane scrolled up keeps its distance from the bottom.
    func testAnOversizedHistoryCapsTheScrollTotal() {
        let scroll = HerdrPaneScroll(
            linesFromBottom: 10,
            maxLinesFromBottom: .max,
            rows: 40,
            mouseReporting: false,
            alternateScreenActive: false
        )
        XCTAssertEqual(scroll.scrollState, GhosttySurfaceScrollState(total: .max, offset: .max - 50, len: 40, cellOffset: 0))
    }

    /// A scroll gesture's travel becomes Herdr wheel steps as Ghostty makes lines of it for tmux: one
    /// per cell height, the rest kept for the next, up or down with the travel, at the cell where the
    /// gesture is, each carrying Herdr's three history lines.
    func testAScrollGestureSendsWheelStepsToItsPane() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = adapter.terminalScreenPresentationProjection.viewport.panes[0].id
        let cellHeight = Double(try XCTUnwrap(harness.model.measurement).cellMetrics.pixelHeight)
        func travel(
            _ cells: Double,
            _ momentum: GhosttySurfaceMouseScrollMods.Momentum = .changed
        ) -> GhosttyMouseInputSubmissionOutcome {
            adapter.sendMouseScroll(to: pane, GhosttySurfaceMouseScrollEvent(
                deltaX: 0,
                deltaY: cells * cellHeight,
                mods: .init(precision: true, momentum: momentum)
            ))
        }

        XCTAssertEqual(adapter.sendMousePosition(to: pane, CGPoint(x: 1, y: 1), mods: []), .sent)
        XCTAssertEqual(travel(2.5, .began), .sent)
        XCTAssertEqual(travel(0.6), .sent)
        XCTAssertEqual(travel(-3.2), .sent)
        XCTAssertEqual(travel(0, .ended), .sent)

        let up = HerdrInputEvent.mouse(HerdrMouseEvent(kind: .scrollUp, column: 0, row: 0, lines: 3))
        let down = HerdrInputEvent.mouse(HerdrMouseEvent(kind: .scrollDown, column: 0, row: 0, lines: 3))
        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [up, up]),
            frame("w1:p1", [up]),
            frame("w1:p1", [down, down, down]),
        ])

        // A cancelled gesture, as when the program's mouse mode changes, sends none of its travel.
        XCTAssertEqual(travel(0.9, .began), .sent)
        XCTAssertEqual(travel(0.5, .cancelled), .sent)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(position))
            XCTAssertNil(paneInput(write), "a cancelled gesture's travel was sent")
        }
    }

    /// As in Herdr's client, scrolling another pane focuses it, and its steps go to it. A hidden session
    /// takes no scrolling.
    func testScrollingAnotherPaneFocusesItAndAHiddenSessionTakesNone() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)
        let cellHeight = Double(try XCTUnwrap(harness.model.measurement).cellMetrics.pixelHeight)
        let began = GhosttySurfaceMouseScrollEvent(
            deltaX: 0,
            deltaY: 1.2 * cellHeight,
            mods: .init(precision: true, momentum: .began)
        )

        _ = adapter.sendMousePosition(to: ids[1], .zero, mods: [])
        XCTAssertEqual(adapter.sendMouseScroll(to: ids[1], began), .sent)
        var focused: String?
        var input: [UInt8]?
        while focused == nil || input == nil {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            index += 1
            if let focus = paneFocus(write) { focused = focus.paneID }
            if let sent = paneInput(write) { input = sent }
        }
        XCTAssertEqual(focused, "w1:p2")
        XCTAssertEqual(input, frame("w1:p2", [.mouse(HerdrMouseEvent(kind: .scrollUp, column: 0, row: 0, lines: 3))]))

        harness.model.setSelected(false)
        XCTAssertEqual(adapter.sendMouseScroll(to: ids[0], began), .surfaceRejected)
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await session.bridge.written(position))
            XCTAssertNil(paneInput(write), "a hidden session scrolled")
        }
    }

    // MARK: - Mouse

    /// A button held while the screen switches to another tab is released in the pane it was pressed in as
    /// that pane leaves the screen, once, since the screen has no way left to send the touch's end there; the
    /// touch's end itself sends nothing more.
    func testAButtonHeldAsItsPaneLeavesTheScreenIsReleasedThere() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true, otherTabs: ["t2"])
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")

        XCTAssertEqual(adapter.sendMousePosition(to: pane, try point(harness, column: 2), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left)), .sent)
        harness.model.reveal(.tab("t2"), bootID: "boot")
        let away = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(away.params, ["tab_id": "t2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: away.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, focusedTab: "t2", otherTabs: ["t1"], focusedPane: "w1:p3", panes: Self.bothTabsPanes
        ))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["thr fou"], panes: Self.secondTabDrawn()))
        try await harness.waitUntil("the tab reached didn't come on screen") { self.drawnPanes(harness) == Self.secondTab }
        _ = adapter.sendMouseButton(to: pane, .init(state: .release, button: .left))
        try await Task.sleep(for: .milliseconds(100))

        let written = await session.bridge.writtenCount
        let inputs = try await harness.writes(session.bridge, from: session.next, count: written - session.next).compactMap(paneInput)
        XCTAssertEqual(inputs, [
            frame("w1:p1", [mouse(.moved, column: 2)]),
            frame("w1:p1", [mouse(.down(.left), column: 2)]),
            frame("w1:p1", [mouse(.up(.left), column: 2)]),
        ])
    }

    /// A button held as a switch is asked is released in the pane it was pressed in, as Herdr takes the release
    /// of a press it took whatever tab it shows the phone (`server/headless.rs`
    /// `client_pane_input_releases_press`): the program never keeps the button down.
    func testAButtonHeldAsASwitchIsAskedIsReleasedInItsPane() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true, otherTabs: ["t2"])
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")

        XCTAssertEqual(adapter.sendMousePosition(to: pane, try point(harness, column: 2), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left)), .sent)
        harness.model.reveal(.tab("t2"), bootID: "boot")
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .left)), .sent)

        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [mouse(.moved, column: 2)]),
            frame("w1:p1", [mouse(.down(.left), column: 2)]),
            frame("w1:p1", [mouse(.up(.left), column: 2)]),
        ])
    }

    /// A tap in a pane whose program reads the mouse is a left click at the tap's cell, after the pointer's
    /// move there, each reported relative to the pane's text area as Herdr's client reports them. A pane
    /// whose program doesn't read the mouse takes no button.
    func testATapInAProgramThatReadsTheMouseIsAClickAtItsCell() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")

        XCTAssertTrue(adapter.isMouseCaptured(for: pane))
        XCTAssertEqual(adapter.sendMousePosition(to: pane, try point(harness, column: 2), mods: []), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left)), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .left)), .sent)

        var sent: [[UInt8]] = []
        for _ in 0..<3 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [mouse(.moved, column: 2)]),
            frame("w1:p1", [mouse(.down(.left), column: 2)]),
            frame("w1:p1", [mouse(.up(.left), column: 2)]),
        ])

        let plain = await makeHarness()
        let plainSession = try await shownSession(plain)
        let plainPane = try paneSurfaceID(plain, "w1:p1")
        let adapterWithoutMouse = plain.model.terminalScreenAdapter
        XCTAssertFalse(adapterWithoutMouse.isMouseCaptured(for: plainPane))
        _ = adapterWithoutMouse.sendMousePosition(to: plainPane, try point(plain, column: 2), mods: [])
        XCTAssertEqual(adapterWithoutMouse.sendMouseButton(to: plainPane, .init(state: .press, button: .left)), .surfaceRejected)
        try await assertNoPaneInput(plainSession.bridge, from: plainSession.next, "a program that doesn't read the mouse got one")
    }

    /// As in Herdr's client, a held button takes the pointer's moves in its pane as drags, a cell at a
    /// time, with the modifiers held, and its release; no other press goes meanwhile, and a button Herdr
    /// has no code for doesn't go.
    func testAHeldButtonDragsAndItsReleaseEndsIt() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")
        let other = try paneSurfaceID(harness, "w1:p2")

        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .four)), .surfaceRejected)
        _ = adapter.sendMousePosition(to: pane, try point(harness, column: 0), mods: [])
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left, mods: [.shift])), .sent)
        _ = adapter.sendMousePosition(to: pane, try point(harness, column: 1), mods: [.shift])
        _ = adapter.sendMousePosition(to: pane, try point(harness, column: 1.4), mods: [.shift])
        _ = adapter.sendMousePosition(to: other, try point(harness, column: 2), mods: [])
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .middle)), .surfaceRejected)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .middle)), .surfaceRejected)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .left)), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .release, button: .left)), .surfaceRejected)

        var sent: [[UInt8]] = []
        for _ in 0..<4 {
            sent.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(sent, [
            frame("w1:p1", [mouse(.moved, column: 0)]),
            frame("w1:p1", [mouse(.down(.left), column: 0, [.shift])]),
            frame("w1:p1", [mouse(.drag(.left), column: 1, [.shift])]),
            frame("w1:p1", [mouse(.up(.left), column: 1)]),
        ])
        try await assertNoPaneInput(session.bridge, from: index, "more mouse input was sent")
    }

    /// A right press goes to the program only in a pane set to take right-clicks, with no modifier held, as
    /// Herdr's client keeps the others for its menu; a middle press goes to any program that reads the mouse.
    /// Neither focuses the pane: the tap that makes a press does.
    func testARightPressGoesOnlyToAPaneThatTakesRightClicks() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true, takingRightClicks: ["w1:p2"])
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")
        let other = try paneSurfaceID(harness, "w1:p2")
        _ = adapter.sendMousePosition(to: pane, try point(harness, column: 0), mods: [])
        _ = adapter.sendMousePosition(to: other, try point(harness, column: 0), mods: [])

        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .right)), .surfaceRejected)
        XCTAssertEqual(adapter.sendMouseButton(to: other, .init(state: .press, button: .right, mods: [.ctrl])), .surfaceRejected)
        XCTAssertEqual(adapter.sendMouseButton(to: other, .init(state: .press, button: .middle)), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: other, .init(state: .release, button: .middle)), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: other, .init(state: .press, button: .right)), .sent)
        XCTAssertEqual(adapter.sendMouseButton(to: other, .init(state: .release, button: .right)), .sent)

        var inputs: [[UInt8]] = []
        for _ in 0..<6 {
            inputs.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(inputs, [
            frame("w1:p1", [mouse(.moved, column: 0)]),
            frame("w1:p2", [mouse(.moved, column: 0)]),
            frame("w1:p2", [mouse(.down(.middle), column: 0)]),
            frame("w1:p2", [mouse(.up(.middle), column: 0)]),
            frame("w1:p2", [mouse(.down(.right), column: 0)]),
            frame("w1:p2", [mouse(.up(.right), column: 0)]),
        ])
        try await assertNoPaneFocus(session.bridge, from: session.next, "a press focused its pane")
    }

    /// A tap on a pane that isn't focused, whose program reads the mouse, does what the screen's tap does
    /// there: focuses the pane, once, and clicks at the tap's cell, as both servers' own clients do.
    func testATapOnAnUnfocusedMousePaneFocusesItOnceAndClicks() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try paneSurfaceID(harness, "w1:p2")

        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: try point(harness, column: 1),
            mouseCaptured: adapter.isMouseCaptured(for: other),
            showsKeyboard: false
        ) {
            switch action {
            case .activateInput, .focusPane:
                XCTAssertEqual(adapter.focusPane(other), .queued)
            case .mousePosition(let position):
                XCTAssertEqual(adapter.sendMousePosition(to: other, position, mods: []), .sent)
            case .mouseButton(let event):
                XCTAssertEqual(adapter.sendMouseButton(to: other, event), .sent)
            }
        }

        var inputs: [[UInt8]] = []
        var focused: [String] = []
        while inputs.count < 3 || focused.isEmpty {
            let write = try ClientWrite.decode(try await session.bridge.written(index))
            index += 1
            if let input = paneInput(write) { inputs.append(input) }
            if let focus = paneFocus(write) { focused.append(focus.paneID) }
        }
        XCTAssertEqual(inputs, [
            frame("w1:p2", [mouse(.moved, column: 1)]),
            frame("w1:p2", [mouse(.down(.left), column: 1)]),
            frame("w1:p2", [mouse(.up(.left), column: 1)]),
        ])
        XCTAssertEqual(focused, ["w1:p2"])
        try await assertNoPaneFocus(session.bridge, from: index, "the tap focused its pane twice")
    }

    /// A hidden session takes no mouse input, as it takes no other input.
    func testAHiddenSessionTakesNoMouseInput() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true)
        let adapter = harness.model.terminalScreenAdapter
        let pane = try paneSurfaceID(harness, "w1:p1")

        harness.model.setSelected(false)
        _ = adapter.sendMousePosition(to: pane, try point(harness, column: 1), mods: [])
        XCTAssertEqual(adapter.sendMouseButton(to: pane, .init(state: .press, button: .left)), .surfaceRejected)
        try await assertNoPaneInput(session.bridge, from: session.next, "a hidden session took mouse input")
    }

    private func paneSurfaceID(_ harness: HerdrModelHarness, _ paneID: String) throws -> UUID {
        let panes = harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.viewport.panes
        let index = try XCTUnwrap(["w1:p1", "w1:p2"].firstIndex(of: paneID))
        return panes[index].id
    }

    /// The middle of `column` in row 0, in the pane's points.
    private func point(_ harness: HerdrModelHarness, column: Double) throws -> CGPoint {
        let metrics = try XCTUnwrap(harness.model.measurement).cellMetrics
        return CGPoint(
            x: (column + 0.5) * Double(metrics.pixelWidth) / metrics.contentScale,
            y: 0.5 * Double(metrics.pixelHeight) / metrics.contentScale
        )
    }

    private func mouse(
        _ kind: HerdrMouseEvent.Kind,
        column: UInt16,
        _ modifiers: HerdrKeyModifiers = []
    ) -> HerdrInputEvent {
        .mouse(HerdrMouseEvent(kind: kind, column: column, row: 0, modifiers: modifiers))
    }

    private func assertNoPaneFocus(_ bridge: FakeBridgeTransport, from index: Int, _ message: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await bridge.written(position))
            XCTAssertNil(paneFocus(write), message)
        }
    }

    private func assertNoPaneInput(_ bridge: FakeBridgeTransport, from index: Int, _ message: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        for position in index..<written {
            let write = try ClientWrite.decode(try await bridge.written(position))
            XCTAssertNil(paneInput(write), message)
        }
    }

    // MARK: - Keys follow the tap

    /// Keys typed right after a tap on another pane of the tab go to that pane, before Herdr's snapshot says
    /// it is focused, as Herdr's client sends keys to the pane it has just focused; the screen draws it as
    /// the pane typed into and gives the composer its pane at once, and a scroll over it doesn't focus it
    /// again. Once Herdr shows the move, the user is in the pane Herdr has focused, as another client may
    /// move it.
    func testKeysTypedRightAfterATapGoToThePaneTapped() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: Self.threePanes)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("x"), .accepted)
        XCTAssertEqual(adapter.terminalInteractionProjection.selectedActiveLeafID, ids[1])
        XCTAssertEqual(adapter.sendMouseScroll(to: ids[1], Self.scrollBegan(harness)), .sent)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        let sent1 = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent1, frame("w1:p2", [typed("x")]))

        try await showFocus(of: "w1:p2", answering: focus.id, in: session.bridge, of: harness, revision: 2)
        try await harness.waitUntil("Herdr didn't show the move") {
            harness.model.focusedPaneID == "w1:p2" && harness.model.stateTraceLabel == "shown"
        }
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 4, focusedPane: "w1:p3", panes: Self.tabPanes(Self.threePanes)))
        try await harness.waitUntil("the user didn't follow Herdr's focus after the move") {
            harness.model.userPaneID == "w1:p3"
        }
        try await assertNoPaneFocus(session.bridge, from: index, "a scroll over the pane tapped focused it again")
    }

    /// A second tap before Herdr answered the first takes the keys at once.
    func testKeysAfterASecondQuickTapGoToTheSecondPane() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: Self.threePanes)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        XCTAssertEqual(adapter.focusPane(ids[2]), .queued)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("y"), .accepted)
        // The first focus is in flight; the second waits for its answer, and the key goes meanwhile.
        let first = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(first.paneID, "w1:p2")
        let typedY = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(typedY, frame("w1:p3", [typed("y")]))

        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2", panes: Self.tabPanes(Self.threePanes)))
        let second = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(second.paneID, "w1:p3")
        XCTAssertEqual(harness.model.userPaneID, "w1:p3", "Herdr's answer to the first focus took the keys back")
        try await showFocus(of: "w1:p3", answering: second.id, in: session.bridge, of: harness, revision: 3)
        try await harness.waitUntil("Herdr didn't show the second move") {
            harness.model.focusedPaneID == "w1:p3" && harness.model.stateTraceLabel == "shown"
        }
        XCTAssertEqual(harness.model.userPaneID, "w1:p3")
    }

    /// A pane that closes while the move to it is under way takes no keys, and none go to the pane left;
    /// once the move ends, keys follow the pane Herdr has focused.
    func testKeysForAPaneThatClosedMidMoveAreDropped() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: Self.threePanes)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, panes: Self.tabPanes(["w1:p1", "w1:p3"])))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.model.userPaneID, "w1:p2")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("z"), .transportUnavailable)
        XCTAssertTrue(harness.model.isInputAvailable)

        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, error: (code: "pane_not_found", message: "pane not found")))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p3", x: 4, width: 3, height: 1),
        ]))
        try await harness.waitUntil("the move didn't end") { harness.model.userPaneID == "w1:p1" }
        try await assertNoPaneInput(session.bridge, from: session.next, "a key for the closed pane went somewhere")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("a"), .accepted)
        let sent3 = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent3, frame("w1:p1", [typed("a")]))
    }

    /// A tap on a pane Herdr has just closed, which the model still lists: the engine completes the move's
    /// request as it starts, the move ends, and the user is back in the pane Herdr has focused, so a later
    /// key goes there, not to the pane gone.
    func testATapOnAPaneHerdrJustClosedEndsTheMove() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: Self.threePanes)
        var index = session.next

        // Herdr closes the pane: the snapshot without it, and the frame drawn against that snapshot, in one
        // read. Holding the main actor right after lets the engine take both while the model still has the
        // pane, so the tap goes.
        let closed = HerdrServerScript.snapshot(revision: 2, panes: Self.tabPanes(["w1:p1", "w1:p3"]))
        let drawn = try harness.shownSurface(projection: 2, revision: 2, lines: ["one three"], panes: [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
            .init(id: "w1:p3", x: 4, width: 3, height: 1),
        ])
        await session.bridge.serve(closed + drawn)
        usleep(300_000)
        XCTAssertTrue(harness.model.focusPane("w1:p2"))
        try await harness.waitUntil("the move to the pane gone didn't end") {
            harness.model.userPaneID == "w1:p1"
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.model.userPaneID, "w1:p1", "the move to the pane gone came back")
        XCTAssertEqual(harness.model.terminalScreenAdapter.sendInputToFocusedSurface("k"), .accepted)
        let sent = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent, frame("w1:p1", [typed("k")]))
    }

    /// Another client moving the focus after Remux's move ends the move: keys go to the pane tapped until
    /// then, and to the pane Herdr has focused after.
    func testAnotherClientsFocusAfterTheMoveTakesTheKeys() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, panes: Self.threePanes)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let ids = adapter.terminalScreenPresentationProjection.viewport.panes.map(\.id)

        XCTAssertEqual(adapter.focusPane(ids[1]), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("b"), .accepted)
        let sent4 = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent4, frame("w1:p2", [typed("b")]))

        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, focusedPane: "w1:p2", panes: Self.tabPanes(Self.threePanes)))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, focusedPane: "w1:p3", panes: Self.tabPanes(Self.threePanes)))
        await session.bridge.serve(try harness.shownSurface(projection: 3, revision: 3, lines: ["one two"], panes: Self.drawn(Self.threePanes, focused: "w1:p3")))
        try await harness.waitUntil("the overtaken move didn't end") {
            harness.model.userPaneID == "w1:p3" && harness.model.stateTraceLabel == "shown"
        }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("c"), .accepted)
        let sent5 = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent5, frame("w1:p3", [typed("c")]))
    }

    /// A pick from Panes of a pane a zoomed tab doesn't draw: Herdr takes input only for the zoomed tab's
    /// focused pane, so keys are dropped quietly until Herdr shows the pane, never sent to the pane left;
    /// the session stays ready to type into and the screen keeps the frame's pane, so nothing flickers.
    func testAZoomedTabPickDropsKeysUntilThePaneShowsAndKeepsInputAvailable() async throws {
        let harness = await makeHarness()
        let session = try await shownTab(harness, zoomed: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the zoomed pane didn't draw") {
            harness.model.presentation(ofPane: "w1:p1") == .ready
        }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready)
        let shown = try XCTUnwrap(adapter.terminalInteractionProjection.selectedActiveLeafID)
        let other = try XCTUnwrap(adapter.paneSelectionSheetRenderProjection(topLevelID: try topLevel(harness)).panes.last)

        XCTAssertEqual(adapter.focusPane(other.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p2")
        XCTAssertEqual(harness.model.userPaneID, "w1:p2")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("q"), .transportUnavailable)
        XCTAssertEqual(adapter.sendKeyEventToFocusedSurface(GhosttySurfaceKeyEvent(keyCode: .enter)), .transportUnavailable)
        XCTAssertTrue(harness.model.isInputAvailable)
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.terminalInteractionProjection.selectedActiveLeafID, shown)
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .ready)
        XCTAssertNil(adapter.commandFailureEvent, "a dropped key said so")

        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, zoomed: true, focusedPane: "w1:p2", panes: Self.tabPanes(["w1:p1", "w1:p2"])))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["two"], panes: [
            .init(id: "w1:p2", x: 0, width: 7, height: 1, focused: true),
        ]))
        try await harness.waitUntil("Herdr didn't show the pane picked") {
            harness.model.screenPaneID == "w1:p2" && harness.model.stateTraceLabel == "shown"
        }
        try await assertNoPaneInput(session.bridge, from: session.next, "a key went while the pane picked wasn't shown")
        XCTAssertEqual(adapter.sendInputToFocusedSurface("r"), .accepted)
        let sent6 = try await nextWrite(session.bridge, from: &index, paneInput)
        XCTAssertEqual(sent6, frame("w1:p2", [typed("r")]))
    }

    /// A pick of a pane or a tab on another tab: keys are dropped until Herdr shows that tab, then go to the
    /// pane it has focused, and the session stays ready to type into meanwhile.
    func testACrossTabPickDropsKeysUntilTheTabShows() async throws {
        for place in [HerdrPlace.pane("w1:p4"), .tab("t2")] {
            let harness = await makeHarness()
            let session = try await shownTab(harness, secondTab: Self.secondTab)
            var index = session.next
            let adapter = harness.model.terminalScreenAdapter

            XCTAssertTrue(harness.model.reveal(place, bootID: "boot"))
            XCTAssertEqual(adapter.sendInputToFocusedSurface("s"), .transportUnavailable, "\(place)")
            XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable, "\(place)")
            let focused = place == .tab("t2") ? "w1:p3" : "w1:p4"
            let step = try await nextWrite(session.bridge, from: &index) { write -> String? in
                if let focus = self.paneFocus(write) { return focus.id }
                if case .command(let id, "tab.focus", _) = write { return id }
                return nil
            }
            await session.bridge.serve(HerdrConnectionTests.reply(id: step, json: #"{"type":"ok"}"#))
            await session.bridge.serve(Self.secondTabOnScreen(revision: 2, focusedPane: focused))
            await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["three four"], panes: Self.drawn(Self.secondTab, focused: focused)))
            try await harness.waitUntil("Herdr didn't show the other tab for \(place)") {
                harness.model.screenPaneID == focused && harness.model.stateTraceLabel == "shown"
            }
            try await assertNoPaneInput(session.bridge, from: session.next, "a key went before the other tab showed for \(place)")
            XCTAssertEqual(adapter.sendInputToFocusedSurface("t"), .accepted)
            let sent7 = try await nextWrite(session.bridge, from: &index, paneInput)
            XCTAssertEqual(sent7, frame(focused, [typed("t")]))
        }
    }

    /// A tap on another pane whose program reads the mouse focuses it and clicks there, and the keys typed
    /// next go to it.
    func testKeysAfterATapClickGoToThePaneClicked() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness, mouseReporting: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let other = try paneSurfaceID(harness, "w1:p2")

        for action in GhosttySurfaceTapGesture.actions(
            forLocalPoint: try point(harness, column: 1),
            mouseCaptured: adapter.isMouseCaptured(for: other),
            showsKeyboard: false
        ) {
            switch action {
            case .activateInput, .focusPane: XCTAssertEqual(adapter.focusPane(other), .queued)
            case .mousePosition(let position): _ = adapter.sendMousePosition(to: other, position, mods: [])
            case .mouseButton(let event): XCTAssertEqual(adapter.sendMouseButton(to: other, event), .sent)
            }
        }
        XCTAssertEqual(adapter.sendInputToFocusedSurface("k"), .accepted)
        var inputs: [[UInt8]] = []
        for _ in 0..<4 {
            inputs.append(try await nextWrite(session.bridge, from: &index, paneInput))
        }
        XCTAssertEqual(inputs, [
            frame("w1:p2", [mouse(.moved, column: 1)]),
            frame("w1:p2", [mouse(.down(.left), column: 1)]),
            frame("w1:p2", [mouse(.up(.left), column: 1)]),
            frame("w1:p2", [typed("k")]),
        ])
    }

    private static let threePanes = ["w1:p1", "w1:p2", "w1:p3"]

    /// `panes` drawn side by side as `shownTab` draws them, `focused` focused.
    private static func drawn(_ panes: [String], focused: String) -> [HerdrServerScript.Pane] {
        panes.enumerated().map { HerdrServerScript.Pane(id: $1, x: UInt16($0 * 4), width: 3, height: 1, focused: $1 == focused) }
    }

    /// Herdr's answer to the focus `id`, then the snapshot and the frame showing `pane` focused in the tab
    /// of `threePanes`, which complete the move.
    private func showFocus(
        of pane: String,
        answering id: String,
        in bridge: FakeBridgeTransport,
        of harness: HerdrModelHarness,
        revision: UInt64
    ) async throws {
        await bridge.serve(HerdrConnectionTests.reply(id: id, json: #"{"type":"ok"}"#))
        await bridge.serve(HerdrServerScript.snapshot(revision: revision, focusedPane: pane, panes: Self.tabPanes(Self.threePanes)))
        await bridge.serve(try harness.shownSurface(
            projection: revision, revision: revision, lines: ["one two three"], panes: Self.drawn(Self.threePanes, focused: pane)
        ))
    }

    private static func scrollBegan(_ harness: HerdrModelHarness) -> GhosttySurfaceMouseScrollEvent {
        let cellHeight = Double(harness.model.measurement?.cellMetrics.pixelHeight ?? 1)
        return GhosttySurfaceMouseScrollEvent(deltaX: 0, deltaY: 0.2 * cellHeight, mods: .init(precision: true, momentum: .began))
    }

    /// A session shown with panes `w1:p1` and `w1:p2`, both drawn, its snapshot focusing `focusedPane`;
    /// returns its bridge and the index of the first write after the show. A test that moves the focus
    /// types into the other pane, which takes input only once it has drawn.
    private func shownSession(
        _ harness: HerdrModelHarness,
        focusedPane: String = "w1:p1",
        mouseReporting: Bool = false,
        takingRightClicks: Set<String> = [],
        otherTabs: [String] = []
    ) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await harness.bridge()
        let snapshotPanes = ["w1:p1", "w1:p2"].map {
            HerdrServerScript.snapshotPane($0, rightClickPassthrough: takingRightClicks.contains($0))
        }
        await bridge.serve(
            try HerdrServerScript.welcome()
                + HerdrServerScript.snapshot(revision: 1, otherTabs: otherTabs, focusedPane: focusedPane, panes: snapshotPanes)
        )
        let panes: [HerdrServerScript.Pane] = [
            .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true, mouseReporting: mouseReporting),
            .init(id: "w1:p2", x: 4, width: 3, height: 1, mouseReporting: mouseReporting),
        ]
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one two"], panes: panes))
        harness.setScreenSize()
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 2, lines: ["one two"], panes: panes))
        try await harness.waitUntil("the panes' renderers weren't created") {
            harness.model.paneSurface("w1:p1") != nil && harness.model.paneSurface("w1:p2") != nil
        }
        let paneIDs = panes.map(\.id)
        showInWindow(harness, panes: paneIDs)
        try await harness.waitUntil("the panes didn't draw") {
            paneIDs.allSatisfy { harness.model.presentation(ofPane: $0) == .ready }
        }
        try await harness.waitUntil("input wasn't offered") { harness.model.isInputAvailable }
        return (bridge, index)
    }

    /// A pane is ready once its renderer has drawn into a window, as on the screen.
    private func showInWindow(_ harness: HerdrModelHarness, panes: [String]) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        for paneID in panes {
            if let view = harness.model.paneSurface(paneID)?.renderer.view {
                viewController.view.addSubview(view)
            }
        }
        window.isHidden = false
        windows.append(window)
    }

    /// The next write from `index` on that `match` takes, skipping others; `index` moves past it.
    private func nextWrite<Value>(
        _ bridge: FakeBridgeTransport,
        from index: inout Int,
        _ match: (ClientWrite) -> Value?
    ) async throws -> Value {
        while true {
            let write = try ClientWrite.decode(try await bridge.written(index))
            index += 1
            if let value = match(write) { return value }
        }
    }

    private func paneInput(_ write: ClientWrite) -> [UInt8]? {
        if case .paneInput(let frame) = write { frame } else { nil }
    }

    private func ping(_ write: ClientWrite) -> String? {
        if case .ping(let data) = write { data } else { nil }
    }

    private func paneFocus(_ write: ClientWrite) -> (id: String, paneID: String)? {
        if case .paneFocus(let id, let paneID) = write { (id, paneID) } else { nil }
    }

    private func frame(_ paneID: String, _ events: [HerdrInputEvent]) -> [UInt8] {
        HerdrClientMessage.paneInput(paneID: paneID, events: events).frame
    }

    private func typed(_ character: Unicode.Scalar) -> HerdrInputEvent {
        .key(HerdrKeyEvent(code: .character(character), generatedText: String(character)))
    }

    /// A reconnect replaces the connection, not the panes: the last frame stays until the new
    /// connection's first, which the same server boot paints into the same terminals.
    func testAReconnectKeepsTheLastFrameUntilTheNewConnectionsFirst() async throws {
        let harness = await makeHarness()
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await first.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: panes))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let renderer = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer)

        harness.model.reconnect()
        let second = try await harness.bridge(1)
        try await harness.waitUntil("the first connection wasn't closed") { await first.isClosed }
        XCTAssertEqual(harness.shownRows(), ["w1:p1": ["one"]])
        XCTAssertTrue(harness.model.paneSurface("w1:p1")?.renderer === renderer)

        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await second.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["two"], panes: panes))
        try await harness.waitUntil("the new connection's frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["two"]]
        }
        XCTAssertTrue(harness.model.paneSurface("w1:p1")?.renderer === renderer)
        XCTAssertFalse(harness.model.isDisconnected)
    }

    /// A restarted server paints its panes into new terminals. A pane it names as before stays the same
    /// leaf, as when a pane's terminal is replaced: its old surface stays on screen while the new renderer
    /// is admitted and draws its first picture, then the new boot's frame goes on screen, the leaf finds the
    /// new surface, and the old one closes.
    func testAPaneOfARestartedServerStaysTheSameLeafWithANewSurface() async throws {
        let gate = RendererFenceGate()
        let harness = await makeHarness(rendererFenceGate: gate)
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-1"))
        await first.serve(HerdrServerScript.surface(
            boot: "boot-1", projection: 1, revision: 1, lines: ["one"], panes: panes
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let adapter = harness.model.terminalScreenAdapter
        let lookup = adapter.terminalManagedSurfaceLookup
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let firstSurface = try XCTUnwrap(lookup.managedSurface(for: id))
        let container = GhosttyPaneScrollContainerView()
        _ = container.update(
            surface: firstSurface,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        XCTAssertNotNil(firstSurface.view.superview)

        gate.holdsRegistrations = true
        harness.model.reconnect()
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-2"))
        await second.serve(try harness.shownSurface(
            boot: "boot-2", projection: 1, revision: 1, lines: ["two"], panes: panes
        ))
        try await harness.waitUntil("the new boot's renderer wasn't waiting on its registration") {
            gate.heldRegistrationCount == 1
        }
        XCTAssertEqual(harness.model.layout?.bootID, "boot-1", "the new boot's frame went on screen before its pane drew")
        XCTAssertTrue(lookup.managedSurface(for: id) === firstSurface)
        XCTAssertNotNil(firstSurface.view.superview)

        gate.releaseRegistrations()
        try await harness.waitUntil("the restarted server's frame wasn't shown") {
            harness.model.layout?.bootID == "boot-2" && harness.shownRows() == ["w1:p1": ["two"]]
        }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID, id)
        let secondSurface = try XCTUnwrap(lookup.managedSurface(for: id))
        XCTAssertFalse(secondSurface === firstSurface)
        XCTAssertEqual(secondSurface.id, id)
        XCTAssertNil(firstSurface.view.superview)
        XCTAssertNil(firstSurface.onScrollStateChange)
        _ = container.update(
            surface: secondSurface,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        XCTAssertNotNil(secondSurface.view.superview)
        XCTAssertNotNil(secondSurface.onScrollStateChange)
    }

    /// When Ghostty can't paint a restarted server's pane into its new terminal, the pane keeps its old
    /// surface, failed: the screen still finds it under the pane's leaf, and nothing can be typed.
    func testAPaneOfARestartedServerWhoseNewTerminalFailsKeepsItsOldSurfaceFailed() async throws {
        let producerFailure = ProducerFailure()
        let harness = await makeHarness(producerFailure: producerFailure)
        let first = try await harness.bridge(0)
        let panes: [HerdrServerScript.Pane] = [.init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true)]
        await first.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-1"))
        await first.serve(HerdrServerScript.surface(
            boot: "boot-1", projection: 1, revision: 1, lines: ["one"], panes: panes
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the first frame wasn't shown") {
            harness.shownRows() == ["w1:p1": ["one"]]
        }
        let model = harness.model
        let adapter = model.terminalScreenAdapter
        let id = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        let oldSurface = try XCTUnwrap(adapter.terminalManagedSurfaceLookup.managedSurface(for: id))

        producerFailure.isOn = true
        model.reconnect()
        let second = try await harness.bridge(1)
        await second.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-2"))
        await second.serve(HerdrServerScript.surface(
            boot: "boot-2", projection: 1, revision: 1, lines: ["two"], panes: panes
        ))
        try await harness.waitUntil("the new boot's pane didn't fail") {
            guard model.layout?.bootID == "boot-2", case .failed = model.presentation(ofPane: "w1:p1") else {
                return false
            }
            return true
        }

        let shownID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.focusedSurfaceID)
        XCTAssertEqual(shownID, id)
        XCTAssertTrue(adapter.terminalManagedSurfaceLookup.managedSurface(for: shownID) === oldSurface)
        XCTAssertFalse(model.isInputAvailable)
    }

    /// A hidden session's renderer gets its screen surface when admitted, hidden and unfocused, and its
    /// pane stays pending: being made early neither shows the pane nor takes input.
    func testAHiddenSessionsPaneGetsItsSurfaceHiddenAndStaysPending() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1))
        await bridge.serve(HerdrServerScript.surface(
            projection: 1,
            revision: 1,
            lines: ["left 1"],
            panes: [.init(id: "w1:p1", x: 0, width: 6, height: 1, focused: true)]
        ))
        harness.setScreenSize()
        try await harness.waitUntil("the pane's renderer wasn't created") {
            harness.model.paneSurface("w1:p1") != nil
        }

        let managed = try XCTUnwrap(harness.model.paneSurface("w1:p1")?.renderer.managedSurface)
        XCTAssertFalse(managed.isVisible)
        XCTAssertFalse(managed.isFocused)
        XCTAssertFalse(managed.rendererIsAvailable)
        XCTAssertEqual(harness.model.presentation(ofPane: "w1:p1"), .pending)
        XCTAssertFalse(harness.model.isInputAvailable)
    }

    // MARK: - Notifications and bells

    private static let notification = HerdrServerScript.notification(
        .needsAttention,
        title: "claude needs attention",
        body: "w1 · 1 · build",
        agent: "claude",
        workspace: "w1",
        tab: "t2",
        pane: "w1:p3"
    )

    /// Herdr sends its notifications to every connection, so a session that isn't on screen hands them
    /// on with the server boot their pane ids belong to and the names of their workspace and tab; a
    /// reconnect to a restarted server says so.
    func testAHiddenSessionHandsOnItsNotificationsAndAServerRestart() async throws {
        let harness = await makeHarness()
        let bridge = try await connectedSession(harness, lines: ["one"])
        await bridge.serve(HerdrServerScript.snapshot(revision: 2, workspaceLabel: "remux", otherTabs: ["t2"]))

        await bridge.serve(Self.notification)
        try await harness.waitUntil("the notification wasn't handed on") { !harness.stateLog.notifications.isEmpty }
        guard case .received(let notification, let bootID, let place)? = harness.stateLog.notifications.first else {
            return XCTFail("expected a notification, got \(harness.stateLog.notifications)")
        }
        XCTAssertEqual(notification.title, "claude needs attention")
        XCTAssertEqual(notification.paneID, "w1:p3")
        XCTAssertEqual(bootID, "boot")
        XCTAssertEqual(place, HerdrNotificationPlace(workspace: "remux", tab: "t2"))

        XCTAssertTrue(harness.model.reconnect())
        let restarted = try await harness.bridge(1)
        await restarted.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(revision: 1, boot: "boot-2"))
        try await harness.waitUntil("the restart wasn't reported") {
            harness.stateLog.notifications.last == .serverRestarted
        }
        XCTAssertEqual(harness.stateLog.notifications.count, 2)
    }

    /// What the notification rules read: the snapshot's focused tab, whether the session is shown, and
    /// each agent's status as this phone shows it. An agent that finished work while its pane was off
    /// screen reads as done, from Herdr's record of the completion.
    func testTheNotificationStateFollowsTheSnapshotAndHerdrsCompletions() async throws {
        let harness = await makeHarness()
        let bridge = try await connectedSession(harness, lines: ["one"])
        await bridge.serve(
            HerdrServerScript.snapshot(revision: 2, otherTabs: ["t2"], agents: [
                HerdrServerScript.snapshotAgent("w1:p3", tab: "t2", status: .working, stateChange: 3),
            ])
                + HerdrServerScript.agentCompletions(revision: 3, ["w1:p3": 4])
                + HerdrServerScript.snapshot(revision: 3, otherTabs: ["t2"], agents: [
                    HerdrServerScript.snapshotAgent("w1:p3", tab: "t2", status: .idle, stateChange: 4),
                ])
        )
        try await harness.waitUntil("the finished agent didn't read as done") {
            harness.model.notificationState?.agentStatuses["w1:p3"] == .done
        }
        XCTAssertEqual(harness.model.notificationState?.focusedTabID, "t1")
        XCTAssertEqual(harness.model.notificationState?.focusedWorkspaceID, "w1")
        XCTAssertEqual(harness.model.notificationState?.isShown, false)
        harness.model.setSelected(true)
        XCTAssertEqual(harness.model.notificationState?.isShown, true)
    }

    private static let shownPanes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 3, height: 1),
    ]
    /// The same panes with `w1:p2` narrower, so the frame's layout shows when it has been taken.
    private static let narrowedPanes: [HerdrServerScript.Pane] = [
        .init(id: "w1:p1", x: 0, width: 3, height: 1, focused: true),
        .init(id: "w1:p2", x: 4, width: 2, height: 1),
    ]

    /// Agent `w1:p2` working at revision 2 with its frame on screen, then finished at revision 3.
    private func finishOnScreen(
        _ harness: HerdrModelHarness,
        _ bridge: FakeBridgeTransport,
        finishedFrame: Bool
    ) async throws {
        let workingFrame = try harness.shownSurface(projection: 2, revision: 3, lines: ["one two"], panes: Self.shownPanes)
        let finished = try harness.shownSurface(projection: 3, revision: 4, lines: ["one tw"], panes: Self.narrowedPanes)
        await bridge.serve(
            HerdrServerScript.snapshot(revision: 2, agents: [
                HerdrServerScript.snapshotAgent("w1:p2", status: .working, stateChange: 3),
            ])
                + workingFrame
                + HerdrServerScript.agentCompletions(revision: 3, ["w1:p2": 4])
                + HerdrServerScript.snapshot(revision: 3, agents: [
                    HerdrServerScript.snapshotAgent("w1:p2", status: .idle, stateChange: 4),
                ])
                + (finishedFrame ? finished : [])
        )
        if finishedFrame {
            // The frame's layout follows the frame's acknowledgement, so it is in once the layout is.
            try await harness.waitUntil("the finished agent's frame didn't arrive") {
                harness.model.layout?.panes.first { $0.paneID == "w1:p2" }?.innerRect?.width == 2
            }
        } else {
            try await harness.waitUntil("the finished agent's snapshot didn't arrive") {
                [.done, .idle].contains(harness.model.notificationState?.agentStatuses["w1:p2"])
            }
        }
    }

    /// An agent whose pane is on screen in a frame drawn after it finished has been seen, so it reads as
    /// idle, as in Herdr's client.
    func testAnAgentFinishingOnScreenReadsAsSeen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        try await finishOnScreen(harness, session.bridge, finishedFrame: true)
        XCTAssertEqual(harness.model.notificationState?.agentStatuses["w1:p2"], .idle)
    }

    /// Only a frame drawn against the newest snapshot shows its agents, as Herdr's client checks: when an
    /// agent finishes as the user goes to another tab, the frame still on screen is the old tab's, and the
    /// new tab's frame doesn't show the agent, so it stays done.
    func testAnOlderFrameStillOnScreenDoesNotSeeANewerSnapshot() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        try await finishOnScreen(harness, session.bridge, finishedFrame: false)
        XCTAssertEqual(harness.model.notificationState?.agentStatuses["w1:p2"], .done)

        let otherTab = try harness.shownSurface(
            projection: 4,
            revision: 4,
            lines: ["three"],
            panes: [.init(id: "w1:p3", x: 0, width: 5, height: 1, focused: true)]
        )
        await session.bridge.serve(
            HerdrServerScript.snapshot(revision: 4, focusedTab: "t2", focusedPane: "w1:p3", closed: ["w1:p4"], agents: [
                HerdrServerScript.snapshotAgent("w1:p2", status: .idle, stateChange: 4),
            ])
                + otherTab
        )
        try await harness.waitUntil("the other tab's frame didn't arrive") {
            harness.model.layout?.panes.map(\.paneID) == ["w1:p3"]
        }
        XCTAssertEqual(harness.model.notificationState?.agentStatuses["w1:p2"], .done)
    }

    /// Back in front, the user sees the frame on screen, as Herdr's client acknowledges its surface when
    /// its terminal regains focus: a completion drawn while the app was inactive counts as seen then.
    func testComingBackToTheAppSeesTheFrameOnScreen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        harness.model.handleAppLifecyclePhase(.inactive)
        try await finishOnScreen(harness, session.bridge, finishedFrame: true)
        XCTAssertEqual(harness.model.notificationState?.agentStatuses["w1:p2"], .done)

        harness.model.handleAppLifecyclePhase(.active)
        XCTAssertEqual(harness.model.notificationState?.agentStatuses["w1:p2"], .idle)
    }

    // MARK: - Agents in the sheets

    /// The session's agents follow its snapshots, placed by the snapshot's workspace and tab names.
    func testTheSessionsAgentsFollowItsSnapshots() async throws {
        let harness = await makeHarness()
        let bridge = try await connectedSession(harness, lines: ["one"])
        func snapshot(_ revision: UInt64, cwd: String, status: HerdrAgentStatus) -> [UInt8] {
            HerdrServerScript.snapshot(
                revision: revision,
                workspaceLabel: "remux",
                otherTabs: ["t2"],
                panes: [HerdrServerScript.snapshotPane("w1:p1", cwd: cwd), HerdrServerScript.snapshotPane("w1:p3", tab: "t2")],
                agents: [HerdrServerScript.snapshotAgent(
                    "w1:p3",
                    agent: "claude",
                    tab: "t2",
                    status: status,
                    stateChange: status == .working ? 2 : 4
                )]
            )
        }
        await bridge.serve(snapshot(2, cwd: "/src", status: .working))
        try await harness.waitUntil("the working agent didn't show") {
            harness.model.agents.state(ofPane: "w1:p3")?.status == .working
        }

        await bridge.serve(snapshot(3, cwd: "/src/app", status: .working) + snapshot(4, cwd: "/src/app", status: .blocked))
        try await harness.waitUntil("the blocked agent didn't show") {
            harness.model.agents.state(ofPane: "w1:p3")?.status == .blocked
        }
        let agents = harness.model.agents
        XCTAssertEqual(agents.agents.map(\.place), ["remux › t2"])
        XCTAssertEqual(agents.bootID, "boot")
        XCTAssertEqual(agents.status(ofTab: "t2"), .blocked)
        XCTAssertNil(agents.status(ofTab: "t1"))
    }

    /// The tab sheet's tile shows the tab's most urgent agent and the pane sheet's tile its pane's agent;
    /// a pane without an agent shows none.
    func testThePaneAndTabTilesShowTheirAgents() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, agents: [
            HerdrServerScript.snapshotAgent("w1:p2", status: .working, stateChange: 2),
        ]))
        try await harness.waitUntil("the agent wasn't shown") { harness.model.agents.status != nil }

        let adapter = harness.model.terminalScreenAdapter
        let window = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).windows.first)
        XCTAssertEqual(window.agentStatus, .working)
        let panes = adapter.paneSelectionSheetRenderProjection(topLevelID: window.id).panes
        XCTAssertEqual(panes.map(\.agent), [nil, TerminalAgentState(.working)])
    }

    /// A tab that isn't on screen shows its most urgent agent on its tile as well.
    func testATabNotOnScreenShowsItsAgentOnItsTile() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            workspaceLabel: "remux",
            otherTabs: ["t2"],
            panes: [HerdrServerScript.snapshotPane("w1:p1"), HerdrServerScript.snapshotPane("w1:p3", tab: "t2")],
            agents: [HerdrServerScript.snapshotAgent("w1:p3", tab: "t2", status: .blocked, stateChange: 2)]
        ))
        try await harness.waitUntil("the agent wasn't shown") { harness.model.agents.status(ofTab: "t2") != nil }

        let windows = harness.model.terminalScreenAdapter.windowSelectionSheetRenderProjection(group: nil).windows
        XCTAssertEqual(windows.map(\.agentStatus), [nil, .blocked])
    }

    /// The Tabs sheet's rows say what each tab holds. The tab on screen's row puts Herdr's focused pane in
    /// front, here a shell, by the folder its program is in; another tab's row puts its most urgent agent's
    /// pane in front, with what the agent says it is doing, then two of its other panes; a tab without
    /// agents shows its first pane, by its name. Each row names its tab as the user did, and shows its most
    /// urgent agent: work as a spinner, other states as a dot. When Herdr's focus moves to the agent, the row
    /// on screen follows.
    func testTheTabsSheetsRowsSayWhatEachTabHolds() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let panes = [
            HerdrServerScript.snapshotPane("w1:p1", cwd: "/home/me/remux", foregroundCWD: "/home/me/remux/app"),
            HerdrServerScript.snapshotPane("w1:p2"),
            HerdrServerScript.snapshotPane("w1:p3", tab: "t2", label: "logs"),
            HerdrServerScript.snapshotPane("w1:p4", tab: "t2"),
            HerdrServerScript.snapshotPane("w1:p6", tab: "t2"),
            HerdrServerScript.snapshotPane("w1:p7", tab: "t2"),
            HerdrServerScript.snapshotPane("w1:p5", tab: "t3", label: "server", cwd: "/srv"),
        ]
        let agents = [
            HerdrServerScript.snapshotAgent("w1:p2", terminalTitleStripped: "Fix the tests", agent: "claude", stateChange: 2),
            HerdrServerScript.snapshotAgent(
                "w1:p4", terminalTitleStripped: "codex | Review the diff", agent: "codex", tab: "t2", status: .blocked,
                stateChange: 2
            ),
            HerdrServerScript.snapshotAgent("w1:p6", terminalTitleStripped: "Draft", agent: "opencode", tab: "t2", stateChange: 2),
        ]
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2, workspaceLabel: "remux", otherTabs: ["t2", "t3"], panes: panes, agents: agents
        ))
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the tabs' rows weren't listed") {
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.compactMap(\.contents).count == 3
        }

        let windows = adapter.windowSelectionSheetRenderProjection(group: nil).windows
        XCTAssertEqual(windows.map(\.contents), [
            .init(name: "main", programs: [.terminal, .agent("claude")], activity: "app"),
            .init(name: "t2", programs: [.agent("codex"), .terminal, .agent("opencode")], activity: "codex | Review the diff"),
            .init(name: "t3", programs: [.terminal], activity: "server"),
        ])
        XCTAssertEqual(windows.map(\.rowAgentMark), [.spinner, .dot(.blocked), nil])

        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3, workspaceLabel: "remux", otherTabs: ["t2", "t3"], focusedPane: "w1:p2", panes: panes,
            agents: agents
        ))
        try await harness.waitUntil("the row on screen didn't follow Herdr's focus") {
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.first?.contents
                == .init(name: "main", programs: [.agent("claude"), .terminal], activity: "Fix the tests")
        }
    }

    /// Herdr's labels remain even without a custom-name flag, on and off the current workspace. A missing
    /// pane description leaves only the tab label, with no duplicate program identity.
    func testTheTabsSheetsRowsKeepHerdrsLabelsWithoutSynthesizingDescriptions() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        await session.bridge.serve(Self.twoWorkspaces(revision: 2, customTabLabels: false, agents: [
            HerdrServerScript.snapshotAgent("w1:p4", agent: "claude-code", tab: "t2", status: .idle),
            HerdrServerScript.snapshotAgent("w2:p7", title: "Plan the release", agent: "pi", workspace: "w2", tab: "t4"),
        ]))
        let adapter = harness.model.terminalScreenAdapter
        try await harness.waitUntil("the tabs' agent metadata wasn't projected") {
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.dropFirst().first?.contents?.programs.first
                == .agent("claude")
        }

        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection(group: nil).windows.map(\.contents), [
            .init(name: "t1", programs: [.terminal, .terminal], activity: ""),
            .init(name: "t2", programs: [.agent("claude"), .terminal], activity: ""),
        ])
        let beta = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).grouping?.groups[1].id)
        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection(group: beta).windows.map(\.contents), [
            .init(name: "t3", programs: [.terminal], activity: ""),
            .init(name: "t4", programs: [.agent("pi"), .terminal], activity: "Plan the release"),
        ])
    }

    /// A nonfocused pane's label is visible in the map even though it is not the tab row's description.
    func testRenamingAnUnfocusedPaneTellsTheOpenMap() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        let tab = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).windows.first?.id)
        func names() -> [String] {
            adapter.paneSelectionSheetRenderProjection(topLevelID: tab).panes.compactMap { $0.renameField?.name }
        }
        var changes = 0
        let watch = adapter.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 2, panes: [
            HerdrServerScript.snapshotPane("w1:p1"),
            HerdrServerScript.snapshotPane("w1:p2", label: "logs"),
        ]))
        try await harness.waitUntil("the pane's manual name wasn't projected") { names() == ["", "logs"] }
        XCTAssertEqual(changes, 1)
        await session.bridge.serve(HerdrServerScript.snapshot(revision: 3, panes: [
            HerdrServerScript.snapshotPane("w1:p1"),
            HerdrServerScript.snapshotPane("w1:p2"),
        ]))
        try await harness.waitUntil("the pane's cleared name wasn't projected") { names() == ["", ""] }
        XCTAssertEqual(changes, 2)
    }

    /// A snapshot that changes what a tab's row says tells the views: an agent naming its thread anew, a shell
    /// moving to another folder. Raw spinner changes that Herdr excludes from its stripped title do not
    /// update the row, nor does a new title of an agent whose pane no row puts in front.
    func testATabsRowTellsTheViewsOnlyWhenWhatItSaysChanges() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        func serve(
            _ revision: UInt64, folder: String = "app", claude: String = "Fix the tests", blink: String = "!",
            thread: String = "Review the diff", spinner: String = "⠋"
        ) async {
            let waiting = "[ \(blink) ] Action Required | codex | \(thread)"
            await session.bridge.serve(HerdrServerScript.snapshot(
                revision: revision,
                workspaceLabel: "remux",
                otherTabs: ["t2", "t3"],
                panes: [
                    HerdrServerScript.snapshotPane("w1:p1", cwd: "/home/me", foregroundCWD: "/home/me/\(folder)"),
                    HerdrServerScript.snapshotPane("w1:p2"),
                    HerdrServerScript.snapshotPane("w1:p3", tab: "t2"),
                    HerdrServerScript.snapshotPane("w1:p5", tab: "t3"),
                ],
                agents: [
                    HerdrServerScript.snapshotAgent(
                        "w1:p2", terminalTitle: "✳ \(claude)", terminalTitleStripped: claude, agent: "claude",
                        stateChange: 2
                    ),
                    HerdrServerScript.snapshotAgent(
                        "w1:p3", terminalTitle: waiting, terminalTitleStripped: waiting, agent: "codex", tab: "t2",
                        status: .blocked, stateChange: 2
                    ),
                    HerdrServerScript.snapshotAgent(
                        "w1:p5", terminalTitle: "\(spinner) codex | Plan the release",
                        terminalTitleStripped: "codex | Plan the release", agent: "codex", tab: "t3", stateChange: 2
                    ),
                ]
            ))
        }
        let adapter = harness.model.terminalScreenAdapter
        func activities() -> [String?] {
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.map { $0.contents?.activity }
        }
        await serve(2)
        try await harness.waitUntil("the tabs' rows weren't listed") {
            activities() == ["app", "[ ! ] Action Required | codex | Review the diff", "codex | Plan the release"]
        }

        var screenChanges = 0
        let watch = adapter.objectWillChange.sink { screenChanges += 1 }
        defer { watch.cancel() }
        await serve(3, claude: "Fix the flaky test", spinner: "⠙")
        await serve(4, claude: "Fix the flaky test", thread: "Review the fix", spinner: "⠹")
        try await harness.waitUntil("the agent's new thread didn't reach its row") {
            activities() == ["app", "[ ! ] Action Required | codex | Review the fix", "codex | Plan the release"]
        }
        XCTAssertEqual(screenChanges, 1, "a ticking title or a pane no row shows told the views")

        await serve(
            5, folder: "docs", claude: "Fix the flaky test", thread: "Review the fix", spinner: "⠸"
        )
        try await harness.waitUntil("the shell's new folder didn't reach its row") {
            activities() == ["docs", "[ ! ] Action Required | codex | Review the fix", "codex | Plan the release"]
        }
        XCTAssertEqual(screenChanges, 2)
    }

    /// A tab shows its agent done until a frame drawn after it finished shows the agent's pane, as Herdr's
    /// client rolls its tabs up from the statuses it shows.
    func testATabShowsItsAgentDoneUntilItsPaneIsSeen() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        try await finishOnScreen(harness, session.bridge, finishedFrame: false)
        XCTAssertEqual(harness.model.agents.status(ofTab: "t1"), .done)

        await session.bridge.serve(
            try harness.shownSurface(projection: 3, revision: 4, lines: ["one tw"], panes: Self.narrowedPanes)
        )
        try await harness.waitUntil("the finished agent's frame wasn't seen") {
            harness.model.agents.status(ofTab: "t1") == .idle
        }
    }

    /// Each bell Herdr rings in the session on screen is handed on; one that comes after the session left
    /// the screen isn't.
    func testABellInTheSessionOnScreenIsHandedOn() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let bells = { harness.stateLog.notifications.filter { $0 == .bell }.count }

        await session.bridge.serve(HerdrServerScript.bell())
        try await harness.waitUntil("the bell wasn't handed on") { bells() == 1 }
        await session.bridge.serve(HerdrServerScript.bell(count: 2))
        try await harness.waitUntil("the second bell wasn't handed on") { bells() == 2 }

        harness.model.setSelected(false)
        await session.bridge.serve(HerdrServerScript.bell())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(bells(), 2, "a hidden session handed on a bell")
    }

    /// A bell Herdr rang just before the app went to the background, taken by the model only after it did,
    /// isn't handed on, so the phone doesn't vibrate for it: the session is no longer on screen.
    func testABellTakenAfterTheAppWentToTheBackgroundIsntHandedOn() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)

        await session.bridge.serve(HerdrServerScript.bell())
        // Holding the main actor lets the connection hand the bell on while the session is still shown,
        // and keeps the model from taking it until the app has gone to the background.
        usleep(300_000)
        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(harness.stateLog.notifications.contains(.bell), "a bell was handed on in the background")
    }

    /// A program's copy in the session on screen goes on the iPhone clipboard and the copy notice shows, as
    /// in Herdr's client: only for a write that went in and wasn't already there, never for a payload that
    /// isn't base64 or isn't text, and not after the session left the screen.
    func testAProgramsCopyInTheSessionOnScreenReachesTheClipboard() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)
        let adapter = harness.model.terminalScreenAdapter
        func copy(_ text: String) -> [UInt8] {
            HerdrServerScript.clipboard(Data(text.utf8).base64EncodedString())
        }

        await session.bridge.serve(copy("copied text"))
        try await harness.waitUntil("the copy didn't reach the clipboard") {
            harness.pasteboard.writes == ["copied text"]
        }
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.statusOverlay, .notice(HerdrScreenModel.copiedNotice))

        await session.bridge.serve(copy("copied text"))
        await session.bridge.serve(HerdrServerScript.clipboard("not base64!"))
        await session.bridge.serve(HerdrServerScript.clipboard(Data([0xff, 0xfe]).base64EncodedString()))
        await session.bridge.serve(copy("next"))
        try await harness.waitUntil("the next copy didn't reach the clipboard") {
            harness.pasteboard.writes.count == 2
        }
        XCTAssertEqual(harness.pasteboard.writes, ["copied text", "next"])

        harness.model.setSelected(false)
        await session.bridge.serve(copy("hidden"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.pasteboard.writes, ["copied text", "next"], "a hidden session wrote the clipboard")
    }

    /// A copy Herdr sent just before the app went to the background, taken by the model only after it
    /// did, isn't written: the session is no longer on screen.
    func testACopyTakenAfterTheAppWentToTheBackgroundIsntWritten() async throws {
        let harness = await makeHarness()
        let session = try await shownSession(harness)

        await session.bridge.serve(HerdrServerScript.clipboard(Data("late copy".utf8).base64EncodedString()))
        // Holding the main actor lets the connection hand the copy on while the session is still shown,
        // and keeps the model from taking it until the app has gone to the background.
        usleep(300_000)
        harness.model.handleAppLifecyclePhase(.background)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.pasteboard.writes, [], "a copy was written after the app went to the background")
        XCTAssertNotEqual(
            harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.statusOverlay,
            .notice(HerdrScreenModel.copiedNotice)
        )
    }

    /// A hidden session asked to go to a pane in another tab asks Herdr to focus it right after the show,
    /// as Herdr's client sends `pane.focus` with the activation; Herdr then shows the pane's tab.
    func testARevealedPaneIsFocusedRightAfterTheShow() async throws {
        let harness = await makeHarness()
        let bridge = try await revealableSession(harness)

        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        try await Task.sleep(for: .milliseconds(100))
        let whileHidden = await bridge.writtenCount
        harness.model.setSelected(true)
        var index = whileHidden
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertTrue(show.active)
        let focus = try await nextWrite(bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
        for write in try await harness.writes(bridge, count: whileHidden) {
            XCTAssertNil(paneFocus(write), "a pane was focused while hidden")
        }
    }

    /// A pane is gone to only on the server boot its id came from, and only while it exists; on the
    /// session on screen it is gone to at once.
    func testARevealGoesOnlyToAPaneThatStillExists() async throws {
        let harness = await makeHarness()
        let bridge = try await revealableSession(harness)

        harness.model.reveal(.pane("w1:p3"), bootID: "old-boot")
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        harness.model.reveal(.pane("w1:gone"), bootID: "boot")
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        let focus = try await nextWrite(bridge, from: &index, paneFocus)
        XCTAssertEqual(focus.paneID, "w1:p3")
        await bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        try await Task.sleep(for: .milliseconds(100))
        let written = await bridge.writtenCount
        for write in try await harness.writes(bridge, from: index, count: written - index) {
            XCTAssertNil(paneFocus(write), "another pane was focused")
        }
    }

    /// A pane asked for belongs to the show it was asked for: a session left before it could be shown
    /// doesn't go there on a later show.
    func testARevealIsForgottenWhenTheSessionIsLeftFirst() async throws {
        let harness = await makeHarness()
        harness.model.reveal(.pane("w1:p3"), bootID: "boot")
        harness.model.setSelected(true)
        harness.model.setSelected(false)
        let bridge = try await revealableSession(harness)

        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertTrue(show.active)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        try await Task.sleep(for: .milliseconds(150))
        let written = await bridge.writtenCount
        for write in try await harness.writes(bridge, from: index, count: written - index) {
            XCTAssertNil(paneFocus(write), "a forgotten pane was focused")
        }
    }

    /// A hidden, connected session whose snapshot has pane `w1:p1` in tab `t1` and `w1:p3` in tab `t2`.
    private func revealableSession(_ harness: HerdrModelHarness) async throws -> FakeBridgeTransport {
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + HerdrServerScript.snapshot(
            revision: 1,
            otherTabs: ["t2"],
            panes: [HerdrServerScript.snapshotPane("w1:p1"), HerdrServerScript.snapshotPane("w1:p3", tab: "t2")]
        ))
        await bridge.serve(HerdrServerScript.surface(projection: 1, revision: 1, lines: ["one"], panes: Self.onePane))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }
        return bridge
    }
}

// MARK: - Tabs and workspaces

extension HerdrScreenModelTests {
    /// A tab tile goes to its tab with `tab.focus`, as Herdr's client goes to a tab it shows, the same way
    /// as a move to a pane: the tab left keeps Remux's zoom, and once Herdr has answered and the tab is on
    /// screen the setting zooms it.
    func testATabTileMovesWithTabFocusAndZoomsTheTabItShows() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownWorkspaces(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let tile = try XCTUnwrap(
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.first { $0.displayName == "t2" }
        )

        XCTAssertEqual(adapter.focusTopLevel(tile.id), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(index, session.next + 1, "something went before the tab's focus")
        XCTAssertEqual(focus.method, "tab.focus")
        XCTAssertEqual(focus.params, ["tab_id": "t2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.twoWorkspaces(revision: 4, focusedTab: "t2", focusedPane: "w1:p3"))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
    }

    /// A workspace goes with `workspace.focus`, as Herdr's client switches workspaces, to the tab this
    /// phone has there, and that tab gets the setting's zoom once it is on screen.
    func testAWorkspaceMovesWithWorkspaceFocusAndZoomsTheTabItShows() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownWorkspaces(harness, zoomingOnShow: true)
        var index = session.next

        harness.model.reveal(.workspace("w2"), bootID: "old-boot")
        try await Task.sleep(for: .milliseconds(100))
        let written = await session.bridge.writtenCount
        for write in try await harness.writes(session.bridge, from: index, count: written - index) {
            XCTAssertFalse(isCommand(write), "a workspace of another boot went: \(write)")
        }
        harness.model.reveal(.workspace("w2"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(focus.method, "workspace.focus")
        XCTAssertEqual(focus.params, ["workspace_id": "w2"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.twoWorkspaces(revision: 4, focusedTab: "t4", focusedPane: "w2:p6"))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w2:p6", "on"])
    }

    /// As Herdr's client retargets a show in progress, a workspace picked while the session is still being
    /// shown takes the show over and goes at once, and a later pick takes it over in turn, going from where
    /// the workspace took the session.
    func testAWorkspacePickedDuringAShowTakesTheShowOver() async throws {
        let harness = await makeHarness()
        let bridge = try await hiddenWorkspaces(harness)
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)

        harness.model.reveal(.workspace("w2"), bootID: "boot")
        let focus = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(focus.method, "workspace.focus")
        XCTAssertEqual(focus.params, ["workspace_id": "w2"])
        XCTAssertTrue(harness.model.reveal(.tab("t3"), bootID: "boot"), "a later pick during the show was refused")

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await bridge.serve(Self.twoWorkspaces(revision: 2, focusedTab: "t4", focusedPane: "w2:p6"))
        let tab = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(tab.method, "tab.focus")
        XCTAssertEqual(tab.params, ["tab_id": "t3"])
    }

    /// A workspace picked during a show the session then left belongs to that show, as Herdr's client
    /// drops navigation left from an abandoned one: the next show doesn't go there.
    func testAWorkspacePickedDuringAShowIsDroppedWhenTheSessionLeaves() async throws {
        let harness = await makeHarness()
        let bridge = try await hiddenWorkspaces(harness)
        harness.model.setSelected(true)
        var index = 0
        _ = try await harness.nextSurfaceSet(bridge, from: &index)
        harness.model.reveal(.workspace("w2"), bootID: "boot")
        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(bridge, from: &index)

        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the session wasn't shown again") { harness.model.stateTraceLabel == "shown" }
        try await Task.sleep(for: .milliseconds(150))
        let written = await bridge.writtenCount
        for write in try await harness.writes(bridge, from: index, count: written - index) {
            XCTAssertNil(command(write), "the dropped workspace went: \(write)")
        }
    }

    /// A workspace picked in the Sessions sheet for a hidden session goes right behind its show, as Herdr's
    /// client opens a machine at a workspace.
    func testARevealedWorkspaceGoesRightAfterTheShow() async throws {
        let harness = await makeHarness()
        let bridge = try await hiddenWorkspaces(harness)

        harness.model.reveal(.workspace("w2"), bootID: "boot")
        harness.model.setSelected(true)
        var index = 0
        _ = try await harness.nextSurfaceSet(bridge, from: &index)
        let focus = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(focus.method, "workspace.focus")
        XCTAssertEqual(focus.params, ["workspace_id": "w2"])
    }

    /// New Tab goes in the workspace the Tabs sheet shows and New Workspace starts from it, each with the
    /// command Herdr's client sends, focused. The tab left keeps Remux's zoom.
    func testNewTabAndNewWorkspaceGoInTheWorkspaceTheSheetShows() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownWorkspaces(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let grouping = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).grouping)
        let beta = try XCTUnwrap(grouping.groups.first { $0.name == "beta" }).id

        XCTAssertEqual(adapter.createTopLevel(inGroup: beta), .queued)
        let tab = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(index, session.next + 1, "something went before the new tab")
        XCTAssertEqual(tab.method, "tab.create")
        XCTAssertEqual(tab.params, ["workspace_id": "w2", "focus": "true"])
        await session.bridge.serve(HerdrConnectionTests.reply(id: tab.id, json: #"{"type":"tab_created"}"#))

        XCTAssertEqual(adapter.createTopLevelGroup(from: nil), .queued)
        let workspace = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(workspace.method, "workspace.create")
        XCTAssertEqual(workspace.params, ["source_workspace_id": "w1", "focus": "true"])
    }

    /// A workspace the Tabs sheet showed that closes meanwhile gives way to the workspace on screen, for its
    /// tiles and its New Tab alike.
    func testTheSheetFallsBackToTheWorkspaceOnScreenWhenTheShownOneCloses() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let grouping = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).grouping)
        let beta = try XCTUnwrap(grouping.groups.first { $0.name == "beta" }).id

        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            workspaces: [.init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])])],
            focusedTab: "t1",
            focusedPane: "w1:p1"
        ))
        try await harness.waitUntil("beta didn't close") { harness.model.places.outline?.workspaces.count == 1 }
        XCTAssertEqual(adapter.windowSelectionSheetRenderProjection(group: beta).windows.map(\.displayName), ["t1", "t2"])
        XCTAssertEqual(adapter.createTopLevel(inGroup: beta), .queued)
        let tab = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(tab.method, "tab.create")
        XCTAssertEqual(tab.params, ["workspace_id": "w1", "focus": "true"])
    }

    /// The Tabs sheet lists the tabs of the workspace on screen, and the workspaces, the one on screen
    /// first. A workspace picked there lists its own tabs, none selected, with no preview but the tab on
    /// screen's, and the sheet keeps the height of the largest workspace.
    func testTheTabsSheetListsAWorkspacesTabsAndOffersTheOthers() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertEqual(adapter.terminalInteractionProjection.windowCount, 2)
        XCTAssertEqual(adapter.terminalInteractionProjection.selectedWindowIndex, 0)
        let onScreen = adapter.windowSelectionSheetRenderProjection(group: nil)
        XCTAssertEqual(onScreen.windows.map(\.displayName), ["t1", "t2"])
        XCTAssertEqual(onScreen.windows.map(\.isSelected), [true, false])
        XCTAssertEqual(onScreen.windows.map(\.paneCount), [2, 2])
        let grouping = try XCTUnwrap(onScreen.grouping)
        XCTAssertEqual(grouping.noun, .workspace)
        XCTAssertEqual(grouping.groups.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(grouping.shownGroupID, grouping.groups[0].id)
        XCTAssertEqual(grouping.largestWindowCount, 2)

        let other = adapter.windowSelectionSheetRenderProjection(group: grouping.groups[1].id)
        XCTAssertEqual(other.windows.map(\.displayName), ["t3", "t4"])
        XCTAssertEqual(other.windows.map(\.isSelected), [false, false])
        XCTAssertEqual(other.windows.map(\.paneCount), [1, 2])
        XCTAssertEqual(other.grouping?.shownGroupID, grouping.groups[1].id)
        XCTAssertEqual(other.previewLeafIDs, onScreen.previewLeafIDs)

        var index = session.next
        harness.model.reveal(.workspace("w2"), bootID: "boot")
        let focus = try await nextWrite(session.bridge, from: &index, command)
        await session.bridge.serve(HerdrConnectionTests.reply(id: focus.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.twoWorkspaces(revision: 3, focusedTab: "t4", focusedPane: "w2:p6"))
        try await harness.waitUntil("the workspace the session went to didn't come first") {
            adapter.windowSelectionSheetRenderProjection(group: nil).grouping?.groups.map(\.name) == ["beta", "alpha"]
        }
    }

    /// The Tabs sheet's workspaces each show their most urgent agent, across their tabs; a workspace
    /// without agents shows none.
    func testTheTabsSheetsWorkspacesShowTheirAgents() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        await session.bridge.serve(Self.twoWorkspaces(revision: 2, agents: [
            HerdrServerScript.snapshotAgent("w2:p5", workspace: "w2", tab: "t3", status: .working, stateChange: 2),
            HerdrServerScript.snapshotAgent("w2:p6", workspace: "w2", tab: "t4", status: .blocked, stateChange: 2),
        ]))
        try await harness.waitUntil("the agents weren't shown") { harness.model.agents.agents.count == 2 }

        let grouping = try XCTUnwrap(harness.model.terminalScreenAdapter.windowSelectionSheetRenderProjection(group: nil).grouping)
        XCTAssertEqual(grouping.groups.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(grouping.groups.map(\.agentStatus), [nil, .blocked])
    }

    /// A swipe goes to the next tab of the workspace on screen, by the same move as a tile.
    func testASwipeGoesToTheNextTabOfTheWorkspace() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next

        XCTAssertEqual(harness.model.terminalScreenAdapter.focusAdjacentTopLevel(.next), .queued)
        let focus = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(focus.method, "tab.focus")
        XCTAssertEqual(focus.params, ["tab_id": "t2"])
    }

    /// A swipe during a switch to a tab of another workspace goes on in that workspace, from the tab the switch
    /// goes to, not in the workspace still on screen.
    func testASwipeDuringASwitchToAnotherWorkspaceGoesOnThere() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next

        harness.model.reveal(.tab("t3"), bootID: "boot")
        let pick = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(pick.params, ["tab_id": "t3"])
        XCTAssertEqual(harness.model.terminalScreenAdapter.focusAdjacentTopLevel(.next), .queued)
        XCTAssertEqual(harness.model.switchingTabID, "t4", "the swipe went on in the workspace on screen")
    }

    /// A swipe during a switch to a new tab goes on from it once Herdr's answer names the pane it made and a
    /// snapshot lists it, and takes no swipe before: the tab it would count from isn't known yet, and counting
    /// from the tab left would go somewhere the user isn't going.
    func testASwipeDuringASwitchToANewTabGoesOnFromItOnceHerdrNamesIt() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertTrue(harness.model.create(.tab(workspaceID: "w1"), bootID: "boot"))
        let created = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(created.method, "tab.create")
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .missingTarget(.adjacentTopLevel), "a swipe counted from the tab left")

        await session.bridge.serve(HerdrConnectionTests.reply(
            id: created.id, json: #"{"type":"tab_created","tab":{"tab_id":"t5"},"root_pane":{"pane_id":"w1:p9"}}"#
        ))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 5,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"]), ("t5", ["w1:p9"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"]), ("t4", ["w2:p6", "w2:p7"])], activeTab: "t4"),
            ],
            focusedTab: "t5",
            focusedPane: "w1:p9"
        ))
        try await harness.waitUntil("the snapshot didn't list the new tab") {
            harness.model.places.outline?.workspace(containingTab: "t5") != nil
        }
        XCTAssertEqual(adapter.focusAdjacentTopLevel(.next), .queued)
        let next = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(next.method, "tab.focus")
        XCTAssertEqual(next.params, ["tab_id": "t1"], "the swipe didn't go on from the new tab")
    }

    /// A pick waits in the lane behind a command Herdr hasn't answered. The session leaves and comes back
    /// before Herdr answers: the pick belonged to the show it was asked in, as Herdr's client retires what a
    /// session it leaves still had to send, so it doesn't go in the new show.
    func testAPickWaitingBehindACommandDoesntGoInALaterShow() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let selection = GhosttyHistorySelection(
            start: GhosttyTerminalCell(row: 0, column: 0),
            end: GhosttyTerminalCell(row: 0, column: 2)
        )
        let read = Task { await harness.model.readSelection(selection, inPane: "w1:p1") }
        let pending = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(pending.method, HerdrScreenModel.paneSelectionReadMethod)

        harness.model.reveal(.workspace("w2"), bootID: "boot")
        try await Task.sleep(for: .milliseconds(100))
        harness.model.setSelected(false)
        _ = try await harness.nextSurfaceSet(session.bridge, from: &index)
        harness.model.setSelected(true)
        let show = try await harness.nextSurfaceSet(session.bridge, from: &index)
        await session.bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: pending.id,
            json: #"{"type":"pane_selection","pane_id":"w1:p1","text":"one"}"#
        ))
        _ = await read.value
        await session.bridge.serve(Self.twoWorkspaces(revision: 2))
        await session.bridge.serve(try harness.shownSurface(projection: 2, revision: 2, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the session wasn't shown again") { harness.model.stateTraceLabel == "shown" }
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        for write in try await harness.writes(session.bridge, from: index, count: written - index) {
            XCTAssertNil(command(write), "the pick from the show left went in the new one: \(write)")
        }
    }

    /// New Tab is the newest pick: a move asked before it whose focus Herdr hasn't answered, and one asked
    /// while that one waited, don't take the session away from the tab it makes.
    func testOlderMovesDontTakeTheSessionAwayFromANewTab() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next

        XCTAssertTrue(harness.model.reveal(.tab("t2"), bootID: "boot"))
        let first = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(first.params, ["tab_id": "t2"])
        XCTAssertTrue(harness.model.reveal(.tab("t3"), bootID: "boot"))
        XCTAssertTrue(harness.model.create(.tab(workspaceID: "w1"), bootID: "boot"))
        await session.bridge.serve(HerdrConnectionTests.reply(id: first.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(Self.twoWorkspaces(revision: 3, focusedTab: "t2", focusedPane: "w1:p3"))
        let created = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(created.method, "tab.create")
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: created.id,
            json: #"{"type":"tab_created","tab":{"tab_id":"t5"},"root_pane":{"pane_id":"w1:p9"}}"#
        ))
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        for write in try await harness.writes(session.bridge, from: index, count: written - index) {
            XCTAssertNil(command(write), "an older move went after New Tab: \(write)")
        }
    }

    /// The Panes sheet's split sends Herdr's client's `pane.split` of the focused pane in the workspace on
    /// screen, without taking Remux's zoom off first, since the split stays on the tab. Herdr focuses the
    /// pane it made and unzooms the tab; the setting zooms the new pane.
    func testASplitZoomsThePaneItMakes() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownWorkspaces(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertEqual(adapter.splitFocusedPane(GHOSTTY_SPLIT_DIRECTION_UP), .missingTarget(.focusedPane))
        XCTAssertEqual(adapter.splitFocusedPane(GHOSTTY_SPLIT_DIRECTION_DOWN), .queued)
        let split = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(split.method, "pane.split")
        XCTAssertEqual(split.params, ["workspace_id": "w1", "target_pane_id": "w1:p1", "direction": "down", "focus": "true"])
        for write in try await harness.writes(session.bridge, from: session.next, count: index - session.next) {
            XCTAssertNil(paneZoom(write), "Remux's zoom came off before the split")
        }
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: split.id,
            json: #"{"type":"pane_info","pane":{"pane_id":"w1:p8"}}"#
        ))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p8", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"]), ("t4", ["w2:p6", "w2:p7"])], activeTab: "t4"),
            ],
            focusedTab: "t1",
            focusedPane: "w1:p8"
        ))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p8", "on"])
    }

    /// A tile and a pane picked from the layout on screen go only on that layout's server boot: once a new
    /// boot's snapshot is in, while the old frame is still on screen, they send nothing, though the new boot
    /// has a tab and a pane by the same ids.
    func testATileFromAnEarlierBootsLayoutSendsNothingOnANewBoot() async throws {
        let harness = await makeHarness()
        _ = try await shownWorkspaces(harness, zoomingOnShow: false)
        let adapter = harness.model.terminalScreenAdapter
        let tile = try XCTUnwrap(
            adapter.windowSelectionSheetRenderProjection(group: nil).windows.first { $0.displayName == "t2" }
        )
        let pane = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes.first { !$0.isFocused }).id

        XCTAssertTrue(harness.model.reconnect())
        let restarted = try await harness.bridge(1)
        await restarted.serve(try HerdrServerScript.welcome() + Self.twoWorkspaces(revision: 1, boot: "boot-2"))
        var index = 0
        _ = try await harness.nextSurfaceSet(restarted, from: &index)
        XCTAssertEqual(harness.model.layout?.bootID, "boot", "the earlier boot's frame wasn't still on screen")

        XCTAssertEqual(adapter.focusTopLevel(tile.id), .missingTarget(.topLevel(tile.id)))
        XCTAssertEqual(adapter.focusPane(pane), .missingTarget(.pane(pane)))
        try await Task.sleep(for: .milliseconds(150))
        let written = await restarted.writtenCount
        for write in try await harness.writes(restarted, from: index, count: written - index) {
            XCTAssertFalse(isCommand(write), "a pick from the earlier boot went: \(write)")
        }
    }

    /// New Workspace under a session not on screen shows the session and makes the workspace as part of the
    /// show, as a place picked there goes: the show, then `workspace.create` from the workspace this phone
    /// has there, and the show ends on the new workspace's pane.
    func testANewWorkspaceForASessionNotOnScreenGoesWithItsShow() async throws {
        let harness = await makeHarness()
        let bridge = try await hiddenWorkspaces(harness)

        XCTAssertTrue(harness.model.create(.workspace(source: "w1"), bootID: "boot"))
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        XCTAssertTrue(show.active)
        let created = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(created.method, "workspace.create")
        XCTAssertEqual(created.params, ["source_workspace_id": "w1", "focus": "true"])

        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(HerdrConnectionTests.reply(
            id: created.id,
            json: #"{"type":"workspace_created","workspace":{"workspace_id":"w3"},"tab":{"tab_id":"t5"},"root_pane":{"pane_id":"w3:p8"}}"#
        ))
        await bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"]), ("t4", ["w2:p6", "w2:p7"])], activeTab: "t4"),
                .init(id: "w3", label: "gamma", tabs: [("t5", ["w3:p8"])]),
            ],
            focusedTab: "t5",
            focusedPane: "w3:p8"
        ))
        await bridge.serve(try harness.shownSurface(
            projection: 2,
            revision: 1,
            lines: ["new"],
            panes: [.init(id: "w3:p8", x: 0, width: 7, height: 1, focused: true)]
        ))
        try await harness.waitUntil("the session wasn't shown on the new workspace") {
            harness.model.stateTraceLabel == "shown" && harness.model.layout?.tab?.tabID == "t5"
        }
    }

    /// Workspace `w1` "alpha" has tab `t1` (`w1:p1`, `w1:p2`) and `t2` (`w1:p3`, `w1:p4`); workspace `w2`
    /// "beta" has tab `t3` (`w2:p5`) and `t4` (`w2:p6`, `w2:p7`), where this phone has `t4`.
    private static func twoWorkspaces(
        revision: UInt64,
        boot: String = "boot",
        focusedTab: String = "t1",
        focusedPane: String = "w1:p1",
        zoomedTabs: Set<String> = [],
        customTabLabels: Bool = true,
        agents: [String] = []
    ) -> [UInt8] {
        HerdrServerScript.snapshot(
            revision: revision,
            boot: boot,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"]), ("t4", ["w2:p6", "w2:p7"])], activeTab: "t4"),
            ],
            focusedTab: focusedTab,
            focusedPane: focusedPane,
            zoomedTabs: zoomedTabs,
            customTabLabels: customTabLabels,
            agents: agents
        )
    }

    /// The two workspaces, connected and hidden.
    private func hiddenWorkspaces(_ harness: HerdrModelHarness) async throws -> FakeBridgeTransport {
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + Self.twoWorkspaces(revision: 1))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }
        return bridge
    }

    /// The two workspaces shown on tab `t1`, which, with `zoomingOnShow`, Herdr zooms behind the show.
    /// Returns the bridge and the index of the first write after the show's.
    private func shownWorkspaces(
        _ harness: HerdrModelHarness,
        zoomingOnShow: Bool
    ) async throws -> (bridge: FakeBridgeTransport, next: Int) {
        let bridge = try await hiddenWorkspaces(harness)
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        index += 1
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        if zoomingOnShow {
            let zoom = try await nextWrite(bridge, from: &index, paneZoom)
            await bridge.serve(Self.twoWorkspaces(revision: 2, zoomedTabs: ["t1"]))
            await bridge.serve(try harness.shownSurface(projection: 2, revision: 1, lines: ["one"], panes: [Self.zoomedPane]))
            await bridge.serve(HerdrServerScript.zoomReply(id: zoom.id, changed: true, zoomed: true, panes: Self.places(2)))
        } else {
            await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        }
        try await harness.waitUntil("the session wasn't shown") {
            harness.model.stateTraceLabel == "shown" && harness.model.layout != nil
        }
        if zoomingOnShow { try await waitForMap(harness) }
        return (bridge, index)
    }

    private func command(_ write: ClientWrite) -> (id: String, method: String, params: [String: String])? {
        if case .command(let id, let method, let params) = write { (id, method, params) } else { nil }
    }

    /// Any command to Herdr's lane: a focus, a zoom or another.
    private func isCommand(_ write: ClientWrite) -> Bool {
        switch write {
        case .command, .paneFocus, .paneZoom: true
        default: false
        }
    }
}

// MARK: - Close and rename

extension HerdrScreenModelTests {
    /// Closing a tab that isn't on screen moves nothing: it goes through the lane as Herdr's client's
    /// `tab.close`, and the session stays shown, its frames not held.
    func testClosingATabNotOnScreenIsAPlainCommand() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let tile = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).windows.first { $0.displayName == "t2" })

        XCTAssertNil(tile.closeConfirmation, "a tab that leaves its workspace another asked")
        XCTAssertEqual(adapter.closeTopLevel(tile.id), .queued)
        let close = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(close.method, "tab.close")
        XCTAssertEqual(close.params, ["tab_id": "t2"])
        XCTAssertEqual(harness.model.stateTraceLabel, "shown", "a close off screen held the frames")
    }

    /// Closing the tab on screen takes the session wherever Herdr shows it then, and the setting zooms that
    /// tab as it zooms any tab the session comes to. The closed tab takes Remux's zoom with it, so nothing is
    /// unzoomed first.
    func testClosingTheTabOnScreenZoomsTheTabHerdrShowsThen() async throws {
        let harness = await makeHarness(settings: Self.zooming)
        let session = try await shownWorkspaces(harness, zoomingOnShow: true)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let tile = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).windows.first { $0.displayName == "t1" })

        XCTAssertEqual(adapter.closeTopLevel(tile.id), .queued)
        let close = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(close.method, "tab.close")
        XCTAssertEqual(close.params, ["tab_id": "t1"])
        for write in try await harness.writes(session.bridge, from: session.next, count: index - session.next) {
            XCTAssertNil(paneZoom(write), "Remux's zoom came off a tab that was closing")
        }
        await session.bridge.serve(HerdrConnectionTests.reply(id: close.id, json: #"{"type":"ok"}"#))
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 3,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t2", ["w1:p3", "w1:p4"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"]), ("t4", ["w2:p6", "w2:p7"])], activeTab: "t4"),
            ],
            focusedTab: "t2",
            focusedPane: "w1:p3"
        ))
        let zoom = try await nextWrite(session.bridge, from: &index, paneZoom)
        XCTAssertEqual([zoom.paneID, zoom.mode], ["w1:p3", "on"])
    }

    /// A close or rename goes only on the server boot its ids came from, while its target is still there;
    /// one that changed sends nothing and says it didn't go, as Herdr's client says a close target changed.
    func testACloseOrRenameOfAChangedTargetIsRefused() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        let index = session.next

        XCTAssertFalse(harness.model.ask(.close(.tab("t9"), group: false), bootID: "boot"))
        XCTAssertFalse(harness.model.ask(.rename(.tab("t2"), name: "build"), bootID: "old-boot"))
        XCTAssertFalse(harness.model.ask(.close(.workspace("w2"), group: false), bootID: "old-boot"))
        guard case .commandFailure = harness.model.terminalScreenAdapter.terminalScreenPresentationProjection.statusOverlay else {
            return XCTFail("a refused close didn't say so")
        }
        try await Task.sleep(for: .milliseconds(150))
        let written = await session.bridge.writtenCount
        for write in try await harness.writes(session.bridge, from: index, count: written - index) {
            XCTAssertFalse(isCommand(write), "a stale close or rename went: \(write)")
        }
    }

    /// A session that isn't on screen takes no close or rename: Herdr refuses commands from a hidden one.
    func testAHiddenSessionTakesNoCloseOrRename() async throws {
        let harness = await makeHarness()
        let bridge = try await hiddenWorkspaces(harness)
        let index = await bridge.writtenCount

        XCTAssertFalse(harness.model.ask(.close(.tab("t2"), group: false), bootID: "boot"))
        XCTAssertFalse(harness.model.ask(.rename(.workspace("w2"), name: "docs"), bootID: "boot"))
        try await Task.sleep(for: .milliseconds(150))
        let written = await bridge.writtenCount
        for write in try await harness.writes(bridge, from: index, count: written - index) {
            XCTAssertFalse(isCommand(write), "a hidden session sent a close or rename: \(write)")
        }
    }

    /// Renames go as Herdr's client sends them: trimmed; never an empty tab or workspace name, which Herdr
    /// would keep as the name; an empty pane name clears the manual one; and an auto-named tab given its own
    /// name back sends nothing.
    func testRenamesGoAsHerdrsClientSendsThem() async throws {
        let harness = await makeHarness()
        let bridge = try await harness.bridge()
        await bridge.serve(try HerdrServerScript.welcome() + Self.twoWorkspaces(revision: 1, customTabLabels: false))
        harness.setScreenSize()
        try await harness.waitUntil("the session didn't connect") { harness.model.stateTraceLabel == "hidden" }
        harness.model.setSelected(true)
        var index = 0
        let show = try await harness.nextSurfaceSet(bridge, from: &index)
        await bridge.serve(HerdrServerScript.surfaceSetReply(id: show.id, active: true))
        await bridge.serve(try harness.shownSurface(projection: 1, revision: 1, lines: ["one two"], panes: Self.twoPanes))
        try await harness.waitUntil("the session wasn't shown") { harness.model.stateTraceLabel == "shown" }

        XCTAssertFalse(harness.model.ask(.rename(.tab("t2"), name: "   "), bootID: "boot"))
        XCTAssertFalse(harness.model.ask(.rename(.workspace("w2"), name: ""), bootID: "boot"))
        XCTAssertTrue(harness.model.ask(.rename(.tab("t2"), name: " t2 "), bootID: "boot"), "an unchanged automatic name was refused")
        XCTAssertTrue(harness.model.ask(.rename(.tab("t2"), name: "  build "), bootID: "boot"))
        let tab = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(tab.method, "tab.rename")
        XCTAssertEqual(tab.params, ["tab_id": "t2", "label": "build"])
        await bridge.serve(HerdrConnectionTests.reply(id: tab.id, json: #"{"type":"tab_info"}"#))

        XCTAssertTrue(harness.model.ask(.rename(.pane("w1:p2"), name: "  "), bootID: "boot"))
        let pane = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(pane.method, "pane.rename")
        XCTAssertEqual(pane.params, ["pane_id": "w1:p2", "label": ""])
        await bridge.serve(HerdrConnectionTests.reply(id: pane.id, json: #"{"type":"pane_info"}"#))

        XCTAssertTrue(harness.model.ask(.rename(.workspace("w2"), name: "docs"), bootID: "boot"))
        let workspace = try await nextWrite(bridge, from: &index, command)
        XCTAssertEqual(workspace.method, "workspace.rename")
        XCTAssertEqual(workspace.params, ["workspace_id": "w2", "label": "docs"])
    }

    /// Herdr's server asking to confirm a tab's close, as when it would close a worktree group, asks the
    /// user about its workspace's close instead of failing; agreeing closes the workspace.
    func testHerdrAskingToConfirmACloseAsksAboutItsWorkspace() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter

        XCTAssertTrue(harness.model.ask(.close(.tab("t3"), group: false), bootID: "boot"))
        let close = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(close.method, "tab.close")
        await session.bridge.serve(HerdrConnectionTests.reply(
            id: close.id,
            error: ("confirmation_required", "closing this tab closes the worktree group")
        ))
        try await harness.waitUntil("Herdr's question didn't reach the user") { adapter.askedCloseConfirmation != nil }
        XCTAssertEqual(adapter.askedCloseConfirmation, GhosttyCloseConfirmation(
            title: "Close Workspace?",
            message: "“beta” and its 2 tabs and 3 panes will close.",
            action: "Close Workspace"
        ))
        XCTAssertEqual(harness.model.askedCloseConfirmation?.request, .close(.workspace("w2"), group: false))
        if case .commandFailure = adapter.terminalScreenPresentationProjection.statusOverlay {
            XCTFail("Herdr's question was shown as a failure")
        }

        adapter.answerAskedCloseConfirmation(agreed: true)
        XCTAssertNil(adapter.askedCloseConfirmation)
        let workspace = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(workspace.method, "workspace.close")
        XCTAssertEqual(workspace.params, ["workspace_id": "w2", "close_group": "false"])
    }

    /// The workspace's only tab asks before it closes, since that closes the workspace; agreeing closes the
    /// tab itself. A pane of a tab with others closes at once.
    func testClosingAWorkspacesLastTabAsksFirst() async throws {
        let harness = await makeHarness()
        let session = try await shownWorkspaces(harness, zoomingOnShow: false)
        var index = session.next
        let adapter = harness.model.terminalScreenAdapter
        let grouping = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).grouping)
        let beta = try XCTUnwrap(grouping.groups.first { $0.name == "beta" }).id
        func betaTab() throws -> GhosttyWindowSelectionSheetRenderProjection.Window {
            try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: beta).windows.first { $0.displayName == "t3" })
        }
        let onScreen = try XCTUnwrap(adapter.windowSelectionSheetRenderProjection(group: nil).windows.first { $0.isSelected })

        XCTAssertNil(try betaTab().closeConfirmation, "t3 isn't beta's only tab")
        XCTAssertEqual(adapter.paneSelectionSheetRenderProjection(topLevelID: onScreen.id).panes.map(\.closeConfirmation), [nil, nil])
        await session.bridge.serve(HerdrServerScript.snapshot(
            revision: 2,
            workspaces: [
                .init(id: "w1", label: "alpha", tabs: [("t1", ["w1:p1", "w1:p2"]), ("t2", ["w1:p3", "w1:p4"])]),
                .init(id: "w2", label: "beta", tabs: [("t3", ["w2:p5"])]),
            ],
            focusedTab: "t1",
            focusedPane: "w1:p1"
        ))
        try await harness.waitUntil("beta's other tab didn't close") { harness.model.places.outline?.workspace("w2")?.tabs.count == 1 }
        XCTAssertEqual(try betaTab().closeConfirmation, GhosttyCloseConfirmation(
            title: "Close Workspace?",
            message: "“beta” and its 1 tab and 1 pane will close.",
            action: "Close Workspace"
        ))
        XCTAssertEqual(adapter.closeTopLevel(try betaTab().id), .queued)
        let close = try await nextWrite(session.bridge, from: &index, command)
        XCTAssertEqual(close.method, "tab.close")
        XCTAssertEqual(close.params, ["tab_id": "t3"])
    }
}

