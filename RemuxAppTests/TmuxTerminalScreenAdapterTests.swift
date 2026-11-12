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
                afterSettingChange: true
            ),
            [1]
        )

        XCTAssertTrue(policy.setEnabled(false))
        XCTAssertEqual(
            policy.windowIDsNeedingChange(
                in: staleUnzoomedTopology,
                zoomingWindowIDs: [1],
                afterSettingChange: true
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

    /// A clipboard paste and the composer's paste each reach tmux as a paste through a buffer, for
    /// the pane they were sent to. The app adds no bracket and converts no line end: tmux, which
    /// knows what the pane's program asked for, does both. The composer's paste and its Enter go to
    /// the pane the composer captured, though the focus moves between them.
    func testPastesReachTmuxAsBufferPastesForTheirPane() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark }
        )
        let written = PasteWriteRecorder()
        session.controller.setOutboundSink { written.append($0) }
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(firstPane.renderer.view)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where firstPane.renderer.presentation != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(adapter.terminalInteractionProjection.isInputAvailable)
        await drain(session.controller)
        _ = written.takeCommands(namingPane: 0)

        XCTAssertEqual(adapter.sendPasteToFocusedSurface(""), .empty)
        XCTAssertEqual(adapter.sendPasteToFocusedSurface("one\ntwo"), .accepted)
        await drain(session.controller)
        XCTAssertEqual(written.takeCommands(namingPane: 0), [
            "send-keys -X -t %0 cancel",
            "set-buffer -b BUFFER -- \"one\\012two\"",
            "list-panes -t %0",
            "paste-buffer -p -b BUFFER -t %0",
        ])

        // The composer captured the first pane. The focus moves to the second between the
        // composer's paste and its Enter; both still go to the first.
        let panes = adapter.terminalScreenPresentationProjection.viewport.panes
        let firstSurfaceID = try XCTUnwrap(panes.first(where: { adapter.tmuxPaneID(for: $0.id) == 0 })?.id)
        let secondSurfaceID = try XCTUnwrap(panes.first(where: { adapter.tmuxPaneID(for: $0.id) == 1 })?.id)
        let composed = Task { await adapter.sendPasteAwaitingCommandCompletion("three\nfour", to: firstSurfaceID) }
        for _ in 0..<100 where !written.hasCommands(namingPane: 0) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(written.takeCommands(namingPane: 0), [
            "send-keys -X -t %0 cancel",
            "set-buffer -b BUFFER -- \"three\\012four\"",
            "list-panes -t %0",
            "paste-buffer -p -b BUFFER -t %0",
        ])

        _ = adapter.focusPane(secondSurfaceID)
        await drain(session.controller)
        XCTAssertEqual(adapter.tmuxPaneID(for: try XCTUnwrap(
            adapter.terminalScreenPresentationProjection.readiness.selectedActiveLeafID
        )), 1)
        _ = written.takeCommands(namingPane: 0)
        let entered = Task {
            await adapter.sendKeyEventAwaitingCommandCompletion(
                GhosttySurfaceKeyEvent(action: .press, keyCode: .enter),
                to: firstSurfaceID
            )
        }
        for _ in 0..<100 where !written.hasCommands(namingPane: 0) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(written.takeCommands(namingPane: 0), ["send-keys -H -t %0 0d"])

        adapter.invalidate()
        await session.shutdown()
        let delivered = await (composed.value, entered.value)
        XCTAssertFalse(delivered.0, "the session ended before tmux answered the paste")
        XCTAssertFalse(delivered.1, "the session ended before tmux answered the Enter")
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

    private func drain(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// The commands the controller wrote for one pane or through a paste buffer, with this client's own
/// buffer name replaced by `BUFFER` and a paste's query cut down to its command and target.
private final class PasteWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var written = Data()

    func append(_ data: Data) {
        lock.withLock { written.append(data) }
    }

    func hasCommands(namingPane pane: Int) -> Bool {
        lock.withLock { !Self.commands(in: written, namingPane: pane).isEmpty }
    }

    func takeCommands(namingPane pane: Int) -> [String] {
        lock.withLock {
            defer { written.removeAll() }
            return Self.commands(in: written, namingPane: pane)
        }
    }

    private static func commands(in written: Data, namingPane pane: Int) -> [String] {
        String(decoding: written, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains("-t %\(pane)") || $0.contains("-buffer -b ") }
            .map { line in
                line.hasPrefix("list-panes -t %\(pane) -F '#{pane_id} #{==:")
                    ? "list-panes -t %\(pane)"
                    : String(line.replacing(#/remux-paste-[0-9a-f]{16}-[0-9]+/#, with: "BUFFER"))
            }
    }
}
