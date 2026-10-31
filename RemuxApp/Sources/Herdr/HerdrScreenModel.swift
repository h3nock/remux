import Foundation
import GhosttyKit

/// One Herdr pane's renderer, over the pane terminal the engine gave it.
@MainActor
final class HerdrPaneSurface: TerminalPaneInputSink {
    let paneID: String
    let terminal: HerdrRetainedTerminal
    let renderer: TerminalPaneRenderer

    init(paneID: String, terminal: HerdrRetainedTerminal, renderer: TerminalPaneRenderer) {
        self.paneID = paneID
        self.terminal = terminal
        self.renderer = renderer
    }

    func screenSurface(id: UUID) -> GhosttyManagedSurface {
        renderer.screenSurface(id: id, inputSink: self)
    }

    // The composer's input goes through the screen model, which holds the connection.
    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool { false }

    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool { false }
}

/// The screen model for one Herdr session, as `TmuxScreenModel` is for tmux: one connection at a time
/// to the session's server, the session's terminal engine, and a renderer for each pane terminal. It
/// reports the domain `TerminalRuntimeState` that the root reduces.
///
/// The root says whether it wants the session on screen; the model speaks the protocol as Herdr's own
/// client does for a remote session: it connects hidden, then shows the session. Frames go from the
/// connection to the engine without passing through the main actor; the model lays out the panes and
/// owns their renderers.
@MainActor
final class HerdrScreenModel {
    typealias BridgeOpener = @Sendable (HerdrBridgeKind) async throws -> any HerdrBridgeTransport
    typealias RendererFenceFactory = @MainActor (
        HerdrTerminalEngine,
        _ paneID: String,
        HerdrRetainedTerminal
    ) -> any TerminalPaneRendererFence

    let target: SessionTarget
    let sessionInstanceID: UUID
    let terminalScreenAdapter = HerdrTerminalScreenAdapter()
    /// The session's workspaces and tabs, from the newest snapshot, kept across a reconnect.
    let places = HerdrSessionPlaces()

    /// What the model tells its owner about the session's notifications.
    enum NotificationEvent: Equatable {
        /// A Herdr notification, with the server boot whose pane ids it uses and the names of the
        /// place it is about.
        case received(HerdrSemanticNotification, bootID: String?, place: HerdrNotificationPlace)
        /// The server restarted, so earlier notifications point at panes that are gone.
        case serverRestarted
        /// A program in the session on screen rang the bell.
        case bell
    }

    /// What the model asks of the connection and the engine, in the order it asks.
    private enum Operation: Sendable {
        /// Shows the session, and takes it to `destination` right after, when given (`reconcileVisibility`).
        case show(HerdrSurfaceGeometry, to: HerdrDestination?)
        case hide
        case resize(HerdrSurfaceGeometry)
        case theme([HerdrHostThemeUpdate])
        case appActive(Bool)
        /// Input for a pane, or for a popup drawn from its frames; `delivered`, when given, learns whether
        /// Herdr has it.
        case input(HerdrTerminalTarget, events: [HerdrInputEvent], delivered: CheckedContinuation<Bool, Never>?)
        /// Remux's move to a place or creation (`move(_:to:)`); `fromAnotherTab` when another tab was on
        /// screen as it was asked for. `ask` names it among the attempt's moves (`Attempt.move`).
        case move(HerdrDestination, fromAnotherTab: Bool, ask: UInt64)
        /// The zoom button's zoom of the focused pane's tab.
        case zoom(String, zoomed: Bool)
        /// The pane sheet's question for a zoomed tab's layout, through a zoom of `paneID` that changes
        /// nothing (`fillTabMapIfNeeded`).
        case askLayout(String)
        /// Any other command, through the engine's lane after everything asked before it.
        case command(
            String,
            params: any Encodable & Sendable,
            answered: CheckedContinuation<Result<HerdrCommandReply, HerdrCommandError>, Never>
        )

        /// Tells whoever waits on the operation that it won't be carried out.
        func abandon() {
            switch self {
            case .input(_, _, let delivered?):
                delivered.resume(returning: false)
            case .command(_, _, let answered):
                answered.resume(returning: .failure(.connectionEnded))
            default:
                break
            }
        }
    }

    /// A move Remux asked for that hasn't ended. The engine decides what the move does; the model learns
    /// which of its view requests carries it, then that the request ended (`moveEnded`).
    private struct PendingMove {
        let ask: UInt64
        /// The pane it goes to; nil for a tab, a workspace or a creation, whose pane Herdr names once there.
        let pane: String?
        /// The tab it goes to, by its id, or by the name the screen gives a tab Herdr is making, whose id is
        /// known only once Herdr made it; nil for a close, which goes wherever Herdr shows the session then.
        let goesTo: (tabID: String?, name: String)?
        /// The engine's request that takes the session there, once the engine has the move.
        var request: UInt64?
        /// The pane a creation made, once Herdr's answer names it, whose tab the move goes to.
        var made: String?
    }

    /// One connection to the server, from opening its bridge to its end. A reconnect replaces it, and
    /// the panes keep their last frame meanwhile. Its id names its connection to the engine.
    ///
    /// Its task opens the connection, then carries out the operations one at a time, in the order they
    /// were asked for. Herdr takes the newest of a show and a hide, so that order is the session's
    /// state. No operation waits for Herdr's answer, so a hide goes out while a show is unanswered.
    @MainActor
    private final class Attempt {
        let id: UInt64
        var task: Task<Void, Never>?
        /// The connection, from the moment its bridge opened: from then on only the connection closes
        /// the bridge.
        var connection: HerdrConnection?
        /// The hello is on its way to Herdr: from then on, until the welcome, whether the path works is
        /// unknown.
        var helloSent = false
        /// The connection's welcome came and the model took it.
        var isOpen = false
        /// Herdr's surface switch names the snapshot's boot, so nothing is shown before one arrives.
        var hasSnapshot = false
        /// Whether the model asked for the session shown.
        var wantsShown = false
        /// A show or hide was asked that the engine hasn't started yet: the screen reads nothing of the
        /// request before it as the session's state.
        var visibilityPending = false
        /// The engine's current view request, as its `started` event said; only for what the screen
        /// reads, since the engine alone decides what is current.
        var request: (id: UInt64, kind: HerdrViewKind, showing: Bool)?
        /// The newest request the engine completed.
        var activatedRequest: UInt64?
        /// Remux's newest move, from the moment it is asked until it ends (`userPaneID`).
        var move: PendingMove?
        /// The moves asked so far, which name each one.
        var moveAsks: UInt64 = 0
        /// How the attempt's bridge closes, set once it is given up; nil while it is under way.
        var closeCause: HerdrBridgeCloseCause?
        /// The give-up's close of the connection.
        var closing: Task<Void, Never>?
        /// Whether the focused pane asks for every key as an escape code.
        var reportsAllKeys = false
        private var operations: [Operation] = []
        private var operationWaiter: CheckedContinuation<Void, Never>?
        private var operationsFinished = false

        init(id: UInt64) {
            self.id = id
        }

        var ended: Bool { closeCause != nil }

        var requestedShown: Bool { wantsShown }

        /// The session reads as connected: the connection is open with its first snapshot and, while the
        /// session is shown, has completed a request, so the panes show its frames.
        var isReady: Bool {
            isOpen && hasSnapshot && (!wantsShown || activatedRequest != nil)
        }

        /// Ready and shown, with no show in progress: the session takes input. A session shown again keeps
        /// its last frame and reads as connected meanwhile, but takes no input, as Herdr's client freezes
        /// input while a show is in progress. A move doesn't freeze it, as in Herdr's client; the engine refuses
        /// only input Herdr wouldn't take once the move's commands ahead of it are applied.
        var isActivated: Bool {
            guard isReady, wantsShown, !visibilityPending, let request, request.kind != .hide else { return false }
            return !request.showing || activatedRequest == request.id
        }

        /// Activated with no request in progress: the frame on screen shows where the session is, so a
        /// command for the tab on screen can go.
        var isSettled: Bool {
            isActivated && activatedRequest == request?.id
        }

        /// Returns once the attempt's task has returned and its give-up has closed its connection.
        func closed() async {
            await task?.value
            await closing?.value
        }

        /// Queued while the connection opens, and carried out once it is open. Only the newest size
        /// matters, as Herdr's client sends only the newest it sampled: a new size replaces every one
        /// not yet sent. A show queued before it already carries a newer size than those.
        func ask(_ operation: Operation) {
            guard !ended, !operationsFinished else {
                operation.abandon()
                return
            }
            if case .resize = operation {
                operations.removeAll { if case .resize = $0 { true } else { false } }
            }
            operations.append(operation)
            wake()
        }

        /// The next operation in the order asked, or nil once the attempt is over. An operation stays
        /// queued until taken here, so a newer size can still replace it.
        func nextOperation() async -> Operation? {
            while true {
                if operationsFinished { return nil }
                if !operations.isEmpty { return operations.removeFirst() }
                await withCheckedContinuation { operationWaiter = $0 }
            }
        }

        func finishOperations() {
            operationsFinished = true
            let abandoned = operations
            operations.removeAll()
            abandoned.forEach { $0.abandon() }
            wake()
        }

        private func wake() {
            operationWaiter?.resume()
            operationWaiter = nil
        }
    }

    /// Herdr's server closes a connection that sends no hello within 4 s of connecting; the bridge is
    /// closed before that if the screen has no size yet, and opened again once it has one.
    static let helloDeadline: Duration = .seconds(3)

    /// When a session that has connected reconnects by itself, as Herdr's client retries every endpoint,
    /// wake rules included (`endpoint/supervisor.rs`).
    struct RecoveryTiming: Sendable {
        /// The first retry after a drop; each failure in a row doubles it, up to `longestRetry`.
        var firstRetry: Duration = .milliseconds(500)
        var longestRetry: Duration = .seconds(120)
        /// A drop this long after the connection's first snapshot in the foreground starts the delays over.
        var stable: Duration = .seconds(60)
        /// A server that needs attention (incompatible, or a snapshot Remux can't read) is tried again
        /// this often.
        var recheck: Duration = .seconds(30)
        /// After the app comes back, delays are at most `wakeRetry` for `wakeWindow`.
        var wakeWindow: Duration = .seconds(30)
        var wakeRetry: Duration = .seconds(2)
    }

    /// What follows an attempt's end.
    private enum Recovery {
        /// A dropped connection: try again with growing delays, showing the last frame meanwhile.
        case retry
        /// The server needs attention: say why, and try again every `recheck`.
        case recheck
        /// The user has to act (sign-in, host key, Herdr missing), or the failure is Remux's own.
        case none
    }

    private let openBridge: BridgeOpener
    private let connectionTiming: HerdrConnection.Timing
    private let recoveryTiming: RecoveryTiming
    private let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void
    private let onNotification: (NotificationEvent) -> Void
    private let engine: HerdrTerminalEngine
    /// Where the phone keeps the zooms Remux made, for the session's end to take off.
    private let zoomKeepers: HerdrZoomKeepers
    /// The engine's claim on the session's zooms, made once before the first bridge opens: a release an earlier
    /// model of the session still has under way stops first (`HerdrZoomKeepers`), so the wait spends none of
    /// Herdr's time for a hello, and the session opens on the tab that release went back to.
    private var zoomClaim: Task<Void, Never>?
    private let makeRendererFence: RendererFenceFactory
    private let clipboard: TerminalClipboard
    private var runtime: GhosttyKitRuntime?
    private var currentTerminalSettings: TerminalSettings
    /// The colours of the current theme: Herdr gets them in the theme report, and Herdr's pane borders
    /// are drawn in them. nil when Ghostty can't give them.
    private(set) var terminalColors: GhosttyTerminalColors?
    private var reportTracker = TerminalRuntimeStateReportTracker()
    private var stopped = false
    private var failure: TerminalDisconnectReason?
    private var updatesTask: Task<Void, Never>?

    private var attempt: Attempt?
    private var attemptCount: UInt64 = 0
    private var sizeWaiter: CheckedContinuation<Void, Never>?

    /// Whether any connection reached its first snapshot. Only then does a failure reconnect by itself:
    /// a session that never opened says why.
    private var hasConnected = false
    /// A retry is waiting or under way after a drop; the session reads as reconnecting meanwhile.
    private var isReconnecting = false
    /// Failed attempts since the last stable connection, which set the next delay.
    private var failuresInARow = 0
    /// When the next attempt is due. Kept while the app is in the background, whose timer stops.
    private var recoveryDue: ContinuousClock.Instant?
    private var recoveryTimer: Task<Void, Never>?
    /// The current connection's first snapshot since it opened or the app came back, as Herdr's client
    /// counts how long a connection stayed up: time in the background doesn't count.
    private var readySince: ContinuousClock.Instant?
    private var wokeAt: ContinuousClock.Instant?

    private(set) var isSelected = false
    private var appPhase = GhosttyAppLifecyclePhase.active
    private var lastViewport: (size: CGSize, scale: CGFloat)?
    private(set) var measurement: GhosttyTerminalViewportMeasurement?
    /// When the screen first had a size, which a waiting bridge's hello deadline is held against.
    private var sizeKnownSince: ContinuousClock.Instant?

    /// A frame the engine drew, as it comes (`HerdrEngineUpdate.drawn`).
    private struct DrawnFrame {
        let layout: HerdrPaneLayout
        let projectionRevision: UInt64
        let connection: UInt64

        /// What the frame shows once on screen, whose agents the user then sees (`presentedFrame`).
        var presented: (connection: UInt64, bootID: String, projectionRevision: UInt64, paneIDs: Set<String>) {
            (connection, layout.bootID, projectionRevision, Set(layout.panes.lazy.filter { $0.innerRect != nil }.map(\.paneID)))
        }
    }

    /// The layout of the frame on screen. A frame the engine drew with panes that have no renderer yet waits
    /// off screen until all of them have drawn (`pendingFrame`), so the screen goes from one whole picture to
    /// the next, its names, focus and input with it.
    private(set) var layout: HerdrPaneLayout?
    /// The newest frame the engine drew, while the frame on screen stays until this one's panes have drawn
    /// off screen (`holdsScreen(for:)`).
    private var pendingFrame: DrawnFrame?
    /// The renderers of `pendingFrame`'s panes, each drawing its first picture off screen.
    private var stagedSurfaces: [String: HerdrPaneSurface] = [:]
    /// Surfaces of panes that left the screen, closed once the screen has let go of their views
    /// (`closeReleasedSurfaces`), so the last picture stays until the next one is in its place.
    private var retiredSurfaces: [HerdrPaneSurface] = []
    /// The newest snapshot, kept across a reconnect until the new connection's first.
    private var snapshot: HerdrSnapshot?
    /// The frame on screen: the connection and snapshot revision it was drawn against, and its panes.
    private var presentedFrame: (connection: UInt64, bootID: String, projectionRevision: UInt64, paneIDs: Set<String>)?
    /// The session's agents as this phone shows them.
    let agents = HerdrAgentPresentation()
    /// Where to go once the session is shown, and the server boot its ids belong to.
    private var pendingReveal: (destination: HerdrDestination, bootID: String?)?
    /// The workspace close Herdr's server asked the user to confirm, until the user answers
    /// (`answerAskedCloseConfirmation(agreed:)`).
    private(set) var askedCloseConfirmation: HerdrCloseConfirmation?
    /// The pane Herdr has focused, as the newest snapshot says. A pane can be focused before its first
    /// frame arrives. The user may be in another while Remux's move is under way (`userPaneID`).
    private(set) var focusedPaneID: String?
    /// Tabs the user unzoomed with the pane sheet's button, which the setting leaves alone after.
    private var tabsUnzoomedByUser: Set<HerdrTabKey> = []
    private var tabMap: HerdrTabMap?
    /// The zoomed tab's panes the map had no place for when Remux last asked Herdr for its layout.
    private var askedTabMapGap: HerdrTabMapGap?
    private var terminals: [String: HerdrRetainedTerminal] = [:]
    private var surfaces: [String: HerdrPaneSurface] = [:]
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
    /// Where the pointer is over each pane, in the pane's points: a tap's place or a scroll gesture's.
    private var pointers: [String: CGPoint] = [:]
    /// The scroll travel over each pane not yet a whole wheel step.
    private var wheelRemainders: [String: Double] = [:]
    /// The mouse button held down in a pane, from its press to its release.
    private var mouseGesture: MouseGesture?
    private var presentationFailures: [String: TerminalDisconnectReason] = [:]
    /// The popup over the tab on screen.
    private(set) lazy var popup: HerdrPopupController = makePopupController()
    private let makePopupAttachment: HerdrPopupController.AttachmentFactory?
    /// The ink of the popup's frame: Herdr's accent as the session showed it last (`learnPopupAccent`).
    private(set) var popupAccent = HerdrPopupAccent.herdrDefault
    private var popupPointer: CGPoint?
    /// The scroll travel over the popup not yet a whole row.
    private var popupWheelRemainder: Double?
    private var notices = HerdrNoticePolicy(visibleFor: GhosttyTerminalNotice.failureDuration)
    private var creatingTerminals: Set<ObjectIdentifier> = []
    /// Ghostty gives a terminal one renderer at a time, so a replacement waits for these to close.
    private var closingTerminals: Set<ObjectIdentifier> = []
    private var creationsDrained: CheckedContinuation<Void, Never>?
    /// Renderers whose surfaces aren't freed yet. Ghostty requires the app to outlive every surface,
    /// so a stop releases the runtime only once this is back to zero.
    private var closingRenderers = 0
    private var closesDrained: CheckedContinuation<Void, Never>?
    /// How long a switch to another tab goes before the screen says so (`switchingCue`).
    private let switchingCueDelay: Duration
    private var switchingCueTimer: Task<Void, Never>?
    /// The switch under way has taken longer than `switchingCueDelay`.
    private var isSwitchingCueDue = false

    init(
        target: SessionTarget,
        sessionInstanceID: UUID,
        openBridge: @escaping BridgeOpener,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        onNotification: @escaping (NotificationEvent) -> Void,
        connectionTiming: HerdrConnection.Timing = HerdrConnection.Timing(),
        recoveryTiming: RecoveryTiming = RecoveryTiming(),
        switchingCueDelay: Duration = HerdrScreenModel.switchingCueDelay,
        engine: HerdrTerminalEngine = HerdrTerminalEngine(cellWidthPx: 1, cellHeightPx: 1),
        zoomKeepers: HerdrZoomKeepers = HerdrZoomKeepers(store: InMemoryHerdrOwnedZoomStore()),
        makeRendererFence: @escaping RendererFenceFactory = {
            HerdrPaneRendererFence(engine: $0, paneID: $1, terminal: $2)
        },
        makePopupAttachment: HerdrPopupController.AttachmentFactory? = nil,
        clipboard: TerminalClipboard = .general
    ) {
        self.target = target
        self.sessionInstanceID = sessionInstanceID
        self.openBridge = openBridge
        self.onRuntimeStateChange = onRuntimeStateChange
        self.onNotification = onNotification
        self.connectionTiming = connectionTiming
        self.recoveryTiming = recoveryTiming
        self.switchingCueDelay = switchingCueDelay
        self.engine = engine
        self.zoomKeepers = zoomKeepers
        self.makeRendererFence = makeRendererFence
        self.makePopupAttachment = makePopupAttachment
        self.clipboard = clipboard
        currentTerminalSettings = target.terminalSettings
        terminalScreenAdapter.attach(to: self)
        do {
            runtime = try GhosttyKitRuntime(terminalSettings: target.terminalSettings)
        } catch {
            failure = Self.runtimeStartFailure
            didChange()
            return
        }
        terminalColors = try? runtime?.terminalColors()
        popup.setRuntime(runtime)
        let engine = self.engine
        updatesTask = Task { [weak self] in
            for await update in engine.updates {
                self?.handle(update)
            }
        }
        restart()
    }

    /// True when no connection is open or opening, so the root may replace this model without dropping
    /// a session the user is attached to.
    var isDisconnected: Bool {
        guard let attempt else { return true }
        return attempt.ended
    }

    // MARK: - What the root wants

    /// Whether the root shows this session: the selected session, outside Home. A sheet over the
    /// terminal keeps it shown. Only a selected session's panes are presented to Ghostty.
    func setSelected(_ selected: Bool) {
        guard !stopped, selected != isSelected else { return }
        isSelected = selected
        // Where the session was asked to go applies to the show it was asked for.
        if !selected { pendingReveal = nil }
        reconcilePresentationActivity()
        closeReleasedSurfaces()
        reconcileVisibility()
        reconcilePopupHold()
    }

    /// Goes to `place`, a pick from what the screen or a list shows of the session (`ask(_:bootID:)`).
    @discardableResult
    func reveal(_ place: HerdrPlace, bootID: String?) -> Bool {
        ask(.go(.place(place)), bootID: bootID)
    }

    /// New Tab, New Workspace or a split of a pane, with the command Herdr's client sends, focused, which
    /// goes to the pane Herdr makes (`ask(_:bootID:)`). A tab the session leaves for a new one keeps its
    /// zoom. Herdr's split unzooms the tab it splits (`workspace/tab.rs`), so the setting zooms the new pane,
    /// as tmux keeps a window zoomed through a split; a tab the user unzoomed stays unzoomed.
    @discardableResult
    func create(_ creation: HerdrCreation, bootID: String?) -> Bool {
        ask(.go(.creation(creation)), bootID: bootID)
    }

    /// A pane of the tab on screen, as a scroll over it picks it: a pick from the layout drawn.
    func focusPane(_ paneID: String) -> Bool {
        reveal(.pane(paneID), bootID: layout?.bootID)
    }

    /// The one way Remux asks something of the session. It goes only on the server boot its ids came from,
    /// while what it names is still there; one whose target changed is refused, as Herdr's client refuses a
    /// stale close (`overlay_input.rs` `accept_close_confirmation`).
    /// - Going somewhere, as Herdr's client goes to a notification's pane or a workspace on its machine, is
    ///   a move there on the session on screen (`move(_:to:)`); a session not on screen goes there right
    ///   after its show, as part of it.
    /// - A close or a rename goes only on the session on screen, since Herdr refuses commands from a hidden
    ///   one. A close of what is on screen, the workspace, the tab or one of its panes, takes the session
    ///   wherever Herdr shows it then, so it is a view request as a move is (`.closing`). Any other close,
    ///   and a rename, moves nothing: they go through the lane after the commands asked before them.
    /// Returns false when it won't go: the model has stopped, the session can't take it, or what it names
    /// changed.
    @discardableResult
    func ask(_ request: HerdrRequest, bootID: String?) -> Bool {
        guard !stopped else { return false }
        guard case .go(let destination) = request else { return change(request, bootID: bootID) }
        pendingReveal = (destination, bootID)
        guard let attempt = shownOpenAttempt else { return true }
        guard let destination = takePendingReveal() else { return false }
        move(attempt, to: destination)
        return true
    }

    /// A close or rename on the session on screen (`ask(_:bootID:)`). A tab or workspace name is trimmed
    /// and never empty, since Herdr would keep an empty one as the name; a pane's empty name clears its
    /// manual one, as Herdr's client sends it (`overlay_input.rs` `save_rename_overlay`). An auto-named tab
    /// given its own name back sends nothing, which would only pin the name.
    private func change(_ request: HerdrRequest, bootID: String?) -> Bool {
        guard let attempt = shownOpenAttempt, let snapshot, Self.holds(request.origin, bootID: bootID, in: snapshot) else {
            if !stopped { refused(request) }
            return false
        }
        switch request {
        case .go:
            return false
        case .close(let place, let group) where snapshot.isOnScreen(place):
            move(attempt, to: .closing(place, group: group))
        case .close(let place, let group):
            send(request, method: place.closeMethod, params: place.closeParams(group: group), on: attempt)
        case .rename(let place, let typed):
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            switch place {
            case .pane:
                break
            case .tab(let id):
                guard !name.isEmpty else { return false }
                if let tab = snapshot.tabs.first(where: { $0.tabID == id }), !tab.customLabel, tab.label == name {
                    return true
                }
            case .workspace:
                guard !name.isEmpty else { return false }
            }
            send(request, method: place.renameMethod, params: place.renameParams(name), on: attempt)
        }
        return true
    }

    /// The current attempt, while it is open and the session is on screen.
    private var shownOpenAttempt: Attempt? {
        guard let attempt, isCurrent(attempt), attempt.isOpen, attempt.requestedShown else { return nil }
        return attempt
    }

    /// Where to go, once a snapshot is in, if what it names is still there on the server boot its ids came
    /// from.
    private func takePendingReveal() -> HerdrDestination? {
        guard let reveal = pendingReveal, let snapshot else { return nil }
        pendingReveal = nil
        guard Self.holds(reveal.destination.origin, bootID: reveal.bootID, in: snapshot) else { return nil }
        return reveal.destination
    }

    /// Whether `origin`, named on server boot `bootID`, is still there in `snapshot`.
    private static func holds(_ origin: HerdrPlace?, bootID: String?, in snapshot: HerdrSnapshot) -> Bool {
        (bootID.map { $0 == snapshot.bootID } ?? true) && (origin.map(snapshot.contains) ?? true)
    }

    /// A close or rename that moves nothing, through the engine's lane after the operations asked before it.
    private func send(
        _ request: HerdrRequest,
        method: String,
        params: some Encodable & Sendable,
        on attempt: Attempt
    ) {
        Task { [weak self] in
            guard let self else { return }
            let result = await command(method, params: params, on: attempt)
            guard isCurrent(attempt) else { return }
            if case .failure(let failure) = result { return changeAnswered(request, failure: failure) }
            changeAnswered(request, failure: nil)
        }
    }

    /// Herdr answered a close or rename. A close Herdr's server wants confirmed, as one that would close a
    /// worktree group, asks the user about its workspace's close instead of failing, as Herdr's client does
    /// (`client/shell/actions.rs`); any other failure says so.
    private func changeAnswered(_ request: HerdrRequest, failure: HerdrCommandError?) {
        let method: String
        let label: String
        switch request {
        case .go: return
        case .close(let place, _):
            method = place.closeMethod
            label = place.closeFailureLabel
        case .rename(let place, _):
            method = place.renameMethod
            label = place.renameFailureLabel
        }
        guard let failure else { return notices.succeeded(method, bootID: layout?.bootID) }
        if case .failed("confirmation_required", _) = failure, case .close(let place, _) = request,
           let outline = places.outline, let workspace = outline.workspace(containing: place) {
            askedCloseConfirmation = outline.closeConfirmation(ofWorkspace: workspace.id)
            didChange()
            return
        }
        presentFailure(of: method, label: label, failure)
    }

    /// A close or rename that won't go, whose target or server boot changed, says so, as Herdr's client
    /// says a close target changed.
    private func refused(_ request: HerdrRequest) {
        let label: String
        switch request {
        case .go: return
        case .close(let place, _): label = place.closeFailureLabel
        case .rename(let place, _): label = place.renameFailureLabel
        }
        notices.replaced()
        terminalScreenAdapter.presentFailure(label)
    }

    /// What runs in a pane and what it is doing, as the Tabs sheet's rows say, read from the newest snapshot
    /// when the sheet is drawn (`HerdrSnapshot.program(ofPane:)`, `activity(ofPane:)`). A snapshot tells the
    /// views when it changes what a row says, and only then: an agent's ticking title reaches no row.
    func program(ofPane paneID: String) -> TerminalProgram {
        snapshot?.program(ofPane: paneID) ?? .terminal
    }

    func activity(ofPane paneID: String) -> String {
        snapshot?.activity(ofPane: paneID) ?? ""
    }

    /// What the rename alert for `place` starts with (`HerdrSnapshot.renameField(for:)`).
    func renameField(for place: HerdrPlace) -> TerminalRenameField? {
        snapshot?.renameField(for: place)
    }

    /// The user answered the asked confirmation; agreeing asks for its close as any close goes.
    func answerAskedCloseConfirmation(agreed: Bool) {
        guard let confirmation = askedCloseConfirmation else { return }
        askedCloseConfirmation = nil
        if agreed { ask(confirmation.request, bootID: confirmation.bootID) }
        didChange()
    }

    /// The background hides the session; the app's other phases leave it on screen.
    ///
    /// In the background a waiting reconnect stops and a connection still opening is given up, as in
    /// Herdr's client; an open one stays. Back from it, as in Herdr's client after a resume, a waiting
    /// reconnect runs at once and delays are short for a while; an open connection is shown again at
    /// once while it checks itself with a ping, and one that is gone fails its show or the ping.
    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        guard !stopped else { return }
        let wasBackground = appPhase == .background
        appPhase = phase
        if phase == .background, !wasBackground {
            enterBackground()
        } else if phase != .background, wasBackground {
            leaveBackground()
        }
        reconcilePresentationActivity()
        attempt?.ask(.appActive(phase != .background))
        reconcileVisibility()
        // Back in front, the user sees the frame on screen, as Herdr's client acknowledges its surface
        // when its terminal regains focus (`shell/input.rs`).
        if phase == .active { acknowledgeShownAgents() }
        didChange()
    }

    private func enterBackground() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        readySince = nil
        guard let attempt, !attempt.ended, !attempt.isOpen else { return }
        // Not a failure: it is opened again on return.
        giveUp(attempt, suspending: true)
        recoveryDue = recoveryDue ?? .now
    }

    private func leaveBackground() {
        wokeAt = .now
        if recoveryDue != nil { restart() }
    }

    /// Live settings: the renderers take the new appearance in place, and Herdr gets the new colours.
    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard !stopped, settings != currentTerminalSettings else { return }
        guard !settings.hasSameTerminalAppearance(as: currentTerminalSettings) else {
            currentTerminalSettings = settings
            return
        }
        try runtime?.applyTerminalSettings(settings)
        let themeChanged = settings.theme != currentTerminalSettings.theme
        currentTerminalSettings = settings
        if themeChanged {
            terminalColors = try? runtime?.terminalColors()
            didChange()
        }
        for surface in Array(surfaces.values) + stagedSurfaces.values where !surface.renderer.isClosing {
            if !surface.renderer.applyTerminalConfiguration(theme: settings.theme) {
                surface.renderer.failPresentation(message: Self.configurationFailureMessage)
            }
        }
        if !popup.applyTheme(settings.theme) {
            popup.surface?.renderer.failPresentation(message: Self.configurationFailureMessage)
        }
        if themeChanged, let themeReport {
            attempt?.ask(.theme(themeReport))
        }
        if let lastViewport {
            prepareViewport(size: lastViewport.size, scale: lastViewport.scale)
        }
    }

    /// The screen's size. Herdr's client sends its size on every resize; a hidden session gets it with
    /// the next show.
    func prepareViewport(size: CGSize, scale: CGFloat) {
        guard !stopped, let runtime else { return }
        lastViewport = (size, scale)
        let measured: GhosttyTerminalViewportMeasurement?
        do {
            measured = try runtime.measureTmuxViewportLayout(size: size, scale: scale)
        } catch {
            if let attempt { end(attempt, Self.viewportFailure, recovery: .none) }
            return
        }
        guard let measured, measured != measurement else { return }
        if measurement == nil { sizeKnownSince = .now }
        measurement = measured
        popup.setViewport(cell: measured.cellMetrics, columns: measured.controlViewport.columns, rows: measured.controlViewport.rows)
        if let geometry { attempt?.ask(.resize(geometry)) }
        resumeSizeWaiter()
        // The panes of a frame held off screen take a new cell size there, and the frame on screen keeps its
        // picture until they have drawn at it.
        for (paneID, surface) in pendingFrame == nil ? surfaces : stagedSurfaces {
            guard let metrics = displayMetrics(for: paneID) else { continue }
            _ = surface.renderer.updateDisplay(metrics: metrics)
        }
        for paneID in Array(terminals.keys) {
            createRendererIfPossible(paneID)
        }
        // A frame held off screen at the grid asked for again is shown as it is.
        showPreparedFrameIfReady()
        didChange()
    }

    /// Ends the current connection, if any, and opens a new one. The panes keep their terminals, so
    /// the last frame stays on screen until the new connection's first. Pane failures say to reconnect,
    /// so a reconnect also tries the failed panes again: a pane Ghostty couldn't paint gets a new
    /// terminal from the new connection's first frame, and a failed renderer is replaced over its
    /// terminal now.
    ///
    /// Returns false when the model can't open a connection, because its terminal runtime didn't start
    /// or it has stopped; the root then replaces it.
    ///
    /// A reconnect the user asks for runs now and starts the delays over, as in Herdr's client.
    @discardableResult
    func reconnect() -> Bool {
        guard !stopped, runtime != nil else { return false }
        isReconnecting = false
        failuresInARow = 0
        failure = nil
        popup.retryAttach()
        restart()
        return true
    }

    /// Closes the connection, lets the engine finish its event and free the pane producers, waits for
    /// renderers still being created, then closes every renderer, which unregisters it from the engine
    /// before freeing it, and releases the Ghostty app once every renderer closed anywhere is freed.
    ///
    /// The session's end first takes off the zooms Remux made, as tmux's does, after a command still in
    /// flight, and waits for Herdr's answers, each within Herdr's time for a show, so the unzooms aren't lost
    /// with the connection (`HerdrTerminalEngine.releaseZooms`). A runtime replaced by a new attempt leaves
    /// them: the new attempt takes them over from the phone's record of them. Closing the connection then
    /// hides the session on the server.
    func stop(_ reason: TerminalRuntimeStopReason = .sessionEnded) async {
        guard !stopped else { return }
        let feed = attempt.flatMap { isCurrent($0) && $0.isOpen ? HerdrEngineFeed(engine: engine, connection: $0.id) : nil }
        stopped = true
        cancelRecovery()
        switchingCueTimer?.cancel()
        popup.stop()
        if let feed, reason == .sessionEnded {
            await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
                Task { [stepTime = connectionTiming.activation] in
                    await feed.releaseZooms(within: stepTime) { released.resume() }
                }
            }
        }
        if let attempt {
            giveUp(attempt)
            await attempt.closed()
        }
        await engine.stop()
        if !creatingTerminals.isEmpty {
            await withCheckedContinuation { creationsDrained = $0 }
        }
        let open = Array(surfaces.values) + stagedSurfaces.values + retiredSurfaces
        surfaces.removeAll()
        stagedSurfaces.removeAll()
        retiredSurfaces.removeAll()
        pendingFrame = nil
        for surface in open {
            close(surface.renderer)
        }
        if closingRenderers > 0 {
            await withCheckedContinuation { closesDrained = $0 }
        }
        terminals.removeAll()
        presentationFailures.removeAll()
        layout = nil
        terminalScreenAdapter.invalidate()
        runtime = nil
    }

    // MARK: - What the screen reads

    var runtimePhase: GhosttyTerminalRuntimePhase {
        if let failure { return .failed(message: failure.message, reason: failure) }
        guard let attempt, !attempt.ended, attempt.isOpen else { return .starting }
        return .running
    }

    var isConnectionOpen: Bool {
        guard let attempt else { return false }
        return attempt.isOpen && !attempt.ended
    }

    /// The session reads as connected once its current connection is ready (`Attempt.isReady`). Until
    /// then the panes show the last connection's frame, which takes no input.
    var isConnectionReady: Bool {
        guard let attempt, isCurrent(attempt) else { return false }
        return attempt.isReady
    }

    var stateTraceLabel: String {
        if stopped { return "released" }
        if failure != nil { return "ended" }
        if isReconnecting { return "reconnecting" }
        guard let attempt, attempt.isOpen else { return "connecting" }
        guard attempt.requestedShown else { return "hidden" }
        return attempt.isSettled ? "shown" : "showing"
    }

    func paneSurface(_ paneID: String) -> HerdrPaneSurface? {
        surfaces[paneID]
    }

    /// What Herdr's notification rules read of this session, once a snapshot has arrived.
    var notificationState: HerdrNotificationSessionState? {
        guard let snapshot else { return nil }
        return HerdrNotificationSessionState(
            isShown: isSelected,
            focusedWorkspaceID: snapshot.focusedWorkspaceID,
            focusedTabID: snapshot.focusedTabID,
            agentStatuses: Dictionary(agents.agents.map { ($0.paneID, $0.state.status) }) { $1 }
        )
    }

    func presentation(ofPane paneID: String?) -> TerminalPanePresentation {
        guard let paneID else { return .pending }
        if let failure = presentationFailures[paneID] { return .failed(failure) }
        return surfaces[paneID]?.renderer.presentation ?? .pending
    }

    // MARK: - Input

    /// The session takes input: it is shown on an open connection with no show in progress, and Herdr has a
    /// pane focused, as Herdr's client sends input (`shell/input.rs`): Herdr's client drops input before its
    /// first snapshot and while a show is in progress, and the server drops input on a hidden surface. It
    /// holds while Remux's move is under way, whichever pane the user is in (`userPaneID`), and while the
    /// screen catches up with where Herdr has the session, so the keyboard stays up; the keys typed meanwhile
    /// are dropped (`inputTarget(forPane:)`).
    var isInputAvailable: Bool {
        popup.takesInput || focusedPaneID.flatMap(herdrInputTarget(forPane:)) != nil
    }

    /// The pane the user is in: the pane of Remux's move from the moment it is asked until it ends, else
    /// the pane Herdr has focused. A move to a tab, a workspace or a new pane is in no pane until it ends,
    /// as Herdr names that pane only once there.
    ///
    /// Keys follow it, as Herdr's client sends every key to its own focused pane, through
    /// `inputTarget(forPane:)`: while Herdr doesn't take input for it yet, as for another pane of a zoomed
    /// tab or a pane on another tab, keys are dropped, one by one, as Herdr's client drops input during an
    /// activation, and never go to the pane left. The screen's drawing, readiness and the composer's pane
    /// follow it only once it is drawn (`screenPaneID`); until then they keep the focus of the frame on
    /// screen, which stays until the frame showing where the move went is on screen, so the session stays
    /// ready to type into.
    var userPaneID: String? {
        guard let attempt, isCurrent(attempt), let move = attempt.move else { return focusedPaneID }
        return move.pane
    }

    /// The pane the screen shows as the user's: `userPaneID` once it is drawn, else the pane focused in the
    /// frame on screen. A snapshot ahead of that frame changes nothing here until its own frame is on screen.
    var screenPaneID: String? {
        guard let layout else { return nil }
        guard let pane = userPaneID, isDrawn(pane) else { return layout.focusedPaneID }
        return pane
    }

    /// Whether the frame on screen draws `paneID` with its text, and no newer frame waits off screen.
    private func isDrawn(_ paneID: String) -> Bool {
        pendingFrame == nil && layout?.panes.contains { $0.paneID == paneID && $0.hasTextArea } == true
    }

    /// Whether the screen shows where Herdr has the session: the pane Herdr has focused is drawn, so an action
    /// on what the user sees can go to Herdr's focus.
    private var showsHerdrsFocus: Bool {
        focusedPaneID.map(isDrawn) ?? false
    }

    private var inputTarget: (attempt: Attempt, paneID: String)? {
        userPaneID.flatMap(inputTarget(forPane:))
    }

    /// Where input for `paneID` goes, the one rule for every input: Herdr takes it (`herdrInputTarget`), and
    /// the frame on screen draws the pane (`isDrawn`), so nothing typed goes to a pane the user doesn't see,
    /// as one on the tab a move is going to while the tab left is still on screen. As it goes, the engine
    /// sends it only if Herdr still takes it once the commands ahead of it are applied, as after the steps
    /// of a move away from the pane (`HerdrTerminalEngine.send(_:to:connection:)`): a composer part that
    /// doesn't go is refused, and a key is dropped.
    private func inputTarget(forPane paneID: String) -> (attempt: Attempt, paneID: String)? {
        guard isDrawn(paneID) else { return nil }
        return herdrInputTarget(forPane: paneID)
    }

    /// Whether Herdr takes input for `paneID`: the session is shown with no show in progress, and Herdr takes
    /// input for the pane, as it does for the panes of the tab a client views
    /// (`server/headless/client_views.rs` `shell_client_views_pane`): only the focused pane while that tab is
    /// zoomed, and any pane of it otherwise.
    private func herdrInputTarget(forPane paneID: String) -> (attempt: Attempt, paneID: String)? {
        guard let attempt = shownAttempt, let snapshot else { return nil }
        let tab = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }
        guard paneID == snapshot.focusedPaneID
            || (tab?.zoomed == false
                && snapshot.panes.contains { $0.paneID == paneID && $0.tabID == snapshot.focusedTabID })
        else { return nil }
        return (attempt, paneID)
    }

    private var shownAttempt: Attempt? {
        guard let attempt, isCurrent(attempt), attempt.isActivated else { return nil }
        return attempt
    }

    func sendText(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if popup.takesInput { return popup.sendText(text) }
        guard let target = inputTarget else { return .transportUnavailable }
        return send(
            HerdrInputTranslator.events(forText: text, reportsAllKeys: target.attempt.reportsAllKeys),
            to: target
        )
    }

    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        if popup.takesInput { return popup.sendPaste(text) }
        guard let target = inputTarget else { return .transportUnavailable }
        return send([.paste(text)], to: target)
    }

    /// A release is accepted without being sent: Herdr's client sends none from a plain terminal.
    func sendKey(_ key: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        if popup.takesInput { return popup.sendKey(key) }
        guard let target = inputTarget else { return .transportUnavailable }
        guard let event = HerdrInputTranslator.event(for: key) else {
            return key.action == .release ? .accepted : .surfaceRejected
        }
        return send([event], to: target)
    }

    /// Input is accepted once queued behind the session's earlier operations; Herdr doesn't
    /// acknowledge input. Input over Herdr's byte limit isn't sent: Herdr would close the connection,
    /// or refuse a paste.
    private func send(
        _ events: [HerdrInputEvent],
        to target: (attempt: Attempt, paneID: String)
    ) -> FocusedTerminalInputSubmissionResult {
        let messages = HerdrInputTranslator.messages(events)
        do {
            try messages.forEach(HerdrConnection.checkLimits)
        } catch {
            presentInputFailure()
            return .surfaceRejected
        }
        for message in messages {
            ask(input: message, to: .pane(target.paneID), on: target.attempt, delivered: nil)
        }
        return .accepted
    }

    /// The composer's message goes to the pane it was written in, focused or not: Herdr takes input for
    /// every pane on the shown tab. Each part returns true once Herdr has it, so the composer's pause
    /// before Enter runs from there; false when it can't go, or the connection ended first.
    func sendPasteAwaitingDelivery(_ text: String, toPane paneID: String) async -> Bool {
        guard !text.isEmpty else { return false }
        return await sendAwaitingDelivery([.paste(text)], toPane: paneID)
    }

    func sendKeyAwaitingDelivery(_ key: GhosttySurfaceKeyEvent, toPane paneID: String) async -> Bool {
        guard let event = HerdrInputTranslator.event(for: key) else { return false }
        return await sendAwaitingDelivery([event], toPane: paneID)
    }

    private func sendAwaitingDelivery(_ events: [HerdrInputEvent], toPane paneID: String) async -> Bool {
        // Herdr drops pane input while a popup is open over the tab, and still answers the ping.
        guard let target = inputTarget(forPane: paneID), popup.popup == nil,
              (try? HerdrConnection.checkLimits(events)) != nil
        else { return false }
        return await withCheckedContinuation { delivered in
            ask(input: events, to: .pane(target.paneID), on: target.attempt, delivered: delivered)
        }
    }

    // MARK: - The popup

    var popupPresentation: TerminalPanePresentation {
        popup.presentation
    }

    /// The pointer moved over the popup, in its terminal's points, as over a pane (`motion`): the cell a tap
    /// clicks and a scroll gesture's steps are reported at.
    func movePopupPointer(to point: CGPoint, mods: GhosttySurfaceKeyEvent.Mods) {
        let previous = popupPointer.flatMap(popupCell(at:))
        popupPointer = point
        guard let terminalID = popup.popup?.terminalID, let cell = popupCell(at: point),
              let kind = motion(to: cell, from: previous, over: .popup(terminalID), readsMouse: popupReportsMouse)
        else { return }
        _ = popup.sendMouse(kind, column: cell.column, row: cell.row, modifiers: HerdrInputTranslator.modifiers(for: mods))
    }

    /// A swipe over the popup, as the pane's: its travel in whole rows of the panes' font.
    func scrollPopup(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        let momentum = event.mods.momentum
        guard momentum != .cancelled else {
            popupWheelRemainder = nil
            return true
        }
        if momentum == .began { popupWheelRemainder = 0 }
        defer {
            if momentum == .ended { popupWheelRemainder = nil }
        }
        guard popup.takesInput, let cell = popup.displayed?.cell ?? measurement?.cellMetrics else { return false }
        let cellHeight = Double(cell.pixelHeight)
        let travel = (popupWheelRemainder ?? 0) + event.deltaY
        let steps = (travel / cellHeight).rounded(.towardZero)
        popupWheelRemainder = travel - steps * cellHeight
        guard let at = popupCell(at: popupPointer ?? .zero) else { return false }
        return popup.scroll(rows: Int(steps), column: at.column, row: at.row)
    }

    /// Whether the popup's program reads the mouse, as its attach and Herdr's surface say.
    var popupReportsMouse: Bool {
        popup.reportsMouse
    }

    /// A button pressed or released at the pointer over the popup, as Herdr's client sends one to a popup
    /// whose program reads the mouse (`client/shell/mouse.rs`): the press, and then its release
    /// (`releaseHeldButton`). Herdr writes either to the program only while it reads the mouse
    /// (`server/pane_input.rs`). Returns false when the event doesn't go.
    func sendPopupMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard let button = HerdrInputTranslator.mouseButton(event.button) else { return false }
        switch event.state {
        case .press:
            guard mouseGesture == nil, popupReportsMouse, let terminalID = popup.popup?.terminalID,
                  let cell = popupCell(at: popupPointer ?? .zero),
                  popup.sendMouse(.down(button), column: cell.column, row: cell.row, modifiers: HerdrInputTranslator.modifiers(for: event.mods))
            else { return false }
            mouseGesture = MouseGesture(target: .popup(terminalID), button: button, cell: cell)
            return true
        case .release:
            return releaseHeldButton(button, mods: event.mods)
        }
    }

    /// The popup's cell at `point`, in its terminal's points, within the grid it draws.
    private func popupCell(at point: CGPoint) -> PaneCell? {
        guard let cell = popup.displayed?.cell ?? measurement?.cellMetrics else { return nil }
        let grid = popup.displayed?.grid
        func index(_ points: CGFloat, size: CGFloat, count: UInt16?) -> UInt16 {
            let index = max(Int((points / max(size, 1)).rounded(.down)), 0)
            return UInt16(clamping: count.map { min(index, Int(max($0, 1)) - 1) } ?? index)
        }
        return PaneCell(
            column: index(point.x, size: cell.pointWidth, count: grid?.columns),
            row: index(point.y, size: cell.pointHeight, count: grid?.rows)
        )
    }

    /// Typing into the popup, read as Herdr's client reads a terminal's: Herdr says whether the popup's
    /// program asks for every key (`ClientShellKeyboardReportAll` follows the popup, `render.rs`
    /// `shell_focused_runtime`).
    private func sendPopupText(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard let attempt = shownAttempt else { return .transportUnavailable }
        return sendPopupInput(HerdrInputTranslator.events(forText: text, reportsAllKeys: attempt.reportsAllKeys))
    }

    /// The popup's input, as Herdr's client sends a popup's: in the order typed, within Herdr's limits.
    private func sendPopupInput(_ events: [HerdrInputEvent]) -> FocusedTerminalInputSubmissionResult {
        guard let attempt = shownAttempt, let terminalID = popup.popup?.terminalID else { return .transportUnavailable }
        let messages = HerdrInputTranslator.messages(events)
        do {
            try messages.forEach(HerdrConnection.checkLimits)
        } catch {
            presentInputFailure()
            return .surfaceRejected
        }
        for message in messages {
            ask(input: message, to: .popup(terminalID), on: attempt, delivered: nil)
        }
        return .accepted
    }

    private func deliverPopupInput(_ events: [HerdrInputEvent], to terminalID: String) async -> Bool {
        guard let attempt = shownAttempt, popup.popup?.terminalID == terminalID,
              (try? HerdrConnection.checkLimits(events)) != nil
        else { return false }
        return await withCheckedContinuation { delivered in
            ask(input: events, to: .popup(terminalID), on: attempt, delivered: delivered)
        }
    }

    /// The phone holds the popup while it is on the phone's screen: the session is shown and selected, the
    /// app isn't in the background, and no move of Remux's is taking the session elsewhere.
    private func reconcilePopupHold() {
        let attempt = shownAttempt
        popup.setHeld(!stopped && isSelected && appPhase != .background && popup.popup != nil
            && attempt != nil && attempt?.move == nil)
    }

    /// Herdr's accent, which Herdr's client draws a popup's border in (`client/shell/composition.rs`), is the
    /// colour of the focused pane's border lines (`ui/panes.rs`). A tab without lines there, as a single pane
    /// is by Herdr's default `pane_borders`, keeps the one the session showed last.
    private func learnPopupAccent(from layout: HerdrPaneLayout) {
        guard let color = HerdrPopupAccent.color(in: layout) else { return }
        popupAccent = color
    }

    private func makePopupController() -> HerdrPopupController {
        let openBridge = openBridge
        let engine = engine
        let makeAttachment = makePopupAttachment ?? { terminalID, geometry in
            HerdrTerminalAttachment(terminalID: terminalID, geometry: geometry, openBridge: { try await openBridge(.terminal) })
        }
        return HerdrPopupController(
            theme: currentTerminalSettings.theme,
            makeAttachment: makeAttachment,
            makeFrameFence: { HerdrPaneRendererFence(engine: engine, target: .popup($0), terminal: $1) },
            paintFrames: { paints, revision in Task { await engine.setPaintsPopup(paints, revision: revision) } },
            input: HerdrPopupController.Input(
                text: { [weak self] in self?.sendPopupText($0) ?? .transportUnavailable },
                send: { [weak self] in self?.sendPopupInput($0) ?? .transportUnavailable },
                deliver: { [weak self] in await self?.deliverPopupInput($1, to: $0) ?? false }
            ),
            onHeldElsewhere: { [weak self] in
                self?.terminalScreenAdapter.presentInformation(Self.popupHeldElsewhereMessage, for: GhosttyTerminalNotice.failureDuration)
            },
            onSurface: { [weak self] in self?.terminalScreenAdapter.makeScreenSurface(forPopup: $0) },
            onChange: { [weak self] in self?.popupChanged() }
        )
    }

    /// The popup's renderer changed, or the popup went by itself, as one Herdr leaves out goes with its
    /// attach: the panes it covered are drawn again.
    private func popupChanged() {
        reconcilePresentationActivity()
        didChange()
    }

    /// All input over the session's connection goes this way. Input other than the wheel ends the selection
    /// of the terminal it goes to, a pane's or the popup's, as Herdr's client ends its own on a key, text or a
    /// paste, whatever sends it.
    private func ask(
        input events: [HerdrInputEvent],
        to target: HerdrTerminalTarget,
        on attempt: Attempt,
        delivered: CheckedContinuation<Bool, Never>?
    ) {
        if events.contains(where: { if case .mouse = $0 { false } else { true } }) {
            managedSurface(of: target)?.endSelection()
        }
        attempt.ask(.input(target, events: events, delivered: delivered))
    }

    private func managedSurface(of target: HerdrTerminalTarget) -> GhosttyManagedSurface? {
        switch target {
        case .pane(let paneID):
            return surfaces[paneID]?.renderer.managedSurface
        case .popup(let terminalID):
            guard let surface = popup.surface, surface.terminalID == terminalID else { return nil }
            return surface.renderer.managedSurface
        }
    }

    /// Remux's move to `destination`: a view request the engine starts when it goes (`.move`); the newest
    /// wins, and as in Herdr's client, a move while a show is in progress takes that show over. It goes
    /// with the command Herdr's client sends for the place or creation. Herdr's zoom is a flag on a tab,
    /// which shows its focused pane, so a move within the tab on screen is a `pane.focus`, as Herdr's
    /// client sends on a click. A move to another tab changes the tab: the tab left keeps its zoom, Remux's
    /// included; the setting zooms the tab reached unless it is zoomed already; and a pane's `pane.focus`
    /// marks the tab's agents seen. The engine holds the frames meanwhile, so only the tab reached shows, as
    /// it ends up. A tab another client moves the session to stays as it is.
    ///
    /// The user is in the move's pane from this moment (`userPaneID`), so keys typed right after a tap go
    /// to the pane tapped.
    private func move(_ attempt: Attempt, to destination: HerdrDestination) {
        var fromAnotherTab = false
        var pane: String?
        var goesTo: (tabID: String?, name: String)?
        switch destination {
        case .place(let place):
            let reached = tab(reachedBy: place)
            fromAnotherTab = reached.map { $0 != herdrTab } == true
            if case .pane(let id) = place { pane = id }
            goesTo = reached.map { ($0.tabID, tabName(ofTab: $0.tabID) ?? $0.tabID) }
        case .creation(.tab):
            goesTo = (nil, Self.newTabName)
        case .creation(.workspace):
            goesTo = (nil, Self.newWorkspaceName)
        case .creation(let split):
            goesTo = split.tabPlace.flatMap(tab(reachedBy:)).map { ($0.tabID, tabName(ofTab: $0.tabID) ?? $0.tabID) }
        case .closing:
            break
        }
        attempt.moveAsks += 1
        attempt.move = PendingMove(ask: attempt.moveAsks, pane: pane, goesTo: goesTo)
        attempt.ask(.move(destination, fromAnotherTab: fromAnotherTab, ask: attempt.moveAsks))
        reconcilePresentationActivity()
        didChange()
    }

    /// The engine took move `ask`: `request` carries it, or nothing does, as when Herdr has the session
    /// there already. A newer move has replaced it if the attempt's isn't this one. The engine's updates
    /// come on their own, so the request may already have completed, as one to a pane gone by then does at
    /// once, or a later one replaced it.
    private func moveTaken(_ ask: UInt64, by request: UInt64?, on attempt: Attempt) {
        guard attempt.move?.ask == ask else { return }
        guard let request, attempt.activatedRequest.map({ $0 < request }) ?? true,
              attempt.request.map({ $0.id <= request }) ?? true
        else { return moveEnded(on: attempt) }
        attempt.move?.request = request
    }

    /// Remux's move ended, as Herdr showed where it went, another client took the session elsewhere, its
    /// pane closed, its focus failed, or a later request replaced it: the user is in the pane Herdr has
    /// focused from here on.
    private func moveEnded(on attempt: Attempt) {
        guard attempt.move != nil else { return }
        attempt.move = nil
        reconcilePresentationActivity()
        // A frame held while the move went elsewhere is the newest Herdr sent, as when the move was refused.
        showPreparedFrameIfReady()
        didChange()
    }

    /// Which tabs the setting zooms as the session comes to them.
    private var zoomPolicy: HerdrZoomPolicy {
        HerdrZoomPolicy(
            zoomsMultipaneTabs: currentTerminalSettings.zoomMultipaneWindowsByDefault,
            unzoomedByUser: tabsUnzoomedByUser
        )
    }

    /// The tab Herdr has the session on, as the newest snapshot has it. While a newer frame waits off screen,
    /// the screen still shows the tab before it (`layout`).
    private var herdrTab: HerdrTabKey? {
        guard let snapshot, let tabID = snapshot.focusedTabID else { return nil }
        return HerdrTabKey(bootID: snapshot.bootID, tabID: tabID)
    }

    /// The tab a move to `place` shows.
    private func tab(reachedBy place: HerdrPlace) -> HerdrTabKey? {
        guard let snapshot, let tabID = snapshot.tabID(reachedBy: place) else { return nil }
        return HerdrTabKey(bootID: snapshot.bootID, tabID: tabID)
    }

    /// The current request's focus or creation was answered, in the engine's order.
    private func answered(_ step: HerdrCommandLane.Step, failure: HerdrCommandError?) {
        let label: String
        switch step {
        case .focus(let place): label = place.focusFailureLabel
        case .create(let creation): label = creation.failureLabel
        case .close(let place, let group): return changeAnswered(.close(place, group: group), failure: failure)
        case .zoom, .zoomReached: return
        }
        if let failure {
            presentFailure(of: step.method, label: label, failure)
        } else {
            notices.succeeded(step.method, bootID: layout?.bootID)
        }
    }

    /// A command's failure as Herdr's notice rules read it.
    private nonisolated static func commandError(_ failure: Error) -> HerdrCommandError {
        failure as? HerdrCommandError ?? .failed(code: "invalid_response", message: failure.localizedDescription)
    }

    private func presentFailure(of method: String, label: String, _ failure: Error) {
        let error = Self.commandError(failure)
        if notices.shows(method, failedWith: error, bootID: layout?.bootID) {
            terminalScreenAdapter.presentFailure(label)
        }
    }

    // MARK: - Zoom

    /// The pane sheet's zoom button: Herdr zooms or unzooms the focused pane's tab, through the engine's
    /// lane after the commands already asked for. Every `pane.zoom` focuses its target first, so it goes
    /// only while no request is in progress, on the pane the session is on, as the engine checks when it
    /// goes, and only while the screen shows that pane (`showsHerdrsFocus`): the sheet describes the tab on
    /// screen, so the button is refused, as keys are, while the screen still shows the tab before Herdr's.
    /// A tab the user unzooms isn't zoomed again as the session comes back on screen, as tmux keeps a user's
    /// choice for a window. Returns false when the session can't take it.
    func setFocusedPaneZoomed(_ zoomed: Bool) -> Bool {
        guard let attempt, isCurrent(attempt), attempt.isSettled, showsHerdrsFocus,
              let paneID = focusedPaneID, let tab = herdrTab
        else { return false }
        if zoomed {
            tabsUnzoomedByUser.remove(tab)
        } else {
            tabsUnzoomedByUser.insert(tab)
        }
        attempt.ask(.zoom(paneID, zoomed: zoomed))
        return true
    }

    /// The pane sheet is opening. A zoomed tab's map places the panes its frame doesn't draw from the
    /// newest full layout Herdr reported, and a tab zoomed before Remux saw it, as by another client
    /// while the setting is off, has none. Herdr's endpoint has no layout query, so Remux asks for the
    /// zoom the tab already has: Herdr changes nothing and answers with the tab's full layout, which
    /// fills the map as any zoom's answer does. It asks once for each set of missing panes, through the
    /// engine's lane, which lets it go only while no request is in progress, since the zoom focuses its
    /// pane; one that doesn't go is asked again at the next opening.
    func fillTabMapIfNeeded() {
        guard let attempt, isCurrent(attempt), attempt.isSettled, showsHerdrsFocus,
              let layout, let tab = layout.tab, tab.zoomed, let snapshot, snapshot.bootID == layout.bootID,
              snapshot.focusedTabID == tab.tabID, let paneID = snapshot.focusedPaneID
        else { return }
        let gap = HerdrTabMapGap(
            tab: HerdrTabKey(bootID: layout.bootID, tabID: tab.tabID),
            paneIDs: Set(layout.panes.lazy.map(\.paneID).filter { self.mapRect(ofPane: $0) == nil })
        )
        guard !gap.paneIDs.isEmpty, gap != askedTabMapGap else { return }
        askedTabMapGap = gap
        attempt.ask(.askLayout(paneID))
    }

    /// Herdr answered a zoom Remux sent: the zoom button's outcome is reported, and any zoom's layout fills
    /// the tab's map. One that didn't go, as the pane sheet's question while a request was in progress, is
    /// asked again at the next opening. An answer that comes after the stop changes nothing.
    private func zoomAnswered(
        _ zoom: HerdrPaneZoomResult?,
        bootID: String,
        failure: HerdrCommandError?,
        reportsFailure: Bool
    ) {
        guard !stopped else { return }
        if let failure {
            if reportsFailure {
                presentFailure(of: Self.paneZoomMethod, label: Self.zoomFailureLabel, failure)
            } else if failure == .notSent {
                askedTabMapGap = nil
            }
            return
        }
        guard let zoom else { return }
        if reportsFailure { notices.succeeded(Self.paneZoomMethod, bootID: bootID) }
        tabMap = HerdrTabMap(
            bootID: bootID,
            tabID: zoom.layout.tabID,
            rects: Dictionary(zoom.layout.panes.map { ($0.paneID, $0.rect) }) { first, _ in first }
        )
        didChange()
    }

    /// Where `paneID` sits in the tab on screen, for the pane sheet's map: from the newest full layout of
    /// the tab Herdr reported.
    func mapRect(ofPane paneID: String) -> HerdrSurfaceRect? {
        guard let layout, let tab = layout.tab, let tabMap, tabMap.bootID == layout.bootID, tabMap.tabID == tab.tabID
        else { return nil }
        return tabMap.rects[paneID]
    }

    nonisolated static func zoomParams(_ paneID: String, zoomed: Bool) -> [String: String] {
        ["pane_id": paneID, "mode": zoomed ? "on" : "off"]
    }

    // MARK: - Scrolling

    /// History lines per wheel step, as Herdr's client sends by default. A program that reads the mouse,
    /// or takes the wheel as arrow keys, gets one report or key per step instead.
    static let wheelLines: UInt16 = 3

    /// A scroll gesture's travel over a pane becomes Herdr wheel steps the way Ghostty turns travel into
    /// lines for tmux: one step per cell height, the rest kept for the next. Herdr decides what a step
    /// does: it scrolls the pane's history, or goes to the program as a wheel report or an arrow key. As
    /// in Herdr's client, scrolling another pane focuses it. The wheel goes where any input goes
    /// (`inputTarget(forPane:)`), placed in the pane's drawn area.
    func scroll(_ event: GhosttySurfaceMouseScrollEvent, inPane paneID: String) -> Bool {
        let momentum = event.mods.momentum
        // A cancelled gesture, as when the program's mouse mode changes, sends none of its travel.
        guard momentum != .cancelled else {
            wheelRemainders[paneID] = nil
            return true
        }
        if momentum == .began { wheelRemainders[paneID] = 0 }
        defer {
            if momentum == .ended { wheelRemainders[paneID] = nil }
        }
        guard let target = inputTarget(forPane: paneID), let measurement,
              let cell = paneCell(at: pointers[paneID] ?? .zero, inPane: paneID)
        else { return false }
        if momentum == .began, paneID != userPaneID { _ = focusPane(paneID) }

        let cellHeight = Double(measurement.cellMetrics.pixelHeight)
        let travel = (wheelRemainders[paneID] ?? 0) + event.deltaY
        let steps = (travel / cellHeight).rounded(.towardZero)
        wheelRemainders[paneID] = travel - steps * cellHeight
        guard steps != 0 else { return true }

        let wheel = HerdrMouseEvent(
            kind: steps > 0 ? .scrollUp : .scrollDown,
            column: cell.column,
            row: cell.row,
            lines: Self.wheelLines
        )
        let events = Array(repeating: HerdrInputEvent.mouse(wheel), count: Int(steps.magnitude))
        return send(events, to: target) == .accepted
    }

    private func applyScroll(toPane paneID: String) {
        guard let scroll = paneScrolls[paneID],
              let managed = currentSurface(of: paneID)?.renderer.managedSurface
        else { return }
        managed.setRemoteScroll(scroll.scrollState, route: scroll.route)
    }

    // MARK: - Mouse

    /// A pane's cell, relative to its text area.
    private struct PaneCell: Equatable {
        let column: UInt16
        let row: UInt16
    }

    /// A mouse button held down in a pane or the popup, and the cell last reported with it. One at a time, as
    /// in Herdr's client.
    private struct MouseGesture {
        let target: HerdrTerminalTarget
        let button: HerdrMouseEvent.Button
        var cell: PaneCell
    }

    /// Whether the pane's program reads the mouse, as Herdr's surface says.
    func reportsMouse(inPane paneID: String) -> Bool {
        paneScrolls[paneID]?.mouseReporting == true
    }

    /// The pointer moved over a pane (`motion`). The wheel's steps are reported at this cell too.
    func movePointer(to point: CGPoint, inPane paneID: String, mods: GhosttySurfaceKeyEvent.Mods) {
        let previous = pointers[paneID].flatMap { paneCell(at: $0, inPane: paneID) }
        pointers[paneID] = point
        guard let target = inputTarget(forPane: paneID), let cell = paneCell(at: point, inPane: paneID),
              let kind = motion(to: cell, from: previous, over: .pane(paneID), readsMouse: reportsMouse(inPane: paneID))
        else { return }
        _ = send([mouseEvent(kind, at: cell, mods: mods)], to: target)
    }

    /// What the pointer reaching `cell` over `target` reports, as Herdr's client passes on the host
    /// terminal's motion to a pane or the popup (`client/shell/mouse.rs`): while a button pressed there is
    /// held, a drag each time it reaches another cell; with none held, to a program that reads the mouse, a
    /// move each time it reaches another cell, which Herdr reports only to a program asking for every motion.
    /// Nil when nothing goes.
    private func motion(
        to cell: PaneCell,
        from previous: PaneCell?,
        over target: HerdrTerminalTarget,
        readsMouse: Bool
    ) -> HerdrMouseEvent.Kind? {
        if let gesture = mouseGesture {
            guard gesture.target == target, cell != gesture.cell else { return nil }
            mouseGesture?.cell = cell
            return .drag(gesture.button)
        }
        return readsMouse && cell != previous ? .moved : nil
    }

    /// A button pressed or released at the pointer, as Herdr's client sends one to a pane: a press goes
    /// only to a program that reads the mouse, and a right press only to a pane set to take right-clicks
    /// (`pane.input.set`) with no modifier held, since Herdr's own menu takes them otherwise. Until its
    /// release, which goes where the press went (`releaseHeldButton`), the press takes the pointer's moves and
    /// no other press goes.
    /// The tap that makes the press focuses the pane, as a tap does on any pane. Returns false when the
    /// event doesn't go.
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent, inPane paneID: String) -> Bool {
        guard let button = HerdrInputTranslator.mouseButton(event.button) else { return false }
        switch event.state {
        case .press:
            guard mouseGesture == nil, let target = inputTarget(forPane: paneID), reportsMouse(inPane: paneID),
                  button != .right || takesRightClick(inPane: paneID, mods: event.mods),
                  let cell = pointers[paneID].flatMap({ paneCell(at: $0, inPane: paneID) }),
                  send([mouseEvent(.down(button), at: cell, mods: event.mods)], to: target) == .accepted
            else { return false }
            mouseGesture = MouseGesture(target: .pane(paneID), button: button, cell: cell)
            return true
        case .release:
            return releaseHeldButton(button, mods: event.mods)
        }
    }

    /// The release of the button held, wherever it is reported, goes where its press went. Herdr takes the
    /// release of a press it took whatever tab it shows the phone (`server/headless.rs`
    /// `client_pane_input_releases_press`, `ClientShellPopupInput`), so it goes while the session is shown,
    /// also once a move leaves the pane: the program never keeps the button down.
    private func releaseHeldButton(_ button: HerdrMouseEvent.Button, mods: GhosttySurfaceKeyEvent.Mods) -> Bool {
        guard let gesture = mouseGesture, gesture.button == button else { return false }
        mouseGesture = nil
        switch gesture.target {
        case .pane(let paneID):
            guard let attempt = shownAttempt else { return false }
            let cell = pointers[paneID].flatMap { paneCell(at: $0, inPane: paneID) } ?? gesture.cell
            return send([mouseEvent(.up(button), at: cell, mods: mods)], to: (attempt, paneID)) == .accepted
        case .popup:
            let cell = popupCell(at: popupPointer ?? .zero) ?? gesture.cell
            return popup.sendMouse(.up(button), column: cell.column, row: cell.row, modifiers: HerdrInputTranslator.modifiers(for: mods))
        }
    }

    private func takesRightClick(inPane paneID: String, mods: GhosttySurfaceKeyEvent.Mods) -> Bool {
        HerdrInputTranslator.modifiers(for: mods).isEmpty
            && snapshot?.panes.first { $0.paneID == paneID }?.rightClickPassthrough == true
    }

    private func mouseEvent(
        _ kind: HerdrMouseEvent.Kind,
        at cell: PaneCell,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> HerdrInputEvent {
        .mouse(HerdrMouseEvent(
            kind: kind,
            column: cell.column,
            row: cell.row,
            modifiers: HerdrInputTranslator.modifiers(for: mods)
        ))
    }

    /// The cell at `point`, in the pane's points, within the pane's drawn area. Herdr reports a cell to a
    /// program in SGR pixel mode as the cell's centre pixel.
    private func paneCell(at point: CGPoint, inPane paneID: String) -> PaneCell? {
        guard let measurement, let area = layout?.panes.first(where: { $0.paneID == paneID })?.innerRect
        else { return nil }
        let scale = measurement.cellMetrics.contentScale
        func index(_ points: CGFloat, size: UInt32, count: UInt16) -> UInt16 {
            let index = Int((Double(points) * scale / Double(max(size, 1))).rounded(.down))
            return UInt16(min(max(index, 0), Int(max(count, 1)) - 1))
        }
        return PaneCell(
            column: index(point.x, size: measurement.cellMetrics.pixelWidth, count: area.width),
            row: index(point.y, size: measurement.cellMetrics.pixelHeight, count: area.height)
        )
    }

    // MARK: - Selection

    /// The text of a selection in `paneID`, read by Herdr, which keeps the pane's history and joins its
    /// wrapped lines. The read waits in line behind the commands asked before it and for Herdr's answer as
    /// long as Herdr's client waits for a command. Explicit Copy reports a failed read; optional menu
    /// inspection returns nil without changing notices.
    func readSelection(
        _ selection: GhosttyHistorySelection, inPane paneID: String, reportResult: Bool = true
    ) async -> String? {
        guard let attempt = shownAttempt else {
            if reportResult {
                notices.replaced()
                terminalScreenAdapter.presentFailure(Self.copyFailureLabel)
            }
            return nil
        }
        do {
            let reply = try await command(
                Self.paneSelectionReadMethod,
                params: HerdrSelectionRead(paneID: paneID, selection: selection),
                on: attempt
            ).get()
            let text = try HerdrSelectionRead.text(fromReply: reply.json)
            if reportResult { notices.succeeded(Self.paneSelectionReadMethod, bootID: layout?.bootID) }
            return text
        } catch {
            if reportResult, isCurrent(attempt) {
                presentFailure(of: Self.paneSelectionReadMethod, label: Self.copyFailureLabel, error)
            }
            return nil
        }
    }

    /// A plain-text link's visible regions and completeness at `cell`, a history cell of `paneID`, which
    /// Herdr finds across the pane's wrapped rows; nil when absent. It is asked about the frame on screen,
    /// and its regions, rows of that frame's viewport, come back as history rows. The answer holds only
    /// while the terminal still shows that frame: as Herdr's client does, one found in content or a viewport
    /// that has changed since is dropped. As for Herdr's client the question is optional, so a failure says
    /// nothing.
    func resolveLink(at cell: GhosttyTerminalCell, inPane paneID: String) async -> HerdrResolvedLink? {
        guard let attempt = shownAttempt,
              let content = await engine.content(ofPane: paneID),
              let request = HerdrLinkResolve(paneID: paneID, cell: cell, content: content),
              let reply = try? await command(Self.paneLinkResolveMethod, params: request, on: attempt).get(),
              await engine.content(ofPane: paneID) == content
        else { return nil }
        return try? request.link(fromReply: reply.json)
    }

    /// `method` through the engine's lane, after the operations asked before it: it waits in line behind
    /// them, and behind the steps of the view request in progress, then for Herdr's answer as long as
    /// Herdr's client waits for a command.
    private func command(
        _ method: String,
        params: some Encodable & Sendable,
        on attempt: Attempt
    ) async -> Result<HerdrCommandReply, HerdrCommandError> {
        await withCheckedContinuation { answered in
            attempt.ask(.command(method, params: params, answered: answered))
        }
    }

    /// Herdr's client ends a pane's selection when the pane's width changes, since Herdr rewraps its lines
    /// and their rows move, and when its program switches screens. A change of height keeps the rows, and
    /// on the phone the keyboard makes one, so the selection stays.
    private func endSelections(movedBy layout: HerdrPaneLayout) {
        for pane in layout.panes {
            guard let width = pane.innerRect?.width,
                  let previous = self.layout?.panes.first(where: { $0.paneID == pane.paneID })?.innerRect?.width,
                  width != previous
            else { continue }
            surfaces[pane.paneID]?.renderer.managedSurface?.endSelection()
        }
    }

    private func endSelections(movedBy scrolls: [String: HerdrPaneScroll]) {
        for (paneID, scroll) in scrolls {
            guard let previous = paneScrolls[paneID], previous.alternateScreenActive != scroll.alternateScreenActive
            else { continue }
            surfaces[paneID]?.renderer.managedSurface?.endSelection()
        }
    }

    private func inputFailed(_ attemptID: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        presentInputFailure()
    }

    /// A failure Remux finds itself, which Herdr's rules don't hold back. It replaces any notice on
    /// screen, as Herdr's client keeps one.
    private func presentInputFailure() {
        notices.replaced()
        terminalScreenAdapter.presentFailure(Self.inputFailureLabel)
    }

    /// Herdr refused input, with its reason; the same refusal isn't repeated while it is on screen.
    private func inputRefused(_ attemptID: UInt64, message: String) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt),
              notices.showsRefusedInput(message, bootID: layout?.bootID)
        else { return }
        terminalScreenAdapter.presentFailure(Self.inputFailureLabel)
    }

    private func keyboardReportAllChanged(_ attemptID: UInt64, _ enabled: Bool) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        attempt.reportsAllKeys = enabled
    }

    // MARK: - Connection

    /// Gives up the current attempt, if any, and starts a new one: the session's first connection, a
    /// reconnect the user asks for, and a reconnect by itself, when its delay is up or the app comes back.
    /// The panes keep their terminals, so the last frame stays on screen until the new connection's
    /// first; pane failures say to reconnect, so the failed panes are tried again. A recheck keeps saying
    /// what needs attention until it connects.
    private func restart() {
        cancelRecovery()
        if let attempt { giveUp(attempt) }
        attemptCount += 1
        let attempt = Attempt(id: attemptCount)
        self.attempt = attempt
        readySince = nil
        attempt.task = Task { [weak self] in await self?.run(attempt) }
        retryFailedPanes()
        reconcilePresentationActivity()
        didChange()
    }

    /// Once the connection is open, the attempt's operations are carried out in order.
    private func run(_ attempt: Attempt) async {
        let feed = HerdrEngineFeed(engine: engine, connection: attempt.id)
        if zoomClaim == nil {
            let session = HerdrSessionAddress(target)
            zoomClaim = Task { [engine, zoomKeepers] in await engine.keepOwnedZooms(of: session, from: zoomKeepers) }
        }
        await zoomClaim?.value
        guard isCurrent(attempt),
              let size = await connectionAndScreenSize(for: attempt, feed: feed),
              let connection = attempt.connection
        else { return }
        // Frames can arrive before `open` returns; the engine paints them at the hello's cell size.
        await engine.setCellSize(widthPx: size.cellWidthPx, heightPx: size.cellHeightPx)
        await engine.beginConnection(attempt.id, outbox: connection.outbox)
        attempt.helloSent = true
        do {
            try await connection.open(
                hello: HerdrHello(
                    cellWidthPx: size.cellWidthPx,
                    cellHeightPx: size.cellHeightPx,
                    cols: size.cols,
                    rows: size.rows,
                    surfaceActive: false
                ),
                appActive: appPhase != .background
            )
        } catch {
            if isCurrent(attempt) {
                end(attempt, disconnectReason(connectionFailedWith: error), recovery: Self.recovery(connectionFailedWith: error, opened: false))
            }
            return
        }
        guard isCurrent(attempt) else { return }
        await feed.opened(methods: await connection.negotiated?.methods ?? [], commandTimeout: connectionTiming.command)
        guard isCurrent(attempt) else { return }
        attempt.isOpen = true
        if let themeReport { attempt.ask(.theme(themeReport)) }
        reconcileVisibility()
        reconcilePresentationActivity()
        didChange()
        while let operation = await attempt.nextOperation() {
            guard isCurrent(attempt) else {
                operation.abandon()
                break
            }
            await perform(operation, on: connection, feed: feed, attempt: attempt)
        }
    }

    /// The attempt's connection, in `attempt.connection`, and the screen's size for its hello, or nil when
    /// the attempt is over. The bridge opens at once, so its setup overlaps the screen's first layout, and
    /// goes straight to the connection, which the attempt's give-up closes. A connection still waiting for
    /// a size at the hello deadline is closed, and another opens once the size is known.
    private func connectionAndScreenSize(for attempt: Attempt, feed: HerdrEngineFeed) async -> HerdrSurfaceGeometry? {
        while true {
            // Herdr's clock starts when the bridge reaches its socket, which can be before the opening
            // returns.
            let deadline = ContinuousClock.now + Self.helloDeadline
            let transport: any HerdrBridgeTransport
            do {
                transport = try await openBridge(.session)
            } catch {
                // A cancelled opening releases what it claimed.
                if isCurrent(attempt) {
                    let reason = disconnectReason(openingBridgeFailedWith: error)
                    end(attempt, reason, recovery: Self.recovery(openingBridgeFailedWith: error, reason: reason))
                }
                return nil
            }
            // A bridge that opens after the attempt was given up closes the way the give-up decided.
            if let cause = attempt.closeCause {
                await transport.close(cause)
                return nil
            }
            let connection = HerdrConnection(
                transport: transport,
                timing: connectionTiming,
                onEvent: Self.eventHandler(feed: feed, attemptID: attempt.id, model: self)
            )
            attempt.connection = connection
            if let size = await screenSize(for: attempt, until: deadline) { return size }
            guard isCurrent(attempt) else { return nil }
            await connection.close(.finished)
            attempt.connection = nil
            guard await screenSize(for: attempt, until: nil) != nil else { return nil }
        }
    }

    /// Each operation returns once its messages are queued on the connection; Herdr's answer to a show
    /// comes back separately, and the engine says when a frame completing it is painted.
    private func perform(
        _ operation: Operation,
        on connection: HerdrConnection,
        feed: HerdrEngineFeed,
        attempt: Attempt
    ) async {
        let attemptID = attempt.id
        switch operation {
        case .show(let geometry, let destination):
            // The engine sends the show and its steps; its frames are held from here on.
            await feed.start(.shown(geometry, to: destination, zoom: zoomPolicy), within: connectionTiming.activation)
        case .hide:
            // Frames from here on show what leaving does, so the engine holds them before anything goes out.
            await feed.start(.hidden, within: connectionTiming.activation)
        case .resize(let geometry):
            await feed.resize(columns: geometry.cols, rows: geometry.rows)
            await connection.resize(geometry)
            await engine.setCellSize(widthPx: geometry.cellWidthPx, heightPx: geometry.cellHeightPx)
        case .theme(let updates):
            for update in updates {
                await connection.reportHostTheme(update)
            }
        case .appActive(let active):
            await connection.setAppActive(active)
        case .input(let target, let events, let delivered):
            switch await feed.send(events, to: target) {
            case .sent:
                guard let delivered else { return }
                // Herdr acknowledges no input, but answers a ping only after reading everything sent before
                // it. Later operations don't wait for the answer.
                Task { delivered.resume(returning: await connection.confirmAlive()) }
            case .notTaken, .ended:
                // Keys Herdr wouldn't take are dropped, as Herdr drops them; the composer says what didn't
                // go. The connection's end is reported when the reader sees it.
                delivered?.resume(returning: false)
            case .inactive:
                if let delivered { delivered.resume(returning: false) } else { inputFailed(attemptID) }
            }
        case .move(let destination, let fromAnotherTab, let ask):
            guard let geometry else { return moveTaken(ask, by: nil, on: attempt) }
            let request = await feed.start(
                .moved(destination, fromAnotherTab: fromAnotherTab, columns: geometry.cols, rows: geometry.rows, zoom: zoomPolicy),
                within: connectionTiming.activation
            )
            moveTaken(ask, by: request, on: attempt)
        case .zoom(let paneID, let zoomed):
            await feed.setZoom(zoomed, ofPane: paneID)
        case .askLayout(let paneID):
            await feed.askLayout(ofPane: paneID)
        case .command(let method, let params, let answered):
            await feed.command(method, params: params) { answered.resume(returning: $0) }
        }
    }

    /// Frames and snapshots go to the engine from the connection's reader; only what the model acts on
    /// comes to the main actor, and nothing here waits for a reply from the connection.
    private static func eventHandler(
        feed: HerdrEngineFeed,
        attemptID: UInt64,
        model: HerdrScreenModel
    ) -> @Sendable (HerdrConnectionEvent) async -> Void {
        { [weak model] event in
            guard let model else { return }
            switch event {
            case .snapshot(let snapshot, let completions):
                await feed.receive(snapshot)
                Task { @MainActor in model.snapshotArrived(attemptID, snapshot, completions: completions) }
            case .surface(let output):
                await feed.receive(output)
            case .ended(let error):
                await model.connectionEnded(attemptID, error)
                // Also after a stop, which takes no more of the attempt's events.
                await feed.ended()
            case .inputRefused(let message):
                Task { @MainActor in model.inputRefused(attemptID, message: message) }
            case .keyboardReportAll(let enabled):
                Task { @MainActor in model.keyboardReportAllChanged(attemptID, enabled) }
            case .response(let chunk):
                await feed.receive(chunk)
            case .notification(let notification):
                Task { @MainActor in model.notificationArrived(attemptID, notification) }
            case .bell:
                Task { @MainActor in model.bellRang(attemptID) }
            case .clipboard(let base64):
                Task { @MainActor in model.clipboardWritten(attemptID, base64: base64) }
            }
        }
    }

    /// Whether `attempt` is the model's and still under way: an ended one's late events and a bridge
    /// that opens after it ended are dropped.
    private func isCurrent(_ attempt: Attempt) -> Bool {
        !stopped && self.attempt === attempt && !attempt.ended
    }

    private var geometry: HerdrSurfaceGeometry? {
        guard let measurement else { return nil }
        return HerdrSurfaceGeometry(
            cellWidthPx: measurement.cellMetrics.pixelWidth,
            cellHeightPx: measurement.cellMetrics.pixelHeight,
            cols: measurement.controlViewport.columns,
            rows: measurement.controlViewport.rows
        )
    }

    /// The screen's size once it has one, or nil when the attempt is over or `deadline` passed before
    /// the screen first had a size. A size known only after the deadline is too late even if it's known
    /// before the bridge's opening returns: Herdr's clock may already have run out.
    private func screenSize(
        for attempt: Attempt,
        until deadline: ContinuousClock.Instant?
    ) async -> HerdrSurfaceGeometry? {
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                // A wait that ended first cancelled its timer, which then wakes no later wait.
                guard !Task.isCancelled else { return }
                self?.resumeSizeWaiter()
            }
        }
        defer { timer?.cancel() }
        while isCurrent(attempt) {
            if let geometry, let sizeKnownSince, deadline.map({ sizeKnownSince <= $0 }) ?? true {
                return geometry
            }
            if let deadline, ContinuousClock.now >= deadline { return nil }
            await withCheckedContinuation { sizeWaiter = $0 }
        }
        return nil
    }

    private func resumeSizeWaiter() {
        sizeWaiter?.resume()
        sizeWaiter = nil
    }

    private func snapshotArrived(_ attemptID: UInt64, _ snapshot: HerdrSnapshot, completions: [String: UInt64]?) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        if appPhase != .background, readySince == nil { readySince = .now }
        if let previous = self.snapshot?.bootID, previous != snapshot.bootID {
            onNotification(.serverRestarted)
        }
        let rows = terminalScreenAdapter.tabRowContents
        let panes = self.snapshot?.panes
        self.snapshot = snapshot
        if agents.project(snapshot, completions: completions) { didChange() }
        acknowledgeShownAgents()
        // The sheets and the toolbar list the session's tabs.
        if places.update(with: snapshot) { didChange() }
        if snapshot.focusedPaneID != focusedPaneID {
            focusedPaneID = snapshot.focusedPaneID
            reconcilePresentationActivity()
            didChange()
        }
        // Rows and pane tiles read metadata on demand. A rename of an unfocused pane still updates its tile.
        if terminalScreenAdapter.tabRowContents != rows || snapshot.panes != panes { didChange() }
        guard !attempt.hasSnapshot else { return }
        attempt.hasSnapshot = true
        hasConnected = true
        failure = nil
        reconcileVisibility()
        didChange()
    }

    /// Herdr sends its notifications to every connection, shown or hidden; the owner decides what
    /// reaches the screen. The boot is known once this connection's first snapshot is in.
    private func notificationArrived(_ attemptID: UInt64, _ notification: HerdrSemanticNotification) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt) else { return }
        let snapshot = attempt.hasSnapshot ? self.snapshot : nil
        onNotification(.received(
            notification,
            bootID: snapshot?.bootID,
            place: HerdrNotificationPlace(notification, in: snapshot)
        ))
    }

    /// Herdr rings only the session in front, which the connection checks; a bell that comes after the
    /// session left the screen has no one to ring for.
    private func bellRang(_ attemptID: UInt64) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt), isOnScreen else { return }
        onNotification(.bell)
    }

    /// A program in the session on screen wrote the clipboard (OSC 52); a write that comes after the session
    /// left the screen has no one to write for. As in Herdr's client, a payload that isn't base64 is
    /// dropped, and the copy notice shows only after a write that wasn't a duplicate
    /// (`client/clipboard_forwarding.rs`, `selection.rs` `write_osc52_bytes`). The iPhone clipboard holds
    /// text, so bytes that aren't UTF-8 are dropped too.
    private func clipboardWritten(_ attemptID: UInt64, base64: String) {
        guard let attempt, attempt.id == attemptID, isCurrent(attempt), isOnScreen,
              let bytes = Data(base64Encoded: base64), let text = String(data: bytes, encoding: .utf8),
              clipboard.write(text)
        else { return }
        notices.replaced()
        terminalScreenAdapter.presentInformation(Self.copiedNotice, for: Self.copiedNoticeDuration)
    }

    /// The panes on screen show their agents as they are now, as Herdr's client counts a pane it
    /// presents while its terminal has focus as seen (`endpoint_agent_state.rs` `acknowledge_surface`):
    /// only a frame drawn against the newest snapshot shows its agents, so an older frame still on screen
    /// acknowledges nothing.
    private func acknowledgeShownAgents() {
        guard appPhase == .active, let attempt = shownAttempt, let frame = presentedFrame,
              frame.connection == attempt.id, let snapshot,
              frame.bootID == snapshot.bootID, frame.projectionRevision == snapshot.revision
        else { return }
        if agents.acknowledge(panes: frame.paneIDs) { didChange() }
    }

    private func connectionEnded(_ attemptID: UInt64, _ error: HerdrConnectionError) {
        guard let attempt, attempt.id == attemptID else { return }
        end(attempt, error.terminalDisconnectReason(on: target.server), recovery: Self.recovery(connectionFailedWith: error, opened: true))
    }

    /// Ends the attempt and reports why. A connection Remux closes sends no `ended` event, so whoever
    /// finds the reason reports it here. `unresponsive` when Herdr didn't answer in time.
    private func end(
        _ attempt: Attempt,
        _ reason: TerminalDisconnectReason,
        recovery: Recovery,
        unresponsive: Bool = false
    ) {
        guard isCurrent(attempt) else { return }
        giveUp(attempt, unresponsive: unresponsive)
        let stayedUp = readySince.map { ContinuousClock.now - $0 >= recoveryTiming.stable } ?? false
        readySince = nil
        // A session that never opened says why instead of retrying.
        switch hasConnected ? recovery : .none {
        case .retry:
            failure = nil
            isReconnecting = true
            // A connection that stayed up starts the delays over, as in Herdr's client.
            if stayedUp { failuresInARow = 0 }
            failuresInARow += 1
            scheduleRecovery(after: retryDelay())
        case .recheck:
            failure = reason
            isReconnecting = false
            scheduleRecovery(after: recoveryTiming.recheck)
        case .none:
            failure = reason
            isReconnecting = false
            cancelRecovery()
        }
        // A frame held while the attempt's move went elsewhere is the newest Herdr sent.
        showPreparedFrameIfReady()
        reconcilePresentationActivity()
        didChange()
    }

    /// 0.5 s after the first failure, doubling with each one in a row up to 2 min, and at most the wake
    /// delay for a while after the app comes back.
    private func retryDelay() -> Duration {
        var delay = recoveryTiming.firstRetry
        for _ in 1..<max(failuresInARow, 1) {
            delay = min(delay * 2, recoveryTiming.longestRetry)
        }
        if let wokeAt, ContinuousClock.now < wokeAt + recoveryTiming.wakeWindow {
            delay = min(delay, recoveryTiming.wakeRetry)
        }
        return delay
    }

    private func scheduleRecovery(after delay: Duration) {
        recoveryDue = .now + delay
        startRecoveryTimer()
    }

    /// The background stops the timer; the due time stays for the return.
    private func startRecoveryTimer() {
        recoveryTimer?.cancel()
        guard appPhase != .background, let due = recoveryDue else { return }
        recoveryTimer = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    private func cancelRecovery() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        recoveryDue = nil
    }

    /// Gives the attempt up, once, whatever ends it: a failure, a replacement, the background or a stop.
    /// Its operations end, its opening stops, the engine drops what its connection still sends, and the
    /// connection closes, telling the bridge whether Herdr went silent or the path is in doubt: the
    /// attempt was waiting for its welcome, or the app is going to the background, where its SSH
    /// connection may not survive. A bridge that opens afterwards closes the same way; one given up
    /// otherwise before anything was written to it opened fine, so its SSH connection can carry the next
    /// opening.
    private func giveUp(_ attempt: Attempt, unresponsive: Bool = false, suspending: Bool = false) {
        guard !attempt.ended else { return }
        let cause: HerdrBridgeCloseCause = unresponsive ? .unresponsive
            : attempt.isOpen ? .finished
            : suspending || attempt.helloSent ? .givenUpWhileOpening : .finished
        attempt.closeCause = cause
        attempt.finishOperations()
        attempt.task?.cancel()
        if attempt === self.attempt { resumeSizeWaiter() }
        Task { [engine, id = attempt.id] in await engine.endConnection(id) }
        if let connection = attempt.connection {
            attempt.closing = Task { await connection.close(cause) }
        }
    }

    /// The root wants the session on screen, and the app isn't in the background, which hides it.
    private var isOnScreen: Bool {
        isSelected && appPhase != .background
    }

    /// Shows the session while it is on screen (`isOnScreen`) and hides it otherwise. Herdr takes the
    /// newest of a show and a hide, so each change is sent at once, even while the last is unanswered.
    /// A place or creation asked for goes right after the show, as part of it.
    private func reconcileVisibility() {
        guard let attempt, isCurrent(attempt), attempt.isOpen, attempt.hasSnapshot, let geometry
        else { return }
        let wanted = isOnScreen
        guard wanted != attempt.wantsShown else { return }
        attempt.wantsShown = wanted
        attempt.visibilityPending = true
        attempt.ask(wanted ? .show(geometry, to: takePendingReveal()) : .hide)
        // Input is offered only once a show completes, and closes as soon as a hide is asked.
        didChange()
    }

    /// The engine's view requests, in its order: the screen reads the newest one started and the newest
    /// one completed.
    private func viewRequestUpdated(_ update: HerdrEngineUpdate) {
        switch update {
        case .started(let request, let kind, let showing, let connection):
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            attempt.request = (request, kind, showing)
            if kind != .move, (kind == .show) == attempt.wantsShown { attempt.visibilityPending = false }
            // A later request replaced the one carrying Remux's move.
            if let moving = attempt.move?.request, request > moving { moveEnded(on: attempt) }
        case .activated(let request, let connection):
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            attempt.activatedRequest = request
            // The engine completes a move once Herdr shows where it went, or where Herdr has the session
            // since it was overtaken, its pane closed or its focus failed.
            if attempt.move?.request == request { moveEnded(on: attempt) }
            acknowledgeShownAgents()
        case .answered(let request, let step, let failure, let made, let connection):
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            if let made, attempt.move?.request == request { attempt.move?.made = made }
            answered(step, failure: failure)
        case .zoomAnswered(let zoom, let bootID, let failure, let reportsFailure, let connection):
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            zoomAnswered(zoom, bootID: bootID, failure: failure, reportsFailure: reportsFailure)
        case .showRefused(_, let reason, let connection):
            // Herdr's client rolls a refused show back and stays on what it showed before; a Remux session
            // screen has nothing else to show, so the connection ends, which takes the session off Herdr's
            // screen, and the session reconnects. A show Herdr doesn't answer runs out of its time instead.
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            end(attempt, TerminalDisconnectReason(kind: .runtime, message: reason), recovery: .retry)
        case .timedOut(_, let connection):
            // Herdr's answers and a frame showing them must all be in within the request's time, as in
            // Herdr's client (`activation.rs`); a request that doesn't complete is rolled back like a show
            // Herdr refused.
            guard let attempt, attempt.id == connection, isCurrent(attempt) else { return }
            end(attempt, Self.activationTimeout, recovery: .retry, unresponsive: true)
        default:
            break
        }
    }

    /// Herdr stores a client's theme and uses it whenever that client is in front, so one full report
    /// before the first show, and one after each theme change, keeps the server on the phone's theme.
    /// Being full, each report also replaces an appearance Herdr would otherwise keep over the next
    /// background. Without a report Herdr uses another client's colours; nothing else is lost.
    private var themeReport: [HerdrHostThemeUpdate]? {
        guard let terminalColors else { return nil }
        return Self.hostTheme(terminalColors, appearance: currentTerminalSettings.theme.isLight ? .light : .dark)
    }

    /// As Herdr's client reports its terminal: the appearance, then the colours.
    static func hostTheme(
        _ colors: GhosttyTerminalColors,
        appearance: HerdrHostThemeUpdate.Appearance
    ) -> [HerdrHostThemeUpdate] {
        func rgb(_ color: GhosttyTerminalColors.Color) -> HerdrRGB {
            HerdrRGB(red: color.red, green: color.green, blue: color.blue)
        }
        var palette: [UInt8: HerdrRGB] = [:]
        for (index, color) in colors.palette.prefix(256).enumerated() {
            palette[UInt8(index)] = rgb(color)
        }
        return [
            .appearance(appearance),
            .defaultColor(.foreground, rgb(colors.foreground)),
            .defaultColor(.background, rgb(colors.background)),
            .paletteColors(palette),
        ]
    }

    // MARK: - Panes

    private func handle(_ update: HerdrEngineUpdate) {
        guard !stopped else { return }
        switch update {
        case .paneTerminal(let paneID, let terminal):
            terminals[paneID] = terminal
            presentationFailures.removeValue(forKey: paneID)
            // The frame that lists the pane follows, and decides where its renderer goes.
            return
        case .drawn(let layout, let projectionRevision, let connection):
            guard receive(DrawnFrame(layout: layout, projectionRevision: projectionRevision, connection: connection))
            else { return }
        case .paneScroll(let scrolls):
            endSelections(movedBy: scrolls)
            paneScrolls = scrolls
            for paneID in Set(surfaces.keys).union(stagedSurfaces.keys) {
                applyScroll(toPane: paneID)
            }
            // Only the panes' scroll views follow it; the screen has nothing new to show.
            return
        case .paneTerminalFailed(let paneID):
            presentationFailures[paneID] = Self.paneFailure
            currentSurface(of: paneID)?.renderer.failPresentation(message: Self.paneFailure.message)
            showPreparedFrameIfReady()
        case .rendererWakeFailed(let paneID):
            currentSurface(of: paneID)?.renderer.failPresentation(message: Self.rendererFailureMessage)
        case .popupTerminal(let terminalID, let terminal):
            popup.takeFrameTerminal(terminal, terminalID: terminalID)
        case .popupTerminalFailed(let terminalID):
            popup.frameTerminalFailed(terminalID: terminalID)
        case .popupRendererWakeFailed(let terminalID):
            popup.rendererWakeFailed(terminalID: terminalID)
        case .failed(let error, let connection):
            if let attempt, attempt.id == connection {
                end(attempt, error.terminalDisconnectReason(on: target.server), recovery: Self.recovery(connectionFailedWith: error, opened: true))
            }
        case .started, .activated, .timedOut, .answered, .zoomAnswered, .showRefused:
            viewRequestUpdated(update)
        }
        didChange()
    }

    /// A frame the engine drew: shown at once, or held off screen while its panes draw their first pictures
    /// (`holdsScreen(for:)`). Returns whether the screen has anything new to show: a frame that changes only
    /// the snapshot it was drawn against changes only what counts as seen.
    private func receive(_ frame: DrawnFrame) -> Bool {
        let shown = frame.layout.textPaneIDs
        terminals = terminals.filter { shown.contains($0.key) }
        if pendingFrame == nil, frame.layout == layout, !shown.contains(where: lacksRenderer) {
            presentedFrame = frame.presented
            acknowledgeShownAgents()
            return false
        }
        if holdsScreen(for: frame.layout) {
            pendingFrame = frame
            stage()
            showPreparedFrameIfReady()
        } else {
            let discarded = stagedSurfaces.values
            stagedSurfaces.removeAll()
            show(frame)
            for surface in discarded { close(surface.renderer) }
        }
        return true
    }

    /// Whether Herdr drew the frame at the grid the screen asks for now. Herdr's client presents a pending
    /// surface only at the current geometry, checking each surface as it arrives and again before it presents
    /// (`endpoint/activation.rs` `receive_surface`, `activation/model.rs` `coherent_surface`). A frame at
    /// another grid waits: Herdr answers each resize of the phone's surface with a whole frame at the new
    /// size, also for a tab another client sizes or where nothing runs, since the resize has Herdr repaint the
    /// phone's surface from scratch and its next render sends that surface in full (`server/headless.rs`
    /// `ClientShellResize`, `clients.rs` `request_repaint`, `headless/render.rs` `render_and_stream`). Unlike
    /// Herdr's client, which drops the surface it holds on a resize, the frame is kept: after a resize away
    /// and back, Herdr's repaint at the grid asked for again can be the very frame held, which the engine
    /// passes on only once.
    private func isDrawnAtScreenGrid(_ layout: HerdrPaneLayout) -> Bool {
        guard let geometry else { return true }
        return layout.columns == max(geometry.cols, 1) && layout.rows == max(geometry.rows, 1)
    }

    /// Whether Remux's move under way goes to another tab than `frame`'s, or to one Herdr hasn't made yet, or
    /// wherever a close takes the session.
    private func isPassedOver(_ frame: DrawnFrame) -> Bool {
        guard let attempt, isCurrent(attempt), let move = attempt.move else { return false }
        guard let tabID = move.goesTo?.tabID else { return true }
        return tabID != frame.layout.tab?.tabID
    }

    /// Whether the frame on screen stays while `next`'s panes draw their first pictures off screen: `next`
    /// draws a pane whose terminal has no renderer yet, as another tab's panes or a restarted server's do,
    /// and none of the panes on screen goes on in it. A pane that goes on, as in a split, was painted for
    /// `next` already, so its old picture can't stay, and `next` goes on screen at once.
    private func holdsScreen(for next: HerdrPaneLayout) -> Bool {
        guard layout != nil else { return false }
        let panes = next.textPaneIDs
        let goesOn = panes.contains { paneID in
            surfaces[paneID].map { $0.terminal === terminals[paneID] } ?? false
        }
        return panes.contains(where: lacksRenderer) && !goesOn
    }

    /// Whether the pane's terminal has no renderer on screen.
    private func lacksRenderer(_ paneID: String) -> Bool {
        terminals[paneID].map { surfaces[paneID]?.terminal !== $0 } ?? false
    }

    /// Makes the renderers of the frame held off screen, each at its place in that frame, and closes those
    /// made for a frame it replaced, as a quick switch on to a third tab does.
    private func stage() {
        guard let frame = pendingFrame else { return }
        let shown = frame.layout.textPaneIDs
        let replaced = stagedSurfaces.filter { !shown.contains($0.key) || $0.value.terminal !== terminals[$0.key] }
        for paneID in replaced.keys { stagedSurfaces.removeValue(forKey: paneID) }
        for paneID in shown {
            if let surface = stagedSurfaces[paneID], let metrics = displayMetrics(for: paneID) {
                _ = surface.renderer.updateDisplay(metrics: metrics)
            } else {
                createRendererIfPossible(paneID)
            }
        }
        for surface in replaced.values { close(surface.renderer) }
    }

    /// Shows the frame held off screen once every pane it draws has its first picture, or failed: one pane
    /// for a zoomed tab, each of a split one, and only while it is drawn at the screen's grid
    /// (`isDrawnAtScreenGrid`). The newest intent wins: while Remux's move goes elsewhere, the frame waits for
    /// the move's own, or for the move's end.
    private func showPreparedFrameIfReady() {
        guard let frame = pendingFrame, isDrawnAtScreenGrid(frame.layout), !isPassedOver(frame) else { return }
        for paneID in frame.layout.textPaneIDs where presentationFailures[paneID] == nil && terminals[paneID] != nil {
            guard let surface = stagedSurfaces[paneID], surface.terminal === terminals[paneID] else { return }
            switch surface.renderer.presentation {
            case .ready, .failed: continue
            case .pending, .awaitingFrame: return
            }
        }
        show(frame)
    }

    /// Puts `frame` on screen in one turn: its layout, its panes' renderers, the focus, and what counts as
    /// seen. The surfaces it no longer shows retire, keeping their pictures until the screen lets go of them.
    private func show(_ frame: DrawnFrame) {
        let layout = frame.layout
        pendingFrame = nil
        endSelections(movedBy: layout)
        self.layout = layout
        if let tab = layout.tab, !tab.zoomed {
            let drawn = layout.panes.compactMap { pane in pane.hasTextArea ? pane.innerRect.map { (pane.paneID, $0) } : nil }
            tabMap = HerdrTabMap(
                bootID: layout.bootID,
                tabID: tab.tabID,
                rects: Dictionary(drawn) { first, _ in first }
            )
        }
        let shown = layout.textPaneIDs
        presentationFailures = presentationFailures.filter { shown.contains($0.key) }
        pointers = pointers.filter { shown.contains($0.key) }
        wheelRemainders = wheelRemainders.filter { shown.contains($0.key) }
        // A button held in a pane that leaves the screen is released there now, since the screen has no way left to
        // send the touch's end to it: Herdr takes a release whatever tab it shows (`server/headless.rs`
        // `client_pane_input_releases_press`), as Herdr's client releases what it holds once its input
        // context is gone (`client/shell/input.rs` `release_input_leases`). A later release finds no press.
        if let gesture = mouseGesture, case .pane(let paneID) = gesture.target, !shown.contains(paneID) {
            mouseGesture = nil
            if let attempt = shownAttempt {
                _ = send([mouseEvent(.up(gesture.button), at: gesture.cell, mods: [])], to: (attempt, paneID))
            }
        }
        for (paneID, staged) in stagedSurfaces {
            if let left = surfaces.updateValue(staged, forKey: paneID) { retiredSurfaces.append(left) }
            applyScroll(toPane: paneID)
        }
        stagedSurfaces.removeAll()
        for (paneID, surface) in surfaces where !shown.contains(paneID) || surface.terminal !== terminals[paneID] {
            surfaces.removeValue(forKey: paneID)
            retiredSurfaces.append(surface)
        }
        for paneID in shown {
            if let surface = surfaces[paneID], let metrics = displayMetrics(for: paneID) {
                _ = surface.renderer.updateDisplay(metrics: metrics)
            } else {
                createRendererIfPossible(paneID)
            }
        }
        learnPopupAccent(from: layout)
        popup.update(from: layout)
        presentedFrame = frame.presented
        acknowledgeShownAgents()
        reconcilePresentationActivity()
        closeReleasedSurfaces()
    }

    /// Closes the retired surfaces the screen has let go of: a view out of the window, or one whose pane shows
    /// its new surface in the window now, over it in the same place. Off screen, the session lets go at once.
    /// A renderer's close tells the model its presentation changed, so they leave the list before they close.
    private func closeReleasedSurfaces() {
        let released = retiredSurfaces.filter { surface in
            !isSelected || surface.renderer.view.window == nil || surfaces[surface.paneID]?.renderer.view.window != nil
        }
        guard !released.isEmpty else { return }
        retiredSurfaces.removeAll { surface in released.contains { $0 === surface } }
        for surface in released { close(surface.renderer) }
    }

    /// A pane renderer's presentation changed: a renderer off screen may have drawn its first picture, a new
    /// view may be in the window, and a retired one out of it.
    private func paneRendererChanged() {
        guard !stopped else { return }
        closeReleasedSurfaces()
        showPreparedFrameIfReady()
        didChange()
    }

    /// The pane's surface over its terminal now: the one drawing off screen, else the one on screen.
    private func currentSurface(of paneID: String) -> HerdrPaneSurface? {
        stagedSurfaces[paneID] ?? surfaces[paneID]
    }

    /// A pane's size on screen in the newest frame the engine drew.
    private func displayMetrics(for paneID: String) -> GhosttySurfaceDisplayMetrics? {
        guard let measurement,
              let area = (pendingFrame?.layout ?? layout)?.panes.first(where: { $0.paneID == paneID })?.innerRect
        else { return nil }
        return measurement.displayMetrics(columns: UInt32(area.width), rows: UInt32(area.height))
    }

    private func retryFailedPanes() {
        presentationFailures.removeAll()
        for paneID in Array(terminals.keys) {
            createRendererIfPossible(paneID)
        }
        func replace(_ surface: HerdrPaneSurface) {
            let terminal = ObjectIdentifier(surface.terminal)
            closingTerminals.insert(terminal)
            close(surface.renderer) { [weak self] in
                guard let self else { return }
                closingTerminals.remove(terminal)
                createRendererIfPossible(surface.paneID)
                didChange()
            }
        }
        func isFailed(_ surface: HerdrPaneSurface) -> Bool {
            if case .failed = surface.renderer.presentation { true } else { false }
        }
        let failed = surfaces.values.filter(isFailed) + stagedSurfaces.values.filter(isFailed)
        surfaces = surfaces.filter { !isFailed($0.value) }
        stagedSurfaces = stagedSurfaces.filter { !isFailed($0.value) }
        failed.forEach(replace)
        didChange()
    }

    private func createRendererIfPossible(_ paneID: String) {
        guard !stopped, let runtime,
              let terminal = terminals[paneID],
              surfaces[paneID]?.terminal !== terminal, stagedSurfaces[paneID]?.terminal !== terminal,
              !closingTerminals.contains(ObjectIdentifier(terminal)),
              presentationFailures[paneID] == nil,
              let metrics = displayMetrics(for: paneID),
              creatingTerminals.insert(ObjectIdentifier(terminal)).inserted
        else { return }
        TerminalPaneRenderer.create(
            app: runtime.appHandle,
            terminal: terminal,
            fence: makeRendererFence(engine, paneID, terminal),
            writeInput: nil,
            baseConfig: runtime.makeTmuxBaseSurfaceConfig(),
            metrics: metrics,
            theme: currentTerminalSettings.theme,
            diagnosticName: "herdr pane=\(paneID)",
            onRendererFailure: { [weak self] in self?.rendererFailed(paneID, terminal: terminal) }
        ) { [weak self, runtime] result in
            guard let self else {
                // Nothing waits for this close, so it keeps the Ghostty app alive itself.
                if case .success(let renderer) = result {
                    renderer.close { withExtendedLifetime(runtime) {} }
                }
                return
            }
            self.rendererCreated(result, paneID: paneID, terminal: terminal)
        }
    }

    private func rendererCreated(
        _ result: Result<TerminalPaneRenderer, TerminalPaneRenderer.CreateError>,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) {
        creatingTerminals.remove(ObjectIdentifier(terminal))
        defer { resumeCreationDrainIfQuiescent() }
        // The engine may have replaced or dropped the terminal while its renderer was being registered.
        let isCurrentTerminal = !stopped && terminals[paneID] === terminal
        switch result {
        case .failure(let error):
            guard isCurrentTerminal else { return }
            presentationFailures[paneID] = TerminalDisconnectReason(
                kind: .runtime,
                message: "Terminal renderer could not be created. Reconnect to try again."
            )
            GhosttyRuntimeTrace.diagnostics(
                "herdrPane.createFailed pane=\(paneID) error=\(String(describing: error))"
            )
            showPreparedFrameIfReady()
        case .success(let renderer):
            guard isCurrentTerminal, let metrics = displayMetrics(for: paneID) else {
                close(renderer)
                return
            }
            let surface = HerdrPaneSurface(paneID: paneID, terminal: terminal, renderer: renderer)
            // The panes of a frame held off screen draw their first pictures there.
            let staged = pendingFrame != nil
            if staged {
                stagedSurfaces[paneID] = surface
            } else if let left = surfaces.updateValue(surface, forKey: paneID) {
                retiredSurfaces.append(left)
            }
            terminalScreenAdapter.makeScreenSurface(for: surface)
            applyScroll(toPane: paneID)
            renderer.onPresentationChange = { [weak self] in self?.paneRendererChanged() }
            // Settings and the pane's size may have changed while the renderer was being registered.
            if !renderer.applyTerminalConfiguration(theme: currentTerminalSettings.theme)
                || !renderer.updateDisplay(metrics: metrics) {
                renderer.failPresentation(message: Self.configurationFailureMessage)
            }
            reconcilePresentationActivity()
            if staged { renderer.prepare() }
            closeReleasedSurfaces()
            showPreparedFrameIfReady()
        }
        didChange()
    }

    private func rendererFailed(_ paneID: String, terminal: HerdrRetainedTerminal) {
        guard let surface = [stagedSurfaces[paneID], surfaces[paneID]].lazy.compactMap({ $0 }).first(where: { $0.terminal === terminal })
        else { return }
        surface.renderer.failPresentation(message: Self.rendererFailureMessage)
        didChange()
    }

    /// Only the selected session's panes are presented. Without an open connection the panes show a
    /// frozen frame, so none is focused: Herdr's client shows no cursor while its session isn't online.
    private func reconcilePresentationActivity() {
        let sceneActive = appPhase == .active
        let live = failure == nil && isConnectionOpen
        // A popup covers the panes and has the only cursor, so they aren't drawn under it.
        let popupShown = popup.popup != nil
        for (paneID, surface) in surfaces {
            let inLayout = layout?.panes.contains { $0.paneID == paneID } == true
            surface.renderer.setSceneActive(sceneActive)
            surface.renderer.setPresented(isSelected && inLayout && !popupShown)
            surface.renderer.setFocused(isSelected && live && inLayout && !popupShown && paneID == screenPaneID)
        }
        // A pane drawing off screen is neither presented nor focused until its frame goes on screen.
        for surface in stagedSurfaces.values {
            surface.renderer.setSceneActive(sceneActive)
        }
        popup.setRendererActivity(HerdrPopupController.RendererActivity(
            sceneActive: sceneActive,
            presented: isSelected && popupShown,
            focused: isSelected && live && popupShown
        ))
    }

    /// Every renderer is closed here, so a stop can wait for all of them; `completion` runs once the
    /// renderer's surface is freed.
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
        guard closingRenderers == 0, let continuation = closesDrained else { return }
        closesDrained = nil
        continuation.resume()
    }

    private func resumeCreationDrainIfQuiescent() {
        guard creatingTerminals.isEmpty, let continuation = creationsDrained else { return }
        creationsDrained = nil
        continuation.resume()
    }

    // MARK: - Switching tabs

    /// The tab the screen is going to while it still shows another, by its id, once known, and its name: the
    /// newest intent, so the tab Remux's move goes to while it is under way, else the tab of a frame whose
    /// panes draw off screen.
    private var switchTarget: (tabID: String?, name: String)? {
        let shownTab = layout?.tab?.tabID
        if let attempt, isCurrent(attempt), let move = attempt.move, let target = move.goesTo {
            guard target.tabID == nil || target.tabID != shownTab else { return nil }
            // A new tab or workspace is known by its pane's tab once a snapshot lists the pane Herdr made.
            let made = move.made.flatMap { made in snapshot?.panes.first { $0.paneID == made }?.tabID }
            return (target.tabID ?? made, target.tabID.flatMap(tabName(ofTab:)) ?? target.name)
        }
        guard let tab = pendingFrame?.layout.tab, tab.tabID != shownTab else { return nil }
        return (tab.tabID, tabName(ofTab: tab.tabID) ?? tab.label)
    }

    /// What the screen calls a tab, in the switching cue and the popup's frame, as the newest snapshot has it:
    /// the user's name for it, else "tab" and its number, as the toolbar counts tabs; Herdr's own name for a
    /// tab is its number.
    func tabName(ofTab tabID: String) -> String? {
        guard let tab = snapshot?.tabs.first(where: { $0.tabID == tabID }) else { return nil }
        return tab.customLabel ? tab.label : "tab \(tab.number)"
    }

    /// The tab a switch under way goes to, which the next tab over is counted from.
    var switchingTabID: String? {
        switchTarget?.tabID
    }

    /// Whether the screen is going to another tab than the one it shows, known by its id or not yet, as a new
    /// tab before Herdr's answer names it.
    var isSwitching: Bool {
        switchTarget != nil
    }

    /// The name of the tab the screen says it is switching to: only once the switch has taken longer than
    /// `switchingCueDelay`, so a quick one, whose tap is its own feedback, shows nothing in between.
    var switchingCue: String? {
        isSwitchingCueDue ? switchTarget?.name : nil
    }

    /// Times the switching cue from the moment a switch starts until it ends; a switch to another tab on the
    /// way keeps the time of the first.
    private func reconcileSwitchingCue() {
        guard switchTarget != nil else {
            switchingCueTimer?.cancel()
            switchingCueTimer = nil
            isSwitchingCueDue = false
            return
        }
        guard switchingCueTimer == nil, !isSwitchingCueDue else { return }
        switchingCueTimer = Task { [weak self, switchingCueDelay] in
            try? await Task.sleep(for: switchingCueDelay)
            guard !Task.isCancelled, let self else { return }
            switchingCueTimer = nil
            isSwitchingCueDue = true
            didChange()
        }
    }

    // MARK: - Reporting

    private func didChange() {
        guard !stopped else { return }
        reconcilePopupHold()
        // A reconnect reads as one until the session is ready again, shown or not.
        if isConnectionReady { isReconnecting = false }
        reconcileSwitchingCue()
        terminalScreenAdapter.objectWillChange.send()
        let readiness = terminalScreenAdapter.terminalScreenPresentationProjection.readiness
        var state = TerminalReadinessProjector.runtimeState(readiness)
        // Reconnecting by itself, the session keeps its last frame and says so until it is back.
        if isReconnecting, state == .connecting { state = .reconnecting(.transportLoss) }
        let source: TerminalRuntimeStateUpdateSource = readiness.phase == .running ? .readiness : .runtime
        guard reportTracker.shouldReport(state: state, source: source) else { return }
        onRuntimeStateChange(TerminalRuntimeStateUpdate(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID,
            state: state,
            source: source
        ))
    }

    private static let runtimeStartFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal runtime failed to initialize"
    )

    private static let viewportFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "terminal viewport failed to initialize"
    )

    private static let paneFailure = TerminalDisconnectReason(
        kind: .runtime,
        message: "Terminal pane could not be painted. Reconnect to try again."
    )

    /// The tap's own feedback, as the Tabs sheet closing, covers a quicker switch.
    nonisolated static let switchingCueDelay: Duration = .milliseconds(500)
    /// What the switching cue calls a tab or workspace Herdr is making.
    static let newTabName = "a new tab"
    static let newWorkspaceName = "a new workspace"

    private static let activationTimeout = TerminalDisconnectReason(
        kind: .transportIO,
        message: "Herdr didn't show the session in time."
    )

    nonisolated static let paneFocusMethod = "pane.focus"
    nonisolated static let paneZoomMethod = "pane.zoom"
    nonisolated static let paneSelectionReadMethod = "pane.selection.read"
    nonisolated static let paneLinkResolveMethod = "pane.link.resolve"
    private static let inputFailureLabel = "input"
    /// Herdr refuses an attach while another device's holds the popup; it then shows as Herdr draws it.
    static let popupHeldElsewhereMessage = "Another device has this popup open, so it shows at that device's size."
    private static let copyFailureLabel = "copy"
    private static let zoomFailureLabel = "zoom pane"
    static let copiedNotice = "Copied to clipboard"
    /// As long as Herdr's client shows its copy notice.
    static let copiedNoticeDuration: Duration = .seconds(2)

    private static let rendererFailureMessage = "Terminal renderer is unavailable. Reconnect to try again."
    private static let configurationFailureMessage =
        "Terminal renderer could not apply its current configuration. Reconnect to try again."

    private func disconnectReason(openingBridgeFailedWith error: Error) -> TerminalDisconnectReason {
        (error as? HerdrBridgeError)?.terminalDisconnectReason(on: target.server)
            ?? GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
    }

    private func disconnectReason(connectionFailedWith error: Error) -> TerminalDisconnectReason {
        (error as? HerdrConnectionError)?.terminalDisconnectReason(on: target.server)
            ?? TerminalDisconnectReason(kind: .unknown, message: error.localizedDescription)
    }

    /// As Herdr's client sorts an endpoint's failures (`supervisor.rs`, `remote/saved.rs`): a dropped or
    /// broken connection is retried, a server that can't talk to Remux needs attention. Remux leaves
    /// sign-in, host key and a missing Herdr to the repair panel, whose actions fix them. `opened` says
    /// whether the connection had opened before it failed.
    private static func recovery(connectionFailedWith error: Error, opened: Bool) -> Recovery {
        switch error as? HerdrConnectionError {
        case .closed?, .transport?, .unresponsive?, .handshakeTimedOut?, .serverShutdown?:
            return .retry
        case .wire(.invalidControl(let kind))? where kind.hasPrefix("shell.snapshot."):
            return .recheck
        case .wire(.unnegotiatedSnapshot)?:
            return .recheck
        case .wire?:
            return .retry
        case .outdated?, .rejected?, .incompatible?:
            return .recheck
        case .bridge(let error)?:
            return recovery(bridgeFailedWith: error, opened: opened)
        case nil:
            return .none
        }
    }

    /// A bridge that exits once its connection is open is a drop, as Herdr's client retries any endpoint
    /// that disconnects: Herdr's bridge exits by itself after a minute with nothing to carry, which an app
    /// in the background can't prevent. One that exits while opening says why: Herdr is missing or
    /// couldn't start.
    private static func recovery(bridgeFailedWith error: HerdrBridgeError, opened: Bool) -> Recovery {
        switch error {
        case .remoteExit, .channel:
            .retry
        case .program:
            opened ? .retry : .none
        }
    }

    /// An SSH failure is retried when the server couldn't be reached or the link broke.
    private static func recovery(openingBridgeFailedWith error: Error, reason: TerminalDisconnectReason) -> Recovery {
        if let error = error as? HerdrBridgeError { return recovery(bridgeFailedWith: error, opened: false) }
        switch reason.kind {
        case .serverUnreachable, .transportIO, .unknown:
            return .retry
        default:
            return .none
        }
    }
}

extension HerdrConnectionError {
    /// Why the session on `server` ended, as its screen tells it.
    func terminalDisconnectReason(on server: SavedServer) -> TerminalDisconnectReason {
        let message = errorDescription ?? "The connection to Herdr failed."
        switch self {
        case .bridge(let error):
            return error.terminalDisconnectReason(on: server)
        case .closed, .transport, .unresponsive, .handshakeTimedOut:
            return TerminalDisconnectReason(kind: .transportIO, message: message)
        case .serverShutdown(let reason):
            // Herdr says why: it's shutting down, or a live update is handing over to a new server.
            return TerminalDisconnectReason(
                kind: .remoteExit,
                message: "Herdr stopped on \(server.displayName).",
                detail: reason.flatMap { $0.isEmpty ? nil : $0 }
            )
        case .outdated(let version):
            // As Herdr's own client says: the install may already be new, and only the running server old.
            let running = version.map { "Herdr \($0) is running" } ?? "An older Herdr is running"
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: "\(running) on \(server.displayName). Update Herdr, then restart its server."
            )
        case .rejected(_, let reason):
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: Self.incompatibleMessage(on: server),
                detail: reason.isEmpty ? nil : reason
            )
        case .incompatible:
            return TerminalDisconnectReason(
                kind: .backendUnavailable(.herdr),
                message: Self.incompatibleMessage(on: server)
            )
        case .wire:
            return TerminalDisconnectReason(kind: .runtime, message: message)
        }
    }
}

extension HerdrConnectionError {
    private static func incompatibleMessage(on server: SavedServer) -> String {
        "Herdr on \(server.displayName) doesn't work with this version of Remux."
    }
}

extension HerdrBridgeError {
    /// The same whether opening the bridge failed or its first read reported the failure: the live bridge
    /// opens before Herdr's executable is looked up.
    func terminalDisconnectReason(on server: SavedServer) -> TerminalDisconnectReason {
        let message = errorDescription ?? "The bridge to Herdr failed."
        switch self {
        case .program(let failure):
            return BackendProblem(failure, path: server.herdrExecutablePath).disconnectReason(for: .herdr)
        case .remoteExit(_, let stderr):
            return TerminalDisconnectReason(
                kind: .remoteExit,
                message: "The server closed the connection before Herdr started.",
                detail: RemoteProgramCommand.startupMessage(in: stderr)
            )
        case .channel:
            return TerminalDisconnectReason(kind: .transportIO, message: message)
        }
    }
}

extension HerdrPaneLayout.Pane {
    /// A pane with no text area, or one the frame doesn't draw, has no terminal.
    var hasTextArea: Bool {
        guard let innerRect else { return false }
        return innerRect.width > 0 && innerRect.height > 0
    }
}

extension HerdrPaneLayout {
    /// The panes the frame draws with a text area: those with a terminal.
    var textPaneIDs: Set<String> {
        Set(panes.lazy.filter(\.hasTextArea).map(\.paneID))
    }
}

extension HerdrPaneScroll {
    /// Herdr routes a wheel step to a program that reads the mouse first, then to one on the alternate
    /// screen as an arrow key, and otherwise scrolls the pane's history.
    var route: GhosttySurfaceScrollRoute {
        if mouseReporting { return .mouseReport }
        if alternateScreenActive { return .altScreenCursor }
        return .remoteHistory
    }

    /// The server's numbers aren't trusted to fit: a history too long to add the rows to is capped first,
    /// so the total, the position and the rows stay consistent.
    var scrollState: GhosttySurfaceScrollState {
        let history = min(maxLinesFromBottom, UInt64.max - rows)
        let fromBottom = min(linesFromBottom, history)
        return GhosttySurfaceScrollState(
            total: history + rows,
            offset: history - fromBottom,
            len: rows,
            cellOffset: 0
        )
    }
}
