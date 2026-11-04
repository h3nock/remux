import CoreGraphics
import Foundation
import GhosttyKit

/// MainActor owner of one control attachment and one retained renderer surface
/// for every live pane. Active-window visibility and focus are projections of
/// authoritative tmux topology, drawn only while the root shows the session.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var livePaneIDs: Set<TmuxPaneID> = []
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?
    @Published private(set) var transportFailure: TerminalDisconnectReason?
    @Published private(set) var viewportMeasurement: GhosttyTerminalViewportMeasurement?

    private let app: ghostty_app_t
    private(set) var controller: TmuxSessionController!
    private let link: TmuxSessionLink
    private let baseSurfaceConfig: () -> ghostty_terminal_surface_config_s
    private let paneViewTheme: () -> TerminalTheme
    /// The tmux path set in Edit Server, nil for Automatic: what a tmux that can't run says depends on it.
    private let tmuxPath: String?
    private var hasBeenReady = false

    typealias PaneSurfaceCreator = @MainActor (
        ghostty_app_t,
        TmuxSessionController,
        TmuxSessionController.RetainedPaneTerminal,
        ghostty_terminal_surface_config_s,
        GhosttySurfaceDisplayMetrics,
        TerminalTheme,
        @escaping @MainActor (TmuxPaneID) -> Void,
        @escaping @MainActor (Result<TmuxPaneSurface, TerminalPaneRenderer.CreateError>) -> Void
    ) -> Void
    private let createPaneSurface: PaneSurfaceCreator

    @Published private(set) var surfacesByPaneID: [TmuxPaneID: TmuxPaneSurface] = [:]
    private var pendingTerminalsByPaneID: [
        TmuxPaneID: TmuxSessionController.RetainedPaneTerminal
    ] = [:]
    private var creatingPaneIDs: Set<TmuxPaneID> = []
    private var presentationFailures: [TmuxPaneID: TerminalDisconnectReason] = [:]
    // Also invalidates the screen when an unselected pane changes presentation.
    @Published private(set) var presentationRevision: UInt64 = 0

    func presentation(for paneID: TmuxPaneID?) -> TerminalPanePresentation {
        guard let paneID else { return .pending }
        if let failure = presentationFailures[paneID] { return .failed(failure) }
        guard livePaneIDs.contains(paneID) else { return .pending }
        return surfacesByPaneID[paneID]?.renderer.presentation ?? .pending
    }

    private func presentationDidChange() {
        presentationRevision &+= 1
    }

    private func failPresentation(_ paneID: TmuxPaneID, message: String) {
        guard !isShutDown, topology?.panes.contains(where: { $0.id == paneID }) == true else { return }
        presentationFailures[paneID] = TerminalDisconnectReason(kind: .runtime, message: message)
        presentationDidChange()
    }
    private var isAppActive = true
    /// Whether the root shows this session. A session that isn't shown stays attached and keeps its
    /// terminals current; it only stops drawing.
    private(set) var isSelected = true
    private var didStartLink = false
    private var linkIsActive = false
    private var isShutDown = false
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?
    /// Renderers whose surfaces aren't freed yet. Ghostty requires the app to outlive every surface,
    /// so a shutdown returns, and its owner frees the app, only once this is back to zero.
    private var closingRenderers = 0
    private var closesDrainedContinuation: CheckedContinuation<Void, Never>?

    private final class Relay: @unchecked Sendable {
        weak var target: TmuxTerminalSession?
    }

    init(
        app: ghostty_app_t,
        transport: any TmuxControlTransport,
        baseSurfaceConfig: @escaping () -> ghostty_terminal_surface_config_s,
        paneViewTheme: @escaping () -> TerminalTheme,
        tmuxPath: String? = nil,
        zoomOwner: TmuxZoomOwner? = nil,
        createPaneSurface: @escaping PaneSurfaceCreator = TmuxPaneSurface.create
    ) {
        self.app = app
        self.baseSurfaceConfig = baseSurfaceConfig
        self.paneViewTheme = paneViewTheme
        self.tmuxPath = tmuxPath
        self.createPaneSurface = createPaneSurface

        let relay = Relay()
        let controller = TmuxSessionController(callbacks: TmuxSessionController.Callbacks(
            onState: { state in
                MainActor.assumeIsolated { relay.target?.handleState(state) }
            },
            onTopology: { topology in
                MainActor.assumeIsolated { relay.target?.handleTopology(topology) }
            },
            onPaneRemoved: { paneID in
                MainActor.assumeIsolated { relay.target?.handlePaneRemoved(paneID) }
            },
            onPaneTerminal: { terminal in
                MainActor.assumeIsolated { relay.target?.handlePaneTerminal(terminal) }
            },
            onActivePaneChanged: { paneID in
                MainActor.assumeIsolated { relay.target?.handleActivePaneChanged(paneID) }
            },
            onPaneSurfaceFailed: { paneID, failedSurface in
                MainActor.assumeIsolated {
                    relay.target?.handlePaneSurfaceFailure(paneID, failedSurface: failedSurface)
                }
            },
            onRequestFailed: { request in
                MainActor.assumeIsolated { relay.target?.handleRequestFailed(request) }
            }
        ), zoomOwner: zoomOwner)
        self.controller = controller
        self.link = TmuxSessionLink(controller: controller, transport: transport)
        relay.target = self
    }

    // MARK: Connection

    func connect(viewport: TmuxControlViewport?) {
        guard !isShutDown, !didStartLink, let viewport else { return }
        didStartLink = true
        linkIsActive = true
        transportFailure = nil
        let link = self.link
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await link.start(viewport: viewport)
            } catch {
                await self?.connectFailed(link: link, error: error)
            }
        }
    }

    private func connectFailed(link failed: TmuxSessionLink, error: any Error) async {
        await failed.stop()
        guard !isShutDown, link === failed, linkIsActive else { return }
        linkIsActive = false
        transportFailure = GhosttyTerminalDisconnectReasonClassifier.tmuxStartFailure(error, tmuxPath: tmuxPath)
        state = .detached(nil)
    }

    func disconnect() async {
        guard linkIsActive else { return }
        linkIsActive = false
        await link.stop()
        controller.attachmentStopped()
    }

    func invalidateInactiveTransportOnForeground(
        willInvalidate: (TerminalDisconnectReason) -> Void
    ) async -> TerminalDisconnectReason? {
        guard linkIsActive else { return nil }
        guard let isActive = await link.controlChannelIsActive(), !isActive else { return nil }
        guard linkIsActive, !isShutDown else { return nil }
        let reason = GhosttyTerminalDisconnectReasonClassifier.foregroundMissingHost()
        willInvalidate(reason)
        await link.invalidateTransport()
        return reason
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        livePaneIDs.removeAll()
        pendingTerminalsByPaneID.removeAll()

        if !creatingPaneIDs.isEmpty {
            await withCheckedContinuation { shutdownDrainContinuation = $0 }
        }
        for surface in surfacesByPaneID.values {
            closeRetainedSurface(surface)
        }
        if closingRenderers > 0 {
            await withCheckedContinuation { closesDrainedContinuation = $0 }
        }
        linkIsActive = false
        await link.stop()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func resumeShutdownDrainIfQuiescent() {
        guard creatingPaneIDs.isEmpty, let continuation = shutdownDrainContinuation else { return }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Native callbacks

    private func handleState(_ newState: TmuxSessionController.SessionState) {
        if case .ready = newState {
            hasBeenReady = true
        }
        // tmux refuses an attach to a session it doesn't have before the session ever shows ("can't find
        // session", or "no sessions" with no server); the control client reads that refusal as a failure.
        if case .detached(.channelAborted) = newState, !hasBeenReady {
            applyState(.detached(.sessionEnded))
            return
        }
        applyState(newState)
    }

    private func applyState(_ newState: TmuxSessionController.SessionState) {
        state = newState
        switch newState {
        case .detached, .closed:
            reconcilePresentationActivity()
            linkIsActive = false
            Task { await link.stop() }
        case .ready:
            reconcilePresentationActivity()
        case .attaching, .syncing:
            break
        }
    }

    func handleTopology(_ snapshot: TmuxSessionController.TopologySnapshot) {
        topology = snapshot
        let paneIDs = Set(snapshot.panes.map(\.id))
        livePaneIDs = Set(snapshot.panes.lazy.filter { $0.phase == .live }.map(\.id))
        pendingTerminalsByPaneID = pendingTerminalsByPaneID.filter { paneIDs.contains($0.key) }
        presentationFailures = presentationFailures.filter { paneIDs.contains($0.key) }
        reconcileSurfaceDisplayMetrics()
        for paneID in pendingTerminalsByPaneID.keys.sorted() {
            createSurfaceIfPossible(paneID: paneID)
        }
        reconcilePresentationActivity()
    }

    private func handlePaneRemoved(_ paneID: TmuxPaneID) {
        livePaneIDs.remove(paneID)
        pendingTerminalsByPaneID.removeValue(forKey: paneID)
        presentationFailures.removeValue(forKey: paneID)
        presentationDidChange()
        guard let surface = surfacesByPaneID[paneID] else { return }
        closeRetainedSurface(surface)
    }

    private func handlePaneTerminal(
        _ terminal: TmuxSessionController.RetainedPaneTerminal
    ) {
        let paneID = terminal.paneID
        guard !isShutDown, presentationFailures[paneID] == nil,
              topology?.panes.contains(where: { $0.id == paneID }) == true
        else { return }

        // The retained terminal handoff is the native client's live boundary.
        // Hydration completion does not emit a second topology snapshot, so a
        // pane first reported as hydrating must become capture-eligible here.
        markPaneLiveAfterTerminalHandoff(paneID)

        guard
              surfacesByPaneID[paneID] == nil,
              pendingTerminalsByPaneID[paneID] == nil
        else { return }
        pendingTerminalsByPaneID[paneID] = terminal
        createSurfaceIfPossible(paneID: paneID)
    }

    private func markPaneLiveAfterTerminalHandoff(_ paneID: TmuxPaneID) {
        livePaneIDs.insert(paneID)
    }

    private func handleActivePaneChanged(_ paneID: TmuxPaneID) {
        surfacesByPaneID[paneID]?.renderer.refreshInteractionState()
    }

    private func handleRendererFailure(_ paneID: TmuxPaneID) {
        guard !isShutDown else { return }
        if case .failed = presentation(for: paneID) { return }
        guard let surface = surfacesByPaneID[paneID] else {
            failPresentation(paneID, message: "Terminal pane could not be initialized. Reconnect to try again.")
            return
        }
        guard let topology,
              let metrics = presentationMetrics(for: paneID, in: topology)
        else {
            surface.renderer.failPresentation(message: "Terminal renderer is unavailable. Reconnect to try again.")
            return
        }
        surface.renderer.replaceRenderer(
            baseConfig: baseSurfaceConfig(),
            metrics: metrics,
            theme: paneViewTheme()
        ) { [weak self, weak surface] result in
            guard let self else { return }
            switch result {
            case .replaced:
                if let surface,
                   surfacesByPaneID[paneID] === surface {
                    self.reconcilePresentationActivity()
                }
            case .busy:
                break
            case .failed:
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.rendererReplacement failed pane=\(paneID)"
                )
            }
        }
    }

    private func handlePaneSurfaceFailure(
        _ paneID: TmuxPaneID,
        failedSurface: TmuxSessionController.TerminalSurfaceHandle?
    ) {
        guard !isShutDown else { return }
        guard let failedSurface else {
            failPresentation(paneID, message: "Terminal pane could not be initialized. Reconnect to try again.")
            return
        }
        guard let surface = surfacesByPaneID[paneID],
              surface.renderer.rawSurface == failedSurface.value
        else { return }
        surface.renderer.reportRendererFailure()
    }

    private func handleRequestFailed(_ request: TmuxSessionController.Request) {
        lastFailedRequest = request
    }

    // MARK: Viewport and surface creation

    func updateViewportMeasurement(_ measurement: GhosttyTerminalViewportMeasurement) {
        guard measurement != viewportMeasurement else { return }
        viewportMeasurement = measurement
        reconcileSurfaceDisplayMetrics()
        for paneID in pendingTerminalsByPaneID.keys.sorted() {
            createSurfaceIfPossible(paneID: paneID)
        }
        reconcilePresentationActivity()
    }

    private func createSurfaceIfPossible(paneID: TmuxPaneID) {
        guard !isShutDown,
              let topology,
              let metrics = presentationMetrics(for: paneID, in: topology),
              presentationFailures[paneID] == nil,
              let terminal = pendingTerminalsByPaneID[paneID],
              surfacesByPaneID[paneID] == nil,
              creatingPaneIDs.insert(paneID).inserted
        else { return }

        createPaneSurface(
            app,
            controller,
            terminal,
            baseSurfaceConfig(),
            metrics,
            paneViewTheme(),
            { [weak self] paneID in self?.handleRendererFailure(paneID) }
        ) { [weak self] result in
            guard let self else {
                if case .success(let surface) = result { surface.renderer.close() }
                return
            }
            creatingPaneIDs.remove(paneID)
            // The terminal stays pending until its renderer's creation and
            // registration finish, whatever the result.
            pendingTerminalsByPaneID.removeValue(forKey: paneID)
            switch result {
            case .failure(let error):
                failPresentation(paneID, message: "Terminal renderer could not be created. Reconnect to try again.")
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.createFailed pane=\(paneID) error=\(String(describing: error))"
                )
            case .success(let surface):
                guard !isShutDown,
                      self.topology?.panes.contains(where: { $0.id == paneID }) == true
                else {
                    close(surface.renderer)
                    resumeShutdownDrainIfQuiescent()
                    return
                }
                surface.renderer.onPresentationChange = { [weak self] in self?.presentationDidChange() }
                surfacesByPaneID[paneID] = surface
                // Registration crosses the writer queue. Geometry and settings
                // may have changed while this renderer was being admitted.
                if let failure = presentationFailures.removeValue(forKey: paneID) {
                    surface.renderer.failPresentation(message: failure.message)
                } else {
                    applyCurrentPresentationConfiguration(to: surface)
                }
                surface.renderer.setSceneActive(isAppActive)
                reconcilePresentationActivity()
            }
            resumeShutdownDrainIfQuiescent()
        }
    }

    private func applyCurrentPresentationConfiguration(to surface: TmuxPaneSurface) {
        guard let topology,
              let metrics = presentationMetrics(for: surface.paneID, in: topology),
              surface.renderer.applyTerminalConfiguration(theme: paneViewTheme()),
              surface.renderer.updateDisplay(metrics: metrics)
        else {
            surface.renderer.failPresentation(message: "Terminal renderer could not apply its current configuration. Reconnect to try again.")
            return
        }
    }

    private func reconcileSurfaceDisplayMetrics() {
        guard let topology else { return }
        for (paneID, surface) in surfacesByPaneID {
            guard let metrics = presentationMetrics(for: paneID, in: topology) else {
                continue
            }
            _ = surface.renderer.updateDisplay(metrics: metrics)
        }
    }

    private func presentationMetrics(
        for paneID: TmuxPaneID,
        in topology: TmuxSessionController.TopologySnapshot
    ) -> GhosttySurfaceDisplayMetrics? {
        guard let viewportMeasurement,
              let pane = topology.panes.first(where: { $0.id == paneID }),
              let window = topology.windows.first(where: { $0.id == pane.windowID })
        else { return nil }
        let isVisibleZoomPane = window.zoomed && window.activePaneID == paneID
        return viewportMeasurement.displayMetrics(
            columns: isVisibleZoomPane ? window.width : pane.width,
            rows: isVisibleZoomPane ? window.height : pane.height
        )
    }

    // MARK: Composite presentation

    func prepareForPaneSelection(paneID: TmuxPaneID) {
        guard !isShutDown else { return }
        surfacesByPaneID[paneID]?.renderer.cancelPickerCaptureForPresentation()
    }

    func capturePickerPreview(
        paneID: TmuxPaneID,
        columns: UInt32,
        rows: UInt32,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> CGImage? {
        guard !isShutDown,
              state == .ready,
              livePaneIDs.contains(paneID),
              let surface = surfacesByPaneID[paneID],
              !surface.renderer.isClosing
        else { return nil }
        return await surface.renderer.capturePickerPreview(
            columns: columns,
            rows: rows,
            budget: budget
        )
    }

    func cancelPickerPreview(paneID: TmuxPaneID) {
        surfacesByPaneID[paneID]?.renderer.cancelPickerCaptureForPresentation()
    }

    private func reconcilePresentationActivity() {
        let activeWindow: TmuxSessionController.WindowInfo? = {
            guard !isShutDown,
                  isAppActive,
                  isSelected,
                  state == .ready,
                  let topology,
                  let activeWindowID = topology.activeWindowID
            else { return nil }
            return topology.windows.first(where: { $0.id == activeWindowID })
        }()

        for (paneID, surface) in surfacesByPaneID {
            let pane = topology?.panes.first(where: { $0.id == paneID })
            let isInActiveWindow = pane?.windowID == activeWindow?.id
            let isFocused = isInActiveWindow && activeWindow?.activePaneID == paneID
            let isVisible = isInActiveWindow
                && livePaneIDs.contains(paneID)
                && (activeWindow?.zoomed != true || isFocused)
            surface.renderer.setSceneActive(isAppActive)
            surface.renderer.setFocused(isFocused && isVisible)
            surface.renderer.setPresented(isVisible)
        }
        presentationDidChange()
    }

    private func closeRetainedSurface(_ surface: TmuxPaneSurface) {
        close(surface.renderer) { [weak self, weak surface] in
            guard let self, let surface else { return }
            if surfacesByPaneID[surface.paneID] === surface {
                surfacesByPaneID.removeValue(forKey: surface.paneID)
            }
        }
    }

    /// Every renderer is closed here, so a shutdown can wait for all of them; `completion` runs once
    /// the renderer's surface is freed.
    private func close(
        _ renderer: TerminalPaneRenderer,
        completion: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        closingRenderers += 1
        renderer.close { [weak self] in
            completion()
            self?.rendererClosed()
        }
    }

    private func rendererClosed() {
        closingRenderers -= 1
        guard closingRenderers == 0, let continuation = closesDrainedContinuation else { return }
        closesDrainedContinuation = nil
        continuation.resume()
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        reconcilePresentationActivity()
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        reconcilePresentationActivity()
    }

    func applyTerminalConfiguration(theme: TerminalTheme) {
        guard !isShutDown else { return }
        for surface in surfacesByPaneID.values where !surface.renderer.isClosing {
            if !surface.renderer.applyTerminalConfiguration(theme: theme) {
                surface.renderer.failPresentation(message: "Terminal renderer could not apply its current configuration. Reconnect to try again.")
            }
        }
    }

    #if DEBUG
    var creatingPaneIDsForTesting: Set<TmuxPaneID> { creatingPaneIDs }
    func handleStateForTesting(_ state: TmuxSessionController.SessionState) { handleState(state) }
    func handleRendererFailureForTesting(_ paneID: TmuxPaneID) { handleRendererFailure(paneID) }
    func handleRequestFailedForTesting(_ request: TmuxSessionController.Request) {
        handleRequestFailed(request)
    }
    func handlePaneRemovedForTesting(_ paneID: TmuxPaneID) { handlePaneRemoved(paneID) }
    func handlePaneTerminalForTesting(_ paneID: TmuxPaneID) {
        guard !isShutDown,
              topology?.panes.contains(where: { $0.id == paneID }) == true
        else { return }
        markPaneLiveAfterTerminalHandoff(paneID)
    }
    #endif
}
