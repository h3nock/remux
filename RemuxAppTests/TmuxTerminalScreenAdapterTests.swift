import GhosttyKit
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
        height: UInt32 = 24
    ) -> TmuxSessionController.PaneInfo {
        TmuxSessionController.PaneInfo(
            id: id,
            windowID: windowID,
            x: x,
            y: y,
            width: width,
            height: height,
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
                pane(id: 10, windowID: 1, width: 39),
                pane(id: 11, windowID: 1, x: 40, width: 40)
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
                pane(id: 10, windowID: 1, width: 39),
                pane(id: 11, windowID: 1, x: 40, width: 40)
            ],
            activeWindowID: 1
        ))

        let viewport = adapter.terminalScreenPresentationProjection.viewport
        XCTAssertTrue(viewport.isServerZoomed)
        XCTAssertEqual(viewport.panes[0].visibleFrame, nil)
        XCTAssertEqual(
            viewport.panes[1].visibleFrame,
            .init(x: 0, y: 0, columns: 80, rows: 24)
        )
        XCTAssertEqual(
            viewport.panes[1].normalFrame,
            .init(x: 40, y: 0, columns: 40, rows: 24)
        )

        let windowID = try XCTUnwrap(
            adapter.windowSelectionSheetRenderProjection().selectedWindowID
        )
        let panePicker = adapter.paneSelectionSheetRenderProjection(topLevelID: windowID)
        XCTAssertTrue(panePicker.isServerZoomed)
        XCTAssertEqual(panePicker.windowGrid, .init(columns: 80, rows: 24))
        XCTAssertEqual(
            panePicker.panes.compactMap(\.frame),
            [
                .init(x: 0, y: 0, columns: 39, rows: 24),
                .init(x: 40, y: 0, columns: 40, rows: 24),
            ],
            "the picker must keep canonical unzoomed geometry while the viewport is zoomed"
        )

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

        let first = adapter.windowSelectionSheetRenderProjection()
        XCTAssertEqual(
            first.windows.count, 2,
            "the first emitted topology must project immediately, not lag one update behind"
        )
        XCTAssertEqual(first.windows.map(\.displayName), ["editor", "logs"])
        let firstPaneSurfaceID = try XCTUnwrap(first.previewLeafIDs.first)
        XCTAssertEqual(adapter.tmuxPaneID(for: firstPaneSurfaceID), 10)

        let oneWindow = TmuxSessionController.TopologySnapshot(
            sessionName: "fresh-test",
            windows: [window(id: 1, active: true, paneID: 10, name: "renamed")],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(oneWindow)

        let second = adapter.windowSelectionSheetRenderProjection()
        XCTAssertEqual(
            second.windows.count, 1,
            "removing a non-current window must drop its tile on the same topology update"
        )
        XCTAssertEqual(second.windows.first?.totalCount, 1)
        XCTAssertEqual(second.windows.first?.displayName, "renamed")

        await session.shutdown()
    }

    func testNameOnlyTopologyUpdatePreservesSurfaceIdentityAndPanePreview() async throws {
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
        let before = adapter.windowSelectionSheetRenderProjection()
        let beforeWindowID = try XCTUnwrap(before.windows.first?.id)
        let beforePaneID = try XCTUnwrap(before.previewLeafIDs.first)

        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1_024)
        cache.store(preview(image), for: 10)
        let initialByteCost = cache.totalByteCost

        let renamed = TmuxSessionController.TopologySnapshot(
            sessionName: "rename-test",
            windows: [window(id: 1, active: true, paneID: 10, name: "déploy-漢字")],
            panes: [pane(id: 10, windowID: 1)],
            activeWindowID: 1
        )
        session.handleTopology(renamed)
        let after = adapter.windowSelectionSheetRenderProjection()

        XCTAssertEqual(after.windows.first?.displayName, "déploy-漢字")
        XCTAssertEqual(after.windows.first?.id, beforeWindowID)
        XCTAssertEqual(after.previewLeafIDs.first, beforePaneID)
        XCTAssertEqual(
            cache.retainOnly(Set(renamed.panes.map(\.id))),
            [],
            "a name-only topology update must not evict any pane preview"
        )
        XCTAssertTrue(cache.preview(for: 10)?.image === image)
        XCTAssertEqual(cache.totalByteCost, initialByteCost)

        await session.shutdown()
    }

    func testPanePreviewCacheEvictsLeastRecentlyUsedImageWithinByteLimit() throws {
        let first = try makeImage(width: 4, height: 4)
        let second = try makeImage(width: 4, height: 4)
        let third = try makeImage(width: 4, height: 4)
        let imageCost = first.bytesPerRow * first.height
        var cache = TmuxPanePreviewImageCache(byteLimit: imageCost * 2)

        XCTAssertEqual(cache.store(preview(first), for: 1), [])
        XCTAssertEqual(cache.store(preview(second), for: 2), [])
        XCTAssertNotNil(
            cache.preview(for: 1),
            "reading pane 1 must refresh its LRU age"
        )
        XCTAssertEqual(
            cache.store(preview(third), for: 3),
            [2]
        )
        XCTAssertNotNil(cache.preview(for: 1))
        XCTAssertNil(cache.preview(for: 2))
        XCTAssertNotNil(cache.preview(for: 3))
        XCTAssertEqual(cache.totalByteCost, imageCost * 2)
    }

    func testPanePreviewCacheDropsRemovedTopologyPanes() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)
        cache.store(preview(image), for: 1)
        cache.store(preview(image), for: 2)

        XCTAssertEqual(Set(cache.retainOnly(Set([2]))), Set([1]))
        XCTAssertNil(cache.preview(for: 1))
        XCTAssertNotNil(cache.preview(for: 2))
    }

    func testPanePreviewCacheRejectsImageLargerThanByteLimit() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(
            byteLimit: image.bytesPerRow * image.height - 1
        )

        XCTAssertEqual(cache.store(preview(image), for: 1), [])
        XCTAssertNil(cache.preview(for: 1))
        XCTAssertEqual(cache.totalByteCost, 0)
    }

    func testPanePreviewCacheRetainsFullViewportProvenance() throws {
        let image = try makeImage(width: 4, height: 4)
        let expected = provenance()
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)

        cache.store(
            .init(image: image, source: .fullViewport(expected)),
            for: 1
        )

        XCTAssertEqual(cache.entries[1]?.preview.source, .fullViewport(expected))
    }

    func testPanePreviewCacheRetainsPaneGeometrySource() throws {
        let image = try makeImage(width: 4, height: 4)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)

        cache.store(preview(image), for: 1)

        guard case .paneGeometry(let provenance)? = cache.preview(for: 1)?.source else {
            return XCTFail("expected pane geometry provenance")
        }
        XCTAssertEqual(provenance.columns, 80)
        XCTAssertEqual(provenance.rows, 24)
    }

    func testPanePreviewCacheReplacesThePreviousImageForAPane() throws {
        let first = try makeImage(width: 4, height: 4)
        let replacement = try makeImage(width: 3, height: 3)
        var cache = TmuxPanePreviewImageCache(byteLimit: 1024)

        cache.store(preview(first), for: 1)
        cache.store(preview(replacement), for: 1)

        XCTAssertTrue(cache.preview(for: 1)?.image === replacement)
        XCTAssertEqual(cache.entries.count, 1)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func provenance() -> GhosttyPanePreviewSession.FullViewportProvenance {
        GhosttyPanePreviewSession.FullViewportProvenance(
            surfaceID: UUID(),
            pixelWidth: 390,
            pixelHeight: 709
        )
    }

    private func preview(
        _ image: CGImage
    ) -> GhosttyPanePreviewSession.RenderedPreview {
        .init(
            image: image,
            source: .paneGeometry(.init(
                surfaceID: UUID(),
                columns: 80,
                rows: 24
            ))
        )
    }
}
