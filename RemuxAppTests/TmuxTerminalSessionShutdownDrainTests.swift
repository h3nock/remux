import GhosttyKit
import XCTest

@testable import Remux

@MainActor
final class TmuxTerminalSessionShutdownDrainTests: XCTestCase {
    func testUnzoomedActivePaneDoesNotRequestZoomForPresentation() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleStateForTesting(.ready)

        session.handleTopology(twoPaneSnapshot(activePaneID: 10, zoomed: false))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(session.lastFailedRequest)
        await session.shutdown()
    }

    func testRetainedTerminalHandoffPromotesHydratingPaneToLive() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(snapshot(phase: .hydrating))

        XCTAssertTrue(session.livePaneIDs.isEmpty)
        session.handlePaneTerminalForTesting(10)
        XCTAssertEqual(session.livePaneIDs, [10])

        session.handlePaneRemovedForTesting(10)
        XCTAssertTrue(session.livePaneIDs.isEmpty)
        await session.shutdown()
    }

    func testRetainedTerminalHandoffForUnknownPaneIsIgnored() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(snapshot(phase: .hydrating))

        session.handlePaneTerminalForTesting(99)

        XCTAssertTrue(session.livePaneIDs.isEmpty)
        await session.shutdown()
    }

    func testLiveTopologySeedsPickerEligibilityWithoutHandoff() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)

        session.handleTopology(snapshot(phase: .live))

        XCTAssertEqual(session.livePaneIDs, [10])
        await session.shutdown()
    }

    func testTopologyRemovalReconcilesLivePaneSet() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(snapshot(phase: .live))

        session.handleTopology(emptySnapshot())

        XCTAssertTrue(session.livePaneIDs.isEmpty)
        await session.shutdown()
    }

    func testPreparedSelectionClearsWhenSessionDetaches() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(twoPaneSnapshot(activePaneID: 10))

        session.prepareForPaneSelection(paneID: 11)
        XCTAssertEqual(session.pendingPaneIDForTesting, 11)

        session.handleStateForTesting(.detached(.transportClosed))
        XCTAssertNil(session.pendingPaneIDForTesting)
        await session.shutdown()
    }

    func testSameWindowSelectionKeepsPendingIntentWithoutRequestingZoom() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(twoPaneSnapshot(activePaneID: 10, zoomed: false))

        session.prepareForPaneSelection(paneID: 11)
        session.handleStateForTesting(.ready)
        session.handleTopology(twoPaneSnapshot(activePaneID: 11, zoomed: false))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(session.pendingPaneIDForTesting, 11)
        XCTAssertNil(session.lastFailedRequest, "intermediate topology must not enqueue a zoom")
        await session.shutdown()
    }

    func testCrossWindowSelectionKeepsPendingIntentWithoutRequestingZoom() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(crossWindowSnapshot(activeWindowID: 1, targetActivePaneID: 20))

        session.prepareForPaneSelection(paneID: 21)
        session.handleStateForTesting(.ready)
        session.handleTopology(crossWindowSnapshot(activeWindowID: 2, targetActivePaneID: 21))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(session.pendingPaneIDForTesting, 21)
        XCTAssertNil(session.lastFailedRequest, "group intermediate topology must not request zoom")
        await session.shutdown()
    }

    func testSelectionFailureClearsPendingIntent() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(twoPaneSnapshot(activePaneID: 10, zoomed: false))
        session.prepareForPaneSelection(paneID: 11)

        session.handleRequestFailedForTesting(.selectPane)

        XCTAssertNil(session.pendingPaneIDForTesting)
        await session.shutdown()
    }

    func testActivePaneRollbackRemainsPendingAcrossIntermediateTopology() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(twoPaneSnapshot(activePaneID: 10))

        session.prepareForPaneSelection(paneID: 11)
        session.prepareForPaneSelection(paneID: 10)

        XCTAssertEqual(
            session.pendingPaneIDForTesting,
            10,
            "A → B → A must preserve A as the latest unconfirmed intent"
        )

        session.handleTopology(twoPaneSnapshot(activePaneID: 11))

        XCTAssertEqual(
            session.pendingPaneIDForTesting,
            10,
            "B's intermediate topology must not replace the latest A intent"
        )
        await session.shutdown()
    }

    func testShutdownCompletesWithoutNativePaneHandoff() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(snapshot(phase: .hydrating))

        await session.shutdown()

        XCTAssertTrue(session.livePaneIDs.isEmpty)
    }

    private func makeSession(runtime: GhosttyKitRuntime) -> TmuxTerminalSession {
        TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, _, _, _, _, _, _ in
                XCTFail("topology alone must not create a pane renderer")
            }
        )
    }

    private func snapshot(
        phase: TmuxSessionController.PaneInfo.Phase
    ) -> TmuxSessionController.TopologySnapshot {
        .init(
            sessionName: "session",
            windows: [window(activePaneID: 10)],
            panes: [pane(id: 10, phase: phase)],
            activeWindowID: 1
        )
    }

    private func twoPaneSnapshot(
        activePaneID: TmuxPaneID,
        zoomed: Bool = true
    ) -> TmuxSessionController.TopologySnapshot {
        .init(
            sessionName: "session",
            windows: [window(activePaneID: activePaneID, zoomed: zoomed)],
            panes: [pane(id: 10, phase: .live), pane(id: 11, phase: .live)],
            activeWindowID: 1
        )
    }

    private func crossWindowSnapshot(
        activeWindowID: TmuxWindowID,
        targetActivePaneID: TmuxPaneID
    ) -> TmuxSessionController.TopologySnapshot {
        .init(
            sessionName: "session",
            windows: [
                window(id: 1, active: activeWindowID == 1, activePaneID: 10),
                window(
                    id: 2,
                    active: activeWindowID == 2,
                    activePaneID: targetActivePaneID,
                    zoomed: false
                ),
            ],
            panes: [
                pane(id: 10, windowID: 1, phase: .live),
                pane(id: 20, windowID: 2, phase: .live),
                pane(id: 21, windowID: 2, phase: .live),
            ],
            activeWindowID: activeWindowID
        )
    }

    private func emptySnapshot() -> TmuxSessionController.TopologySnapshot {
        .init(sessionName: "session", windows: [], panes: [], activeWindowID: nil)
    }

    private func window(
        id: TmuxWindowID = 1,
        active: Bool = true,
        activePaneID: TmuxPaneID,
        zoomed: Bool = true
    ) -> TmuxSessionController.WindowInfo {
        .init(
            id: id,
            name: "",
            active: active,
            zoomed: zoomed,
            width: 80,
            height: 24,
            activePaneID: activePaneID
        )
    }

    private func pane(
        id: TmuxPaneID,
        windowID: TmuxWindowID = 1,
        phase: TmuxSessionController.PaneInfo.Phase
    ) -> TmuxSessionController.PaneInfo {
        .init(
            id: id,
            windowID: windowID,
            x: 0,
            y: 0,
            width: 80,
            height: 24,
            phase: phase
        )
    }
}
