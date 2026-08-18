import CoreGraphics
import Foundation
import GhosttyKit

/// MainActor owner of one control attachment and one retained renderer surface
/// for every live pane. Active-window visibility and focus are projections of
/// authoritative tmux topology.
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

    typealias PaneSurfaceCreator = @MainActor (
        ghostty_app_t,
        TmuxSessionController,
        TmuxSessionController.RetainedPaneTerminal,
        ghostty_terminal_surface_config_s,
        GhosttySurfaceDisplayMetrics,
        TerminalTheme,
        @escaping @MainActor (TmuxPaneID) -> Void,
        @escaping @MainActor (Result<TmuxPaneSurface, TmuxPaneSurface.CreateError>) -> Void
    ) -> Void
    private let createPaneSurface: PaneSurfaceCreator

    @Published private(set) var surfacesByPaneID: [TmuxPaneID: TmuxPaneSurface] = [:]
    private var pendingTerminalsByPaneID: [
        TmuxPaneID: TmuxSessionController.RetainedPaneTerminal
    ] = [:]
    private var creatingPaneIDs: Set<TmuxPaneID> = []
    private var failedCreationPaneIDs: Set<TmuxPaneID> = []
    private var isAppActive = true
    private var didStartLink = false
    private var linkIsActive = false
    private var isShutDown = false
    private var shutdownDrainContinuation: CheckedContinuation<Void, Never>?

    private final class Relay: @unchecked Sendable {
        weak var target: TmuxTerminalSession?
    }

    init(
        app: ghostty_app_t,
        transport: any TmuxControlTransport,
        baseSurfaceConfig: @escaping () -> ghostty_terminal_surface_config_s,
        paneViewTheme: @escaping () -> TerminalTheme,
        createPaneSurface: @escaping PaneSurfaceCreator = TmuxPaneSurface.create
    ) {
        self.app = app
        self.baseSurfaceConfig = baseSurfaceConfig
        self.paneViewTheme = paneViewTheme
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
            onPaneSurfaceFailed: { paneID in
                MainActor.assumeIsolated { relay.target?.handleRendererFailure(paneID) }
            },
            onRequestFailed: { request in
                MainActor.assumeIsolated { relay.target?.handleRequestFailed(request) }
            }
        ))
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
        transportFailure = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
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
        await closeAllRetainedSurfaces()
        linkIsActive = false
        await link.stop()
        await withCheckedContinuation { continuation in
            controller.shutdown { continuation.resume() }
        }
    }

    private func closeAllRetainedSurfaces() async {
        let surfaces = Array(surfacesByPaneID.values)
        guard !surfaces.isEmpty else { return }
        await withCheckedContinuation { continuation in
            var remaining = surfaces.count
            for surface in surfaces {
                surface.close { [weak self, weak surface] in
                    if let self, let surface,
                       self.surfacesByPaneID[surface.paneID] === surface {
                        self.surfacesByPaneID.removeValue(forKey: surface.paneID)
                    }
                    remaining -= 1
                    if remaining == 0 { continuation.resume() }
                }
            }
        }
    }

    private func resumeShutdownDrainIfQuiescent() {
        guard creatingPaneIDs.isEmpty, let continuation = shutdownDrainContinuation else { return }
        shutdownDrainContinuation = nil
        continuation.resume()
    }

    // MARK: Native callbacks

    private func handleState(_ newState: TmuxSessionController.SessionState) {
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
        failedCreationPaneIDs.formIntersection(paneIDs)
        reconcileSurfaceDisplayMetrics()
        for paneID in pendingTerminalsByPaneID.keys.sorted() {
            createSurfaceIfPossible(paneID: paneID)
        }
        reconcilePresentationActivity()
    }

    private func handlePaneRemoved(_ paneID: TmuxPaneID) {
        livePaneIDs.remove(paneID)
        pendingTerminalsByPaneID.removeValue(forKey: paneID)
        failedCreationPaneIDs.remove(paneID)
        guard let surface = surfacesByPaneID[paneID] else { return }
        closeRetainedSurface(surface)
    }

    private func handlePaneTerminal(
        _ terminal: TmuxSessionController.RetainedPaneTerminal
    ) {
        let paneID = terminal.paneID
        guard !isShutDown,
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
        surfacesByPaneID[paneID]?.refreshInteractionState()
    }

    private func handleRendererFailure(_ paneID: TmuxPaneID) {
        guard !isShutDown,
              let surface = surfacesByPaneID[paneID],
              let topology,
              let metrics = presentationMetrics(for: paneID, in: topology)
        else { return }
        surface.replaceRenderer(
            baseConfig: baseSurfaceConfig(),
            metrics: metrics,
            theme: paneViewTheme()
        ) { [weak self, weak surface] result in
            guard let self else { return }
            switch result {
            case .replaced:
                if let surface,
                   surfacesByPaneID[paneID] === surface {
                    _ = surface.applyTerminalConfiguration(theme: paneViewTheme())
                    if let currentTopology = self.topology,
                       let currentMetrics = self.presentationMetrics(
                           for: paneID,
                           in: currentTopology
                       ) {
                        surface.updateCanonicalViewportMetrics(currentMetrics)
                    }
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
              let terminal = pendingTerminalsByPaneID.removeValue(forKey: paneID),
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
                if case .success(let surface) = result { surface.close() }
                return
            }
            creatingPaneIDs.remove(paneID)
            switch result {
            case .failure(let error):
                failedCreationPaneIDs.insert(paneID)
                GhosttyRuntimeTrace.diagnostics(
                    "tmuxPane.createFailed pane=\(paneID) error=\(String(describing: error))"
                )
            case .success(let surface):
                guard !isShutDown,
                      self.topology?.panes.contains(where: { $0.id == paneID }) == true
                else {
                    surface.close()
                    resumeShutdownDrainIfQuiescent()
                    return
                }
                surface.setSceneActive(isAppActive)
                surfacesByPaneID[paneID] = surface
                reconcilePresentationActivity()
            }
            resumeShutdownDrainIfQuiescent()
        }
    }

    private func reconcileSurfaceDisplayMetrics() {
        guard let topology else { return }
        for (paneID, surface) in surfacesByPaneID {
            guard let metrics = presentationMetrics(for: paneID, in: topology) else {
                continue
            }
            _ = surface.updateDisplay(metrics: metrics)
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
        surfacesByPaneID[paneID]?.cancelPickerCaptureForPresentation()
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
              !surface.isClosing
        else { return nil }
        return await surface.capturePickerPreview(
            columns: columns,
            rows: rows,
            budget: budget
        )
    }

    func cancelPickerPreview(paneID: TmuxPaneID) {
        surfacesByPaneID[paneID]?.cancelPickerCaptureForPresentation()
    }

    private func reconcilePresentationActivity() {
        let activeWindow: TmuxSessionController.WindowInfo? = {
            guard !isShutDown,
                  isAppActive,
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
            surface.setSceneActive(isAppActive)
            surface.setFocused(isFocused && isVisible)
            surface.setPresented(isVisible)
        }
    }

    private func closeRetainedSurface(_ surface: TmuxPaneSurface) {
        surface.close { [weak self, weak surface] in
            guard let self, let surface else { return }
            if surfacesByPaneID[surface.paneID] === surface {
                surfacesByPaneID.removeValue(forKey: surface.paneID)
            }
        }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        reconcilePresentationActivity()
    }

    func applyTerminalConfiguration(theme: TerminalTheme) {
        guard !isShutDown else { return }
        for surface in surfacesByPaneID.values where !surface.isClosing {
            _ = surface.applyTerminalConfiguration(theme: theme)
        }
    }

    #if DEBUG
    var creatingPaneIDsForTesting: Set<TmuxPaneID> { creatingPaneIDs }
    func handleStateForTesting(_ state: TmuxSessionController.SessionState) { handleState(state) }
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
