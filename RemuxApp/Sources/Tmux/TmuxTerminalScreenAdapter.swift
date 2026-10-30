import Combine
import CoreGraphics
import Foundation
import GhosttyKit

struct TmuxMultipaneZoomDefaultPolicy {
    var isEnabled = false
    private var resolvedWindowIDs: Set<TmuxWindowID> = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    mutating func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != isEnabled else { return false }
        isEnabled = enabled
        resolvedWindowIDs.removeAll(keepingCapacity: true)
        return true
    }

    mutating func windowIDsNeedingChange(
        in topology: TmuxSessionController.TopologySnapshot,
        includingMatchingWindows: Bool = false
    ) -> [TmuxWindowID] {
        var targets: [TmuxWindowID] = []

        for window in topology.windows {
            var paneCount = 0
            for pane in topology.panes where pane.windowID == window.id {
                paneCount += 1
                if paneCount == 2 { break }
            }
            guard paneCount == 2 else {
                resolvedWindowIDs.remove(window.id)
                continue
            }
            guard !resolvedWindowIDs.contains(window.id),
                  window.activePaneID != nil
            else { continue }

            resolvedWindowIDs.insert(window.id)
            if includingMatchingWindows || window.zoomed != isEnabled {
                targets.append(window.id)
            }
        }
        return targets
    }

    mutating func recordWindowChoice(_ windowID: TmuxWindowID) {
        resolvedWindowIDs.insert(windowID)
    }

    mutating func reset() {
        resolvedWindowIDs.removeAll(keepingCapacity: false)
    }
}


/// Presents a `TmuxTerminalSession` through the `GhosttyTerminalScreenModeling`
/// boundary so `GhosttySurfaceScreen` renders it.
///
/// Topology mapping: tmux window/pane IDs (UInt64) are mapped to stable UUIDs
/// shared by topology and managed surfaces. The session retains one real pane
/// surface per hydrated pane; the adapter indexes managed surfaces for the
/// active window while the composite viewport presents every visible pane.
@MainActor
final class TmuxTerminalScreenAdapter: ObservableObject {
    private weak var session: TmuxTerminalSession?
    private var controller: TmuxSessionController?

    /// The last topology emitted by `session.$topology`. All adapter reads go
    /// through this value, never `session.topology`: `@Published` emits from
    /// `willSet`, so reading the property inside a sink returns the previous
    /// snapshot and the projection lags one topology update behind.
    private var latestTopology: TmuxSessionController.TopologySnapshot?
    private var identities = TmuxTerminalIdentityRegistry()

    private var managedSurfacesByPaneID: [TmuxPaneID: GhosttyManagedSurface] = [:]
    private var activeManagedSurface: GhosttyManagedSurface?
    private var activeManagedPaneID: TmuxPaneID?
    private var pendingFocusedPaneID: TmuxPaneID?
    private var initialViewportHandler: ((CGSize, CGFloat, Bool) -> Void)?
    private var viewportStabilityHandler: ((Bool) -> Void)?
    private var latestViewportMeasurement: GhosttyTerminalViewportMeasurement?
    private var cachedTopologySnapshot = GhosttyRuntimeSurfaceTopologySnapshot.empty
    private var ownedZoomWindowIDs: Set<TmuxWindowID> = []
    private var pendingZoomOwnershipWindowIDs: Set<TmuxWindowID> = []
    private var pendingOwnedZoomPreservation: (windowID: TmuxWindowID, paneID: TmuxPaneID)?
    private var didAdoptZoomMarks = false
    private var multipaneZoomDefault = TmuxMultipaneZoomDefaultPolicy()

    private lazy var commandFailure = GhosttyTerminalNotice { [weak self] in
        self?.objectWillChange.send()
    }

    private var subscriptions: [AnyCancellable] = []

    /// Connects the adapter to a live session. Called once, right after the
    /// session is created.
    func activate(
        session: TmuxTerminalSession,
        zoomMultipaneWindowsByDefault: Bool = false,
        initialViewportHandler: @escaping (CGSize, CGFloat, Bool) -> Void,
        viewportStabilityHandler: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.controller = session.controller
        multipaneZoomDefault.isEnabled = zoomMultipaneWindowsByDefault
        self.initialViewportHandler = initialViewportHandler
        self.viewportStabilityHandler = viewportStabilityHandler

        session.$state
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        session.$topology
            .sink { [weak self] topology in
                guard let self, let session = self.session else { return }
                self.latestTopology = topology
                if let topology {
                    self.reconcileZoomOwnership(with: topology)
                    self.applyMultipaneZoomDefaultIfNeeded(to: topology)
                    self.adoptZoomMarksOnce()
                } else {
                    self.ownedZoomWindowIDs.removeAll()
                    self.pendingZoomOwnershipWindowIDs.removeAll()
                    self.pendingOwnedZoomPreservation = nil
                }
                self.rebuildTopologySnapshot()
                self.reconcileManagedSurfaces(
                    sessionSurfaces: session.surfacesByPaneID,
                    topology: topology
                )
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$surfacesByPaneID
            .sink { [weak self] surfaces in
                guard let self else { return }
                self.reconcileManagedSurfaces(
                    sessionSurfaces: surfaces,
                    topology: self.latestTopology
                )
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$viewportMeasurement
            .sink { [weak self] measurement in
                self?.latestViewportMeasurement = measurement
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
        session.$lastFailedRequest
            .sink { [weak self] request in
                guard let request else { return }
                if request == .selectPane {
                    self?.cancelPendingPaneFocus()
                }
                if request == .zoomPane {
                    self?.pendingZoomOwnershipWindowIDs.removeAll()
                }
                if request == .closePane,
                   let self,
                   let preservation = pendingOwnedZoomPreservation {
                    pendingOwnedZoomPreservation = nil
                    if latestTopology?.windows.first(where: {
                        $0.id == preservation.windowID
                    })?.zoomed
                        != true {
                        ownedZoomWindowIDs.remove(preservation.windowID)
                        controller?.requestForgetZoomMarks(windowIDs: [preservation.windowID])
                    }
                }
                self?.presentCommandFailure(for: request)
            }
            .store(in: &subscriptions)
        session.$presentationRevision
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        session.$transportFailure
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    func invalidate() {
        subscriptions.removeAll()
        managedSurfacesByPaneID.removeAll()
        activeManagedSurface = nil
        ownedZoomWindowIDs.removeAll()
        pendingZoomOwnershipWindowIDs.removeAll()
        pendingOwnedZoomPreservation = nil
        didAdoptZoomMarks = false
        multipaneZoomDefault.reset()
        activeManagedPaneID = nil
        pendingFocusedPaneID = nil
        session = nil
        controller = nil
        initialViewportHandler = nil
        viewportStabilityHandler = nil
        latestViewportMeasurement = nil
        latestTopology = nil
        cachedTopologySnapshot = Self.emptyTopologySnapshot
    }

    func tmuxPaneID(for surfaceID: UUID) -> TmuxPaneID? {
        let paneID = identities.paneID(for: surfaceID)
        guard let paneID,
              latestTopology?.panes.contains(where: { $0.id == paneID }) == true
        else { return nil }
        return paneID
    }

    // MARK: Topology synthesis

    private static var emptyTopologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        GhosttyRuntimeSurfaceTopologySnapshot.empty
    }

    private var topologySnapshot: GhosttyRuntimeSurfaceTopologySnapshot {
        cachedTopologySnapshot
    }

    private var terminalViewportPresentationProjection:
        GhosttyTerminalViewportPresentationProjection
    {
        guard let topology = latestTopology,
              let activeWindowID = topology.activeWindowID,
              let window = topology.windows.first(where: { $0.id == activeWindowID })
        else {
            return GhosttyTerminalViewportPresentationProjection(
                windowGrid: nil,
                cellMetrics: latestViewportMeasurement?.cellMetrics,
                panes: [],
                paneLines: [],
                focusedSurfaceID: activeManagedSurface?.id,
                isServerZoomed: false,
                windowCount: latestTopology?.windows.count ?? 0
            )
        }

        let fullWindowFrame = GhosttyTerminalGridRect(
            x: 0,
            y: 0,
            columns: window.width,
            rows: window.height
        )
        let focusedPaneID = effectiveFocusedPaneID
        let panes = topology.panes
            .filter { $0.windowID == activeWindowID }
            .sorted { lhs, rhs in
                (lhs.y, lhs.x, lhs.id) < (rhs.y, rhs.x, rhs.id)
            }
            .map { pane in
                let surfaceID = identities.surfaceID(for: pane.id)
                let normalFrame = GhosttyTerminalGridRect(
                    x: pane.x,
                    y: pane.y,
                    columns: pane.width,
                    rows: pane.height
                )
                let isFocused = pane.id == focusedPaneID
                return GhosttyTerminalViewportPresentationProjection.Pane(
                    id: surfaceID,
                    normalFrame: normalFrame,
                    visibleFrame: window.zoomed
                        ? (isFocused ? fullWindowFrame : nil)
                        : normalFrame,
                    isFocused: isFocused,
                    currentCommand: pane.currentCommand,
                    currentPath: pane.currentPath
                )
            }

        return GhosttyTerminalViewportPresentationProjection(
            windowGrid: GhosttyTerminalGridSize(
                columns: window.width,
                rows: window.height
            ),
            cellMetrics: latestViewportMeasurement?.cellMetrics,
            panes: panes,
            paneLines: GhosttyPaneSeparatorLayout.lines(for: panes),
            focusedSurfaceID: activeManagedSurface?.id,
            isServerZoomed: window.zoomed,
            windowCount: topology.windows.count
        )
    }

    private func rebuildTopologySnapshot() {
        guard let topology = latestTopology else {
            cachedTopologySnapshot = Self.emptyTopologySnapshot
            return
        }

        let topLevels = topology.windows.map { window in
            let paneIDs = topology.panes
                .filter { $0.windowID == window.id }
                .sorted { lhs, rhs in
                    (lhs.y, lhs.x, lhs.id) < (rhs.y, rhs.x, rhs.id)
                }
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

    private func reconcileManagedSurfaces(
        sessionSurfaces: [TmuxPaneID: TmuxPaneSurface],
        topology: TmuxSessionController.TopologySnapshot?
    ) {
        guard let topology, let activeWindowID = topology.activeWindowID else {
            managedSurfacesByPaneID.removeAll()
            activeManagedSurface = nil
            activeManagedPaneID = nil
            pendingFocusedPaneID = nil
            return
        }

        let activePaneIDs = Set(
            topology.panes.lazy
                .filter { $0.windowID == activeWindowID }
                .map(\.id)
        )
        managedSurfacesByPaneID = managedSurfacesByPaneID.filter {
            activePaneIDs.contains($0.key) && sessionSurfaces[$0.key] != nil
        }

        for paneID in activePaneIDs.sorted() {
            guard managedSurfacesByPaneID[paneID] == nil,
                  let paneSurface = sessionSurfaces[paneID]
            else { continue }
            managedSurfacesByPaneID[paneID] = makeManagedSurface(for: paneSurface)
        }
        let serverFocusedPaneID = topology.windows
            .first(where: { $0.id == activeWindowID })?
            .activePaneID
        if pendingFocusedPaneID == serverFocusedPaneID
            || pendingFocusedPaneID.map({ !activePaneIDs.contains($0) }) == true {
            pendingFocusedPaneID = nil
        }
        let focusedPaneID = Self.resolvedFocusedPaneID(
            server: serverFocusedPaneID,
            pending: pendingFocusedPaneID,
            activePaneIDs: activePaneIDs
        )
        activeManagedPaneID = focusedPaneID
        activeManagedSurface = focusedPaneID.flatMap { managedSurfacesByPaneID[$0] }
    }

    private var effectiveFocusedPaneID: TmuxPaneID? {
        guard let topology = latestTopology,
              let activeWindowID = topology.activeWindowID
        else {
            return nil
        }
        let activePaneIDs = Set(
            topology.panes.lazy
                .filter { $0.windowID == activeWindowID }
                .map(\.id)
        )
        let serverFocusedPaneID = topology.windows
            .first(where: { $0.id == activeWindowID })?
            .activePaneID
        return Self.resolvedFocusedPaneID(
            server: serverFocusedPaneID,
            pending: pendingFocusedPaneID,
            activePaneIDs: activePaneIDs
        )
    }

    static func resolvedFocusedPaneID(
        server: TmuxPaneID?,
        pending: TmuxPaneID?,
        activePaneIDs: Set<TmuxPaneID>
    ) -> TmuxPaneID? {
        if let pending, activePaneIDs.contains(pending) { return pending }
        if let server, activePaneIDs.contains(server) { return server }
        return nil
    }

    private func cancelPendingPaneFocus() {
        guard pendingFocusedPaneID != nil else { return }
        pendingFocusedPaneID = nil
        reconcileManagedSurfaces(
            sessionSurfaces: session?.surfacesByPaneID ?? [:],
            topology: latestTopology
        )
        objectWillChange.send()
    }

    private func makeManagedSurface(
        for paneSurface: TmuxPaneSurface
    ) -> GhosttyManagedSurface {
        let paneID = paneSurface.paneID
        let surfaceID = identities.surfaceID(for: paneID)
        let wasAlreadyWrapped = paneSurface.renderer.managedSurface != nil
        let managed = paneSurface.screenSurface(id: surfaceID)
        if wasAlreadyWrapped {
            // Output reaches a pane of a hidden window without refreshing its scroll state: tmux
            // refreshes only the active pane as output arrives.
            managed.refreshInteractionState()
        } else {
            GhosttyRuntimeTrace.flowEventIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "presentation.managedSurface.ready",
                fields: [
                    "pane": "\(paneID)",
                    "surface": String(describing: paneSurface.renderer.rawSurface),
                    "surface_uuid": managed.id.uuidString,
                ]
            )
        }
        return managed
    }

    private func managedSurface(for id: UUID) -> GhosttyManagedSurface? {
        guard let paneID = identities.paneID(for: id) else { return nil }
        return managedSurfacesByPaneID[paneID]
    }

    private var focusedManagedSurface: GhosttyManagedSurface? {
        activeManagedSurface
    }

    // MARK: Command failures

    private func presentCommandFailure(for request: TmuxSessionController.Request) {
        commandFailure.presentFailure("tmux: \(Self.failureLabel(for: request)) failed")
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
    func prepareInitialViewport(
        size: CGSize,
        scale: CGFloat,
        claimActiveViewport: Bool
    ) {
        initialViewportHandler?(size, scale, claimActiveViewport)
    }

    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection {
        GhosttyTerminalPresentationProjector.terminalScreenPresentationProjection(
            phase: runtimePhase,
            transportWritable: isTransportWritable,
            commandFailureMessage: commandFailure.failureMessage,
            debugStatus: stateTraceLabel,
            registryDebugSummary: "tmux session stack",
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot,
            viewportProjection: terminalViewportPresentationProjection,
            selectedPanePresentation: session?.presentation(for: effectiveFocusedPaneID) ?? .pending,
            isShown: session?.isSelected ?? false
        )
    }

    var terminalInteractionProjection: GhosttyTerminalInteractionProjection {
        GhosttyTerminalPresentationProjector.terminalInteractionProjection(
            phase: runtimePhase,
            presentedSurfaceID: activeManagedSurface?.id,
            snapshot: topologySnapshot,
            selectedPanePresentation: session?.presentation(for: effectiveFocusedPaneID) ?? .pending
        )
    }

    var terminalManagedSurfaceLookup: GhosttyManagedSurfaceLookup {
        GhosttyManagedSurfaceLookup { [weak self] id in
            self?.managedSurface(for: id)
        }
    }

    var commandFailureEvent: GhosttyTerminalCommandFailureEvent? {
        commandFailure.event
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
        pixelBudget: GhosttyPanePreviewSession.PixelBudget
    ) -> GhosttyPanePreviewSession? {
        GhosttyPanePreviewSession(
            leafIDs: leafIDs,
            pixelBudget: pixelBudget,
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
                }
            )
        )
    }

    // MARK: Input routing

    private func preflightFocusedInput() -> FocusedTerminalInputSubmissionResult? {
        guard isTransportWritable else { return .transportUnavailable }
        guard focusedManagedSurface != nil else { return .noFocusedSurface }
        guard session?.presentation(for: effectiveFocusedPaneID) == .ready else { return .surfaceRejected }
        return nil
    }

    var holdsTmuxPrefixKey: Bool { true }

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

    func sendPasteAwaitingCommandCompletion(_ text: String, to surfaceID: UUID) async -> Bool {
        guard isTransportWritable,
              let managed = managedSurface(for: surfaceID)
        else { return false }
        return await managed.sendPasteAwaitingCommandCompletion(text)
    }

    func sendKeyEvent(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) -> FocusedTerminalInputSubmissionResult {
        guard isTransportWritable else { return .transportUnavailable }
        guard let managed = managedSurface(for: surfaceID) else { return .noFocusedSurface }
        return managed.sendKeyEvent(event)
    }

    func sendKeyEventAwaitingCommandCompletion(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) async -> Bool {
        guard isTransportWritable,
              let managed = managedSurface(for: surfaceID)
        else { return false }
        return await managed.sendKeyEventAwaitingCommandCompletion(event)
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

    /// A tmux pane's history is in its local terminal, which reads the selection itself.
    func selectedText(in surfaceID: UUID) async -> String? {
        managedSurface(for: surfaceID)?.controlSurface.readSelection()
    }

    /// A tmux pane's terminal knows where its lines wrap, so its link match is already whole.
    func completeLinkSelection(
        in surfaceID: UUID,
        at point: CGPoint,
        selected: GhosttyLongPressSelection
    ) async -> Bool {
        false
    }

    // MARK: tmux topology actions

    func reclaimActiveTmuxViewport() {
        controller?.reclaimActiveViewport()
    }

    func claimActiveTmuxViewportIfNeeded() {
        controller?.claimActiveViewportIfNeeded()
    }

    func refreshPaneMetadata(inTopLevel id: UUID) {
        guard let windowID = identities.windowID(for: id) else { return }
        controller?.requestRefreshWindowPaneMetadata(windowID: windowID)
    }

    func focusPane(_ id: UUID) -> GhosttyTerminalActionOutcome {
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
        if let topology = latestTopology,
           let activeWindowID = topology.activeWindowID,
           topology.panes.contains(where: {
               $0.id == paneID && $0.windowID == activeWindowID
           }),
           managedSurfacesByPaneID[paneID] != nil {
            pendingFocusedPaneID = paneID
            activeManagedPaneID = paneID
            activeManagedSurface = managedSurfacesByPaneID[paneID]
            objectWillChange.send()
        }
        session?.prepareForPaneSelection(paneID: paneID)
        controller.requestSelectPane(paneID: paneID)
        return .queued
    }

    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.topLevel(id))
        }
        pendingFocusedPaneID = nil
        if let topology = latestTopology,
           let targetWindow = topology.windows.first(where: { $0.id == windowID }) {
            requestWindowSelection(targetWindow, in: topology, controller: controller)
        } else {
            controller.requestSelectWindow(windowID: windowID)
        }
        return .queued
    }

    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTerminalActionOutcome {
        guard
            let controller,
            let topology = latestTopology,
            !topology.windows.isEmpty,
            let activeWindowID = topology.activeWindowID,
            let activeIndex = topology.windows.firstIndex(where: { $0.id == activeWindowID })
        else {
            return .missingTarget(.adjacentTopLevel)
        }

        let targetIndex = direction.advancedIndex(
            from: activeIndex,
            count: topology.windows.count
        )
        guard targetIndex != activeIndex else {
            return .missingTarget(.adjacentTopLevel)
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
        pendingFocusedPaneID = nil
        if topology.activeWindowID != targetWindow.id,
           let targetPaneID = targetWindow.activePaneID {
            session?.prepareForPaneSelection(paneID: targetPaneID)
        }

        controller.requestSelectWindow(
            windowID: targetWindow.id,
            preferredPaneID: targetWindow.activePaneID
        )
    }

    func createTopLevel(inGroup group: UUID?) -> GhosttyTerminalActionOutcome {
        guard let controller else { return .missingTarget(.host) }
        controller.requestNewWindow()
        return .queued
    }

    func createTopLevelGroup(from group: UUID?) -> GhosttyTerminalActionOutcome {
        .missingTarget(.host)
    }

    func splitFocusedPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTerminalActionOutcome {
        guard let controller,
              let activeManagedPaneID,
              let topology = latestTopology,
              let pane = topology.panes.first(where: { $0.id == activeManagedPaneID }),
              let window = topology.windows.first(where: { $0.id == pane.windowID })
        else {
            return .missingTarget(.focusedPane)
        }
        let hasSibling = topology.panes.contains {
            $0.windowID == window.id && $0.id != pane.id
        }
        let appliesDefaultZoom = !hasSibling
            && !window.zoomed
            && multipaneZoomDefault.isEnabled
        let onZoomCreated: (@Sendable () -> Void)?
        if appliesDefaultZoom {
            let windowID = window.id
            onZoomCreated = { [weak self] in
                DispatchQueue.main.async {
                    self?.pendingZoomOwnershipWindowIDs.insert(windowID)
                }
            }
        } else {
            onZoomCreated = nil
        }
        controller.requestSplit(
            paneID: activeManagedPaneID,
            direction: TmuxSessionController.SplitDirection(actionDirection: direction),
            zoom: window.zoomed || appliesDefaultZoom,
            onZoomCreated: onZoomCreated
        )
        return .queued
    }

    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome {
        guard let controller,
              let activeManagedPaneID,
              let topology = latestTopology,
              let activeWindowID = topology.activeWindowID,
              topology.windows.contains(where: { $0.id == activeWindowID })
        else {
            return .missingTarget(.focusedPane)
        }
        multipaneZoomDefault.recordWindowChoice(activeWindowID)
        controller.requestSetPaneZoomed(
            paneID: activeManagedPaneID,
            zoomed: zoomed,
            onZoomSubmitted: { [weak self] windowID in
                DispatchQueue.main.async {
                    self?.pendingZoomOwnershipWindowIDs.insert(windowID)
                }
            }
        )
        return .queued
    }

    func setZoomMultipaneWindowsByDefault(_ enabled: Bool) {
        guard multipaneZoomDefault.setEnabled(enabled), let latestTopology else { return }
        applyMultipaneZoomDefaultIfNeeded(
            to: latestTopology,
            includingMatchingWindows: true
        )
    }

    private func applyMultipaneZoomDefaultIfNeeded(
        to topology: TmuxSessionController.TopologySnapshot,
        includingMatchingWindows: Bool = false
    ) {
        let windowIDs = multipaneZoomDefault.windowIDsNeedingChange(
            in: topology,
            includingMatchingWindows: includingMatchingWindows
        )
        guard !windowIDs.isEmpty else { return }
        controller?.requestSetWindowsZoomed(
            windowIDs: windowIDs,
            zoomed: multipaneZoomDefault.isEnabled,
            onZoomSubmitted: { [weak self] windowIDs in
                DispatchQueue.main.async {
                    self?.pendingZoomOwnershipWindowIDs.formUnion(windowIDs)
                }
            }
        )
    }

    /// The session is ending: undo the zooms Remux made. A runtime replaced by
    /// a new attempt skips this; the new attempt adopts them from their marks.
    func releaseZoomOwnership() {
        var releasedWindowIDs = ownedZoomWindowIDs
        releasedWindowIDs.formUnion(pendingZoomOwnershipWindowIDs)
        guard !releasedWindowIDs.isEmpty else { return }
        controller?.requestReleaseZoom(
            windowIDs: releasedWindowIDs.sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Takes back the zooms this owner made on an earlier attachment (a
    /// reconnect, a replaced runtime, or an app restart), and forgets marks
    /// whose zoom is already gone.
    private func adoptZoomMarksOnce() {
        guard !didAdoptZoomMarks, let controller else { return }
        didAdoptZoomMarks = true
        controller.requestZoomMarks { [weak self] marks in
            DispatchQueue.main.async {
                self?.adoptZoomMarks(marks)
            }
        }
    }

    private func adoptZoomMarks(_ marks: [TmuxZoomMark]) {
        let adoption = TmuxZoomMarkAdoption(
            marks: marks,
            zoomedWindowIDs: Set(latestTopology?.windows.filter(\.zoomed).map(\.id) ?? []),
            zoomingWindowIDs: pendingZoomOwnershipWindowIDs.union(ownedZoomWindowIDs)
        )
        ownedZoomWindowIDs.formUnion(adoption.adoptedWindowIDs)
        if !adoption.forgottenWindowIDs.isEmpty {
            controller?.requestForgetZoomMarks(windowIDs: adoption.forgottenWindowIDs)
        }
    }

    private func reconcileZoomOwnership(
        with topology: TmuxSessionController.TopologySnapshot
    ) {
        if let preservation = pendingOwnedZoomPreservation {
            if let window = topology.windows.first(where: {
                $0.id == preservation.windowID
            }) {
                let paneWasRemoved = !topology.panes.contains(where: {
                    $0.id == preservation.paneID
                })
                if paneWasRemoved, window.zoomed {
                    self.pendingOwnedZoomPreservation = nil
                }
            } else {
                self.pendingOwnedZoomPreservation = nil
                ownedZoomWindowIDs.remove(preservation.windowID)
            }
        }

        var completedOwnershipWindowIDs: Set<TmuxWindowID> = []
        for windowID in pendingZoomOwnershipWindowIDs {
            if let window = topology.windows.first(where: { $0.id == windowID }) {
                if window.zoomed {
                    ownedZoomWindowIDs.insert(windowID)
                    completedOwnershipWindowIDs.insert(windowID)
                }
            } else {
                completedOwnershipWindowIDs.insert(windowID)
            }
        }
        pendingZoomOwnershipWindowIDs.subtract(completedOwnershipWindowIDs)

        let preservedWindowID = pendingOwnedZoomPreservation?.windowID
        let unzoomedWindowIDs = ownedZoomWindowIDs.filter { windowID in
            windowID != preservedWindowID
                && topology.windows.first(where: { $0.id == windowID })?.zoomed == false
        }
        ownedZoomWindowIDs = ownedZoomWindowIDs.filter { windowID in
            windowID == preservedWindowID
                || topology.windows.first(where: { $0.id == windowID })?.zoomed == true
        }
        // The zoom Remux made is gone; a later zoom on these windows is not its own.
        if !unzoomedWindowIDs.isEmpty {
            controller?.requestForgetZoomMarks(
                windowIDs: unzoomedWindowIDs.sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    func closePane(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let paneID = identities.paneID(for: id), let controller else {
            return .missingTarget(.pane(id))
        }
        if let topology = latestTopology,
           let pane = topology.panes.first(where: { $0.id == paneID }),
           let window = topology.windows.first(where: { $0.id == pane.windowID }),
           window.zoomed,
           topology.panes.lazy.filter({ $0.windowID == window.id }).count > 2,
           ownedZoomWindowIDs.contains(window.id) {
            pendingOwnedZoomPreservation = (window.id, paneID)
        }
        controller.requestClosePane(paneID: paneID)
        return .queued
    }

    func closeTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome {
        guard let windowID = identities.windowID(for: id), let controller else {
            return .missingTarget(.topLevel(id))
        }
        controller.requestCloseWindow(windowID: windowID)
        return .queued
    }

    /// tmux's server asks nothing before a close.
    var askedCloseConfirmation: GhosttyCloseConfirmation? { nil }

    func answerAskedCloseConfirmation(agreed: Bool) {}

    func renameTopLevel(_ id: UUID, to name: String) -> Bool { false }

    func renamePane(_ id: UUID, to name: String) -> Bool { false }

    func enterFocusedTmuxCopyMode() -> GhosttyTerminalActionOutcome {
        guard let controller, let activeManagedPaneID else {
            return .missingTarget(.focusedPane)
        }
        controller.requestCopyMode(paneID: activeManagedPaneID)
        return .queued
    }

    // MARK: Selection sheet projections

    func createTopLevelInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.createTopLevelInteractionEffect()
    }

    func splitFocusedPaneInteractionEffect() -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.splitFocusedPaneInteractionEffect()
    }

    func closeTopLevelInteractionEffect(_ id: UUID) -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closeTopLevelInteractionEffect(
            id,
            snapshot: topologySnapshot
        )
    }

    func closePaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTopologyActionInteractionEffect {
        GhosttyTerminalPresentationProjector.closePaneInteractionEffect(
            id,
            inTopLevel: topLevelID,
            snapshot: topologySnapshot
        )
    }

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection? {
        guard let projection = GhosttyTerminalPresentationProjector.windowSheetPresentationProjection(
            snapshot: topologySnapshot
        ) else { return nil }
        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: capturablePreviewLeafIDs(projection.previewLeafIDs)
        )
    }

    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection? {
        GhosttyTerminalPresentationProjector.selectedPaneSheetPresentationProjection(
            snapshot: topologySnapshot
        )
    }

    func paneCount(topLevelID: UUID) -> Int {
        GhosttyTerminalPresentationProjector.paneCount(
            topLevelID: topLevelID,
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

    var topLevelNoun: GhosttyTopLevelNoun { .window }

    /// The windows, each asking before it closes with its panes.
    func windowSelectionSheetRenderProjection(group: UUID?) -> GhosttyWindowSelectionSheetRenderProjection {
        let projection = GhosttyTerminalPresentationProjector.windowSelectionSheetRenderProjection(
            snapshot: topologySnapshot
        )
        return GhosttyWindowSelectionSheetRenderProjection(
            windows: projection.windows.map { window in
                var window = window
                let panes = window.paneCount == 1 ? "1 pane" : "\(window.paneCount) panes"
                window.closeConfirmation = GhosttyCloseConfirmation(
                    title: "Close Window?",
                    message: "This will close Window \(window.displayIndex) and \(panes).",
                    action: "Close Window \(window.displayIndex)"
                )
                return window
            },
            selectedWindowID: projection.selectedWindowID,
            previewLeafIDs: capturablePreviewLeafIDs(projection.previewLeafIDs)
        )
    }

    private func capturablePreviewLeafIDs(_ prioritizedLeafIDs: [UUID]) -> [UUID] {
        guard let session else { return [] }
        return prioritizedLeafIDs.filter { leafID in
            guard let paneID = identities.paneID(for: leafID) else { return false }
            return session.surfacesByPaneID[paneID] != nil
        }
    }

    /// The window's panes; its only pane asks before it closes, since that can close the window.
    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        let selectedTopLevelID = topologySnapshot.selectedTopLevelID
        let projection = GhosttyTerminalPresentationProjector.paneSelectionSheetRenderProjection(
            topLevelID: topLevelID,
            snapshot: topologySnapshot,
            viewport: selectedTopLevelID == topLevelID
                ? terminalViewportPresentationProjection
                : nil
        )
        guard projection.paneCount == 1, var pane = projection.panes.first else { return projection }
        pane.closeConfirmation = GhosttyCloseConfirmation(
            title: "Close Pane?",
            message: "This is the only pane in the window, so closing it can close the window too.",
            action: "Close Pane"
        )
        return GhosttyPaneSelectionSheetRenderProjection(
            panes: [pane],
            selectedPaneID: projection.selectedPaneID,
            isServerZoomed: projection.isServerZoomed
        )
    }
}

// MARK: - Shared reason mapping

extension TmuxSessionController.DetachReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        // tmux ends the client whether the session ended or another client detached this one; reconnecting
        // attaches if the session is still there and finds out if it isn't.
        case .serverExited(let reason):
            TerminalDisconnectReason(kind: .transportIO, message: reason ?? "tmux ended the client")
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
        case .sessionEnded:
            TerminalDisconnectReason(kind: .sessionEnded, message: "tmux has no session by this name")
        }
    }
}

extension TmuxSessionController.CloseReason {
    var terminalDisconnectReason: TerminalDisconnectReason {
        switch self {
        case .unsupportedVersion(let version):
            BackendProblem.unsupportedVersion(version).disconnectReason(for: .tmux)
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
