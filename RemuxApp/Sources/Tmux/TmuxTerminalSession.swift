import Foundation
import GhosttyKit

/// MainActor owner of one control attachment and one retained real renderer
/// surface for every live pane. Only `paneSurface` is published to the phone
/// viewport; the retained map is not presentation state.
@MainActor
final class TmuxTerminalSession: ObservableObject {
    @Published private(set) var state: TmuxSessionController.SessionState = .detached(nil)
    @Published private(set) var topology: TmuxSessionController.TopologySnapshot?
    @Published private(set) var paneSurface: TmuxPaneSurface?
    @Published private(set) var livePaneIDs: Set<TmuxPaneID> = []
    @Published private(set) var lastFailedRequest: TmuxSessionController.Request?
    @Published private(set) var transportFailure: TerminalDisconnectReason?

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

    private var surfacesByPaneID: [TmuxPaneID: TmuxPaneSurface] = [:]
    private var pendingTerminalsByPaneID: [
        TmuxPaneID: TmuxSessionController.RetainedPaneTerminal
    ] = [:]
    private var creatingPaneIDs: Set<TmuxPaneID> = []
    private var failedCreationPaneIDs: Set<TmuxPaneID> = []
    private var pendingPaneID: TmuxPaneID?
    private var zoomRequestedPaneID: TmuxPaneID?
    private var preparingSurface: TmuxPaneSurface?
    private var viewportMetrics: GhosttySurfaceDisplayMetrics?
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
            onPanePhaseChanged: { paneID, phase in
                MainActor.assumeIsolated {
                    relay.target?.handlePanePhaseChanged(paneID, phase: phase)
                }
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
        pendingPaneID = nil
        zoomRequestedPaneID = nil
        cancelPendingPresentation()
        livePaneIDs.removeAll()
        pendingTerminalsByPaneID.removeAll()
        unpublishPane()

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
            pendingPaneID = nil
            zoomRequestedPaneID = nil
            cancelPendingPresentation()
            linkIsActive = false
            Task { await link.stop() }
        case .ready:
            if let topology { presentActivePane(from: topology) }
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
        if let zoomRequestedPaneID,
           activePaneID(in: snapshot) != zoomRequestedPaneID
            || isFullViewport(paneID: zoomRequestedPaneID, in: snapshot) {
            self.zoomRequestedPaneID = nil
        }
        presentActivePane(from: snapshot)
    }

    private func handlePaneRemoved(_ paneID: TmuxPaneID) {
        livePaneIDs.remove(paneID)
        pendingTerminalsByPaneID.removeValue(forKey: paneID)
        failedCreationPaneIDs.remove(paneID)
        if pendingPaneID == paneID { pendingPaneID = nil }
        if zoomRequestedPaneID == paneID { zoomRequestedPaneID = nil }
        if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
        if paneSurface?.paneID == paneID { unpublishPane() }
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

    private func handlePanePhaseChanged(
        _ paneID: TmuxPaneID,
        phase: TmuxSessionController.PaneInfo.Phase
    ) {
        switch phase {
        case .hydrating:
            livePaneIDs.remove(paneID)
            if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
        case .live:
            livePaneIDs.insert(paneID)
            if let topology, activePaneID(in: topology) == paneID {
                presentActivePane(from: topology)
            }
        }
    }

    private func handleActivePaneChanged(_ paneID: TmuxPaneID) {
        guard paneSurface?.paneID == paneID else { return }
        paneSurface?.refreshInteractionState()
    }

    private func handleRendererFailure(_ paneID: TmuxPaneID) {
        guard !isShutDown,
              let surface = surfacesByPaneID[paneID],
              let viewportMetrics
        else { return }
        relinquishPresentationOwnership(of: surface)
        surface.replaceRenderer(
            baseConfig: baseSurfaceConfig(),
            metrics: viewportMetrics,
            theme: paneViewTheme()
        ) { [weak self, weak surface] result in
            guard let self else { return }
            switch result {
            case .replaced:
                if let surface,
                   surfacesByPaneID[paneID] === surface {
                    _ = surface.applyTerminalConfiguration(theme: paneViewTheme())
                    if let currentViewportMetrics = self.viewportMetrics {
                        surface.updateCanonicalViewportMetrics(currentViewportMetrics)
                    }
                    if let topology { presentActivePane(from: topology) }
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
        if request == .selectPane || request == .selectWindow {
            pendingPaneID = nil
            zoomRequestedPaneID = nil
            cancelPendingPresentation()
        }
        if request == .zoomPane {
            // Keep the terminal unpresented: split geometry is not the phone's
            // canonical terminal viewport.
            return
        }
        if let topology { presentActivePane(from: topology) }
    }

    // MARK: Viewport and surface creation

    func updateViewportMetrics(size: CGSize, scale: CGFloat) {
        let metrics = GhosttySurfaceDisplayMetrics(size: size, scale: scale)
        let changed = metrics != viewportMetrics
        viewportMetrics = metrics
        for surface in surfacesByPaneID.values {
            surface.updateCanonicalViewportMetrics(metrics)
        }
        if changed, preparingSurface != nil {
            cancelPendingPresentation()
        }
        for paneID in pendingTerminalsByPaneID.keys.sorted() {
            createSurfaceIfPossible(paneID: paneID)
        }
        if changed, let topology {
            presentActivePane(from: topology)
        }
    }

    private func createSurfaceIfPossible(paneID: TmuxPaneID) {
        guard !isShutDown,
              let metrics = viewportMetrics,
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
                      topology?.panes.contains(where: { $0.id == paneID }) == true
                else {
                    surface.close()
                    resumeShutdownDrainIfQuiescent()
                    return
                }
                surface.setSceneActive(isAppActive)
                surfacesByPaneID[paneID] = surface
                if let topology { presentActivePane(from: topology) }
            }
            resumeShutdownDrainIfQuiescent()
        }
    }

    // MARK: Singular presentation

    func prepareForPaneSelection(paneID: TmuxPaneID) {
        guard !isShutDown,
              isAppActive,
              let topology,
              topology.panes.contains(where: { $0.id == paneID })
        else { return }
        if activePaneID(in: topology) == paneID,
           isFullViewport(paneID: paneID, in: topology) {
            let hasConflictingIntent = pendingPaneID != nil && pendingPaneID != paneID
            if !hasConflictingIntent {
                if paneSurface?.paneID == paneID || preparingSurface?.paneID == paneID {
                    return
                }
                pendingPaneID = nil
                cancelPendingPresentation()
                presentActivePane(from: topology)
                return
            }
        }
        surfacesByPaneID[paneID]?.cancelPickerCaptureForPresentation()
        cancelPendingPresentation()
        pendingPaneID = paneID
        zoomRequestedPaneID = isFullViewport(paneID: paneID, in: topology)
            ? nil
            : paneID
        unpublishPane()
    }

    func capturePickerPreview(
        paneID: TmuxPaneID,
        columns: UInt32,
        rows: UInt32,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) async -> GhosttyPanePreviewSession.RenderedPreview? {
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

    func visiblePaneTexts() -> [(paneID: TmuxPaneID, text: String)] {
        surfacesByPaneID.compactMap { paneID, surface in
            surface.visibleText().map { (paneID, $0) }
        }
    }

    private func presentActivePane(from snapshot: TmuxSessionController.TopologySnapshot) {
        guard !isShutDown, isAppActive, state == .ready,
              let paneID = activePaneID(in: snapshot)
        else { return }
        if let pendingPaneID, pendingPaneID != paneID { return }
        guard livePaneIDs.contains(paneID) else {
            // A refresh of the pane already on screen changes its terminal
            // contents in place. Keep that real surface focused so input can
            // remain ordered through the control-client queue; only a pane
            // that has not yet been presented must wait for hydration.
            if paneSurface?.paneID == paneID,
               isFullViewport(paneID: paneID, in: snapshot) {
                paneSurface?.setSceneActive(true)
                return
            }
            if preparingSurface?.paneID == paneID { cancelPendingPresentation() }
            unpublishPane()
            return
        }

        guard isFullViewport(paneID: paneID, in: snapshot) else {
            unpublishPane()
            if zoomRequestedPaneID != paneID {
                zoomRequestedPaneID = paneID
                controller.requestZoomPane(paneID: paneID)
            }
            return
        }
        zoomRequestedPaneID = nil

        guard paneSurface?.paneID != paneID else {
            pendingPaneID = nil
            paneSurface?.setSceneActive(true)
            return
        }
        guard !failedCreationPaneIDs.contains(paneID),
              let surface = surfacesByPaneID[paneID],
              !surface.isClosing
        else { return }
        if preparingSurface === surface { return }

        cancelPendingPresentation()
        unpublishPane()
        preparingSurface = surface
        surface.prepareForPresentation { [weak self, weak surface] ready in
            guard let self, let surface,
                  preparingSurface === surface
            else { return }
            preparingSurface = nil
            guard ready,
                  !isShutDown,
                  isAppActive,
                  state == .ready,
                  let topology,
                  activePaneID(in: topology) == surface.paneID,
                  livePaneIDs.contains(surface.paneID),
                  pendingPaneID == nil || pendingPaneID == surface.paneID,
                  isFullViewport(paneID: surface.paneID, in: topology)
            else {
                surface.cancelPresentationPreparation()
                return
            }
            paneSurface = surface
            pendingPaneID = nil
            surface.setSceneActive(isAppActive)
            surface.setPresented(true)
        }
    }

    private func cancelPendingPresentation() {
        guard let surface = preparingSurface else { return }
        preparingSurface = nil
        surface.cancelPresentationPreparation()
    }

    private func unpublishPane() {
        guard let surface = paneSurface else { return }
        surface.setPresented(false)
        paneSurface = nil
    }

    private func relinquishPresentationOwnership(of surface: TmuxPaneSurface) {
        if preparingSurface === surface {
            cancelPendingPresentation()
        }
        if paneSurface === surface {
            unpublishPane()
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
        if !active {
            cancelPendingPresentation()
            paneSurface?.setSceneActive(false)
        }
        if active, let topology { presentActivePane(from: topology) }
    }

    func applyTerminalConfiguration(theme: TerminalTheme) {
        guard !isShutDown else { return }
        for surface in surfacesByPaneID.values where !surface.isClosing {
            _ = surface.applyTerminalConfiguration(theme: theme)
        }
    }

    private func activePaneID(
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> TmuxPaneID? {
        guard let windowID = snapshot.activeWindowID else { return nil }
        return snapshot.windows.first(where: { $0.id == windowID })?.activePaneID
    }

    private func isFullViewport(
        paneID: TmuxPaneID,
        in snapshot: TmuxSessionController.TopologySnapshot
    ) -> Bool {
        guard let pane = snapshot.panes.first(where: { $0.id == paneID }),
              let window = snapshot.windows.first(where: { $0.id == pane.windowID })
        else { return false }
        if window.zoomed { return true }
        return !snapshot.panes.contains {
            $0.windowID == window.id && $0.id != paneID
        }
    }

    #if DEBUG
    var pendingPaneIDForTesting: TmuxPaneID? { pendingPaneID }
    var zoomRequestedPaneIDForTesting: TmuxPaneID? { zoomRequestedPaneID }
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
