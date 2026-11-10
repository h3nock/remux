import GhosttyKit
import UIKit
import XCTest

@testable import Remux

@MainActor
final class TmuxTerminalScreenAdapterTests: XCTestCase {
    func testIdentityRegistryKeepsPaneRoundTripStable() {
        var registry = TmuxTerminalIdentityRegistry()
        let paneID = TmuxPaneID(41)

        let surfaceID = registry.surfaceID(for: paneID)

        XCTAssertEqual(registry.surfaceID(for: paneID), surfaceID)
        XCTAssertEqual(registry.paneID(for: surfaceID), paneID)
        XCTAssertNil(registry.paneID(for: UUID()))
    }

    func testIdentityRegistryKeepsWindowRoundTripStable() {
        var registry = TmuxTerminalIdentityRegistry()
        let windowID = TmuxWindowID(17)

        let surfaceID = registry.surfaceID(for: windowID)

        XCTAssertEqual(registry.surfaceID(for: windowID), surfaceID)
        XCTAssertEqual(registry.windowID(for: surfaceID), windowID)
        XCTAssertNil(registry.windowID(for: UUID()))
    }

    func testPendingPaneFocusWinsUntilTmuxConfirmsIt() {
        let activePaneIDs: Set<TmuxPaneID> = [10, 11]

        XCTAssertEqual(
            TmuxTerminalScreenAdapter.resolvedFocusedPaneID(
                server: 10,
                pending: 11,
                activePaneIDs: activePaneIDs
            ),
            11
        )
        XCTAssertEqual(
            TmuxTerminalScreenAdapter.resolvedFocusedPaneID(
                server: 11,
                pending: nil,
                activePaneIDs: activePaneIDs
            ),
            11
        )
    }

    func testPendingPaneFocusCannotEscapeTheActiveWindow() {
        XCTAssertEqual(
            TmuxTerminalScreenAdapter.resolvedFocusedPaneID(
                server: 10,
                pending: 99,
                activePaneIDs: [10, 11]
            ),
            10
        )
    }

    private func makeSession(runtime: GhosttyKitRuntime) -> TmuxTerminalSession {
        TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, _, _, _, _, _, completion in
                completion(.failure(.surfaceCreationFailed(
                    GHOSTTY_TERMINAL_SURFACE_RESULT_INVALID_INPUT
                )))
            }
        )
    }

    private func window(
        id: TmuxWindowID,
        active: Bool,
        paneID: TmuxPaneID?,
        name: String = "",
        zoomed: Bool = true
    ) -> TmuxSessionController.WindowInfo {
        TmuxSessionController.WindowInfo(
            id: id,
            name: name,
            active: active,
            zoomed: zoomed,
            width: 80,
            height: 24,
            activePaneID: paneID
        )
    }

    private func pane(
        id: TmuxPaneID,
        windowID: TmuxWindowID,
        x: UInt32 = 0,
        y: UInt32 = 0,
        width: UInt32 = 80,
        height: UInt32 = 24,
        currentCommand: String = "",
        currentPath: String = ""
    ) -> TmuxSessionController.PaneInfo {
        TmuxSessionController.PaneInfo(
            id: id,
            windowID: windowID,
            x: x,
            y: y,
            width: width,
            height: height,
            currentCommand: currentCommand,
            currentPath: currentPath,
            phase: .live
        )
    }

    private func topology(
        windowID: TmuxWindowID = 1,
        zoomed: Bool,
        activePaneID: TmuxPaneID? = 10,
        paneCount: Int
    ) -> TmuxSessionController.TopologySnapshot {
        TmuxSessionController.TopologySnapshot(
            sessionName: "zoom-default-test",
            windows: [window(
                id: windowID,
                active: true,
                paneID: activePaneID,
                zoomed: zoomed
            )],
            panes: (0..<paneCount).map { offset in
                pane(
                    id: TmuxPaneID(UInt64(10 + offset)),
                    windowID: windowID,
                    x: UInt32(offset * 40),
                    width: UInt32(paneCount == 1 ? 80 : 39)
                )
            },
            activeWindowID: windowID
        )
    }

    func testMultipaneZoomDefaultTargetsAnUnzoomedWindowOnlyOnce() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)
        let topology = topology(zoomed: false, paneCount: 2)

        XCTAssertEqual(policy.windowIDsNeedingChange(in: topology), [1])
        XCTAssertEqual(policy.windowIDsNeedingChange(in: topology), [])
    }

    func testMultipaneZoomDefaultUnzoomsAnAlreadyZoomedWindowWhenDisabled() {
        var policy = TmuxMultipaneZoomDefaultPolicy()

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: true, paneCount: 2)),
            [1]
        )
    }

    func testMultipaneZoomDefaultDoesNotToggleAMatchingWindow() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: true, paneCount: 2)),
            []
        )
    }

    func testChangingGlobalDefaultResetsAResolvedWindow() {
        var policy = TmuxMultipaneZoomDefaultPolicy()

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            []
        )
        XCTAssertTrue(policy.setEnabled(true))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
    }

    func testGlobalResetForwardsLatestIntentAgainstStaleMatchingTopology() {
        var policy = TmuxMultipaneZoomDefaultPolicy()
        let staleUnzoomedTopology = topology(zoomed: false, paneCount: 2)

        XCTAssertTrue(policy.setEnabled(true))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(
                in: staleUnzoomedTopology,
                includingMatchingWindows: true
            ),
            [1]
        )

        XCTAssertTrue(policy.setEnabled(false))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(
                in: staleUnzoomedTopology,
                includingMatchingWindows: true
            ),
            [1]
        )
    }

    func testGlobalChangeDoesNotSubmitAnAlreadyMatchingWindow() {
        var policy = TmuxMultipaneZoomDefaultPolicy()
        let topology = topology(zoomed: true, paneCount: 2)

        XCTAssertTrue(policy.setEnabled(true))
        XCTAssertEqual(policy.windowIDsNeedingChange(in: topology), [])
        XCTAssertEqual(policy.windowIDsNeedingChange(in: topology), [])
    }

    func testMultipaneZoomDefaultWaitsUntilASinglePaneWindowBecomesMultipane() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 1)),
            []
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
    }

    func testMultipaneZoomDefaultReappliesAfterReturningToOnePane() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 1)),
            []
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
    }

    func testReturningToOnePaneEndsThePerWindowChoice() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)
        policy.recordWindowChoice(1)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            []
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 1)),
            []
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
    }

    func testMultipaneZoomDefaultWaitsForAnAuthoritativeActivePane() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(
                in: topology(zoomed: false, activePaneID: nil, paneCount: 2)
            ),
            []
        )
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            [1]
        )
    }

    func testPerWindowResolutionLastsUntilGlobalDefaultChanges() {
        var policy = TmuxMultipaneZoomDefaultPolicy(isEnabled: true)
        policy.recordWindowChoice(1)

        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: false, paneCount: 2)),
            []
        )
        XCTAssertTrue(policy.setEnabled(false))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(in: topology(zoomed: true, paneCount: 2)),
            [1]
        )
    }

    func testNormalMultipaneViewportProjectsEveryTmuxPaneRectangle() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "split-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "split",
                    active: true,
                    zoomed: false,
                    width: 80,
                    height: 24,
                    activePaneID: 11
                )
            ],
            panes: [
                pane(
                    id: 10,
                    windowID: 1,
                    width: 39,
                    currentCommand: "nvim",
                    currentPath: "/work/editor"
                ),
                pane(
                    id: 11,
                    windowID: 1,
                    x: 40,
                    width: 40,
                    currentCommand: "node",
                    currentPath: "/work/server"
                )
            ],
            activeWindowID: 1
        ))

        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertEqual(viewport.windowGrid, .init(columns: 80, rows: 24))
        XCTAssertFalse(viewport.isServerZoomed)
        XCTAssertEqual(viewport.panes.count, 2)
        XCTAssertEqual(
            viewport.panes.map(\.normalFrame),
            [
                .init(x: 0, y: 0, columns: 39, rows: 24),
                .init(x: 40, y: 0, columns: 40, rows: 24),
            ]
        )
        XCTAssertEqual(viewport.panes.map(\.visibleFrame), viewport.panes.map(\.normalFrame))
        XCTAssertEqual(viewport.panes.map(\.isFocused), [false, true])
        XCTAssertEqual(viewport.paneLines, [
            GhosttyPaneLine(orientation: .vertical, position: 39.5, start: -0.5, end: 24.5, ink: .separator, width: 1, cap: .butt),
            GhosttyPaneLine(orientation: .vertical, position: 39.5, start: 12, end: 24.5, ink: .focus, width: 2, cap: .butt),
        ], "the divider in tmux's border, and the focused pane's half of it")

        await session.shutdown()
    }

    func testServerZoomProjectsOnlyActivePaneAcrossFullWindow() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )

        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "zoom-test",
            windows: [
                TmuxSessionController.WindowInfo(
                    id: 1,
                    name: "zoomed",
                    active: true,
                    zoomed: true,
                    width: 80,
                    height: 24,
                    activePaneID: 11
                )
            ],
            panes: [
                pane(
                    id: 10,
                    windowID: 1,
                    width: 39,
                    currentCommand: "nvim",
                    currentPath: "/work/editor"
                ),
                pane(
                    id: 11,
                    windowID: 1,
                    x: 40,
                    width: 40,
                    currentCommand: "node",
                    currentPath: "/work/server"
                )
            ],
            activeWindowID: 1
        ))

        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertTrue(viewport.isServerZoomed)
        XCTAssertEqual(viewport.panes[0].visibleFrame, nil)
        XCTAssertEqual(viewport.paneLines, [], "a zoomed pane has no divider")
        XCTAssertEqual(
            viewport.panes[1].visibleFrame,
            .init(x: 0, y: 0, columns: 80, rows: 24)
        )
        XCTAssertEqual(
            viewport.panes[1].normalFrame,
            .init(x: 40, y: 0, columns: 40, rows: 24)
        )

        let windowID = try XCTUnwrap(
            adapter.windowSelectionSheetRenderProjection(group: nil).selectedWindowID
        )
        let panePicker = adapter.paneSelectionSheetRenderProjection(topLevelID: windowID)
        XCTAssertTrue(panePicker.isServerZoomed)
        XCTAssertEqual(
            panePicker.panes.compactMap(\.frame),
            [
                .init(x: 0, y: 0, columns: 39, rows: 24),
                .init(x: 40, y: 0, columns: 40, rows: 24),
            ],
            "the picker must keep canonical unzoomed geometry while the viewport is zoomed"
        )
        XCTAssertEqual(panePicker.panes.map(\.currentCommand), ["nvim", "node"])
        XCTAssertEqual(panePicker.panes.map(\.currentPath), ["/work/editor", "/work/server"])

        await session.shutdown()
    }

    /// Removing a window asks first, saying how many panes close with it; removing a pane asks only when it
    /// is its window's only pane, since that can close the window.
    func testRemovalsAskWhereTmuxSessionsAskFirst() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )
        session.handleTopology(TmuxSessionController.TopologySnapshot(
            sessionName: "removal-test",
            windows: [
                window(id: 1, active: true, paneID: 10, name: "editor", zoomed: false),
                window(id: 2, active: false, paneID: 20, name: "logs", zoomed: false)
            ],
            panes: [
                pane(id: 10, windowID: 1, width: 40),
                pane(id: 11, windowID: 1, x: 41, width: 39),
                pane(id: 20, windowID: 2)
            ],
            activeWindowID: 1
        ))

        let windows = adapter.windowSelectionSheetRenderProjection(group: nil).windows
        XCTAssertEqual(windows.map(\.closeConfirmation), [
            GhosttyCloseConfirmation(
                title: "Close Window?",
                message: "This will close Window 1 and 2 panes.",
                action: "Close Window 1"
            ),
            GhosttyCloseConfirmation(
                title: "Close Window?",
                message: "This will close Window 2 and 1 pane.",
                action: "Close Window 2"
            ),
        ])
        XCTAssertEqual(
            adapter.paneSelectionSheetRenderProjection(topLevelID: windows[0].id).panes.map(\.closeConfirmation),
            [nil, nil]
        )
        XCTAssertEqual(
            adapter.paneSelectionSheetRenderProjection(topLevelID: windows[1].id).panes.map(\.closeConfirmation),
            [GhosttyCloseConfirmation(
                title: "Close Pane?",
                message: "This is the only pane in the window, so closing it can close the window too.",
                action: "Close Pane"
            )]
        )
        XCTAssertNil(adapter.askedCloseConfirmation)

        await session.shutdown()
    }

    func testWindowProjectionReflectsEmittedTopologyImmediately() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )

        let twoWindows = TmuxSessionController.TopologySnapshot(
            sessionName: "fresh-test",
            windows: [
                window(id: 1, active: true, paneID: 10, name: "editor"),
                window(id: 2, active: false, paneID: 20, name: "logs")
            ],
            panes: [pane(id: 10, windowID: 1), pane(id: 20, windowID: 2)],
            activeWindowID: 1
        )
        session.handleTopology(twoWindows)

        let first = adapter.windowSelectionSheetRenderProjection(group: nil)
        XCTAssertEqual(
            first.windows.count, 2,
            "the first emitted topology must project immediately, not lag one update behind"
        )
        XCTAssertEqual(first.windows.map(\.displayName), ["editor", "logs"])
        let firstPaneSurfaceID = try XCTUnwrap(first.windows.first?.focusedPreviewPaneID)
        XCTAssertEqual(adapter.tmuxPaneID(for: firstPaneSurfaceID), 10)
        XCTAssertTrue(
            first.previewLeafIDs.isEmpty,
            "topology cards must not submit captures before their local surfaces exist"
        )
        XCTAssertTrue(
            try XCTUnwrap(adapter.windowSheetPresentationProjection()).previewLeafIDs.isEmpty,
            "initial presentation must not submit captures before local surfaces exist"
        )

        let oneWindow = TmuxSessionController.TopologySnapshot(
            sessionName: "fresh-test",
            windows: [window(id: 1, active: true, paneID: 10, name: "renamed")],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(oneWindow)

        let second = adapter.windowSelectionSheetRenderProjection(group: nil)
        XCTAssertEqual(
            second.windows.count, 1,
            "removing a non-current window must drop its tile on the same topology update"
        )
        XCTAssertEqual(second.windows.first?.totalCount, 1)
        XCTAssertEqual(second.windows.first?.displayName, "renamed")

        await session.shutdown()
    }

    func testNameOnlyTopologyUpdatePreservesSurfaceIdentityAndCardTarget() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )

        let initial = TmuxSessionController.TopologySnapshot(
            sessionName: "rename-test",
            windows: [window(id: 1, active: true, paneID: 10, name: "editor")],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(initial)
        let before = adapter.windowSelectionSheetRenderProjection(group: nil)
        let beforeWindowID = try XCTUnwrap(before.windows.first?.id)
        let beforePaneID = try XCTUnwrap(before.windows.first?.focusedPreviewPaneID)

        let renamed = TmuxSessionController.TopologySnapshot(
            sessionName: "rename-test",
            windows: [window(id: 1, active: true, paneID: 10, name: "déploy-漢字")],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(renamed)
        let after = adapter.windowSelectionSheetRenderProjection(group: nil)

        XCTAssertEqual(after.windows.first?.displayName, "déploy-漢字")
        XCTAssertEqual(after.windows.first?.id, beforeWindowID)
        XCTAssertEqual(after.windows.first?.focusedPreviewPaneID, beforePaneID)

        await session.shutdown()
    }

    func testPendingPaneSelectionUsesItsPresentationAndFailedSelectionRestoresReadyPane() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark }
        )
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )
        let measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(
            size: CGSize(width: 390, height: 600), scale: UIScreen.main.scale
        ))
        session.updateViewportMeasurement(measurement)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.controller.start(initialSize: .init(cols: 83, rows: 44)) {
                continuation.resume(with: $0)
            }
        }
        session.controller.pump(Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8))
        await drain(session.controller)
        let layout = "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]"
        session.controller.pump(Data((
            "%begin 2 2 1\n3.1\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
            + "%begin 4 4 1\n$42 @0 1 %0 83 44 \(layout) \(layout) test\n%end 4 4 1\n"
        ).utf8))
        await drain(session.controller)
        let hydration = (5...13).map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }.joined()
        session.controller.pump(Data(hydration.utf8))
        for _ in 0..<3 { await drain(session.controller) }
        let firstPane = try XCTUnwrap(session.surfacesByPaneID[0])
        let secondPane = try XCTUnwrap(session.surfacesByPaneID[1])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(firstPane.renderer.view)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where firstPane.renderer.presentation != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(firstPane.renderer.presentation, .ready)
        XCTAssertEqual(secondPane.renderer.presentation, .pending, "a hydrated unattached pane is not ready")
        XCTAssertEqual(
            TerminalReadinessProjector.runtimeState(adapter.terminalScreenPresentationProjection.readiness),
            .connected
        )
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)

        let secondSurfaceID = try XCTUnwrap(adapter.terminalScreenPresentationProjection.viewport.panes
            .first(where: { adapter.tmuxPaneID(for: $0.id) == 1 })?.id)
        _ = adapter.focusPane(secondSurfaceID)
        let pending = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(pending.readiness.selectedActiveLeafID, secondSurfaceID)
        XCTAssertEqual(pending.readiness.selectedPanePresentation, .pending)
        XCTAssertEqual(TerminalReadinessProjector.runtimeState(pending.readiness), .connecting)
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)
        XCTAssertEqual(adapter.sendInputToFocusedSurface("must not be sent"), .surfaceRejected)
        XCTAssertEqual(session.presentation(for: 0), .ready, "the first pane remains ready during pending selection")

        session.handleRequestFailedForTesting(.selectPane)
        let restored = adapter.terminalScreenPresentationProjection
        XCTAssertEqual(adapter.tmuxPaneID(for: try XCTUnwrap(restored.readiness.selectedActiveLeafID)), 0)
        XCTAssertEqual(restored.readiness.selectedPanePresentation, .ready)
        XCTAssertEqual(TerminalReadinessProjector.runtimeState(restored.readiness), .connected)
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)

        adapter.invalidate()
        await session.shutdown()
    }

    func testSelectedPaneFailureOverridesCommandFailureWithoutAnotherSelectionInheritingIt() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )
        session.handleTopology(topology(zoomed: false, activePaneID: 10, paneCount: 2))
        session.handleStateForTesting(.ready)
        session.handleRendererFailureForTesting(11)
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.readiness.selectedPanePresentation, .pending)
        XCTAssertEqual(
            TerminalReadinessProjector.runtimeState(adapter.terminalScreenPresentationProjection.readiness),
            .connecting
        )

        session.handleRequestFailedForTesting(.splitPane)
        session.handleTopology(topology(zoomed: false, activePaneID: 11, paneCount: 2))
        let failed = adapter.terminalScreenPresentationProjection
        guard case .failed(let reason) = failed.readiness.selectedPanePresentation else {
            adapter.invalidate()
            await session.shutdown()
            return XCTFail("the selected pane's missing renderer must expose a repairable failure")
        }
        XCTAssertEqual(reason.kind, .runtime)
        XCTAssertEqual(failed.statusOverlay, .failed(message: reason.message, reason: reason))
        XCTAssertEqual(TerminalReadinessProjector.runtimeState(failed.readiness), .disconnected(reason))
        XCTAssertFalse(adapter.terminalInteractionProjection.isInputAvailable)

        session.handleTopology(topology(zoomed: false, activePaneID: 10, paneCount: 2))
        XCTAssertEqual(adapter.terminalScreenPresentationProjection.readiness.selectedPanePresentation, .pending)
        XCTAssertEqual(
            TerminalReadinessProjector.runtimeState(adapter.terminalScreenPresentationProjection.readiness),
            .connecting,
            "presentation failures belong to the selected pane, not the entire control connection"
        )
        adapter.invalidate()
        await session.shutdown()
    }

    // MARK: Multi-pane zoom default against tmux's replies

    func testMultipaneZoomDefaultZoomsBeforeTheAttachLoadsThePanes() async throws {
        let harness = try await attachedSession(
            zoomsByDefault: true,
            listWindows: Self.singleAndSplitWindows
        )

        let sent = harness.outbound.take()
        let zoom = "resize-pane -Z -t %1 ; \(Self.zoomOwner.markIfZoomedCommand(windowID: 1))\n"
        let zoomRange = try XCTUnwrap(sent.range(of: zoom), "the two-pane window was not zoomed: \(sent)")
        let paneStateRange = try XCTUnwrap(sent.range(of: "list-panes -s -F"))
        let captureRange = try XCTUnwrap(sent.range(of: "capture-pane"))
        XCTAssertLessThan(
            zoomRange.lowerBound, paneStateRange.lowerBound,
            "the zoom must reach tmux before the client reads the panes' sizes"
        )
        XCTAssertLessThan(
            zoomRange.lowerBound, captureRange.lowerBound,
            "the zoom must reach tmux before the client captures the panes"
        )
        XCTAssertEqual(sent.components(separatedBy: "resize-pane").count - 1, 1)
        await harness.tearDown()
    }

    func testDisabledMultipaneZoomDefaultLeavesAnUnzoomedWindowAlone() async throws {
        let harness = try await attachedSession(
            zoomsByDefault: false,
            listWindows: Self.singleAndSplitWindows
        )

        let sent = harness.outbound.take()
        XCTAssertTrue(sent.contains(TmuxZoomOwner.marksQuery), "the attach did not settle: \(sent)")
        XCTAssertFalse(sent.contains("resize-pane"), sent)
        await harness.tearDown()
    }

    func testMultipaneZoomDefaultDoesNotToggleAWindowZoomedAtAttach() async throws {
        let harness = try await attachedSession(
            zoomsByDefault: true,
            listWindows: Self.zoomedSplitAndSingleWindows
        )

        let sent = harness.outbound.take()
        XCTAssertTrue(sent.contains(TmuxZoomOwner.marksQuery), "the attach did not settle: \(sent)")
        XCTAssertFalse(sent.contains("resize-pane"), sent)
        await harness.tearDown()
    }

    func testMultipaneZoomDefaultZoomsAWindowThatBecomesMultipaneBeforeItsNewPaneLoads() async throws {
        let harness = try await attachedSession(
            zoomsByDefault: true,
            listWindows: Self.twoSinglePaneWindows
        )
        let attach = harness.outbound.take()
        XCTAssertFalse(attach.contains("resize-pane"), attach)
        await harness.reply(to: attach)

        let split = "4084,83x44,0,0[83x22,0,0,2,83x21,0,23,3]"
        await harness.receive("%layout-change @1 \(split) \(split) *\n")

        let sent = harness.outbound.take()
        XCTAssertTrue(sent.contains("capture-pane -p -P -C -t %3"), "the new pane was not loaded: \(sent)")
        let zoom = "resize-pane -Z -t %2 ; \(Self.zoomOwner.markIfZoomedCommand(windowID: 1))\n"
        let zoomRange = try XCTUnwrap(sent.range(of: zoom), "the split window was not zoomed: \(sent)")
        let newPaneCaptureRange = try XCTUnwrap(sent.range(of: "capture-pane"))
        let paneStateRange = try XCTUnwrap(sent.range(of: "list-panes -s -F"))
        XCTAssertLessThan(
            zoomRange.lowerBound, paneStateRange.lowerBound,
            "the zoom must reach tmux before the client reads the new pane's size"
        )
        XCTAssertLessThan(
            zoomRange.lowerBound, newPaneCaptureRange.lowerBound,
            "the zoom must reach tmux before the client captures the new pane"
        )
        XCTAssertEqual(sent.components(separatedBy: "resize-pane").count - 1, 1)
        await harness.tearDown()
    }

    /// The adapter reconciles every topology, including the zoomed one, and
    /// none of them toggles the window again; the zoom is Remux's to release.
    func testMultipaneZoomDefaultZoomsOnceAndOwnsTheZoom() async throws {
        let owner = Self.zoomOwner
        let harness = try await attachedSession(
            zoomsByDefault: true,
            listWindows: Self.singleAndSplitWindows
        )
        let attach = harness.outbound.take()
        // tmux ran the zoom before the pane-state scan, so it reports pane 1
        // at the window's width.
        await harness.reply(
            to: attach,
            paneState: Self.paneState(id: 0, width: 83)
                + Self.paneState(id: 1, width: 83)
                + Self.paneState(id: 2, width: 41)
        )
        await harness.receive(
            "%layout-change @1 9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2} b7de,83x44,0,0,1 *Z\n"
        )
        XCTAssertTrue(harness.adapter.terminalScreenPresentationProjection.viewport.isServerZoomed)

        let afterZoom = harness.outbound.take()
        XCTAssertEqual(
            afterZoom, "",
            "the zoomed window is neither zoomed again nor loaded again"
        )
        XCTAssertEqual((attach + afterZoom).components(separatedBy: "resize-pane -Z -t %").count - 1, 1)

        harness.adapter.releaseZoomOwnership()
        await harness.settle()
        XCTAssertEqual(
            harness.outbound.take(),
            "resize-pane -Z -t @1 ; \(owner.clearMarkCommand(windowID: 1))\n"
        )
        await harness.tearDown()
    }

    func testTurningTheMultipaneZoomDefaultOnZoomsTheAttachedWindow() async throws {
        let harness = try await attachedSession(
            zoomsByDefault: false,
            listWindows: Self.singleAndSplitWindows
        )
        _ = harness.outbound.take()

        harness.adapter.setZoomMultipaneWindowsByDefault(true)
        await harness.settle()

        XCTAssertEqual(
            harness.outbound.take(),
            "resize-pane -Z -t %1 ; \(Self.zoomOwner.markIfZoomedCommand(windowID: 1))\n"
        )
        await harness.tearDown()
    }

    private func attachedSession(
        zoomsByDefault: Bool,
        listWindows: String
    ) async throws -> AttachedSession {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            zoomOwner: Self.zoomOwner
        )
        let adapter = TmuxTerminalScreenAdapter()
        adapter.activate(
            session: session,
            zoomMultipaneWindowsByDefault: zoomsByDefault,
            initialViewportHandler: { _, _, _ in },
            viewportStabilityHandler: { _ in }
        )
        let attached = AttachedSession(runtime: runtime, session: session, adapter: adapter)
        session.controller.setOutboundSink { [outbound = attached.outbound] in outbound.append($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.controller.start(initialSize: .init(cols: 83, rows: 44)) {
                continuation.resume(with: $0)
            }
        }
        await attached.receive("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n")
        XCTAssertTrue(attached.outbound.take().contains("list-windows -F"))
        await attached.receive(
            "%begin 2 2 1\n3.1\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
                + "%begin 4 4 1\n\(listWindows)%end 4 4 1\n"
        )
        return attached
    }

    private static let zoomOwner = TmuxZoomOwner(
        serverID: UUID(uuidString: "6B1E0C3A-9F24-4D8B-A5C7-2E9D3F60B714")!
    )

    /// A one-pane window and a current two-pane window, neither zoomed.
    private static let singleAndSplitWindows =
        windowRecord(id: 0, active: false, paneID: 0, layout: "b7dd,83x44,0,0,0")
        + windowRecord(id: 1, active: true, paneID: 1, layout: "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}")

    private static let zoomedSplitAndSingleWindows =
        windowRecord(
            id: 0,
            active: true,
            paneID: 0,
            layout: "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]",
            visibleLayout: "b7dd,83x44,0,0,0"
        )
        + windowRecord(id: 1, active: false, paneID: 2, layout: "b7df,83x44,0,0,2")

    private static let twoSinglePaneWindows =
        windowRecord(id: 0, active: false, paneID: 0, layout: "b7dd,83x44,0,0,0")
        + windowRecord(id: 1, active: true, paneID: 2, layout: "b7df,83x44,0,0,2")

    private static func windowRecord(
        id: Int,
        active: Bool,
        paneID: Int,
        layout: String,
        visibleLayout: String? = nil
    ) -> String {
        "$42 @\(id) \(active ? 1 : 0) %\(paneID) 83 44 \(layout) \(visibleLayout ?? layout) window-\(id)\n"
    }

    /// One line of the client's pane-state scan for a 44-row pane at the prompt.
    private static func paneState(id: Int, width: Int) -> String {
        "%\(id);\(width);44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;43;8,16;zsh;/tmp\n"
    }

    private func drain(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// A session whose own controller is fed tmux's bytes directly, with every
/// outbound byte recorded. Replies are numbered after the attach's four
/// commands.
@MainActor
private final class AttachedSession {
    let runtime: GhosttyKitRuntime
    let session: TmuxTerminalSession
    let adapter: TmuxTerminalScreenAdapter
    let outbound = ZoomDefaultOutboundRecorder()
    private var nextCommandNumber = 5

    init(runtime: GhosttyKitRuntime, session: TmuxTerminalSession, adapter: TmuxTerminalScreenAdapter) {
        self.runtime = runtime
        self.session = session
        self.adapter = adapter
    }

    /// Lets the writer queue and the main actor finish what each sent the other.
    func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                session.controller.queue.async {
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }

    func receive(_ text: String) async {
        session.controller.pump(Data(text.utf8))
        await settle()
    }

    /// Answers each command in `sent`, in order: the pane-state scan with
    /// `paneState`, every other command with an empty reply.
    func reply(to sent: String, paneState: String = "") async {
        var replies = ""
        for command in sent.split(separator: "\n").flatMap({ $0.components(separatedBy: " ; ") }) {
            let number = nextCommandNumber
            nextCommandNumber += 1
            let body = command.hasPrefix("list-panes -s -F") ? paneState : ""
            replies += "%begin \(number) \(number) 1\n\(body)%end \(number) \(number) 1\n"
        }
        await receive(replies)
    }

    func tearDown() async {
        adapter.invalidate()
        await session.shutdown()
        withExtendedLifetime(runtime) {}
    }
}

private final class ZoomDefaultOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        lock.withLock { text += String(decoding: data, as: UTF8.self) }
    }

    /// Everything sent since the last take.
    func take() -> String {
        lock.withLock {
            defer { text = "" }
            return text
        }
    }
}
