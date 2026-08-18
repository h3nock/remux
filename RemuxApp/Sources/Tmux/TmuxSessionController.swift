import Foundation
import GhosttyKit

private func decodeTmuxString(_ bytes: ghostty_tmux_bytes_s) -> String {
    guard let pointer = bytes.ptr, bytes.len > 0 else { return "" }
    return String(
        decoding: UnsafeBufferPointer(start: pointer, count: bytes.len),
        as: UTF8.self
    )
}

/// Queue-confined host for Ghostty's sans-I/O tmux control client.
///
/// The SSH transport owns the wire. This type owns protocol parsing, copied
/// topology, command correlation, canonical pane-terminal handoff, and the
/// borrowed renderer handles used to notify retained pane surfaces directly.
/// Every libghostty call for one client runs on `queue`.
final class TmuxSessionController: @unchecked Sendable {
    enum SessionState: Equatable, Sendable {
        case detached(DetachReason?)
        case attaching
        case syncing
        case ready
        case closed(CloseReason)
    }

    enum DetachReason: Equatable, Sendable {
        case serverExited(String?)
        case channelAborted
        case outOfMemory
        case transportClosed
    }

    enum CloseReason: Equatable, Sendable {
        case unsupportedVersion(String)
    }

    struct WindowInfo: Equatable, Identifiable, Sendable {
        let id: TmuxWindowID
        let name: String
        let active: Bool
        let zoomed: Bool
        let width: UInt32
        let height: UInt32
        let activePaneID: TmuxPaneID?
    }

    struct PaneInfo: Equatable, Identifiable, Sendable {
        enum Phase: Equatable, Sendable {
            case hydrating
            case live
        }

        let id: TmuxPaneID
        let windowID: TmuxWindowID
        let x: UInt32
        let y: UInt32
        let width: UInt32
        let height: UInt32
        let currentCommand: String
        let currentPath: String
        let phase: Phase
    }

    struct TopologySnapshot: Equatable, Sendable {
        let sessionName: String
        let windows: [WindowInfo]
        let panes: [PaneInfo]
        let activeWindowID: TmuxWindowID?
    }

    enum Request: Equatable, Sendable {
        case newWindow
        case splitPane
        case closePane
        case closeWindow
        case selectWindow
        case selectPane
        case zoomPane
        case copyMode
        case setClientSize
        case sendInput
    }

    enum SplitDirection: Sendable {
        case left
        case right
        case up
        case down
    }

    struct ClientSize: Sendable, Equatable {
        let cols: UInt32
        let rows: UInt32

        var controlViewport: TmuxControlViewport? {
            guard let columns = UInt16(exactly: cols),
                  let rows = UInt16(exactly: rows),
                  columns > 0,
                  rows > 0
            else { return nil }
            return TmuxControlViewport(
                columns: columns,
                rows: rows,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }
    }

    enum StartError: Error {
        case invalidInitialGrid
        case alreadyStarted
        case creationFailed(ghostty_tmux_result_e)
    }

    enum SurfaceRegistrationError: Error {
        case clientUnavailable
        case paneUnknown
        case alreadyRegistered
    }

    enum PaneCurrentDirectoryError: LocalizedError, Equatable, Sendable {
        case sessionUnavailable
        case paneUnavailable
        case commandSkipped
        case commandFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                return "The terminal session is no longer available."
            case .paneUnavailable:
                return "The originating terminal pane is no longer available."
            case .commandSkipped:
                return "tmux did not execute the current-directory query."
            case .commandFailed(let detail):
                return detail.isEmpty
                    ? "tmux could not resolve the terminal's current directory."
                    : detail
            case .invalidResponse:
                return "tmux returned an invalid current directory."
            }
        }
    }

    /// One retained reference to ControlClient's canonical pane terminal.
    /// Ownership transfers from the writer queue to MainActor exactly once.
    final class RetainedPaneTerminal: @unchecked Sendable {
        let paneID: TmuxPaneID
        let handle: ghostty_terminal_t

        fileprivate init(paneID: TmuxPaneID, handle: ghostty_terminal_t) {
            self.paneID = paneID
            self.handle = handle
        }

        deinit {
            ghostty_terminal_release(handle)
        }
    }

    struct Callbacks: Sendable {
        var onState: @Sendable (SessionState) -> Void = { _ in }
        var onTopology: @Sendable (TopologySnapshot) -> Void = { _ in }
        var onPaneRemoved: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onPaneTerminal: @Sendable (RetainedPaneTerminal) -> Void = { _ in }
        var onActivePaneChanged: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onPaneSurfaceFailed: @Sendable (TmuxPaneID) -> Void = { _ in }
        var onRequestFailed: @Sendable (Request) -> Void = { _ in }
    }

    /// Pointer values cross actor boundaries only as opaque native identities.
    private struct TerminalSurfaceHandle: @unchecked Sendable, Equatable {
        let value: ghostty_terminal_surface_t

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value == rhs.value
        }
    }

    private enum NavigationIntent {
        case pane(TmuxPaneID)
        case window(TmuxWindowID, preferredPaneID: TmuxPaneID?)
        case zoom(
            TmuxPaneID,
            desired: Bool,
            onZoomSubmitted: @Sendable (TmuxWindowID) -> Void
        )
    }

    private struct WindowZoomIntent {
        let windowIDs: [TmuxWindowID]
        let desired: Bool
        let onZoomSubmitted: @Sendable ([TmuxWindowID]) -> Void
    }

    private enum OutstandingRequest {
        case action(
            Request,
            topologyRevisionAtSubmission: UInt64,
            onSuccess: (@Sendable () -> Void)?
        )
        case viewportClaim
        case paneCurrentDirectory(
            @Sendable (Result<String, PaneCurrentDirectoryError>) -> Void
        )
        case trackedInput(@Sendable (Bool) -> Void)
    }

    let queue: DispatchQueue

    private let callbacks: Callbacks
    private var client: ghostty_tmux_client_t?
    private var state: SessionState = .detached(nil)
    private var topology: TopologySnapshot?
    private var clientSize: ClientSize?
    private var retainedPaneIDs: Set<TmuxPaneID> = []
    private var surfacesByPaneID: [TmuxPaneID: TerminalSurfaceHandle] = [:]
    private var requestsByToken: [UInt64: OutstandingRequest] = [:]
    private var deferredNavigationIntent: NavigationIntent?
    private var deferredWindowZoomIntent: WindowZoomIntent?
    private var successfulMutationRequiredAfterRevision: UInt64?
    private var viewportClaimAwaitingTopology = false
    private var topologyRevision: UInt64 = 0
    private var outboundSink: (@Sendable (Data) -> Void)?
    private var shuttingDown = false

    init(
        callbacks: Callbacks,
        queue: DispatchQueue = DispatchQueue(label: "remux.tmux.session.writer")
    ) {
        self.callbacks = callbacks
        self.queue = queue
    }

    deinit {
        assert(client == nil, "TmuxSessionController deinit without shutdown()")
    }

    func setOutboundSink(_ sink: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            outboundSink = sink
        }
    }

    /// Drain every operation already admitted to the writer queue, then close
    /// the outbound boundary so link teardown cannot discard those bytes.
    func finishOutbound() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                _ = drainOutbound()
                outboundSink = nil
                continuation.resume()
            }
        }
    }

    /// Construct the native client only after transport.start has opened the
    /// control channel. A viewport reported while the transport was opening
    /// becomes the native initial grid and its sole startup refresh-client.
    func start(
        initialSize: ClientSize,
        completion: @escaping @Sendable (Result<Void, StartError>) -> Void
    ) {
        queue.async { [self] in
            guard client == nil, !shuttingDown else {
                completion(.failure(.alreadyStarted))
                return
            }
            let startupSize = clientSize ?? initialSize
            guard let columns = UInt16(exactly: startupSize.cols),
                  let rows = UInt16(exactly: startupSize.rows),
                  columns > 0,
                  rows > 0
            else {
                completion(.failure(.invalidInitialGrid))
                return
            }
            clientSize = startupSize

            var config = ghostty_tmux_client_config_new()
            config.userdata = Unmanaged.passUnretained(self).toOpaque()
            config.action_cb = { userdata, action in
                guard let userdata, let action else { return }
                let controller = Unmanaged<TmuxSessionController>
                    .fromOpaque(userdata).takeUnretainedValue()
                controller.handleAction(action.pointee)
            }
            config.history_line_limit_is_set = true
            config.history_line_limit = 2_000
            config.max_scrollback = 10_000
            config.initial_columns = columns
            config.initial_rows = rows

            var created: ghostty_tmux_client_t?
            let result = ghostty_tmux_client_new(&config, &created)
            guard result == GHOSTTY_TMUX_RESULT_OK, let created else {
                completion(.failure(.creationFailed(result)))
                return
            }
            client = created
            publishState(.attaching)
            completion(.success(()))
        }
    }

    func transportClosed() {
        queue.async { [self] in
            guard !shuttingDown else { return }
            failOutstandingPaneDirectoryQueries(with: .sessionUnavailable)
            failOutstandingTrackedInput()
            deferredNavigationIntent = nil
            deferredWindowZoomIntent = nil
            successfulMutationRequiredAfterRevision = nil
            viewportClaimAwaitingTopology = false
            guard case .closed = state else {
                publishState(.detached(.transportClosed))
                return
            }
        }
    }

    /// Publish an intentional attachment stop without classifying it as a
    /// transport failure. Link teardown itself stays silent because it is
    /// also used by startup-failure cleanup and session shutdown.
    func attachmentStopped() {
        queue.async { [self] in
            guard !shuttingDown else { return }
            failOutstandingPaneDirectoryQueries(with: .sessionUnavailable)
            failOutstandingTrackedInput()
            deferredNavigationIntent = nil
            deferredWindowZoomIntent = nil
            successfulMutationRequiredAfterRevision = nil
            viewportClaimAwaitingTopology = false
            guard case .closed = state else {
                publishState(.detached(nil))
                return
            }
        }
    }

    func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            shuttingDown = true
            outboundSink = nil
            let directoryQueries = outstandingPaneDirectoryQueries()
            let trackedInputCompletions = outstandingTrackedInputCompletions()
            requestsByToken.removeAll()
            directoryQueries.forEach { $0(.failure(.sessionUnavailable)) }
            trackedInputCompletions.forEach { $0(false) }
            deferredNavigationIntent = nil
            deferredWindowZoomIntent = nil
            successfulMutationRequiredAfterRevision = nil
            viewportClaimAwaitingTopology = false
            topology = nil
            clientSize = nil
            retainedPaneIDs.removeAll()
            assert(surfacesByPaneID.isEmpty, "terminal surfaces must unregister before client free")
            surfacesByPaneID.removeAll()
            if let client {
                let result = ghostty_tmux_client_free(client)
                assert(result == GHOSTTY_TMUX_RESULT_OK, "ghostty_tmux_client_free failed: \(result)")
            }
            client = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    func pump(_ data: Data) {
        let enqueuedAt = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : 0
        queue.async { [self, data] in
            guard let client, !shuttingDown else { return }
            let applyStart = GhosttyRuntimeTrace.perfEnabled ? GhosttyRuntimeTrace.nowNanos() : 0
            let result = data.withUnsafeBytes { bytes in
                ghostty_tmux_client_feed(
                    client,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
            if state == .attaching {
                publishState(.syncing)
            }
            let outboundBytes = drainOutbound()
            GhosttyRuntimeTrace.perf(
                "tmuxFeed bytes=\(data.count) wait_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: enqueuedAt, to: applyStart)) apply_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: applyStart)) outbound_bytes=\(outboundBytes) result=\(result)"
            )
            guard result == GHOSTTY_TMUX_RESULT_OK else {
                handleClientFailure(result)
                return
            }
        }
    }

    @discardableResult
    private func drainOutbound() -> Int {
        preconditionOnWriterQueue()
        guard let client, let outboundSink else { return 0 }
        var bytes = ghostty_tmux_bytes_s()
        let result = ghostty_tmux_client_outbound(client, &bytes)
        guard result == GHOSTTY_TMUX_RESULT_OK else {
            handleClientFailure(result)
            return 0
        }
        guard bytes.len > 0 else { return 0 }
        guard let pointer = bytes.ptr else {
            handleClientFailure(GHOSTTY_TMUX_RESULT_CLIENT_FAILED)
            return 0
        }

        let owned = Data(bytes: pointer, count: bytes.len)
        let consumeResult = ghostty_tmux_client_consume(client, bytes.len)
        guard consumeResult == GHOSTTY_TMUX_RESULT_OK else {
            handleClientFailure(consumeResult)
            return 0
        }
        outboundSink(owned)
        return owned.count
    }

    // MARK: Native actions

    private func handleAction(_ action: ghostty_tmux_action_s) {
        preconditionOnWriterQueue()
        switch action.tag {
        case GHOSTTY_TMUX_ACTION_EXIT:
            failOutstandingPaneDirectoryQueries(with: .sessionUnavailable)
            failOutstandingTrackedInput()
            deferredNavigationIntent = nil
            deferredWindowZoomIntent = nil
            successfulMutationRequiredAfterRevision = nil
            viewportClaimAwaitingTopology = false
            let exit = action.value.exit
            let detail = decodeTmuxString(exit.detail)
            switch exit.reason {
            case GHOSTTY_TMUX_EXIT_UNSUPPORTED_VERSION:
                publishState(.closed(.unsupportedVersion(detail)))
            case GHOSTTY_TMUX_EXIT_SERVER:
                publishState(.detached(.serverExited(detail.isEmpty ? nil : detail)))
            default:
                publishState(.detached(.channelAborted))
            }

        case GHOSTTY_TMUX_ACTION_TOPOLOGY:
            handleTopology(action.value.topology)

        case GHOSTTY_TMUX_ACTION_PANE_CHANGED:
            handlePaneChanged(TmuxPaneID(action.value.pane_id))

        case GHOSTTY_TMUX_ACTION_COMMAND_COMPLETE:
            handleCommandCompletion(action.value.command)

        case GHOSTTY_TMUX_ACTION_INPUT_FAILED:
            _ = decodeTmuxString(action.value.input_failure)
            DispatchQueue.main.async { self.callbacks.onRequestFailed(.sendInput) }

        default:
            handleClientFailure(GHOSTTY_TMUX_RESULT_CLIENT_FAILED)
        }
    }

    private func handleTopology(_ action: ghostty_tmux_topology_action_s) {
        preconditionOnWriterQueue()
        var accumulator = TopologyAccumulator()
        let visitResult = withUnsafeMutablePointer(to: &accumulator) { accumulator in
            ghostty_tmux_topology_visit(
                action.view,
                UnsafeMutableRawPointer(accumulator),
                { userdata, record in
                    guard let userdata, let record else { return }
                    userdata.assumingMemoryBound(to: TopologyAccumulator.self)
                        .pointee.append(record.pointee)
                }
            )
        }
        guard visitResult == GHOSTTY_TMUX_RESULT_OK else {
            handleClientFailure(visitResult)
            return
        }

        let snapshot = TopologySnapshot(
            sessionName: decodeTmuxString(action.session_name),
            windows: accumulator.windows,
            panes: accumulator.panes,
            activeWindowID: accumulator.windows.first(where: \.active)?.id
        )
        let previousPaneIDs = Set(topology?.panes.map(\.id) ?? [])
        let nextPaneIDs = Set(snapshot.panes.map(\.id))
        let removed = previousPaneIDs.subtracting(nextPaneIDs).sorted()
        topology = snapshot
        topologyRevision &+= 1
        clearSatisfiedMutationBarrier()
        clearSatisfiedViewportClaim()

        for paneID in removed {
            retainedPaneIDs.remove(paneID)
            surfacesByPaneID.removeValue(forKey: paneID)
        }
        let didBecomeReady = state != .ready
        state = .ready
        DispatchQueue.main.async {
            if didBecomeReady { self.callbacks.onState(.ready) }
            for paneID in removed { self.callbacks.onPaneRemoved(paneID) }
            self.callbacks.onTopology(snapshot)
        }
        admitDeferredMutationsIfPossible()
    }

    private func handlePaneChanged(_ paneID: TmuxPaneID) {
        preconditionOnWriterQueue()
        guard let client else { return }

        if retainedPaneIDs.insert(paneID).inserted {
            var terminal: ghostty_terminal_t?
            let result = ghostty_tmux_client_retain_pane_terminal(
                client,
                paneID.rawValue,
                &terminal
            )
            guard result == GHOSTTY_TMUX_RESULT_OK, let terminal else {
                retainedPaneIDs.remove(paneID)
                DispatchQueue.main.async { self.callbacks.onPaneSurfaceFailed(paneID) }
                return
            }
            let handoff = RetainedPaneTerminal(paneID: paneID, handle: terminal)
            DispatchQueue.main.async { self.callbacks.onPaneTerminal(handoff) }
            return
        }

        if let surface = surfacesByPaneID[paneID] {
            let result = ghostty_terminal_surface_terminal_changed(surface.value)
            if result != GHOSTTY_TERMINAL_SURFACE_RESULT_OK {
                surfacesByPaneID.removeValue(forKey: paneID)
                DispatchQueue.main.async { self.callbacks.onPaneSurfaceFailed(paneID) }
                return
            }
        }

        if activePaneID(in: topology) == paneID {
            DispatchQueue.main.async { self.callbacks.onActivePaneChanged(paneID) }
        }
    }

    private func handleCommandCompletion(_ completion: ghostty_tmux_command_completion_s) {
        preconditionOnWriterQueue()
        guard let outstanding = requestsByToken.removeValue(forKey: completion.token) else { return }
        switch outstanding {
        case .viewportClaim:
            viewportClaimAwaitingTopology = completion.status == GHOSTTY_TMUX_COMMAND_SUCCESS
                && !activeViewportMatchesClientSize
            return
        case .trackedInput(let completionHandler):
            let succeeded = completion.status == GHOSTTY_TMUX_COMMAND_SUCCESS
            if !succeeded {
                reportRequestFailure(.sendInput)
            }
            completionHandler(succeeded)
            return
        case .paneCurrentDirectory(let completionHandler):
            completionHandler(paneCurrentDirectoryResult(for: completion))
            return
        case .action(let request, let topologyRevisionAtSubmission, let onSuccess):
            handleActionCompletion(
                completion,
                request: request,
                topologyRevisionAtSubmission: topologyRevisionAtSubmission,
                onSuccess: onSuccess
            )
        }
    }

    private func handleActionCompletion(
        _ completion: ghostty_tmux_command_completion_s,
        request: Request,
        topologyRevisionAtSubmission: UInt64,
        onSuccess: (@Sendable () -> Void)?
    ) {
        preconditionOnWriterQueue()
        switch completion.status {
        case GHOSTTY_TMUX_COMMAND_SUCCESS:
            if requestMutatesTopology(request) {
                successfulMutationRequiredAfterRevision = max(
                    successfulMutationRequiredAfterRevision ?? 0,
                    topologyRevisionAtSubmission
                )
            }
            onSuccess?()
        case GHOSTTY_TMUX_COMMAND_SKIPPED:
            break
        case GHOSTTY_TMUX_COMMAND_ERROR_BLOCK:
            _ = decodeTmuxString(completion.body)
            DispatchQueue.main.async { self.callbacks.onRequestFailed(request) }
        default:
            DispatchQueue.main.async { self.callbacks.onRequestFailed(request) }
        }
        clearSatisfiedMutationBarrier()
        admitDeferredMutationsIfPossible()
    }

    // MARK: Renderer registration and lifetime fence

    func registerTerminalSurface(
        paneID: TmuxPaneID,
        surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, SurfaceRegistrationError>) -> Void
    ) {
        let handle = TerminalSurfaceHandle(value: surface)
        queue.async { [self, handle] in
            let result: Result<Void, SurfaceRegistrationError>
            if client == nil || shuttingDown {
                result = .failure(.clientUnavailable)
            } else if !retainedPaneIDs.contains(paneID) {
                result = .failure(.paneUnknown)
            } else if surfacesByPaneID[paneID] != nil {
                result = .failure(.alreadyRegistered)
            } else {
                surfacesByPaneID[paneID] = handle
                result = .success(())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Completion is the happens-before fence: every earlier terminal-change
    /// notification has returned and no later one can dereference the handle.
    func unregisterTerminalSurface(
        paneID: TmuxPaneID,
        surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let handle = TerminalSurfaceHandle(value: surface)
        queue.async { [self, handle] in
            if surfacesByPaneID[paneID] == handle {
                surfacesByPaneID.removeValue(forKey: paneID)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    // MARK: Input and commands

    func sendInput(paneID: TmuxPaneID, _ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return true }
        queue.async { [self, bytes] in
            guard let client, outboundSink != nil, !shuttingDown else {
                DispatchQueue.main.async { self.callbacks.onRequestFailed(.sendInput) }
                return
            }
            _ = admitActiveViewportClaimIfNeeded()
            let result = bytes.withUnsafeBytes { buffer in
                ghostty_tmux_client_send_pane_input(
                    client,
                    paneID.rawValue,
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    buffer.count
                )
            }
            if result == GHOSTTY_TMUX_RESULT_OK {
                _ = drainOutbound()
            } else {
                reportImmediateFailure(result, request: .sendInput)
            }
        }
        return true
    }

    /// Sends one terminal payload and completes only when tmux answers for
    /// that exact send-keys command (or the session can no longer do so).
    func sendTrackedInput(
        paneID: TmuxPaneID,
        _ bytes: Data,
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        sendTrackedInput(
            paneID: paneID,
            bytes,
            transport: .exact,
            completion: completion
        )
    }

    func sendTrackedLiteralInput(
        paneID: TmuxPaneID,
        _ bytes: Data,
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        sendTrackedInput(
            paneID: paneID,
            bytes,
            transport: .literal,
            completion: completion
        )
    }

    private enum TrackedInputTransport {
        case exact
        case literal
    }

    private func sendTrackedInput(
        paneID: TmuxPaneID,
        _ bytes: Data,
        transport: TrackedInputTransport,
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        guard !bytes.isEmpty else { return false }
        queue.async { [self, bytes] in
            guard let client, outboundSink != nil, !shuttingDown else {
                reportRequestFailure(.sendInput)
                completion(false)
                return
            }
            _ = admitActiveViewportClaimIfNeeded()
            var token: UInt64 = 0
            let result = bytes.withUnsafeBytes { buffer in
                let pointer = buffer.bindMemory(to: UInt8.self).baseAddress
                return switch transport {
                case .exact:
                    ghostty_tmux_client_send_pane_input_tracked(
                        client,
                        paneID.rawValue,
                        pointer,
                        buffer.count,
                        &token
                    )
                case .literal:
                    ghostty_tmux_client_send_pane_literal_input_tracked(
                        client,
                        paneID.rawValue,
                        pointer,
                        buffer.count,
                        &token
                    )
                }
            }
            guard result == GHOSTTY_TMUX_RESULT_OK else {
                reportImmediateFailure(result, request: .sendInput)
                completion(false)
                return
            }
            requestsByToken[token] = .trackedInput(completion)
            _ = drainOutbound()
        }
        return true
    }

    func setClientSize(
        cols: UInt32,
        rows: UInt32,
        claimActiveViewport: Bool = false
    ) {
        guard cols > 0, rows > 0, cols <= UInt16.max, rows <= UInt16.max else {
            DispatchQueue.main.async { self.callbacks.onRequestFailed(.setClientSize) }
            return
        }
        let nextSize = ClientSize(cols: cols, rows: rows)
        queue.async { [self] in
            guard !shuttingDown else { return }
            guard client != nil else {
                clientSize = nextSize
                return
            }
            var admittedWork = false
            if clientSize != nextSize {
                guard admitCommandOnWriter(
                    command: "refresh-client -C \(cols)x\(rows)",
                    request: .setClientSize
                ) else { return }
                clientSize = nextSize
                admittedWork = true
            }
            if claimActiveViewport, admitActiveViewportClaimIfNeeded() {
                admittedWork = true
            }
            if admittedWork { _ = drainOutbound() }
        }
    }

    func requestNewWindow() {
        queue.async { [self] in
            _ = admitActiveViewportClaimIfNeeded()
            enqueueOnWriter(command: "new-window", request: .newWindow, onSuccess: nil)
        }
    }

    func requestSplit(
        paneID: TmuxPaneID,
        direction: SplitDirection,
        zoom: Bool,
        onZoomCreated: (@Sendable () -> Void)? = nil
    ) {
        let flags = switch direction {
        case .left: "-h -b"
        case .right: "-h"
        case .up: "-v -b"
        case .down: "-v"
        }
        let zoomFlag = zoom ? " -Z" : ""
        queue.async { [self] in
            _ = admitActiveViewportClaimIfNeeded()
            enqueueOnWriter(
                command: "split-window \(flags)\(zoomFlag) -t %\(paneID.rawValue)",
                request: .splitPane,
                onSuccess: onZoomCreated
            )
        }
    }

    func requestClosePane(paneID: TmuxPaneID) {
        queue.async { [self] in enqueuePaneClosure(paneID) }
    }

    func requestCloseWindow(windowID: TmuxWindowID) {
        queue.async { [self] in enqueueWindowClosure(windowID) }
    }

    func requestSelectWindow(
        windowID: TmuxWindowID,
        preferredPaneID: TmuxPaneID? = nil
    ) {
        queue.async { [self] in
            submitNavigation(
                .window(windowID, preferredPaneID: preferredPaneID)
            )
        }
    }

    func requestSelectPane(paneID: TmuxPaneID) {
        queue.async { [self] in
            submitNavigation(.pane(paneID))
        }
    }

    func requestSetPaneZoomed(
        paneID: TmuxPaneID,
        zoomed: Bool,
        onZoomSubmitted: @escaping @Sendable (TmuxWindowID) -> Void = { _ in }
    ) {
        queue.async { [self] in
            submitNavigation(.zoom(
                paneID,
                desired: zoomed,
                onZoomSubmitted: onZoomSubmitted
            ))
        }
    }

    func requestSetWindowsZoomed(
        windowIDs: [TmuxWindowID],
        zoomed: Bool,
        onZoomSubmitted: @escaping @Sendable ([TmuxWindowID]) -> Void = { _ in }
    ) {
        queue.async { [self] in
            submitWindowZoom(WindowZoomIntent(
                windowIDs: windowIDs,
                desired: zoomed,
                onZoomSubmitted: onZoomSubmitted
            ))
        }
    }

    func requestCopyMode(paneID: TmuxPaneID) {
        queue.async { [self] in
            _ = admitActiveViewportClaimIfNeeded()
            enqueueOnWriter(
                command: "copy-mode -t %\(paneID.rawValue)",
                request: .copyMode,
                onSuccess: nil
            )
        }
    }

    func claimActiveViewportIfNeeded() {
        queue.async { [self] in
            guard admitActiveViewportClaimIfNeeded() else { return }
            _ = drainOutbound()
        }
    }

    func requestRefreshWindowPaneMetadata(windowID: TmuxWindowID) {
        queue.async { [self] in
            preconditionOnWriterQueue()
            guard let client, outboundSink != nil, !shuttingDown else { return }
            guard topology?.windows.contains(where: { $0.id == windowID }) == true else {
                return
            }
            let result = ghostty_tmux_client_refresh_window_pane_metadata(
                client,
                windowID.rawValue
            )
            guard result == GHOSTTY_TMUX_RESULT_OK else {
                if result == GHOSTTY_TMUX_RESULT_CLIENT_FAILED
                    || result == GHOSTTY_TMUX_RESULT_CLOSED {
                    handleClientFailure(result)
                }
                return
            }
            _ = drainOutbound()
        }
    }

    func reclaimActiveViewport() {
        queue.async { [self] in
            guard admitActiveViewportClaim(force: true) else { return }
            _ = drainOutbound()
        }
    }

    func paneCurrentDirectory(for paneID: TmuxPaneID) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                submitPaneCurrentDirectoryQueryOnWriter(
                    paneID: paneID,
                    completion: { continuation.resume(with: $0) }
                )
            }
        }
    }

    private func submitNavigation(_ intent: NavigationIntent) {
        preconditionOnWriterQueue()
        guard !awaitingTopologyMutationSettlement else {
            deferredNavigationIntent = intent
            return
        }
        deferredNavigationIntent = nil
        evaluateNavigation(intent, drainOutbound: true)
    }

    private func submitWindowZoom(_ intent: WindowZoomIntent) {
        preconditionOnWriterQueue()
        guard !awaitingTopologyMutationSettlement else {
            deferredWindowZoomIntent = intent
            return
        }
        deferredWindowZoomIntent = nil
        enqueueWindowsZoom(
            intent.windowIDs,
            desired: intent.desired,
            onZoomSubmitted: intent.onZoomSubmitted,
            drainOutbound: true
        )
    }

    private func clearSatisfiedMutationBarrier() {
        preconditionOnWriterQueue()
        guard let requiredRevision = successfulMutationRequiredAfterRevision,
              topologyRevision > requiredRevision
        else { return }
        successfulMutationRequiredAfterRevision = nil
    }

    private func clearSatisfiedViewportClaim() {
        preconditionOnWriterQueue()
        if activeViewportMatchesClientSize {
            viewportClaimAwaitingTopology = false
        }
    }

    private func admitDeferredMutationsIfPossible() {
        preconditionOnWriterQueue()
        guard !awaitingTopologyMutationSettlement else { return }
        if let deferredWindowZoomIntent {
            self.deferredWindowZoomIntent = nil
            enqueueWindowsZoom(
                deferredWindowZoomIntent.windowIDs,
                desired: deferredWindowZoomIntent.desired,
                onZoomSubmitted: deferredWindowZoomIntent.onZoomSubmitted,
                drainOutbound: false
            )
            guard !awaitingTopologyMutationSettlement else { return }
        }
        guard let deferredNavigationIntent else { return }
        self.deferredNavigationIntent = nil
        // Native command admission is callback-safe. Outbound consume is not;
        // the enclosing pump drains once after feed returns.
        evaluateNavigation(deferredNavigationIntent, drainOutbound: false)
    }

    private func evaluateNavigation(
        _ intent: NavigationIntent,
        drainOutbound: Bool
    ) {
        switch intent {
        case .pane(let paneID):
            enqueuePaneSelection(
                paneID,
                drainOutbound: drainOutbound
            )
        case .window(let windowID, let preferredPaneID):
            enqueueWindowSelection(
                windowID: windowID,
                preferredPaneID: preferredPaneID,
                drainOutbound: drainOutbound
            )
        case .zoom(let paneID, let desired, let onZoomSubmitted):
            enqueueSetPaneZoomed(
                paneID,
                desired: desired,
                onZoomSubmitted: onZoomSubmitted,
                drainOutbound: drainOutbound
            )
        }
    }

    private func enqueueSetPaneZoomed(
        _ paneID: TmuxPaneID,
        desired: Bool,
        onZoomSubmitted: @Sendable (TmuxWindowID) -> Void,
        drainOutbound: Bool
    ) {
        guard let topology,
              let pane = topology.panes.first(where: { $0.id == paneID }),
              let window = topology.windows.first(where: { $0.id == pane.windowID })
        else {
            reportRequestFailure(.zoomPane)
            return
        }
        let claimedViewport = admitActiveViewportClaimIfNeeded()
        let hasSibling = topology.panes.contains {
            $0.windowID == window.id && $0.id != paneID
        }
        guard (!desired || hasSibling), window.zoomed != desired else {
            if claimedViewport, drainOutbound { _ = self.drainOutbound() }
            return
        }
        guard admitCommandOnWriter(
            command: "resize-pane -Z -t %\(paneID.rawValue)",
            request: .zoomPane
        ) else { return }
        if desired { onZoomSubmitted(window.id) }
        if drainOutbound { _ = self.drainOutbound() }
    }

    private func enqueueWindowsZoom(
        _ windowIDs: [TmuxWindowID],
        desired: Bool,
        onZoomSubmitted: @Sendable ([TmuxWindowID]) -> Void,
        drainOutbound: Bool
    ) {
        guard let topology else {
            reportRequestFailure(.zoomPane)
            return
        }
        let targets = windowIDs.compactMap { windowID -> (TmuxWindowID, String)? in
            guard let window = topology.windows.first(where: { $0.id == windowID }),
                  window.zoomed != desired,
                  let paneID = window.activePaneID
            else { return nil }
            let hasSibling = topology.panes.contains {
                $0.windowID == windowID && $0.id != paneID
            }
            guard !desired || hasSibling else { return nil }
            let command = desired
                ? "resize-pane -Z -t %\(paneID.rawValue)"
                : "resize-pane -Z -t @\(windowID.rawValue)"
            return (windowID, command)
        }
        guard !targets.isEmpty,
              admitCommandGroupOnWriter(
                  commands: targets.map(\.1),
                  request: .zoomPane
              )
        else { return }
        if desired { onZoomSubmitted(targets.map(\.0)) }
        if drainOutbound { _ = self.drainOutbound() }
    }

    private func enqueuePaneClosure(_ paneID: TmuxPaneID) {
        preconditionOnWriterQueue()
        guard !awaitingTopologyMutationSettlement else {
            reportRequestFailure(.closePane)
            return
        }
        guard let topology,
              let pane = topology.panes.first(where: { $0.id == paneID }),
              let window = topology.windows.first(where: { $0.id == pane.windowID })
        else {
            reportRequestFailure(.closePane)
            return
        }
        _ = admitActiveViewportClaimIfNeeded()

        let windowPanes = topology.panes.filter { $0.windowID == window.id }
        guard window.zoomed, windowPanes.count > 2 else {
            submitCommandOnWriter(
                command: "kill-pane -t %\(paneID.rawValue)",
                request: .closePane,
                drainOutbound: true
            )
            return
        }

        let commands = [
            "kill-pane -t %\(paneID.rawValue)",
            "resize-pane -Z -t @\(window.id.rawValue)",
        ]
        submitCommandGroupOnWriter(
            commands: commands,
            request: .closePane,
            drainOutbound: true
        )
    }

    private func enqueueWindowClosure(_ windowID: TmuxWindowID) {
        preconditionOnWriterQueue()
        guard !awaitingTopologyMutationSettlement,
              topology?.windows.contains(where: { $0.id == windowID }) == true
        else {
            reportRequestFailure(.closeWindow)
            return
        }
        _ = admitActiveViewportClaimIfNeeded()
        submitCommandOnWriter(
            command: "kill-window -t @\(windowID.rawValue)",
            request: .closeWindow,
            drainOutbound: true
        )
    }

    private func enqueuePaneSelection(
        _ paneID: TmuxPaneID,
        drainOutbound: Bool
    ) {
        preconditionOnWriterQueue()
        guard let topology,
              let pane = topology.panes.first(where: { $0.id == paneID }),
              let window = topology.windows.first(where: { $0.id == pane.windowID })
        else {
            reportRequestFailure(.selectPane)
            return
        }
        if topology.activeWindowID != window.id {
            enqueueWindowSelection(
                windowID: window.id,
                preferredPaneID: paneID,
                drainOutbound: drainOutbound
            )
            return
        }

        let claimedViewport = admitActiveViewportClaimIfNeeded()
        guard window.activePaneID != paneID else {
            if claimedViewport, drainOutbound { _ = self.drainOutbound() }
            return
        }
        let command = window.zoomed
            ? "select-pane -Z -t %\(paneID.rawValue)"
            : "select-pane -t %\(paneID.rawValue)"
        submitCommandOnWriter(
            command: command,
            request: .selectPane,
            drainOutbound: drainOutbound
        )
    }

    private func enqueueWindowSelection(
        windowID: TmuxWindowID,
        preferredPaneID: TmuxPaneID?,
        drainOutbound: Bool
    ) {
        preconditionOnWriterQueue()
        guard let topology,
              let window = topology.windows.first(where: { $0.id == windowID })
        else {
            reportRequestFailure(.selectWindow)
            return
        }
        let paneID = preferredPaneID ?? window.activePaneID
        if topology.activeWindowID == windowID {
            let claimedViewport = admitActiveViewportClaimIfNeeded()
            guard let paneID else {
                if claimedViewport, drainOutbound { _ = self.drainOutbound() }
                return
            }
            guard window.activePaneID != paneID else {
                if claimedViewport, drainOutbound { _ = self.drainOutbound() }
                return
            }
            let command = window.zoomed
                ? "select-pane -Z -t %\(paneID.rawValue)"
                : "select-pane -t %\(paneID.rawValue)"
            submitCommandOnWriter(
                command: command,
                request: .selectWindow,
                drainOutbound: drainOutbound
            )
            return
        }

        if let preferredPaneID,
           !topology.panes.contains(where: {
               $0.id == preferredPaneID && $0.windowID == windowID
           }) {
            reportRequestFailure(.selectWindow)
            return
        }
        let commands = Self.crossWindowSelectionCommands(
            windowID: windowID,
            activePaneID: window.activePaneID,
            preferredPaneID: preferredPaneID,
            zoomed: window.zoomed
        )

        if commands.count == 1 {
            submitCommandOnWriter(
                command: commands[0],
                request: .selectWindow,
                drainOutbound: drainOutbound
            )
        } else {
            submitCommandGroupOnWriter(
                commands: commands,
                request: .selectWindow,
                drainOutbound: drainOutbound
            )
        }
    }

    private var hasOutstandingTopologyMutation: Bool {
        requestsByToken.values.contains {
            guard case .action(let request, _, _) = $0 else { return false }
            return requestMutatesTopology(request)
        }
    }

    private var hasOutstandingViewportClaim: Bool {
        requestsByToken.values.contains {
            guard case .viewportClaim = $0 else { return false }
            return true
        }
    }

    private var activeViewportMatchesClientSize: Bool {
        guard let clientSize,
              let topology,
              let activeWindowID = topology.activeWindowID,
              let activeWindow = topology.windows.first(where: {
                  $0.id == activeWindowID
              })
        else { return false }
        return activeWindow.width == clientSize.cols
            && activeWindow.height == clientSize.rows
    }

    private var awaitingTopologyMutationSettlement: Bool {
        hasOutstandingTopologyMutation
            || successfulMutationRequiredAfterRevision != nil
    }

    private func requestMutatesTopology(_ request: Request) -> Bool {
        switch request {
        case .newWindow, .splitPane, .closePane, .closeWindow,
             .selectWindow, .selectPane, .zoomPane:
            true
        case .copyMode, .setClientSize, .sendInput:
            false
        }
    }

    @discardableResult
    private func admitActiveViewportClaimIfNeeded() -> Bool {
        admitActiveViewportClaim(force: false)
    }

    @discardableResult
    private func admitActiveViewportClaim(force: Bool) -> Bool {
        preconditionOnWriterQueue()
        guard let client,
              outboundSink != nil,
              !shuttingDown,
              let clientSize,
              let topology,
              let activeWindowID = topology.activeWindowID,
              let activeWindow = topology.windows.first(where: {
                  $0.id == activeWindowID
              })
        else { return false }

        let viewportMatches = activeWindow.width == clientSize.cols
            && activeWindow.height == clientSize.rows
        if viewportMatches {
            viewportClaimAwaitingTopology = false
            if !force { return false }
        }
        guard !viewportClaimAwaitingTopology,
              !hasOutstandingViewportClaim
        else { return false }

        let (result, token) = enqueueCommandTokenOnWriter(
            "select-window -t @\(activeWindowID.rawValue)",
            client: client
        )
        guard result == GHOSTTY_TMUX_RESULT_OK else {
            if result == GHOSTTY_TMUX_RESULT_CLIENT_FAILED
                || result == GHOSTTY_TMUX_RESULT_CLOSED {
                handleClientFailure(result)
            }
            return false
        }
        requestsByToken[token] = .viewportClaim
        return true
    }

    static func crossWindowSelectionCommands(
        windowID: TmuxWindowID,
        activePaneID: TmuxPaneID?,
        preferredPaneID: TmuxPaneID?,
        zoomed: Bool
    ) -> [String] {
        let selectWindow = "select-window -t @\(windowID.rawValue)"
        guard let preferredPaneID,
              preferredPaneID != activePaneID
        else { return [selectWindow] }
        return [
            selectWindow,
            zoomed
                ? "select-pane -Z -t %\(preferredPaneID.rawValue)"
                : "select-pane -t %\(preferredPaneID.rawValue)",
        ]
    }

    private func enqueueOnWriter(
        command: String,
        request: Request,
        onSuccess: (@Sendable () -> Void)?
    ) {
        submitCommandOnWriter(
            command: command,
            request: request,
            onSuccess: onSuccess,
            drainOutbound: true
        )
    }

    private func submitCommandOnWriter(
        command: String,
        request: Request,
        onSuccess: (@Sendable () -> Void)? = nil,
        drainOutbound: Bool
    ) {
        guard admitCommandOnWriter(
            command: command,
            request: request,
            onSuccess: onSuccess
        ) else { return }
        if drainOutbound { _ = self.drainOutbound() }
    }

    private func admitCommandOnWriter(
        command: String,
        request: Request,
        onSuccess: (@Sendable () -> Void)? = nil
    ) -> Bool {
        preconditionOnWriterQueue()
        guard let client, outboundSink != nil, !shuttingDown else {
            reportRequestFailure(request)
            return false
        }
        let (result, token) = enqueueCommandTokenOnWriter(command, client: client)
        guard result == GHOSTTY_TMUX_RESULT_OK else {
            reportImmediateFailure(result, request: request)
            return false
        }
        requestsByToken[token] = .action(
            request,
            topologyRevisionAtSubmission: topologyRevision,
            onSuccess: onSuccess
        )
        return true
    }

    private func submitPaneCurrentDirectoryQueryOnWriter(
        paneID: TmuxPaneID,
        completion: @escaping @Sendable (
            Result<String, PaneCurrentDirectoryError>
        ) -> Void
    ) {
        preconditionOnWriterQueue()
        guard let client, outboundSink != nil, !shuttingDown else {
            completion(.failure(.sessionUnavailable))
            return
        }
        guard retainedPaneIDs.contains(paneID) else {
            completion(.failure(.paneUnavailable))
            return
        }

        let command = "display-message -p -t %\(paneID.rawValue) '#{pane_current_path}'"
        let (result, token) = enqueueCommandTokenOnWriter(command, client: client)
        guard result == GHOSTTY_TMUX_RESULT_OK else {
            completion(.failure(.commandFailed(String(describing: result))))
            if result == GHOSTTY_TMUX_RESULT_CLIENT_FAILED
                || result == GHOSTTY_TMUX_RESULT_CLOSED {
                handleClientFailure(result)
            }
            return
        }
        requestsByToken[token] = .paneCurrentDirectory(completion)
        _ = drainOutbound()
    }

    private func enqueueCommandTokenOnWriter(
        _ command: String,
        client: ghostty_tmux_client_t
    ) -> (ghostty_tmux_result_e, UInt64) {
        preconditionOnWriterQueue()
        var token: UInt64 = 0
        let result = command.utf8.withContiguousStorageIfAvailable { buffer in
            ghostty_tmux_client_enqueue_command(
                client,
                ghostty_tmux_bytes_s(ptr: buffer.baseAddress, len: buffer.count),
                &token
            )
        } ?? Array(command.utf8).withUnsafeBufferPointer { buffer in
            ghostty_tmux_client_enqueue_command(
                client,
                ghostty_tmux_bytes_s(ptr: buffer.baseAddress, len: buffer.count),
                &token
            )
        }
        return (result, token)
    }

    private func enqueueGroupOnWriter(commands: [String], request: Request) {
        submitCommandGroupOnWriter(
            commands: commands,
            request: request,
            drainOutbound: true
        )
    }

    private func submitCommandGroupOnWriter(
        commands: [String],
        request: Request,
        drainOutbound: Bool
    ) {
        guard admitCommandGroupOnWriter(commands: commands, request: request) else { return }
        if drainOutbound { _ = self.drainOutbound() }
    }

    private func admitCommandGroupOnWriter(commands: [String], request: Request) -> Bool {
        preconditionOnWriterQueue()
        guard let client, outboundSink != nil, !shuttingDown else {
            reportRequestFailure(request)
            return false
        }
        let encoded = commands.map { Array($0.utf8) }
        var tokens = Array(repeating: UInt64(0), count: commands.count)
        let result = withBorrowedCommandBytes(encoded, index: 0, bytes: []) { bytes in
            bytes.withUnsafeBufferPointer { commandBuffer in
                tokens.withUnsafeMutableBufferPointer { tokenBuffer in
                    ghostty_tmux_client_enqueue_command_group(
                        client,
                        commandBuffer.baseAddress,
                        commandBuffer.count,
                        tokenBuffer.baseAddress
                    )
                }
            }
        }
        guard result == GHOSTTY_TMUX_RESULT_OK else {
            reportImmediateFailure(result, request: request)
            return false
        }
        for token in tokens {
            requestsByToken[token] = .action(
                request,
                topologyRevisionAtSubmission: topologyRevision,
                onSuccess: nil
            )
        }
        return true
    }

    private func withBorrowedCommandBytes<Result>(
        _ commands: [[UInt8]],
        index: Int,
        bytes: [ghostty_tmux_bytes_s],
        body: ([ghostty_tmux_bytes_s]) -> Result
    ) -> Result {
        guard index < commands.count else { return body(bytes) }
        return commands[index].withUnsafeBufferPointer { buffer in
            withBorrowedCommandBytes(
                commands,
                index: index + 1,
                bytes: bytes + [ghostty_tmux_bytes_s(ptr: buffer.baseAddress, len: buffer.count)],
                body: body
            )
        }
    }

    // MARK: Helpers

    private func publishState(_ next: SessionState) {
        preconditionOnWriterQueue()
        guard state != next else { return }
        state = next
        DispatchQueue.main.async { self.callbacks.onState(next) }
    }

    private func handleClientFailure(_ result: ghostty_tmux_result_e) {
        preconditionOnWriterQueue()
        guard !shuttingDown else { return }
        failOutstandingPaneDirectoryQueries(with: .sessionUnavailable)
        failOutstandingTrackedInput()
        deferredNavigationIntent = nil
        deferredWindowZoomIntent = nil
        successfulMutationRequiredAfterRevision = nil
        viewportClaimAwaitingTopology = false
        switch result {
        case GHOSTTY_TMUX_RESULT_OUT_OF_MEMORY:
            publishState(.detached(.outOfMemory))
        case GHOSTTY_TMUX_RESULT_CLOSED:
            if case .closed = state { return }
            if case .detached = state { return }
            publishState(.detached(.channelAborted))
        default:
            publishState(.detached(.channelAborted))
        }
    }

    private func reportImmediateFailure(_ result: ghostty_tmux_result_e, request: Request) {
        preconditionOnWriterQueue()
        guard result != GHOSTTY_TMUX_RESULT_OK else { return }
        reportRequestFailure(request)
        if result == GHOSTTY_TMUX_RESULT_CLIENT_FAILED || result == GHOSTTY_TMUX_RESULT_CLOSED {
            handleClientFailure(result)
        }
    }

    private func reportRequestFailure(_ request: Request) {
        DispatchQueue.main.async { self.callbacks.onRequestFailed(request) }
    }

    private func paneCurrentDirectoryResult(
        for completion: ghostty_tmux_command_completion_s
    ) -> Result<String, PaneCurrentDirectoryError> {
        switch completion.status {
        case GHOSTTY_TMUX_COMMAND_SUCCESS:
            let path = decodeTmuxString(completion.body)
                .trimmingCharacters(in: .newlines)
            guard path.hasPrefix("/"),
                  !path.contains("\0"),
                  !path.contains("\n"),
                  !path.contains("\r")
            else { return .failure(.invalidResponse) }
            return .success(path)
        case GHOSTTY_TMUX_COMMAND_SKIPPED:
            return .failure(.commandSkipped)
        case GHOSTTY_TMUX_COMMAND_ERROR_BLOCK:
            let detail = decodeTmuxString(completion.body)
                .trimmingCharacters(in: .newlines)
            return .failure(.commandFailed(detail))
        default:
            return .failure(.invalidResponse)
        }
    }

    private func outstandingPaneDirectoryQueries() -> [
        @Sendable (Result<String, PaneCurrentDirectoryError>) -> Void
    ] {
        requestsByToken.values.compactMap {
            guard case .paneCurrentDirectory(let completion) = $0 else { return nil }
            return completion
        }
    }

    private func failOutstandingPaneDirectoryQueries(
        with error: PaneCurrentDirectoryError
    ) {
        preconditionOnWriterQueue()
        let completions = outstandingPaneDirectoryQueries()
        requestsByToken = requestsByToken.filter {
            guard case .paneCurrentDirectory = $0.value else { return true }
            return false
        }
        completions.forEach { $0(.failure(error)) }
    }

    private func outstandingTrackedInputCompletions() -> [@Sendable (Bool) -> Void] {
        requestsByToken.values.compactMap {
            guard case .trackedInput(let completion) = $0 else { return nil }
            return completion
        }
    }

    private func failOutstandingTrackedInput() {
        preconditionOnWriterQueue()
        let completions = outstandingTrackedInputCompletions()
        requestsByToken = requestsByToken.filter {
            guard case .trackedInput = $0.value else { return true }
            return false
        }
        completions.forEach { $0(false) }
    }

    private func preconditionOnWriterQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    private func activePaneID(in topology: TopologySnapshot?) -> TmuxPaneID? {
        guard let topology, let windowID = topology.activeWindowID else { return nil }
        return topology.windows.first(where: { $0.id == windowID })?.activePaneID
    }

}

private struct TopologyAccumulator {
    var windows: [TmuxSessionController.WindowInfo] = []
    var panes: [TmuxSessionController.PaneInfo] = []

    mutating func append(_ record: ghostty_tmux_topology_record_s) {
        switch record.tag {
        case GHOSTTY_TMUX_TOPOLOGY_WINDOW:
            let window = record.value.window
            windows.append(TmuxSessionController.WindowInfo(
                id: TmuxWindowID(window.id),
                name: decodeTmuxString(window.name),
                active: window.active,
                zoomed: window.zoomed,
                width: Self.uint32(window.width),
                height: Self.uint32(window.height),
                activePaneID: TmuxPaneID(window.active_pane_id)
            ))
        case GHOSTTY_TMUX_TOPOLOGY_PANE:
            let pane = record.value.pane
            panes.append(TmuxSessionController.PaneInfo(
                id: TmuxPaneID(pane.id),
                windowID: TmuxWindowID(pane.window_id),
                x: Self.uint32(pane.x),
                y: Self.uint32(pane.y),
                width: Self.uint32(pane.width),
                height: Self.uint32(pane.height),
                currentCommand: decodeTmuxString(pane.current_command),
                currentPath: decodeTmuxString(pane.current_path),
                phase: pane.phase == GHOSTTY_TMUX_PANE_LIVE ? .live : .hydrating
            ))
        default:
            break
        }
    }

    private static func uint32(_ value: Int) -> UInt32 {
        UInt32(clamping: value)
    }
}
