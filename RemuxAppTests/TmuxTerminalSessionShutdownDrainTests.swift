import GhosttyKit
import XCTest
import UIKit

@testable import Remux

@MainActor
final class TmuxTerminalSessionShutdownDrainTests: XCTestCase {
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

    func testShutdownCompletesWithoutNativePaneHandoff() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(snapshot(phase: .hydrating))

        await session.shutdown()

        XCTAssertTrue(session.livePaneIDs.isEmpty)
    }

    func testInitialRetainFailureWithoutSurfaceIsRepairableAndPaneScoped() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = makeSession(runtime: runtime)
        session.handleTopology(twoPaneSnapshot(activePaneID: 10))
        session.handleStateForTesting(.ready)
        XCTAssertEqual(session.presentation(for: 10), .pending)

        session.handleRendererFailureForTesting(11)
        XCTAssertEqual(session.presentation(for: 10), .pending)
        session.handleTopology(twoPaneSnapshot(activePaneID: 11))
        guard case .failed(let reason) = session.presentation(for: 11) else {
            return XCTFail("selected missing surface must expose repair")
        }
        XCTAssertEqual(reason.kind, .runtime)
        session.handlePaneRemovedForTesting(11)
        XCTAssertEqual(session.presentation(for: 11), .pending)
        await session.shutdown()
    }

    func testCreationFailureKeepsHandoffOwnedUntilReportedAndDoesNotRetryOnTopology() async throws {
        let runtime = try GhosttyKitRuntime()
        var complete: (@MainActor (Result<TmuxPaneSurface, TerminalPaneRenderer.CreateError>) -> Void)?
        weak var handedOff: TmuxSessionController.RetainedPaneTerminal?
        var creations = 0
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { _, _, terminal, _, _, _, _, completion in
                creations += 1
                handedOff = terminal
                complete = completion
            }
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
        session.controller.pump(Data((
            "%begin 2 2 1\n3.1\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
            + "%begin 4 4 1\n$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 test\n%end 4 4 1\n"
        ).utf8))
        await drain(session.controller)
        // Protocol success and topology alone are not presentation success.
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.presentation(for: 0), .pending)
        let hydration = (5...9).map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }.joined()
        session.controller.pump(Data(hydration.utf8))
        await drain(session.controller)
        XCTAssertEqual(creations, 1)
        XCTAssertNotNil(handedOff, "session must own the terminal during asynchronous creation")
        XCTAssertEqual(session.creatingPaneIDsForTesting, [0])
        session.handleTopology(try XCTUnwrap(session.topology))
        XCTAssertEqual(creations, 1)
        XCTAssertNotNil(handedOff, "reconciliation during creation must not consume pending ownership")
        complete?(.failure(.registrationFailed(TmuxSessionController.SurfaceRegistrationError.paneUnknown)))
        complete = nil
        XCTAssertNil(handedOff, "reported terminal failure releases the pending ownership")
        guard case .failed = session.presentation(for: 0) else {
            return XCTFail("initial registration failure must expose repair")
        }
        session.handleTopology(try XCTUnwrap(session.topology))
        session.updateViewportMeasurement(measurement)
        XCTAssertEqual(creations, 1, "ordinary topology/output must not create unbounded retries")
        XCTAssertTrue(session.creatingPaneIDsForTesting.isEmpty)
        await session.shutdown()
    }

    func testBlankFrameRequiresAttachmentAndReplacementTimeoutPreservesRecoveryImage() async throws {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark }
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
        session.controller.pump(Data((
            "%begin 2 2 1\n3.1\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
            + "%begin 4 4 1\n$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 test\n%end 4 4 1\n"
        ).utf8))
        await drain(session.controller)
        let hydration = (5...9).map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }.joined()
        session.controller.pump(Data(hydration.utf8))
        for _ in 0..<3 { await drain(session.controller) }
        let surface = try XCTUnwrap(session.surfacesByPaneID[0])
        let managed = surface.screenSurface(id: UUID())
        XCTAssertEqual(surface.renderer.presentation, .pending, "an unattached renderer is not ready")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(surface.renderer.view)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where surface.renderer.presentation != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(surface.renderer.presentation, .ready, "empty terminal contents still publish a valid frame")
        surface.renderer.view.removeFromSuperview()
        XCTAssertEqual(surface.renderer.presentation, .pending, "detachment invalidates readiness even after a frame")
        viewController.view.addSubview(surface.renderer.view)
        XCTAssertEqual(surface.renderer.presentation, .ready)
        let metrics = try XCTUnwrap(measurement.displayMetrics(columns: 83, rows: 44))
        let recovered = await withCheckedContinuation { continuation in
            surface.renderer.replaceRenderer(
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(), metrics: metrics, theme: .remuxDark
            ) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(recovered, .replaced, "expected \(metrics), actual \(managed.controlSurface.currentSize())")
        XCTAssertEqual(surface.renderer.presentation, .ready)
        XCTAssertTrue(managed.rendererIsAvailable)
        XCTAssertNil(managed.rendererRecoverySnapshot)

        surface.renderer.suppressReplacementPublicationForTesting = true
        var recoveryImage: CGImage?
        let result = await withCheckedContinuation { continuation in
            surface.renderer.replaceRenderer(
                baseConfig: runtime.makeTmuxBaseSurfaceConfig(), metrics: metrics, theme: .remuxDark
            ) { continuation.resume(returning: $0) }
            recoveryImage = managed.rendererRecoverySnapshot
        }
        XCTAssertEqual(result, .failed, "a replacement without a frame must not succeed")
        XCTAssertFalse(managed.rendererIsAvailable)
        XCTAssertNotNil(managed.rendererRecoverySnapshot, "retain the last known frame until repair succeeds")
        XCTAssertTrue(managed.rendererRecoverySnapshot === recoveryImage,
                      "a timed-out replacement must preserve the original recovery image")
        XCTAssertNotEqual(surface.renderer.presentation, .ready)
        await session.shutdown()
    }

    func testInitialFrameTimeoutIsRepairableAndCannotBeErasedByLatePublication() async throws {
        let fixture = try await makeNativeFixture(attach: false)
        defer { fixture.window.isHidden = true }
        fixture.surface.renderer.suppressFirstPublicationForTesting = true
        fixture.window.rootViewController?.view.addSubview(fixture.surface.renderer.view)
        fixture.window.isHidden = false
        try await waitUntil {
            if case .failed = fixture.surface.renderer.presentation { return true }
            return false
        }
        let failure = fixture.surface.renderer.presentation
        XCTAssertFalse(try XCTUnwrap(fixture.surface.renderer.managedSurface).rendererIsAvailable)
        fixture.surface.renderer.suppressFirstPublicationForTesting = false
        _ = fixture.surface.renderer.managedSurface?.controlSurface.requestFrame()
        await drain(fixture.session.controller)
        XCTAssertEqual(fixture.surface.renderer.presentation, failure)
        await fixture.session.shutdown()
    }

    func testReplacementUsesResizeArrivingDuringNativeUnregister() async throws {
        let fixture = try await makeNativeFixture()
        defer { fixture.window.isHidden = true }
        var results: [TerminalPaneRenderer.RendererReplacementResult] = []
        fixture.surface.renderer.replaceRenderer(
            baseConfig: fixture.runtime.makeTmuxBaseSurfaceConfig(),
            metrics: fixture.metrics, theme: .remuxDark
        ) { results.append($0) }
        let resized = try XCTUnwrap(fixture.measurement.displayMetrics(columns: 80, rows: 30))
        // Unregister acknowledgement is dispatched asynchronously. This update
        // arrives before installation, without relying on a timing sleep.
        XCTAssertTrue(fixture.surface.renderer.updateDisplay(metrics: resized))
        try await waitUntil { !results.isEmpty }
        XCTAssertEqual(results, [.replaced])
        XCTAssertEqual(fixture.surface.renderer.managedSurface?.controlSurface.currentSize().width_px, resized.pixelWidth)
        XCTAssertEqual(fixture.surface.renderer.managedSurface?.controlSurface.currentSize().height_px, resized.pixelHeight)
        XCTAssertEqual(fixture.surface.renderer.presentation, .ready)
        await fixture.session.shutdown()
    }

    func testReplacementAcceptsResizeWhileWaitingForFirstFrame() async throws {
        let fixture = try await makeNativeFixture()
        defer { fixture.window.isHidden = true }
        fixture.surface.renderer.suppressReplacementPublicationForTesting = true
        var results: [TerminalPaneRenderer.RendererReplacementResult] = []
        fixture.surface.renderer.replaceRenderer(
            baseConfig: fixture.runtime.makeTmuxBaseSurfaceConfig(),
            metrics: fixture.metrics, theme: .remuxDark
        ) { results.append($0) }
        try await waitUntil { fixture.surface.renderer.isAwaitingReplacementFrameForTesting }
        XCTAssertFalse(try XCTUnwrap(fixture.surface.renderer.managedSurface).rendererIsAvailable)
        let resized = try XCTUnwrap(fixture.measurement.displayMetrics(columns: 80, rows: 30))
        XCTAssertTrue(fixture.surface.renderer.updateDisplay(metrics: resized))
        fixture.surface.renderer.suppressReplacementPublicationForTesting = false
        XCTAssertTrue(try XCTUnwrap(fixture.surface.renderer.managedSurface).controlSurface.requestFrame())
        try await waitUntil { !results.isEmpty }
        let layer = try XCTUnwrap(GhosttyIOSurfaceFrame.rendererLayer(in: fixture.surface.renderer.view.layer))
        let dimensions = try XCTUnwrap(GhosttyIOSurfaceFrame.dimensions(in: layer))
        XCTAssertEqual(dimensions.width, Int(resized.pixelWidth))
        XCTAssertEqual(dimensions.height, Int(resized.pixelHeight))
        XCTAssertEqual(results, [.replaced])
        XCTAssertEqual(fixture.surface.renderer.presentation, .ready)
        await fixture.session.shutdown()
    }

    func testReplacementDeadlinePausesWhenDetachedBackgroundedOrHidden() async throws {
        let fixture = try await makeNativeFixture()
        defer { fixture.window.isHidden = true }
        fixture.surface.renderer.suppressReplacementPublicationForTesting = true
        var results: [TerminalPaneRenderer.RendererReplacementResult] = []
        fixture.surface.renderer.replaceRenderer(
            baseConfig: fixture.runtime.makeTmuxBaseSurfaceConfig(),
            metrics: fixture.metrics, theme: .remuxDark
        ) { results.append($0) }
        try await waitUntil { fixture.surface.renderer.isAwaitingReplacementFrameForTesting }
        fixture.surface.renderer.view.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(results.isEmpty, "detached time must not consume the first-frame deadline")
        fixture.surface.renderer.setSceneActive(false)
        fixture.window.rootViewController?.view.addSubview(fixture.surface.renderer.view)
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(results.isEmpty, "background time must not consume the first-frame deadline")
        fixture.surface.renderer.setPresented(false)
        fixture.surface.renderer.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(results.isEmpty, "an unselected window must not consume the first-frame deadline")
        XCTAssertEqual(fixture.surface.renderer.presentation, .awaitingFrame)
        fixture.surface.renderer.suppressReplacementPublicationForTesting = false
        fixture.surface.renderer.setPresented(true)
        try await waitUntil { !results.isEmpty }
        XCTAssertEqual(results, [.replaced])
        XCTAssertEqual(fixture.surface.renderer.presentation, .ready)
        await fixture.session.shutdown()
    }

    func testFailureWhileAwaitingReplacementCannotBecomeSuccess() async throws {
        let fixture = try await makeNativeFixture()
        defer { fixture.window.isHidden = true }
        fixture.surface.renderer.suppressReplacementPublicationForTesting = true
        var results: [TerminalPaneRenderer.RendererReplacementResult] = []
        fixture.surface.renderer.replaceRenderer(
            baseConfig: fixture.runtime.makeTmuxBaseSurfaceConfig(),
            metrics: fixture.metrics, theme: .remuxDark
        ) { results.append($0) }
        try await waitUntil { fixture.surface.renderer.isAwaitingReplacementFrameForTesting }
        let recoveryImage = try XCTUnwrap(fixture.surface.renderer.managedSurface?.rendererRecoverySnapshot)
        fixture.surface.renderer.reportRendererFailure()
        XCTAssertTrue(fixture.surface.renderer.managedSurface?.rendererRecoverySnapshot === recoveryImage,
                      "failed replacement pixels must not replace the last successful frame")
        XCTAssertEqual(results, [.failed])
        fixture.surface.renderer.suppressReplacementPublicationForTesting = false
        _ = fixture.surface.renderer.managedSurface?.controlSurface.requestFrame()
        await drain(fixture.session.controller)
        guard case .failed = fixture.surface.renderer.presentation else {
            await fixture.session.shutdown()
            return XCTFail("a later publication must not erase the renderer failure")
        }
        XCTAssertFalse(try XCTUnwrap(fixture.surface.renderer.managedSurface).rendererIsAvailable)
        XCTAssertEqual(results, [.failed], "one failure settles the attempt exactly once")
        await fixture.session.shutdown()
    }

    func testRetiredRendererCallbackCannotFailReplacementAndCloseSettlesWait() async throws {
        let fixture = try await makeNativeFixture()
        defer { fixture.window.isHidden = true }
        let retiredFailure = fixture.surface.renderer.rendererFailureCallbackForTesting()
        fixture.surface.renderer.suppressReplacementPublicationForTesting = true
        var results: [TerminalPaneRenderer.RendererReplacementResult] = []
        fixture.surface.renderer.replaceRenderer(
            baseConfig: fixture.runtime.makeTmuxBaseSurfaceConfig(),
            metrics: fixture.metrics, theme: .remuxDark
        ) { results.append($0) }
        try await waitUntil { fixture.surface.renderer.isAwaitingReplacementFrameForTesting }
        retiredFailure()
        XCTAssertTrue(results.isEmpty, "queued health events belong to the retired renderer")
        await fixture.session.shutdown()
        XCTAssertEqual(results, [.failed], "close must settle the frame wait")
        XCTAssertNil(fixture.surface.renderer.rawSurface)
        retiredFailure()
        XCTAssertEqual(results, [.failed])
    }

    func testNeverPresentedPaneCanPublishPickerPreviewWithoutEnablingInput() async throws {
        let fixture = try await makeNativeFixture(attach: false)
        defer { fixture.window.isHidden = true }
        fixture.surface.renderer.setPresented(false)
        let managed = try XCTUnwrap(fixture.surface.renderer.managedSurface)
        XCTAssertFalse(managed.rendererIsAvailable)
        let preview = await fixture.surface.renderer.capturePickerFrame(
            columns: 83, rows: 44, sourceRect: CGRect(x: 0, y: 0, width: 200, height: 120)
        )
        XCTAssertNotNil(preview)
        XCTAssertEqual(fixture.surface.renderer.presentation, .pending)
        XCTAssertFalse(managed.rendererIsAvailable)
        await fixture.session.shutdown()
    }

    /// A session the root doesn't show keeps its pane live but draws nothing; showing it draws the
    /// active pane.
    func testASessionThatIsNotShownDrawsNoPane() async throws {
        let fixture = try await makeNativeFixture(attach: false)
        defer { fixture.window.isHidden = true }
        fixture.session.setSelected(false)
        fixture.window.rootViewController?.view.addSubview(fixture.surface.renderer.view)
        fixture.window.isHidden = false

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.surface.renderer.presentation, .awaitingFrame)
        XCTAssertEqual(fixture.session.presentation(for: 0), .awaitingFrame)

        fixture.session.setSelected(true)
        try await waitUntil { fixture.surface.renderer.presentation == .ready }
        await fixture.session.shutdown()
    }

    func testDelayedInitialCreationAppliesCurrentViewportAndThemeBeforeReady() async throws {
        let fixture = try await makeDelayedNativeFixture()
        let latest = TmuxSessionController.TopologySnapshot(
            sessionName: "main",
            windows: [.init(id: 0, name: "test", active: true, zoomed: false,
                            width: 80, height: 30, activePaneID: 0)],
            panes: [.init(id: 0, windowID: 0, x: 0, y: 0, width: 80, height: 30,
                          currentCommand: "", currentPath: "", phase: .live)],
            activeWindowID: 0
        )
        fixture.session.handleTopology(latest)
        fixture.theme.value = .remuxLight
        fixture.deliver()
        let admitted = try XCTUnwrap(fixture.session.surfacesByPaneID[0])
        XCTAssertTrue(admitted === fixture.surface)
        let expected = try XCTUnwrap(fixture.measurement.displayMetrics(columns: 80, rows: 30))
        let managed = admitted.screenSurface(id: UUID())
        XCTAssertEqual(managed.controlSurface.currentSize().width_px, expected.pixelWidth)
        XCTAssertEqual(managed.controlSurface.currentSize().height_px, expected.pixelHeight)
        XCTAssertEqual(admitted.renderer.view.backgroundColor, TerminalTheme.remuxLight.terminalBackgroundUIColor)
        XCTAssertEqual(admitted.renderer.presentation, .pending)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(admitted.renderer.view)
        window.isHidden = false
        defer { window.isHidden = true }
        try await waitUntil { admitted.renderer.presentation == .ready }
        await fixture.session.shutdown()
    }

    func testDelayedCreationAfterRemovalClosesUnadmittedRenderer() async throws {
        let fixture = try await makeDelayedNativeFixture()
        fixture.session.handleTopology(emptySnapshot())
        fixture.deliver()
        try await waitUntil { fixture.surface.renderer.rawSurface == nil }
        XCTAssertTrue(fixture.session.surfacesByPaneID.isEmpty)
        XCTAssertTrue(fixture.session.creatingPaneIDsForTesting.isEmpty)
        await fixture.session.shutdown()
    }

    func testShutdownDrainsDelayedRegisteredCreationWithoutAdmittingIt() async throws {
        let fixture = try await makeDelayedNativeFixture()
        let shutdown = Task { await fixture.session.shutdown() }
        await drain(fixture.session.controller)
        fixture.deliver()
        await shutdown.value
        XCTAssertNil(fixture.surface.renderer.rawSurface)
        XCTAssertTrue(fixture.session.surfacesByPaneID.isEmpty)
        XCTAssertTrue(fixture.session.creatingPaneIDsForTesting.isEmpty)
    }

    /// Ghostty requires the app to outlive every surface, and the screen model frees the app once the
    /// session's shutdown returns, so the shutdown waits until a renderer it turned away after it
    /// began is freed.
    func testShutdownWaitsForARendererRejectedAfterItBegan() async throws {
        let gate = CloseGate()
        let fixture = try await makeDelayedNativeFixture(closeGate: gate)
        let shutdown = Task {
            await fixture.session.shutdown()
            gate.record("shut down")
        }
        await drain(fixture.session.controller)
        fixture.deliver()
        try await waitUntil { gate.heldCount == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.log, [], "the shutdown returned before the rejected renderer was freed")

        gate.release()
        await shutdown.value
        XCTAssertEqual(gate.log, ["closed", "shut down"])
        XCTAssertNil(fixture.surface.renderer.rawSurface)
    }

    /// A renderer still closing because its pane left is freed before the shutdown returns.
    func testShutdownWaitsForTheRendererOfAPaneThatLeft() async throws {
        let gate = CloseGate()
        let fixture = try await makeNativeFixture(attach: false, closeGate: gate)
        fixture.session.handlePaneRemovedForTesting(0)
        try await waitUntil { gate.heldCount == 1 }
        let shutdown = Task {
            await fixture.session.shutdown()
            gate.record("shut down")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.log, [], "the shutdown returned before the pane's renderer was freed")

        gate.release()
        await shutdown.value
        XCTAssertEqual(gate.log, ["closed", "shut down"])
        XCTAssertNil(fixture.surface.renderer.rawSurface)
    }

    private final class ThemeBox {
        var value = TerminalTheme.remuxDark
    }

    /// Holds renderer unregistrations back until released, and logs each close as its surface is
    /// about to be freed.
    @MainActor
    private final class CloseGate {
        private(set) var log: [String] = []
        private var holds = true
        private var held: [() -> Void] = []

        var heldCount: Int { held.count }

        func record(_ event: String) {
            log.append(event)
        }

        func pass(_ deliver: @escaping () -> Void) {
            if holds { held.append(deliver) } else { deliver() }
        }

        func release() {
            holds = false
            let released = held
            held.removeAll()
            released.forEach { $0() }
        }
    }

    /// The controller's fence, with its unregistration answers passed through a `CloseGate`.
    @MainActor
    private final class HeldCloseFence: TerminalPaneRendererFence {
        private let base: any TerminalPaneRendererFence
        private let gate: CloseGate

        init(base: any TerminalPaneRendererFence, gate: CloseGate) {
            self.base = base
            self.gate = gate
        }

        func registerRenderer(
            _ surface: ghostty_terminal_surface_t,
            completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
        ) {
            base.registerRenderer(surface, completion: completion)
        }

        func unregisterRenderer(
            _ surface: ghostty_terminal_surface_t,
            completion: @escaping @MainActor @Sendable () -> Void
        ) {
            base.unregisterRenderer(surface) { [gate] in
                gate.pass {
                    gate.record("closed")
                    completion()
                }
            }
        }
    }

    private static func fence(
        _ fence: any TerminalPaneRendererFence,
        heldBy gate: CloseGate?
    ) -> any TerminalPaneRendererFence {
        gate.map { HeldCloseFence(base: fence, gate: $0) } ?? fence
    }

    private struct DelayedNativeFixture {
        let runtime: GhosttyKitRuntime
        let session: TmuxTerminalSession
        let surface: TmuxPaneSurface
        let measurement: GhosttyTerminalViewportMeasurement
        let theme: ThemeBox
        let deliver: () -> Void
    }

    private func makeDelayedNativeFixture(closeGate: CloseGate? = nil) async throws -> DelayedNativeFixture {
        let runtime = try GhosttyKitRuntime()
        let theme = ThemeBox()
        var created: TmuxPaneSurface?
        var deliver: (() -> Void)?
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { theme.value },
            createPaneSurface: { app, controller, terminal, config, metrics, paneTheme, failure, completion in
                TmuxPaneSurface.create(
                    app: app, controller: controller, terminal: terminal, baseConfig: config,
                    metrics: metrics, theme: paneTheme, onRendererFailure: failure,
                    wrapFence: { Self.fence($0, heldBy: closeGate) }
                ) { result in
                    if case .success(let surface) = result { created = surface }
                    deliver = { completion(result) }
                }
            }
        )
        let measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(
            size: CGSize(width: 390, height: 600), scale: UIScreen.main.scale
        ))
        session.updateViewportMeasurement(measurement)
        try await hydrateNativePane(in: session)
        XCTAssertEqual(session.creatingPaneIDsForTesting, [0])
        return DelayedNativeFixture(
            runtime: runtime, session: session, surface: try XCTUnwrap(created),
            measurement: measurement, theme: theme, deliver: try XCTUnwrap(deliver)
        )
    }

    private struct NativeFixture {
        let runtime: GhosttyKitRuntime
        let session: TmuxTerminalSession
        let surface: TmuxPaneSurface
        let measurement: GhosttyTerminalViewportMeasurement
        let metrics: GhosttySurfaceDisplayMetrics
        let window: UIWindow
    }

    private func makeNativeFixture(
        attach: Bool = true,
        closeGate: CloseGate? = nil
    ) async throws -> NativeFixture {
        let runtime = try GhosttyKitRuntime()
        let session = TmuxTerminalSession(
            app: runtime.appHandleForTesting,
            transport: DeterministicTmuxControlTransport(chunks: []),
            baseSurfaceConfig: { runtime.makeTmuxBaseSurfaceConfig() },
            paneViewTheme: { .remuxDark },
            createPaneSurface: { app, controller, terminal, config, metrics, paneTheme, failure, completion in
                TmuxPaneSurface.create(
                    app: app, controller: controller, terminal: terminal, baseConfig: config,
                    metrics: metrics, theme: paneTheme, onRendererFailure: failure,
                    wrapFence: { Self.fence($0, heldBy: closeGate) },
                    completion: completion
                )
            }
        )
        let measurement = try XCTUnwrap(runtime.measureTmuxViewportLayout(
            size: CGSize(width: 390, height: 600), scale: UIScreen.main.scale
        ))
        session.updateViewportMeasurement(measurement)
        try await hydrateNativePane(in: session)
        let surface = try XCTUnwrap(session.surfacesByPaneID[0])
        let managed = surface.screenSurface(id: UUID())
        XCTAssertFalse(managed.rendererIsAvailable, "native allocation alone must not enable input")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = UIViewController()
        if attach {
            window.rootViewController?.view.addSubview(surface.renderer.view)
            window.isHidden = false
            try await waitUntil { surface.renderer.presentation == .ready }
        }
        return NativeFixture(
            runtime: runtime, session: session, surface: surface, measurement: measurement,
            metrics: try XCTUnwrap(measurement.displayMetrics(columns: 83, rows: 44)), window: window
        )
    }

    private func hydrateNativePane(in session: TmuxTerminalSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.controller.start(initialSize: .init(cols: 83, rows: 44)) {
                continuation.resume(with: $0)
            }
        }
        session.controller.pump(Data("%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n".utf8))
        await drain(session.controller)
        session.controller.pump(Data((
            "%begin 2 2 1\n3.1\n%end 2 2 1\n%begin 3 3 1\n%end 3 3 1\n"
            + "%begin 4 4 1\n$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 test\n%end 4 4 1\n"
        ).utf8))
        await drain(session.controller)
        let hydration = (5...9).map { "%begin \($0) \($0) 1\n%end \($0) \($0) 1\n" }.joined()
        session.controller.pump(Data(hydration.utf8))
        for _ in 0..<3 { await drain(session.controller) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for native presentation")
    }

    private func drain(_ controller: TmuxSessionController) async {
        await withCheckedContinuation { continuation in
            controller.queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
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
            currentCommand: "",
            currentPath: "",
            phase: phase
        )
    }
}
