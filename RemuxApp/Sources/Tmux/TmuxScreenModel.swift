import Combine
import Foundation
import GhosttyKit

/// The production screen model for tmux workspaces: owns one
/// GhosttyKitRuntime (per session, as before) and one
/// TmuxTerminalSession, connects through the app's prepared-transport
/// pooling, and reports the domain `TerminalRuntimeState` vocabulary
/// the root model already reduces (badges, auto-reconnect).
@MainActor
final class TmuxScreenModel: ObservableObject {
    typealias TransportFactory = @MainActor (TmuxConnectionTarget) -> any TmuxControlTransport

    let target: TmuxConnectionTarget
    let sessionInstanceID: UUID

    /// The screen-facing facet: presents this session through the
    /// GhosttyTerminalScreenModeling boundary for GhosttySurfaceScreen.
    /// Stable screen-facing adapter for this model's session.
    let terminalScreenAdapter = TmuxTerminalScreenAdapter()
    let terminalPreviewClient: TerminalPreviewClient?

    @Published private(set) var session: TmuxTerminalSession?
    @Published private(set) var startupFailure: String?

    /// The reducer's expectations: the target this session connects to.
    var runtimeConnectionTarget: TmuxConnectionTarget { target }

    /// The viewport the root carries into the replacement model on
    /// reconnect for a sized attach. Prefers the last size reported
    /// with the viewport in its settled shape, so disconnecting while
    /// the keyboard is up does not make the next attach first-paint
    /// at the keyboard-shrunken size.
    var carriedClientSize: TmuxSessionController.ClientSize? {
        lastStableClientSize ?? lastSubmittedClientSize
    }

    /// True when no connection exists or is in progress, so the root
    /// model may replace this model (e.g. after a server edit) without
    /// dropping a session the user is still attached to.
    var isDisconnected: Bool {
        guard let session else { return true }
        switch session.state {
        case .detached, .closed: return true
        case .attaching, .syncing, .ready: return false
        }
    }

    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private var runtime: GhosttyKitRuntime?
    private var currentTerminalSettings: TerminalSettings
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var pendingForegroundInactiveReason: TerminalDisconnectReason?
    private var stateObservation: AnyCancellable?
    private var transportFailureObservation: AnyCancellable?
    private var stopped = false
    private var initialViewport: TmuxControlViewport?
    private var lastSubmittedClientSize: TmuxSessionController.ClientSize?
    private var lastStableClientSize: TmuxSessionController.ClientSize?
    private var viewportIsStable = true
    private var lastViewportPointSize: CGSize?
    private var lastViewportScale: CGFloat?

    private let initialClientSize: TmuxSessionController.ClientSize?

    init(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        initialClientSize: TmuxSessionController.ClientSize? = nil
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.onRuntimeStateChange = onRuntimeStateChange
        self.currentTerminalSettings = target.terminalSettings
        self.initialClientSize = initialClientSize
        let flow = "session.open.\(target.workspace.id.uuidString)"
        let runtimeInitStart = GhosttyRuntimeTrace.nowNanos()
        let runtime: GhosttyKitRuntime
        do {
            runtime = try GhosttyKitRuntime(terminalSettings: target.terminalSettings)
        } catch {
            self.terminalPreviewClient = nil
            startupFailure = String(describing: error)
            report(.disconnected(Self.runtimeStartFailureReason))
            return
        }
        self.runtime = runtime
        GhosttyRuntimeTrace.flowEventIfActive(
            flow,
            event: "model.runtime.init",
            fields: ["elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: runtimeInitStart)]
        )

        let transport = transportFactory(target)
        if let provider = (transport as? any TmuxControlTransportSFTPProviding)?
            .sessionSFTPClientProvider {
            self.terminalPreviewClient = TerminalPreviewClient(
                provider: provider,
                liveForwardProvider:
                    (transport as? any TmuxControlTransportLiveForwardProviding)?
                        .sessionLiveForwardProvider
            )
        } else {
            self.terminalPreviewClient = nil
        }
        let session = TmuxTerminalSession(
            app: runtime.appHandle,
            transport: transport,
            baseSurfaceConfig: { [runtime] in
                runtime.makeTmuxBaseSurfaceConfig()
            },
            paneViewTheme: { [weak self, target] in
                self?.currentTerminalSettings.theme ?? target.terminalSettings.theme
            }
        )
        self.session = session
        terminalScreenAdapter.activate(
            session: session,
            zoomMultipaneWindowsByDefault: currentTerminalSettings.zoomMultipaneWindowsByDefault,
            initialViewportHandler: { [weak self] size, scale, claimActiveViewport in
                self?.prepareInitialViewport(
                    size: size,
                    scale: scale,
                    claimActiveViewport: claimActiveViewport
                )
            },
            viewportStabilityHandler: { [weak self] stable in
                self?.setViewportStability(stable)
            }
        )

        if let size = initialClientSize {
            initialViewport = TmuxControlViewport(clientSize: size)
        }

        stateObservation = session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleSessionState(state)
            }

        // A failed connect can leave the state unchanged (.detached(nil)
        // before and after), which the deduplicated state stream drops;
        // the failure itself is the report-worthy signal.
        transportFailureObservation = session.$transportFailure
            .compactMap { $0 }
            .sink { [weak self] failure in
                self?.report(.disconnected(failure))
            }

        GhosttyRuntimeTrace.flowEventIfActive(flow, event: "model.session.created")
        if let initialViewport {
            connect(viewport: initialViewport)
        }
    }

    func terminalPreviewPathResolver(
        for candidate: TerminalPreviewCandidate,
        from surfaceID: UUID
    ) -> TerminalPreviewSession.PathResolver {
        switch candidate.target {
        case .localhost:
            // Live targets carry their destination; the session never
            // invokes this resolver for them.
            return { "" }
        case .file(.absolute(let remotePath)):
            return { remotePath }
        case .file(.relative(let path)):
            guard let controller = session?.controller,
                  let paneID = terminalScreenAdapter.tmuxPaneID(for: surfaceID)
            else {
                return {
                    throw TmuxSessionController.PaneCurrentDirectoryError
                        .paneUnavailable
                }
            }
            let relativePath = TerminalPreviewPath.relative(path)
            return {
                let currentDirectory = try await controller
                    .paneCurrentDirectory(for: paneID)
                return try relativePath.resolved(relativeTo: currentDirectory)
            }
        }
    }

    private func connect(viewport: TmuxControlViewport) {
        initialViewport = viewport
        let initialSize = TmuxSessionController.ClientSize(
            cols: UInt32(viewport.columns),
            rows: UInt32(viewport.rows)
        )
        lastSubmittedClientSize = initialSize
        if viewportIsStable { lastStableClientSize = initialSize }
        report(currentRuntimeState(for: session?.state ?? .attaching, connecting: true))
        session?.connect(viewport: viewport)
    }

    private func prepareInitialViewport(
        size: CGSize,
        scale: CGFloat,
        claimActiveViewport: Bool = false
    ) {
        guard !stopped else { return }
        guard let runtime else { return }
        lastViewportPointSize = size
        lastViewportScale = scale

        do {
            guard let measurement = try runtime.measureTmuxViewportLayout(
                size: size,
                scale: scale
            ) else {
                return
            }
            session?.updateViewportMeasurement(measurement)
            if initialViewport == nil {
                connect(viewport: measurement.controlViewport)
            } else {
                _ = submitClientSizeIfChanged(
                    TmuxSessionController.ClientSize(
                        cols: UInt32(measurement.controlViewport.columns),
                        rows: UInt32(measurement.controlViewport.rows)
                    ),
                    claimActiveViewport: claimActiveViewport
                )
            }
        } catch {
            startupFailure = String(describing: error)
            report(.disconnected(Self.initialViewportFailureReason))
        }
    }

    /// The single host authority for this control connection's client grid.
    /// Record before queueing so repeated pane layouts cannot enqueue duplicate
    /// controller work while the first submission is still pending.
    @discardableResult
    func submitClientSizeIfChanged(
        _ size: TmuxSessionController.ClientSize,
        claimActiveViewport: Bool = false
    ) -> Bool {
        guard !stopped, let controller = session?.controller else { return false }
        let sizeChanged = size != lastSubmittedClientSize
        guard sizeChanged || claimActiveViewport else { return false }
        if sizeChanged {
            lastSubmittedClientSize = size
            if viewportIsStable { lastStableClientSize = size }
        }
        controller.setClientSize(
            cols: size.cols,
            rows: size.rows,
            claimActiveViewport: claimActiveViewport
        )
        return true
    }

    private func setViewportStability(_ stable: Bool) {
        viewportIsStable = stable
        if stable { lastStableClientSize = lastSubmittedClientSize }
    }

    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        // Presentation discontinuity handling lives in the renderer
        // (visibility-resume full damage); here we gate drawing.
        session?.setAppActive(phase == .active)

        guard phase == .active else { return }
        guard let session, case .ready = session.state else {
            reportForegroundDisconnectedStateIfNeeded()
            return
        }

        Task { [weak self] in
            await self?.handleForegroundActivation()
        }
    }

    private func handleForegroundActivation() async {
        guard !stopped else { return }
        if let session,
           case .ready = session.state,
           let reason = await session.invalidateInactiveTransportOnForeground(
               willInvalidate: { reason in
                   pendingForegroundInactiveReason = reason
               }
           ) {
            if pendingForegroundInactiveReason != nil {
                pendingForegroundInactiveReason = nil
                report(.disconnected(reason), source: .foreground)
            }
            return
        }

        reportForegroundDisconnectedStateIfNeeded()
    }

    private func reportForegroundDisconnectedStateIfNeeded() {
        // Foreground is a reconnect opportunity: re-surface a
        // disconnected state with the foreground source so the root's
        // auto-reconnect policy can act on it (the report tracker
        // re-reports foreground disconnects even when unchanged).
        if let state = foregroundDisconnectedState() {
            report(state, source: .foreground)
        }
    }

    private func foregroundDisconnectedState() -> TerminalRuntimeState? {
        guard let session else {
            return .disconnected(Self.runtimeStartFailureReason)
        }

        switch session.state {
        case .attaching, .syncing, .ready:
            return nil
        case .detached, .closed:
            return currentRuntimeState(for: session.state, connecting: false)
        }
    }

    /// Live settings application: updates the runtime's canonical app config
    /// before each retained pane surface re-snapshots it in place.
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard settings != currentTerminalSettings else { return }
        terminalScreenAdapter.setZoomMultipaneWindowsByDefault(
            settings.zoomMultipaneWindowsByDefault
        )
        guard !settings.hasSameTerminalAppearance(as: currentTerminalSettings) else {
            currentTerminalSettings = settings
            return
        }
        try runtime?.applyTerminalSettings(settings)
        currentTerminalSettings = settings
        session?.applyTerminalConfiguration(theme: settings.theme)
        terminalScreenAdapter.terminalConfigurationDidChange()
        if let lastViewportPointSize, let lastViewportScale {
            prepareInitialViewport(size: lastViewportPointSize, scale: lastViewportScale)
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        stateObservation = nil
        transportFailureObservation = nil
        terminalScreenAdapter.prepareForSessionShutdown()
        terminalScreenAdapter.invalidate()
        if let session {
            await session.shutdown()
        }
        session = nil
        runtime = nil
    }

    // MARK: Domain state reporting

    private func handleSessionState(_ state: TmuxSessionController.SessionState) {
        if case .ready = state {
            pendingForegroundInactiveReason = nil
        }
        if case .detached = state,
           let reason = pendingForegroundInactiveReason {
            pendingForegroundInactiveReason = nil
            report(.disconnected(reason), source: .foreground)
            return
        }
        report(currentRuntimeState(for: state, connecting: false))
    }

    private func currentRuntimeState(
        for state: TmuxSessionController.SessionState,
        connecting: Bool
    ) -> TerminalRuntimeState {
        switch state {
        case .attaching, .syncing:
            return .connecting
        case .ready:
            return .connected
        case .detached(let reason):
            if connecting {
                // A connection is being initiated from the session's
                // initial detached state: report progress, not the stale
                // detach.
                return .connecting
            }
            if let reason {
                return .disconnected(reason.terminalDisconnectReason)
            }
            return .disconnected(
                session?.transportFailure ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: "disconnected"
                )
            )
        case .closed(let reason):
            return .disconnected(reason.terminalDisconnectReason)
        }
    }

    private func report(
        _ state: TerminalRuntimeState,
        source: TerminalRuntimeStateUpdateSource = .runtime
    ) {
        guard reportTracker.shouldReport(state: state, source: source) else {
            return
        }
        onRuntimeStateChange(TerminalRuntimeStateUpdate(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID,
            state: state,
            source: source
        ))
    }

    private static let runtimeStartFailureReason = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal runtime failed to initialize"
    )

    private static let initialViewportFailureReason = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal viewport failed to initialize"
    )
}
