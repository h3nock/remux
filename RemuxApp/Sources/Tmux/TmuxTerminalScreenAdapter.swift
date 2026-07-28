import Combine
import CoreGraphics
import Foundation
import GhosttyKit


/// Presents the new tmux session stack (`TmuxTerminalSession`) through the
/// `GhosttyTerminalScreenModeling` boundary so `GhosttySurfaceScreen` — the
/// full terminal UX — renders it unchanged.
///
/// Topology mapping: tmux window/pane IDs (UInt64) are mapped to stable UUIDs
/// for the screen's projections. The session may retain multiple real pane
/// surfaces, while this adapter publishes only the active pane's stable
/// `GhosttyManagedSurface` to the phone viewport.
@MainActor
final class TmuxTerminalScreenAdapter: ObservableObject {
    private static let panePreviewCacheByteLimit = 8 * 1024 * 1024

    private weak var session: TmuxTerminalSession?
    private var controller: TmuxSessionController?

    /// The last topology emitted by `session.$topology`. All adapter reads go
    /// through this value, never `session.topology`: `@Published` emits from
    /// `willSet`, so reading the property inside a sink returns the previous
    /// snapshot and the projection lags one topology update behind.
    private var latestTopology: TmuxSessionController.TopologySnapshot?
    private var identities = TmuxTerminalIdentityRegistry()

    private var activeManagedSurface: GhosttyManagedSurface?
    private var activeManagedPaneID: TmuxPaneID?
    private var initialViewportHandler: ((CGSize, CGFloat) -> Void)?
    private var clientSizeHandler: ((TmuxSessionController.ClientSize) -> Void)?
    private var viewportStabilityHandler: ((Bool) -> Void)?
    private var cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot.empty
    private var panePreviewCache = TmuxPanePreviewImageCache(
        byteLimit: TmuxTerminalScreenAdapter.panePreviewCacheByteLimit
    )

    private var commandFailureMessage: String?
    private(set) var commandFailureEvent: GhosttyTmuxCommandFailureEvent?
    private var commandFailureToken: UInt64 = 0

    private var subscriptions: [AnyCancellable] = []

    /// Connects the adapter to a live session. Called once, right after the
    /// session is created.
    func activate(
        session: TmuxTerminalSession,
        initialViewportHandler: @escaping (CGSize, CGFloat) -> Void,
        clientSizeHandler: @escaping (TmuxSessionController.ClientSize) -> Void,
        viewportStabilityHandler: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.controller = session.controller
        self.initialViewportHandler = initialViewportHandler
        self.clientSizeHandler = clientSizeHandler
        self.viewportStabilityHandler = viewportStabilityHandler

        session.$state
            .sink { [weak self] state in
                guard let self else { return }
                if case .detached = state {
                    self.clearPanePreviewCache(reason: "detached")
                } else if case .closed = state {
                    self.clearPanePreviewCache(reason: "closed")
                }
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        // Subscribed before $paneSurface so the replayed initial value seeds
        // latestTopology ahead of the surface rebuild below.
        session.$topology
            .sink { [weak self] topology in
                guard let self else { return }
                self.latestTopology = topology
                if let topology {
                    self.reconcilePanePreviewCache(with: topology)
                } else {
                    self.clearPanePreviewCache(reason: "topology-unavailable")
                }
                self.rebuildTopologySnapshot()
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$paneSurface
            .sink { [weak self] paneSurface in
                self?.rebuildActiveManagedSurface(for: paneSurface)
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$lastFailedRequest
            .sink { [weak self] request in
                guard let request else { return }
                self?.presentCommandFailure(for: request)
            }
            .store(in: &subscriptions)
        session.$transportFailure
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    func invalidate() {
        subscriptions.removeAll()
        activeManagedSurface = nil
        activeManagedPaneID = nil
        clearPanePreviewCache(reason: "invalidate")
        session = nil
        controller = nil
        initialViewportHandler = nil
        clientSizeHandler = nil
        viewportStabilityHandler = nil
        latestTopology = nil
        cachedTopologySnapshot = Self.emptyTopologySnapshot
    }

    func terminalConfigurationDidChange() {
        clearPanePreviewCache(reason: "appearance-change")
        if let activeManagedSurface {
            reportClientSizeIfActive(activeManagedSurface)
        }
    }

    func tmuxPaneID(for surfaceID: UUID) -> TmuxPaneID? {
        let paneID = activeManagedSurface?.id == surfaceID
            ? activeManagedPaneID
            : identities.paneID(for: surfaceID)
        guard let paneID,
              latestTopology?.panes.contains(where: { $0.id == paneID }) == true
        else { return nil }
        return paneID
    }

    func viewportSnapshots(
        workspaceID: SavedWorkspace.ID,
        serverName: String,
        sessionName: String
    ) -> [TerminalViewportSnapshot] {
        guard let session else { return [] }
        return viewportSnapshots(
            workspaceID: workspaceID,
            serverName: serverName,
            sessionName: sessionName,
            visiblePaneTexts: session.visiblePaneTexts()
        )
    }

    func viewportSnapshots(
        workspaceID: SavedWorkspace.ID,
        serverName: String,
        sessionName: String,
        visiblePaneTexts: [(paneID: TmuxPaneID, text: String)]
    ) -> [TerminalViewportSnapshot] {
        guard let topology = latestTopology else { return [] }
        let textByPaneID = Dictionary(
            uniqueKeysWithValues: visiblePaneTexts.map { ($0.paneID, $0.text) }
        )
        return topology.windows.enumerated().flatMap { windowIndex, window in
            let windowName = window.name.isEmpty
                ? "Window \(windowIndex + 1)"
                : window.name
            return Self.orderedPanes(in: window.id, topology: topology)
                .enumerated()
                .compactMap { paneIndex, pane -> TerminalViewportSnapshot? in
                    guard let text = textByPaneID[pane.id] else { return nil }
                    return TerminalViewportSnapshot(
                        workspaceID: workspaceID,
                        serverName: serverName,
                        sessionName: sessionName,
                        windowID: identities.surfaceID(for: window.id),
                        windowName: windowName,
                        paneID: identities.surfaceID(for: pane.id),
                        paneIndex: paneIndex + 1,
                        text: text
                    )
                }
        }
    }

    static func orderedPanes(
        in windowID: TmuxWindowID,
        topology: TmuxSessionController.TopologySnapshot
    ) -> [TmuxSessionController.PaneInfo] {
        topology.panes
            .filter { $0.windowID == windowID }
            .sorted { lhs, rhs in
                (lhs.y, lhs.x, lhs.id) < (rhs.y, rhs.x, rhs.id)
            }
    }

    // MARK: Topology synthesis

    private static var emptyTopologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        GhosttyRuntimeSurfaceTopologySnapshot.empty
    }

    private var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        cachedTopologySnapshot
    }

    private func rebuildTopologySnapshot() {
        guard let topology = latestTopology else {
            cachedTopologySnapshot = Self.emptyTopologySnapshot
            return
        }

        let topLevels = topology.windows.map { window in
            let paneIDs = Self.orderedPanes(in: window.id, topology: topology)
                .map { identities.surfaceID(for: $0.id) }
            return GhosttyTopLevelSurface(
                id: identities.surfaceID(for: window.id),
                name: window.name,
                leafIDs: paneIDs,
                focusedLeafID: window.activePaneID.map { identities.surfaceID(for: $0) }
            )
        }

        cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot(
            topLevels: topLevels,
            selectedTopLevelID: topology.activeWindowID.map { identities.surfaceID(for: $0) }
        )
    }

    private var runtimePhase: GhosttyTerminalRuntimePhase {
        guard let session else {
            return .failed(message: "terminal session unavailable", reason: nil)
        }
        switch session.state {
        case .attaching, .syncing:
            return .starting
        case .ready:
            return .running
        case .detached(nil):
            if let failure = session.transportFailure {
                return .failed(message: failure.message, reason: failure)
            }
            // Pre-connect; the first connect is imminent.
            return .starting
        case .detached(.some(let reason)):
            let mapped = reason.terminalDisconnectReason
            return .failed(message: mapped.message, reason: mapped)
        case .closed(let reason):
            let mapped = reason.terminalDisconnectReason
            return .failed(message: mapped.message, reason: mapped)
        }
    }

    private var isTransportWritable: Bool {
        session?.state == .ready
    }

    // MARK: Managed surface lifecycle

    private func rebuildActiveManagedSurface(for paneSurface: TmuxPaneSurface?) {
        if activeManagedSurface != nil {
            activeManagedSurface = nil
            activeManagedPaneID = nil
        }

        guard let paneSurface else { return }

        let paneID = paneSurface.paneID
        if case .paneGeometry? = panePreviewCache.entries[paneID]?.preview.source {
            panePreviewCache.remove(paneID)
        }
        let wasAlreadyWrapped = paneSurface.managedSurface != nil
        let managed = paneSurface.screenSurface { [weak self, weak paneSurface] managed, size, _ in
            guard size.width > 1, size.height > 1 else { return }
            GhosttyRuntimeTrace.flowEventOnce(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.layout.ready",
                fields: [
                    "height": "\(size.height)",
                    "pane": "\(paneID)",
                    "surface": paneSurface.map { String(describing: $0.rawSurface) } ?? "released",
                    "width": "\(size.width)",
                ]
            )
            self?.reportClientSizeIfActive(managed)
        }
        activeManagedSurface = managed
        activeManagedPaneID = paneID
        if !wasAlreadyWrapped {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.managedSurface.ready",
                fields: [
                    "pane": "\(paneID)",
                    "surface": String(describing: paneSurface.rawSurface),
                    "surface_uuid": managed.id.uuidString,
                ]
            )
        }
    }

    private func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        if let active = activeManagedSurface, active.id == id {
            return active
        }
        return nil
    }

    private var focusedManagedSurface: GhosttyManagedSurface? {
        activeManagedSurface
    }

    private func reportClientSizeIfActive(_ managed: GhosttyManagedSurface) {
        guard activeManagedSurface === managed else { return }
        let size = managed.controlSurface.currentSize()
        guard size.columns >= 2, size.rows >= 2 else { return }
        clientSizeHandler?(TmuxSessionController.ClientSize(
            cols: UInt32(size.columns),
            rows: UInt32(size.rows)
        ))
    }

    // MARK: Command failures

    private func presentCommandFailure(for request: TmuxSessionController.Request) {
        commandFailureToken &+= 1
        let message = "tmux: \(Self.failureLabel(for: request)) failed"
        commandFailureMessage = message
        commandFailureEvent = GhosttyTmuxCommandFailureEvent(
            token: commandFailureToken,
            message: message
        )
        objectWillChange.send()

        let token = commandFailureToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.commandFailureToken == token else { return }
            self.commandFailureMessage = nil
            self.objectWillChange.send()
        }
    }

    private static func failureLabel(for request: TmuxSessionController.Request) -> String {
        switch request {
        case .newWindow: "new window"
        case .splitPane: "split pane"
        case .closePane: "close pane"
        case .closeWindow: "close window"
        case .selectWindow: "select window"
        case .selectPane: "select pane"
        case .zoomPane: "zoom pane"
        case .copyMode: "copy mode"
        case .setClientSize: "resize"
        case .sendInput: "input"
        }
    }
}

// MARK: - GhosttyTerminalScreenModeling

extension TmuxTerminalScreenAdapter: GhosttyTerminalScreenModeling {
    func prepareInitialViewport(size: CGSize, scale: CGFloat) {
        initialViewportHandler?(size, scale)
    }

    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection {
        GhosttyTerminalPresentationProjector.terminalScreenPresentationProjection(
            phase: runtimePhase,
            transportWritable: isTransportWritable,
            commandFailureMessage: commandFailureMessage,
            debugStatus: stateTraceLabel,
            registryDebugSummary: "tmux session stack",
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot
        )
    }

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: runtimePhase,
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot
        )
    }

    var terminalManagedSurfaceLookup: GhosttyManagedSurfaceLookup {
        GhosttyManagedSurfaceLookup { [weak self] id in
            self?.managedSurface(for: id)
        }
    }

    var stateTraceLabel: String {
        guard let session else { return "released" }
        return switch session.state {
        case .detached: "detached"
        case .attaching: "attaching"
        case .syncing: "syncing"
        case .ready: "ready"
        case .closed: "closed"
        }
    }

    func setViewportStabilityHint(stable: Bool) {
        viewportStabilityHandler?(stable)
    }

    func makePanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
    ) -> GhosttyPanePreviewSession {
        return newPanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: previewSizing
        )
    }

    private func newPanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
    ) -> GhosttyPanePreviewSession {
        GhosttyPanePreviewSession(
            leafIDs: leafIDs,
            previewSizing: previewSizing,
            client: GhosttyPanePreviewSession.PreviewClient(
                capture: { [weak self] leafID, budget in
                    guard let self,
                          let session = self.session,
                          let paneID = self.identities.paneID(for: leafID),
                          let pane = self.latestTopology?.panes.first(where: { $0.id == paneID })
                    else { return nil }
                    return await session.capturePickerPreview(
                        paneID: paneID,
                        columns: pane.width,
                        rows: pane.height,
                        budget: budget
                    )
                },
                cancelCapture: { [weak self] leafID in
                    guard let self,
                          let paneID = self.identities.paneID(for: leafID)
                    else { return }
                    self.session?.cancelPickerPreview(paneID: paneID)
                },
                cachedPreview: { [weak self] leafID in
                    guard let self,
                          let paneID = self.identities.paneID(for: leafID)
                    else { return nil }
                    guard let preview = self.panePreviewCache.preview(for: paneID) else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=miss"
                        )
                        return nil
                    }
                    if case .paneGeometry(let provenance) = preview.source,
                       self.latestTopology?.panes.first(where: { $0.id == paneID }).map({
                           $0.width != provenance.columns || $0.height != provenance.rows
                       }) != false {
                        self.panePreviewCache.remove(paneID)
                        return nil
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=hit source=\(Self.previewSourceLabel(preview.source)) bytes=\(preview.image.bytesPerRow * preview.image.height)"
                    )
                    return preview
                },
                shouldRefreshCachedImage: { [weak self] leafID in
                    guard let self,
                          let paneID = self.identities.paneID(for: leafID)
                    else { return false }
                    return self.activeManagedPaneID == paneID
                },
                cacheRenderedPreview: { [weak self] leafID, preview in
                    guard let self,
                          self.session?.state == .ready,
                          let paneID = self.identities.paneID(for: leafID),
                          self.latestTopology?.panes.contains(where: { $0.id == paneID }) == true
                    else { return }
                    let evictedPaneIDs = self.panePreviewCache.store(
                        preview,
                        for: paneID
                    )
                    guard self.panePreviewCache.entries[paneID]?.preview.image === preview.image else {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache pane=\(paneID) result=reject-oversize bytes=\(preview.image.bytesPerRow * preview.image.height) limit=\(self.panePreviewCache.byteLimit)"
                        )
                        return
                    }
                    GhosttyRuntimeTrace.perf(
                        "tmuxPane.preview.cache pane=\(paneID) result=store source=\(Self.previewSourceLabel(preview.source)) bytes=\(preview.image.bytesPerRow * preview.image.height) total=\(self.panePreviewCache.totalByteCost)"
                    )
                    if !evictedPaneIDs.isEmpty {
                        GhosttyRuntimeTrace.perf(
                            "tmuxPane.preview.cache result=evict panes=\(evictedPaneIDs) total=\(self.panePreviewCache.totalByteCost)"
                        )
                    }
                }
            )
        )
    }

    private static func previewSourceLabel(
        _ source: GhosttyPanePreviewSession.PreviewSource
    ) -> String {
        switch source {
        case .paneGeometry(let provenance):
            return "pane-geometry-\(provenance.columns)x\(provenance.rows)"
        case .fullViewport(let provenance):
            return "full-viewport-\(provenance.pixelWidth)x\(provenance.pixelHeight)"
        }
    }

    private func reconcilePanePreviewCache(
        with topology: TmuxSessionController.TopologySnapshot
    ) {
        let removedPaneIDs = panePreviewCache.retainOnly(Set(topology.panes.map(\.id)))
        guard !removedPaneIDs.isEmpty else { return }
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.cache result=topology-remove panes=\(removedPaneIDs) total=\(panePreviewCache.totalByteCost)"
        )
    }

    private func clearPanePreviewCache(reason: String) {
        guard !panePreviewCache.entries.isEmpty else { return }
        panePreviewCache.removeAll()
        GhosttyRuntimeTrace.perf(
            "tmuxPane.preview.cache result=clear reason=\(reason)"
        )
    }

    // MARK: Input routing

    private func preflightFocusedInput() -> FocusedTerminalInputSubmissionResult? {
        guard isTransportWritable else { return .transportUnavailable }
        guard focusedManagedSurface != nil else { return .noFocusedSurface }
        return nil
    }

    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendInput(text) ?? .noFocusedSurface
    }

    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendPaste(text) ?? .noFocusedSurface
    }

    func sendPaste(_ text: String, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult {
        guard isTransportWritable else { return .transportUnavailable }
        guard let managed = managedSurface(for: surfaceID) else { return .noFocusedSurface }
        return managed.sendPaste(text)
    }

    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        if let preflight = preflightFocusedInput() { return preflight }
        return focusedManagedSurface?.sendKeyEvent(event) ?? .noFocusedSurface
    }

    func isMouseCaptured(for surfaceID: UUID) -> Bool {
        managedSurface(for: surfaceID)?.controlSurface.isMouseCaptured() ?? false
    }

    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        return managed.sendMouseButton(event) ? .sent : .surfaceRejected
    }

    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        managed.sendMousePosition(position, mods: mods)
        return .sent
    }

    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome {
        guard let managed = managedSurface(for: surfaceID) else {
            return .missingTarget(surfaceID)
        }
        managed.sendMouseScroll(event)
        return .sent
    }

    // MARK: tmux topology actions

    func focusTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let paneID = identities.paneID(for: id), let controller else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "adapter.resolve.failed",
                fields: ["target_uuid": id.uuidString]
            )
            return .missingTarget(.pane(id))
        }
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "adapter.resolve.ready",
            fields: [
                "pane": "\(paneID)",
                "target_uuid": id.uuidString,
            ]
        )
        session?.prepareForPaneSelection(paneID: paneID)
        controller.requestSelectPane(paneID: paneID)
        return .queued
    }

    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
        }
        if let topology = latestTopology,
           let targetWindow = topology.windows.first(where: { $0.id == windowID }) {
            requestWindowSelection(targetWindow, in: topology, controller: controller)
        } else {
            controller.requestSelectWindow(windowID: windowID)
        }
        return .queued
    }

    func focusAdjacentTmuxTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome {
        guard
            let controller,
            let topology = latestTopology,
            !topology.windows.isEmpty,
            let activeWindowID = topology.activeWindowID,
            let activeIndex = topology.windows.firstIndex(where: { $0.id == activeWindowID })
        else {
            return .missingTarget(.adjacentWindow)
        }

        let targetIndex = direction.advancedIndex(
            from: activeIndex,
            count: topology.windows.count
        )
        guard targetIndex != activeIndex else {
            return .missingTarget(.adjacentWindow)
        }
        let targetWindow = topology.windows[targetIndex]
        requestWindowSelection(targetWindow, in: topology, controller: controller)
        return .queued
    }

    private func requestWindowSelection(
        _ targetWindow: TmuxSessionController.WindowInfo,
        in topology: TmuxSessionController.TopologySnapshot,
        controller: TmuxSessionController
    ) {
        if topology.activeWindowID != targetWindow.id,
           let targetPaneID = targetWindow.activePaneID {
            session?.prepareForPaneSelection(paneID: targetPaneID)
        }

        controller.requestSelectWindow(
            windowID: targetWindow.id,
            preferredPaneID: targetWindow.activePaneID
        )
    }

    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome {
        guard let controller else { return .missingTarget(.host) }
        controller.requestNewWindow()
        return .queued
    }

    func splitFocusedTmuxPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome {
        guard let controller, let paneSurface = session?.paneSurface else {
            return .missingTarget(.focusedPane)
        }
        controller.requestSplit(
            paneID: paneSurface.paneID,
            direction: TmuxSessionController.SplitDirection(actionDirection: direction),
            zoom: true
        )
        return .queued
    }

    func closeTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let paneID = identities.paneID(for: id), let controller else {
            return .missingTarget(.pane(id))
        }
        controller.requestClosePane(paneID: paneID)
        return .queued
    }

    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.window(id))
        }
        controller.requestCloseWindow(windowID: windowID)
        return .queued
    }

    func enterFocusedTmuxCopyMode() -> GhosttyTmuxModelActionOutcome {
        guard let controller, let paneSurface = session?.paneSurface else {
            return .missingTarget(.focusedPane)
        }
        controller.requestCopyMode(paneID: paneSurface.paneID)
        return .queued
    }

    // MARK: Selection sheet projections

    func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTmuxWindowInteractionEffect()
    }

    func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.splitFocusedTmuxPaneInteractionEffect()
    }

    func closeTmuxWindowInteractionEffect(_ id: UUID) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxWindowInteractionEffect(
            id,
            snapshot: topologySnapshot
        )
    }

    func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTmuxPaneInteractionEffect(
            id,
            inTopLevel: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
            snapshot: topologySnapshot
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.selectedPaneSheetPresentationProjection(
            snapshot: topologySnapshot
        )
    }

    func paneSheetDetentPaneCount(topLevelID: UUID) -> Int {
        GhosttyTerminalPresentationProjector.paneSheetDetentPaneCount(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSheetDetentCellCount() -> Int {
        GhosttyTerminalPresentationProjector.windowSheetDetentCellCount(
            snapshot: topologySnapshot
        )
    }

    func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?
    ) -> GhosttyPaneSelectionSheetTopologyProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetTopologyProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
            snapshot: topologySnapshot
        )
    }

    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot
        )
    }
}

// MARK: - Shared reason mapping

extension TmuxSessionController.DetachReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        case .serverExited(let message):
            TerminalDisconnectReason(
                kind: .remoteExit,
                message: message ?? "tmux server exited"
            )
        case .transportClosed:
            TerminalDisconnectReason(
                kind: .transportIO,
                message: "connection lost"
            )
        case .channelAborted:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux control protocol error"
            )
        case .outOfMemory:
            TerminalDisconnectReason(
                kind: .runtime,
                message: "tmux session sync failed"
            )
        }
    }
}

extension TmuxSessionController.CloseReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        case .unsupportedVersion(let version):
            TerminalDisconnectReason(
                kind: .runtime,
                message: "unsupported tmux version \(version) (requires 3.1+)"
            )
        }
    }
}

private extension TmuxSessionController.SplitDirection {
    init(actionDirection: ghostty_action_split_direction_e) {
        switch actionDirection {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: self = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .down
        default: self = .right
        }
    }
}
