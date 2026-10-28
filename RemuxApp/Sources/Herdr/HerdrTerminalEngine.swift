import Foundation
import GhosttyKit

/// The tab the engine last painted for one connection, and its panes, in the frame's cells.
struct HerdrPaneLayout: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let paneID: String
        /// The pane's text area: its terminal's size, and where it sits in the frame. Nil for a pane the
        /// frame doesn't draw, as a zoomed tab draws only its focused pane.
        let innerRect: HerdrSurfaceRect?
        /// The pane's name as Herdr's pane navigator lists it, from the snapshot.
        var name = ""
        /// The directory of the pane's foreground program, else of its shell; empty when unknown.
        var path = ""
    }

    /// The tab the surface shows: the snapshot's focused tab.
    struct Tab: Equatable, Sendable {
        let tabID: String
        let label: String
        /// Whether the tab is zoomed: the frame then draws only its focused pane.
        let zoomed: Bool
    }

    let bootID: String
    let tab: Tab?
    let columns: UInt16
    let rows: UInt16
    /// The tab's panes in Herdr's order, as the snapshot lists them, also those the frame doesn't draw.
    let panes: [Pane]
    /// The lines Herdr draws around and between the panes, which the crop leaves out of the panes.
    let borders: [HerdrBorderLine]
    /// Whether a popup is open over the tab. It takes the tab's input meanwhile.
    let hasPopup: Bool
}

/// Where a pane's history viewport is and what its program asks of the mouse, from Herdr's surface.
struct HerdrPaneScroll: Equatable, Sendable {
    /// Lines the viewport is above the bottom of the history, and how far up it can go.
    let linesFromBottom: UInt64
    let maxLinesFromBottom: UInt64
    let rows: UInt64
    let mouseReporting: Bool
    let alternateScreenActive: Bool
}

extension HerdrPaneScroll {
    init(of pane: HerdrSurfacePane) {
        self.init(
            linesFromBottom: pane.scroll?.offsetFromBottom ?? 0,
            maxLinesFromBottom: pane.scroll?.maxOffsetFromBottom ?? 0,
            rows: pane.scroll?.viewportRows ?? UInt64(pane.innerRect.height),
            mouseReporting: pane.mouseReporting,
            alternateScreenActive: pane.alternateScreenActive
        )
    }
}

/// What a pane's terminal shows of Herdr's pane, which a request about the terminal's cells names, as
/// Herdr's client names the frame it shows.
struct HerdrPaneContent: Equatable, Sendable {
    /// Herdr's revision of the pane's content; odd while Herdr is changing it.
    let revision: UInt64
    /// As Herdr sent it: nil for a pane it gave no scroll metrics.
    let offsetFromBottom: UInt64?
    /// The history row at the viewport's top.
    let top: UInt64
    /// The text area's size.
    let columns: UInt16
    let rows: UInt16

    init(of pane: HerdrSurfacePane) {
        revision = pane.contentRevision
        offsetFromBottom = pane.scroll?.offsetFromBottom
        top = HerdrPaneScroll(of: pane).scrollState.offset
        columns = pane.innerRect.width
        rows = pane.innerRect.height
    }
}

/// What the engine tells its main-actor owner, in order.
enum HerdrEngineUpdate: Sendable {
    /// A new terminal for a pane, already painted; the owner creates its renderer with a
    /// `HerdrPaneRendererFence`. It replaces an earlier terminal for the same pane, whose renderer the
    /// owner closes.
    case paneTerminal(paneID: String, terminal: HerdrRetainedTerminal)
    /// Follows the terminals of the new panes it lists.
    case layout(HerdrPaneLayout)
    /// Each listed pane's scrolling, whenever any of it changed. Kept out of the layout because the
    /// history grows with every line a program prints.
    case paneScroll([String: HerdrPaneScroll])
    /// Ghostty couldn't make or paint the pane's terminal. It isn't painted again until the pane leaves
    /// the layout or a new connection begins; a terminal it already had keeps its last frame.
    case paneTerminalFailed(paneID: String)
    /// Waking the pane's renderer failed and its registration is dropped, as for a tmux pane.
    case rendererWakeFailed(paneID: String)
    /// A surface Remux can't index came over `connection`. Nothing more of it is painted; the owner
    /// ends that connection.
    case failed(HerdrConnectionError, connection: UInt64)
    /// View request `request` became the engine's current one on `connection`, holding the frames until
    /// it completes. `showing` when it carries a show still in progress, as a move that took one over does.
    case started(request: UInt64, kind: HerdrViewKind, showing: Bool, connection: UInt64)
    /// View request `request` completed: a frame that arrived after it, at or after the floor Herdr
    /// acknowledged, at the requested size, and showing where its commands took the session or what
    /// Herdr shows since it was overtaken, is painted. Follows that frame's layout.
    case activated(request: UInt64, connection: UInt64)
    /// View request `request` didn't complete within its time.
    case timedOut(request: UInt64, connection: UInt64)
    /// Herdr answered the step of the current view request `request` that takes the session to its
    /// place, a focus or a creation: why it failed, or nil when it worked. Reported only while `request`
    /// is current, in order with its other events.
    case answered(request: UInt64, step: HerdrCommandLane.Step, failure: HerdrCommandError?, connection: UInt64)
    /// Herdr answered a zoom Remux sent, of a request's step or not: the tab's layout, for the pane
    /// sheet's map, or why it failed or didn't go. `reportsFailure` for the zoom button's, whose
    /// outcome the screen reports.
    case zoomAnswered(HerdrPaneZoomResult?, bootID: String, failure: HerdrCommandError?, reportsFailure: Bool, connection: UInt64)
    /// Herdr refused the show of the current view request `request`, for `reason`.
    case showRefused(request: UInt64, reason: String, connection: UInt64)
    /// The frame on screen now was drawn against snapshot `projectionRevision`, shows these panes, whose
    /// agents the user can see, and draws `focusedPaneID` focused. Comes before that frame's layout.
    case presented(bootID: String, projectionRevision: UInt64, paneIDs: Set<String>, focusedPaneID: String?, connection: UInt64)
}

/// One connection's way into the engine, named by its owner's attempt. Once that connection ends or a
/// later one begins, its events are dropped, so a replaced connection's late frames never reach the
/// panes.
struct HerdrEngineFeed: Sendable {
    let engine: HerdrTerminalEngine
    let connection: UInt64

    func receive(_ snapshot: HerdrSnapshot) async {
        await engine.receive(snapshot, connection: connection)
    }

    func receive(_ output: HerdrSurfaceDecoder.Output) async {
        await engine.receive(output, connection: connection)
    }

    func receive(_ chunk: HerdrResponseChunk) async {
        await engine.receive(chunk, connection: connection)
    }

    /// The connection ended: its commands fail, and a close waiting for an unzoom goes.
    func ended() async {
        await engine.endConnection(connection)
    }

    /// The connection opened, offering `methods`; Herdr's client retires a command unanswered after
    /// `commandTimeout`.
    func opened(methods: Set<String>, commandTimeout: Duration) async {
        await engine.opened(methods: methods, commandTimeout: commandTimeout, connection: connection)
    }

    /// The request that takes the session where `view` asks (`HerdrTerminalEngine.start`).
    @discardableResult
    func start(_ view: HerdrView, within deadline: Duration) async -> UInt64? {
        await engine.start(view, within: deadline, connection: connection)
    }

    /// `method` through the lane, after the commands asked before it; `answered` gets Herdr's reply, or
    /// why it failed or didn't go.
    func command(
        _ method: String,
        params: some Encodable & Sendable,
        answered: @escaping @Sendable (Result<HerdrCommandReply, HerdrCommandError>) -> Void
    ) async {
        await engine.enqueue(
            HerdrCommandLane.Command(method: method, params: params, purpose: .other(answered: answered)),
            connection: connection
        )
    }

    /// The zoom button's zoom of `pane`, the pane Herdr has focused.
    func setZoom(_ zoomed: Bool, ofPane pane: String) async {
        await engine.enqueue(Self.zoom(pane, zoomed: zoomed, purpose: .zoom(pane: pane, zoomed: zoomed)), connection: connection)
    }

    /// The pane sheet's question for the layout of `pane`'s zoomed tab.
    func askLayout(ofPane pane: String) async {
        await engine.enqueue(Self.zoom(pane, zoomed: true, purpose: .layout(pane: pane)), connection: connection)
    }

    /// Remux's zoom off the tab on screen before the connection closes, if Herdr can take it at once;
    /// `done` once it is answered, or at once when it doesn't go.
    func unzoomBeforeClosing(done: @escaping @Sendable () -> Void) async {
        await engine.unzoomBeforeClosing(done: done, connection: connection)
    }

    func resize(columns: UInt16, rows: UInt16) async {
        await engine.resize(columns: columns, rows: rows, connection: connection)
    }

    private static func zoom(
        _ pane: String,
        zoomed: Bool,
        purpose: HerdrCommandLane.Command.Purpose
    ) -> HerdrCommandLane.Command {
        HerdrCommandLane.Command(
            method: HerdrScreenModel.paneZoomMethod,
            params: HerdrScreenModel.zoomParams(pane, zoomed: zoomed),
            purpose: purpose
        )
    }
}

/// What Remux asks Herdr to show (`HerdrTerminalEngine.start`).
enum HerdrView: Sendable {
    /// The session on screen at `geometry`, taken to `destination` right after, when given.
    case shown(HerdrSurfaceGeometry, to: HerdrDestination?, zoom: HerdrZoomPolicy)
    /// The session on screen taken to `destination`; `fromAnotherTab` when another tab was on screen as it
    /// was asked for.
    case moved(HerdrDestination, fromAnotherTab: Bool, columns: UInt16, rows: UInt16, zoom: HerdrZoomPolicy)
    case hidden
}

enum HerdrViewKind: Sendable {
    case show
    /// A move, or a creation, which takes the session to what it makes.
    case move
    case hide
}

/// Which tabs the setting zooms as the session comes to them: a tab with more than one pane, unless the
/// user unzoomed it with the zoom button.
struct HerdrZoomPolicy: Equatable, Sendable {
    var zoomsMultipaneTabs: Bool
    var unzoomedByUser: Set<HerdrTabKey>

    func zooms(_ tabID: String, in snapshot: HerdrSnapshot) -> Bool {
        zoomsMultipaneTabs && snapshot.panes.count(where: { $0.tabID == tabID }) > 1
            && !unzoomedByUser.contains(HerdrTabKey(bootID: snapshot.bootID, tabID: tabID))
    }
}

enum HerdrRendererRegistrationError: Error, Equatable {
    case engineEnded
    /// The pane was dropped, or shows a newer terminal than the renderer's.
    case terminalGone
    case alreadyRegistered
    case rendererWakeFailed
}

/// Turns a session's frames into each pane's terminal, off the main thread, as the tmux client does on
/// its writer queue. It takes the decoder's output in wire order, one connection at a time, applies
/// Herdr's presentation rules, paints every listed pane into its own terminal, and wakes the pane's
/// renderer.
///
/// Every method runs to completion without suspending, so one event is fully painted before the next
/// one, a registration or a stop is taken. The owner learns of terminals and layouts through `updates`;
/// nothing here waits for the main actor.
actor HerdrTerminalEngine {
    nonisolated let updates: AsyncStream<HerdrEngineUpdate>

    private enum State {
        case running
        /// No connection's frames are painted: none has begun, the last one ended, or it sent a surface
        /// Remux can't index. The next connection to begin is painted.
        case idle
        case stopped
    }

    private struct PaintedSurface: Equatable {
        let bootID: String
        let projectionRevision: UInt64
        let surfaceRevision: UInt64

        init(of surface: HerdrPaneSurfaceFrame) {
            bootID = surface.bootID
            projectionRevision = surface.projectionRevision
            surfaceRevision = surface.surfaceRevision
        }
    }

    private struct PresentedFrame: Equatable {
        let bootID: String
        let projectionRevision: UInt64
        let paneIDs: Set<String>
        let focusedPaneID: String?
    }

    /// A view request, as Herdr's client tracks an activation (`activation/model.rs`): a show, a move or a
    /// hide. The newest is current. A move takes over a show or move still in progress, keeping its show's
    /// floor and frames, as Herdr's client retargets an activation; with none in progress it starts on the
    /// frame on screen. Only frames that arrive after a show began count, so the last frame from before a
    /// hide never completes it. Its steps wait in the lane (`HerdrCommandLane`).
    private struct ViewRequest {
        let id: UInt64
        let kind: HerdrViewKind
        /// The show whose answer gives the floor; nil for a hide, and for a move on a session whose show
        /// completed, which met its floor.
        let show: UInt64?
        /// When it times out. A move that carries on a show keeps the show's, as Herdr's client keeps an
        /// activation's deadline through a retarget (`activation.rs` `retarget`); any other move has its
        /// own, as a navigation on a shown session is a request of its own there. Nil for a hide.
        let due: ContinuousClock.Instant?
        var columns: UInt16
        var rows: UInt16
        /// The projection revision Herdr's acknowledgement returned, once it arrives.
        var floor: UInt64?
        /// Where it takes the session; nil for a show that stays where Herdr has it, and for a hide.
        let destination: HerdrDestination?
        /// For a show that stays where Herdr has the session, the pane Herdr had focused as it began, which
        /// its zoom keeps.
        let kept: String?
        /// Whether the setting zooms the tab it ends on, as it does when the session comes to a tab: on a
        /// show, and on a move from another tab. A move carries on the zoom of the request it took over,
        /// whose leave may already have undone Remux's zoom.
        let zooms: Bool
        /// What a snapshot and the frame drawn against it show once its steps are answered; nil when it
        /// waits for nothing in particular.
        var target: Target?
        /// Where Herdr's answer to its newest step that took the session to its place fell among the
        /// snapshots.
        var answer: (sentAfter: UInt64, answeredAfter: UInt64)?
        /// Herdr's state went elsewhere after its commands, as another client took the session somewhere,
        /// or its target is gone: it sends nothing more, and ends as Herdr shows the session. Once set it
        /// stays.
        var overtaken = false
        /// The snapshots since it began, while in progress.
        var snapshots: [HerdrSnapshot] = []
        /// The newest frame since it began, or since the size last changed.
        var received: (projectionRevision: UInt64, columns: UInt16, rows: UInt16)?
        var completed = false

        /// A show or move that hasn't completed: the frames are held for it.
        var inProgress: Bool { kind != .hide && !completed }

        mutating func record(_ snapshot: HerdrSnapshot) {
            guard inProgress else { return }
            target = target?.noting(snapshot)
            guard snapshots.last.map({ $0.revision < snapshot.revision }) ?? true else { return }
            snapshots.append(snapshot)
        }

        /// Whether `snapshot`, the newest, shows Herdr's state gone elsewhere since the request's commands:
        /// away from the pane a show keeps; with its target gone, whether or not its steps went out, since
        /// one that is gone doesn't come back; or, once Herdr has answered the step that took it there, away
        /// from its target, after that answer or after a snapshot since it went out showed the target.
        func isOvertaken(by snapshot: HerdrSnapshot) -> Bool {
            if let kept, snapshot.focusedPaneID != kept { return true }
            guard let target, !target.isShown(in: snapshot) else { return false }
            if target.isGone(in: snapshot) { return true }
            guard let answer else { return false }
            return snapshot.revision > answer.answeredAfter
                || snapshots.contains { $0.revision > answer.sentAfter && target.isShown(in: $0) }
        }

        /// Whether `surface`, drawn against `snapshot`, completes the request, once nothing of its own is
        /// left in the lane. As in Herdr's client, both must show its target (`activation.rs`
        /// `target_matches`); an overtaken request ends as Herdr shows the session.
        func admits(_ snapshot: HerdrSnapshot, drawnAs surface: HerdrPaneSurfaceFrame) -> Bool {
            guard !overtaken, let target else { return true }
            return target.isShown(in: snapshot) && target.isDrawn(in: surface)
        }
    }

    /// What a view request takes Herdr to, as Herdr's client matches an activation's target
    /// (`activation.rs` `target_matches`): the snapshot has the place focused and, for a pane, the frame
    /// drawn against it draws the pane focused. A place or tab that is gone isn't shown.
    enum Target: Sendable, Equatable {
        case place(HerdrPlace)
        /// The pane a creation made, which Herdr lists only in snapshots from after it made it; snapshots
        /// sent while the creation was in flight can come later. `listed` once a snapshot lists it.
        case made(pane: String, listed: Bool)
        /// The pane, on its tab zoomed or not, as a `pane.zoom` focuses its target.
        case zoom(pane: String, tabID: String, zoomed: Bool)
        /// Where Herdr shows the session once `place` has closed: anywhere a snapshot no longer lists it.
        case closed(HerdrPlace)

        func isShown(in snapshot: HerdrSnapshot) -> Bool {
            switch self {
            case .place(let place):
                return snapshot.isAt(place)
            case .closed(let place):
                return !snapshot.contains(place)
            case .made(let pane, _):
                return snapshot.focusedPaneID == pane
            case .zoom(let pane, let tabID, let zoomed):
                return snapshot.focusedPaneID == pane
                    && snapshot.tabs.contains { $0.tabID == tabID && $0.zoomed == zoomed }
            }
        }

        func isDrawn(in surface: HerdrPaneSurfaceFrame) -> Bool {
            let pane: String
            switch self {
            case .place(.pane(let id)), .made(let id, _), .zoom(let id, _, _): pane = id
            case .place(.tab), .place(.workspace), .closed: return true
            }
            return surface.panes.contains { $0.paneID == pane && $0.focused }
        }

        /// Whether the target is gone from `snapshot`, after which it doesn't come back: the place, the
        /// pane or tab of a zoom, or a made pane a snapshot has listed. A made pane no snapshot has listed
        /// yet isn't gone, since the snapshot may be from before Herdr made it.
        func isGone(in snapshot: HerdrSnapshot) -> Bool {
            switch self {
            case .place(let place):
                return !snapshot.contains(place)
            case .made(let pane, let listed):
                return listed && !snapshot.contains(.pane(pane))
            case .zoom(let pane, let tabID, _):
                return !snapshot.contains(.pane(pane)) || !snapshot.contains(.tab(tabID))
            case .closed:
                return false
            }
        }

        /// The target once `snapshot` is in: a made pane is listed once a snapshot lists it.
        func noting(_ snapshot: HerdrSnapshot) -> Target {
            guard case .made(let pane, false) = self, snapshot.contains(.pane(pane)) else { return self }
            return .made(pane: pane, listed: true)
        }
    }

    /// Herdr's answer to a step that took the session somewhere: what it took the session to, and where the
    /// step and its answer fell among the snapshots.
    private struct StepEffect {
        var target: Target
        let sentAfter: UInt64
        let answeredAfter: UInt64

        /// Whether `snapshot`, the newest, shows the effect or Herdr past it: the target, a snapshot from after
        /// the answer, or the target gone since the step went out.
        func isSettled(by snapshot: HerdrSnapshot) -> Bool {
            target.isShown(in: snapshot) || snapshot.revision > answeredAfter
                || (snapshot.revision > sentAfter && target.isGone(in: snapshot))
        }

        mutating func note(_ snapshot: HerdrSnapshot) {
            target = target.noting(snapshot)
        }
    }

    /// A `client_shell.surface.set` Herdr hasn't answered, and the reply's chunks so far.
    private struct SurfaceSet {
        /// The show it is, or nil for a hide.
        let show: UInt64?
        var data: [UInt8] = []
    }

    /// Makes a pane's producer for a terminal of the given columns and rows.
    typealias ProducerFactory = @Sendable (_ columns: UInt16, _ rows: UInt16) throws -> any HerdrPaneProducing

    private struct Pane {
        let producer: any HerdrPaneProducing
        /// The terminal handed to the owner; a renderer registers only over this one.
        let terminal: HerdrRetainedTerminal
        /// What the terminal shows: the last paint Ghostty accepted.
        var painted: HerdrPanePainter.Painted
        /// Herdr's pane as of that paint.
        var content: HerdrPaneContent
        /// The images the terminal holds and shows, as of that paint.
        var images: HerdrPaneImages
        var renderer: HerdrRendererSurface?
    }

    private let continuation: AsyncStream<HerdrEngineUpdate>.Continuation
    private var state = State.idle
    /// The newest connection begun or ended; its events are painted while running.
    private var connection: UInt64 = 0
    private var presentation = HerdrPresentation()
    /// Kept across connections: its keys name their bytes, and each scene keeps only what Herdr counts
    /// as delivered.
    private var images = HerdrImageStore()
    private var panes: [String: Pane] = [:]
    /// Listed panes whose terminal Ghostty couldn't make or paint, until the next connection.
    private var failedPaneIDs: Set<String> = []
    private var bootID: String?
    private var paintedSurface: PaintedSurface?
    private var presentedFrame: PresentedFrame?
    /// The newest view request on the connection: the one current request, which only `start` replaces.
    private var request: ViewRequest?
    private var requests: UInt64 = 0
    /// The current request's time to complete.
    private var deadline: Task<Void, Never>?
    /// Every command of the connection, the current request's steps and the rest.
    private var lane = HerdrCommandLane()
    /// Where the connection's requests go out.
    private var outbox: (any HerdrOutbound)?
    /// The methods the connection's welcome offered, and how long a command may stay unanswered.
    private var methods: Set<String> = []
    private var commandTimeout: Duration = .seconds(60)
    private var commandIDs: UInt64 = 0
    private var surfaceSets: [String: SurfaceSet] = [:]
    /// The tab Remux zoomed, which it undoes as the session leaves it. Kept across connections: a new
    /// one to the same server boot undoes it all the same.
    private var ownedZoom = HerdrOwnedZoom()
    /// The newest answered step whose effect Herdr's snapshots don't show yet. Herdr can answer before it
    /// sends the snapshot showing the answer, so the next step waits for that snapshot, going from where the
    /// step before it took the session, and a leave unzooms nothing meanwhile.
    private var unsettled: StepEffect?
    private var layout: HerdrPaneLayout?
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
    /// Herdr's border lines in the frame painted last. A patch never changes them, since
    /// `HerdrPresentation` takes only patches inside the panes' text areas and scrollbar columns, so
    /// they are read again only once a surface or a snapshot may have changed what is presented.
    private var borders: [HerdrBorderLine] = []
    private var bordersMayHaveChanged = true
    private var cellWidthPx: UInt32
    private var cellHeightPx: UInt32
    private let makeProducer: ProducerFactory

    init(
        cellWidthPx: UInt32,
        cellHeightPx: UInt32,
        makeProducer: @escaping ProducerFactory = { try HerdrPaneProducer(columns: $0, rows: $1) }
    ) {
        (updates, continuation) = AsyncStream.makeStream()
        self.cellWidthPx = max(cellWidthPx, 1)
        self.cellHeightPx = max(cellHeightPx, 1)
        self.makeProducer = makeProducer
    }

    // MARK: - Frames

    /// Herdr's revisions restart with each connection, so the new one starts a new presentation. The
    /// panes keep their terminals and last paint: the same server boot's next frame is painted as a
    /// change from it, and until then the last frame stays on screen. A pane Ghostty couldn't paint
    /// gets a new terminal from that frame. Connections are numbered in the order their owner made them,
    /// so one that begins after a newer one began or ended changes nothing.
    /// A connection's requests go out through `outbox`.
    @discardableResult
    func beginConnection(_ connection: UInt64, outbox: (any HerdrOutbound)? = nil) -> HerdrEngineFeed {
        let feed = HerdrEngineFeed(engine: self, connection: connection)
        guard state != .stopped, connection > self.connection else { return feed }
        endRequests()
        self.connection = connection
        self.outbox = outbox
        state = .running
        presentation = HerdrPresentation()
        paintedSurface = nil
        presentedFrame = nil
        request = nil
        failedPaneIDs.removeAll()
        return feed
    }

    /// The connection's owner gave it up: nothing it still sends is painted, the panes keep their last
    /// frame, and every command it had waiting or in flight fails.
    func endConnection(_ connection: UInt64) {
        guard state != .stopped, connection >= self.connection else { return }
        self.connection = connection
        state = .idle
        endRequests()
    }

    fileprivate func opened(methods: Set<String>, commandTimeout: Duration, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        self.methods = methods
        self.commandTimeout = commandTimeout
    }

    private func endRequests() {
        cancelDeadline()
        outbox = nil
        surfaceSets.removeAll()
        unsettled = nil
        let (inFlight, waiting) = lane.takeAll()
        if case .command(let command)? = inFlight?.item { fail(command, .connectionEnded) }
        waiting.forEach { fail($0, .connectionEnded) }
    }

    // MARK: - Showing

    /// Frames are drawn as they come, except while hidden and during a view request. Frames Herdr sends
    /// as a hide goes out show what leaving did, such as undoing the zoom, so the frame from before the
    /// hide stays until the next show; and a show's frame from before its zoom would flash the unzoomed
    /// tab, as a move's would flash the tab left and the tab reached unzoomed, so a request draws only the
    /// frame that completes it.
    private var holdsFrames: Bool {
        guard let request else { return false }
        return request.kind == .hide || !request.completed
    }

    /// Starts the view request for `view`: it becomes current in this turn, the frames are held for it
    /// from here on, its steps replace those the previous request hadn't sent, and it has `deadline` to
    /// complete. Herdr sends no frames to a hidden session, so every frame after a show answers it or a
    /// later request. A move with nothing to do starts nothing: one to the place the request in progress
    /// already goes to or, with none, to where Herdr has the session, asked from that tab; or one asked
    /// before any show. A creation is a move to what it makes.
    ///
    /// Returns the request that takes the session where `view` asks: the one it starts or, for a move to
    /// where the request in progress already goes, that one; nil when none does, as for a hide or a move to
    /// where Herdr has the session.
    @discardableResult
    fileprivate func start(_ view: HerdrView, within deadline: Duration, connection: UInt64) -> UInt64? {
        guard state == .running, connection == self.connection, let outbox else { return nil }
        let snapshot = presentation.snapshot
        switch view {
        case .hidden:
            hide(outbox: outbox, snapshot: snapshot)
            return nil
        case .shown(let geometry, let destination, let policy):
            let id = nextRequest()
            let kept = destination == nil ? snapshot?.focusedPaneID : nil
            var steps: [HerdrCommandLane.Step] = []
            if let destination {
                steps = plan(to: destination, zooms: true, policy: policy, in: snapshot)
            } else if let kept, let snapshot, let tabID = snapshot.focusedTabID, policy.zooms(tabID, in: snapshot) {
                steps = [.zoom(kept, navigates: false)]
            }
            let due = ContinuousClock.now + deadline
            request = ViewRequest(
                id: id,
                kind: .show,
                show: id,
                due: due,
                columns: max(geometry.cols, 1),
                rows: max(geometry.rows, 1),
                destination: destination,
                kept: kept,
                zooms: true,
                target: destination.flatMap(Self.target(of:))
            )
            lane.replaceSteps(steps, for: id)
            // The tab takes this size, the surface activates, then the phone takes focus, as Herdr's own
            // client shows a session.
            let message = surfaceSet(active: true, show: id, in: snapshot)
            if let message {
                outbox.send([.shellResize(HerdrConnection.atLeastOneCell(geometry)), message, .focus(true)])
                outbox.setSurfaceActive(true)
            }
            begin(id, kind: .show, showing: true, until: due)
            if message == nil {
                // Herdr names its requests by its boot, which comes with its first snapshot.
                continuation.yield(.showRefused(
                    request: id, reason: HerdrCommandError.noSnapshot.localizedDescription, connection: connection
                ))
            }
            return id
        case .moved(let destination, let fromAnotherTab, let columns, let rows, let policy):
            guard let current = request, current.kind != .hide else { return nil }
            let taken = current.inProgress ? current : nil
            // At the place already, a move asked from another tab still goes, so the setting zooms the tab
            // it reaches, as when another client took the session there first.
            guard !Self.goes(to: destination, taking: taken, in: snapshot) || (taken == nil && fromAnotherTab) else {
                return taken?.id
            }
            let id = nextRequest()
            let zooms = taken?.zooms == true || fromAnotherTab || Self.leaves(to: destination, in: snapshot)
            let due = (taken?.show != nil ? taken?.due : nil) ?? ContinuousClock.now + deadline
            request = ViewRequest(
                id: id,
                kind: .move,
                show: taken?.show,
                due: due,
                columns: max(columns, 1),
                rows: max(rows, 1),
                floor: taken == nil ? 0 : taken?.floor,
                destination: destination,
                kept: nil,
                zooms: zooms,
                target: Self.target(of: destination),
                received: taken == nil
                    ? presentation.presented.map { ($0.surface.projectionRevision, $0.surface.frame.width, $0.surface.frame.height) }
                    : taken?.received
            )
            lane.replaceSteps(plan(to: destination, zooms: zooms, policy: policy, in: snapshot), for: id)
            begin(id, kind: .move, showing: taken?.show != nil, until: due)
            return id
        }
    }

    private func nextRequest() -> UInt64 {
        requests += 1
        return requests
    }

    private func begin(_ id: UInt64, kind: HerdrViewKind, showing: Bool, until due: ContinuousClock.Instant) {
        startDeadline(for: id, until: due)
        continuation.yield(.started(request: id, kind: kind, showing: showing, connection: connection))
        // The pane may be gone already from the snapshot the request starts on, newer than the one it was
        // asked from.
        checkOvertaken()
        dispatch()
    }

    /// What a request to `destination` waits to see: the place, or the place a close closes gone; a
    /// creation's pane is known only from Herdr's answer.
    private static func target(of destination: HerdrDestination) -> Target? {
        switch destination {
        case .place(let place): .place(place)
        case .closing(let place, _): .closed(place)
        case .creation: nil
        }
    }

    /// Whether the request in progress already takes the session to `destination` or, with none or with a
    /// show that stays where Herdr has the session, whether Herdr has it there. A creation or a close goes
    /// somewhere new.
    private static func goes(to destination: HerdrDestination, taking taken: ViewRequest?, in snapshot: HerdrSnapshot?) -> Bool {
        guard case .place(let place) = destination else { return false }
        if let going = taken?.destination { return going == destination }
        return snapshot?.isAt(place) == true
    }

    /// The steps that take the session to `destination`: Remux's zoom off the tab left, if it leaves one
    /// Remux zoomed; then, for a pane, the setting's zoom of its tab when the request zooms, which takes the
    /// session there, and the pane's focus, which marks its tab's agents seen, as Herdr's client goes to a
    /// pane. A tab or workspace shows a pane the snapshot doesn't name before the session is there, so its
    /// focus goes first and the setting's zoom follows on the pane it shows. A creation's command goes, and
    /// the setting's zoom follows on the pane it made whether or not the request zooms, since Herdr gives its
    /// tab a new pane. A close of what is on screen goes, and the setting's zoom follows on the tab Herdr shows
    /// then: Herdr unzooms a tab it takes a pane from (`workspace/tab.rs` `detach_pane`), and the tab or
    /// workspace closed takes Remux's zoom with it, so nothing leaves first. A place the session is at
    /// already still gets its focus.
    private func plan(
        to destination: HerdrDestination,
        zooms: Bool,
        policy: HerdrZoomPolicy,
        in snapshot: HerdrSnapshot?
    ) -> [HerdrCommandLane.Step] {
        switch destination {
        case .place(let place):
            var steps: [HerdrCommandLane.Step] = [.leave(to: place)]
            switch place {
            case .pane(let pane):
                if zooms, let snapshot, let tabID = snapshot.tabID(reachedBy: place), policy.zooms(tabID, in: snapshot) {
                    steps.append(.zoom(pane, navigates: true))
                }
                steps.append(.focus(place))
            case .tab, .workspace:
                steps.append(.focus(place))
                if zooms { steps.append(.zoomReached(policy)) }
            }
            return steps
        case .creation(let creation):
            return [.leave(to: creation.tabPlace), .create(creation), .zoomReached(policy)]
        case .closing(let place, let group):
            return [.close(place, group: group), .zoomReached(policy)]
        }
    }

    /// Hides the session at once: the request in progress ends, its steps not yet sent don't go, and the
    /// commands waiting fail, since Herdr refuses commands from a hidden session. Remux's zoom comes off first
    /// if it can go now, while Herdr still takes commands from this client; otherwise it stays, so the leave
    /// never waits. Focus goes before the hide, while still active: deactivation keeps the stored focus, so
    /// without it the next show's focus would be ignored.
    private func hide(outbox: any HerdrOutbound, snapshot: HerdrSnapshot?) {
        if let snapshot { unzoomIfIdle(in: snapshot, closed: nil) }
        lane.dropSteps()
        lane.takeWaiting().forEach { fail($0, .notSent) }
        let id = nextRequest()
        request = ViewRequest(
            id: id, kind: .hide, show: nil, due: nil, columns: 1, rows: 1, destination: nil, kept: nil, zooms: false
        )
        cancelDeadline()
        // A hide Herdr doesn't confirm leaves only its stale foreground on the server.
        if let message = surfaceSet(active: false, show: nil, in: snapshot) {
            outbox.send([.focus(false), message])
        }
        outbox.setSurfaceActive(false)
        continuation.yield(.started(request: id, kind: .hide, showing: false, connection: connection))
    }

    /// Remux's zoom off the tab on screen as the session leaves, if it can go now: nothing is in flight, the
    /// newest snapshot shows where the last step took the session, and it has the tab Remux zoomed on
    /// screen, since an unzoom focuses its target. Otherwise the zoom stays. `closed` once Herdr has
    /// answered it. Returns whether it went.
    @discardableResult
    private func unzoomIfIdle(in snapshot: HerdrSnapshot, closed: (@Sendable () -> Void)?) -> Bool {
        guard lane.isIdle, unsettled == nil, methods.contains(HerdrScreenModel.paneZoomMethod),
              let pane = ownedZoom.paneToUnzoom(in: snapshot)
        else { return false }
        let unzoom = HerdrCommandLane.Command(
            method: HerdrScreenModel.paneZoomMethod,
            params: HerdrScreenModel.zoomParams(pane, zoomed: false),
            purpose: .unzoom(pane: pane, closed: closed)
        )
        send(.command(unzoom), params: unzoom.params, in: snapshot)
        return true
    }

    /// Whether `destination` is on another tab than the one `snapshot` shows: a place on another tab, or a
    /// new tab or workspace.
    private static func leaves(to destination: HerdrDestination, in snapshot: HerdrSnapshot?) -> Bool {
        let place: HerdrPlace
        switch destination {
        case .place(let picked): place = picked
        case .creation(let creation):
            guard let tabPlace = creation.tabPlace else { return true }
            place = tabPlace
        case .closing:
            return false
        }
        guard let snapshot, let tabID = snapshot.tabID(reachedBy: place) else { return false }
        return tabID != snapshot.focusedTabID
    }

    /// A `client_shell.surface.set` for the snapshot's boot, which Herdr answers even while a command is
    /// in flight; one Herdr leaves unanswered is forgotten after Herdr's command time.
    private func surfaceSet(active: Bool, show: UInt64?, in snapshot: HerdrSnapshot?) -> HerdrClientMessage? {
        guard let bootID = snapshot?.bootID else { return nil }
        commandIDs += 1
        let id = "s\(commandIDs)"
        guard let message = try? HerdrClientMessage.endpointRequest(
            bootID: bootID,
            id: id,
            method: HerdrConnection.surfaceSetMethod,
            params: ["active": active]
        ) else { return nil }
        surfaceSets[id] = SurfaceSet(show: show)
        let connection = self.connection
        Task { [weak self, commandTimeout] in
            try? await Task.sleep(for: commandTimeout)
            await self?.forgetSurfaceSet(id, connection: connection)
        }
        return message
    }

    private func forgetSurfaceSet(_ id: String, connection: UInt64) {
        guard connection == self.connection else { return }
        surfaceSets[id] = nil
    }

    /// Herdr's answer to a show: its projection revision, which a frame completing it, or a move that
    /// took it over, must reach; or a refusal, which the owner hears of while that show is current.
    private func surfaceSetAnswered(_ set: SurfaceSet, data: [UInt8]) {
        guard let show = set.show else { return }
        switch Self.shownRevision(from: data) {
        case .success(let floor):
            guard request?.show == show, request?.inProgress == true else { return }
            request?.floor = floor
            completeIfReady()
        case .failure(let failure):
            guard let request, request.show == show else { return }
            continuation.yield(.showRefused(request: request.id, reason: failure.localizedDescription, connection: connection))
        }
    }

    /// As in Herdr's client, the reply must confirm the show.
    private static func shownRevision(from data: [UInt8]) -> Result<UInt64, Error> {
        struct Reply: Decodable {
            struct Result: Decodable {
                let active: Bool
                let projectionRevision: UInt64

                private enum CodingKeys: String, CodingKey {
                    case active
                    case projectionRevision = "projection_revision"
                }
            }

            let result: Result
        }
        if case .failure(let failure) = HerdrCommandLane.result(of: data) { return .failure(failure) }
        guard let result = try? JSONDecoder().decode(Reply.self, from: Data(data)).result else {
            return .failure(HerdrConnectionError.incompatible("its surface.set reply couldn't be read"))
        }
        guard result.active else { return .failure(HerdrCommandError.notAcknowledged) }
        return .success(result.projectionRevision)
    }

    // MARK: - Commands

    /// A command for the lane, which goes in the lane's order.
    fileprivate func enqueue(_ command: HerdrCommandLane.Command, connection: UInt64) {
        guard state == .running, connection == self.connection else { return fail(command, .connectionEnded) }
        lane.append(command)
        dispatch()
    }

    /// Remux's zoom off the tab on screen before the connection closes, if it can go now, as for a hide, so
    /// the close isn't held back; `done` once Herdr has answered it, or at once.
    fileprivate func unzoomBeforeClosing(done: @escaping @Sendable () -> Void, connection: UInt64) {
        guard state == .running, connection == self.connection, outbox != nil,
              request.map({ $0.kind != .hide }) == true, let snapshot = presentation.snapshot,
              unzoomIfIdle(in: snapshot, closed: done)
        else { return done() }
    }

    /// The one place a command is let go: whenever the lane is free, its next item goes, in the lane's
    /// order, if it may go now against Herdr's newest snapshot. This runs in the same turn as the start,
    /// answer, timeout or snapshot that made it due, so nothing changes between the check and the send. A
    /// step goes from where the step before it took the session, so it waits for the snapshot showing that.
    private func dispatch() {
        guard state == .running, lane.isIdle, outbox != nil, let snapshot = presentation.snapshot else { return }
        lane: while let next = lane.next {
            var item = next
            let params: any Encodable & Sendable
            switch next {
            case .step(let id, let step):
                guard let request, request.id == id, request.inProgress, !request.overtaken else {
                    lane.removeNext()
                    continue
                }
                guard unsettled == nil else { break lane }
                lane.removeNext()
                guard let (sent, stepParams) = command(for: step, of: request, in: snapshot) else { continue }
                item = .step(request: id, sent)
                params = stepParams
            case .command(let command):
                lane.removeNext()
                if let refusal = refusal(of: command, in: snapshot) {
                    fail(command, refusal)
                    continue
                }
                params = command.params
            }
            guard methods.contains(item.method) else {
                finish(HerdrCommandLane.InFlight(id: "", item: item, sentAfter: snapshot.revision),
                       with: .failure(.unsupported(method: item.method)))
                continue
            }
            send(item, params: params, in: snapshot)
            return
        }
        completeIfReady()
    }

    /// What a step sends against Herdr's newest snapshot, as it goes, or nil when it doesn't go. The leave
    /// unzooms the tab Remux zoomed while the session is on it and the request goes to another tab; a
    /// show's zoom goes while the pane it zooms is still focused; the zoom of a tab reached goes as a show's
    /// zoom of the pane Herdr focused there, while the snapshot shows the request's target and the setting
    /// zooms that tab; a step that takes the session somewhere goes as long as the request isn't overtaken.
    private func command(
        for step: HerdrCommandLane.Step,
        of request: ViewRequest,
        in snapshot: HerdrSnapshot
    ) -> (HerdrCommandLane.Step, any Encodable & Sendable)? {
        switch step {
        case .leave(let destination):
            guard let pane = ownedZoom.paneToUnzoom(in: snapshot),
                  ownedZoom.tabID != destination.flatMap(snapshot.tabID(reachedBy:))
            else { return nil }
            return (step, HerdrScreenModel.zoomParams(pane, zoomed: false))
        case .zoom(let pane, let navigates):
            guard navigates || snapshot.focusedPaneID == pane else { return nil }
            return (step, HerdrScreenModel.zoomParams(pane, zoomed: true))
        case .zoomReached(let policy):
            guard request.target?.isShown(in: snapshot) == true, let tabID = snapshot.focusedTabID,
                  policy.zooms(tabID, in: snapshot), let pane = snapshot.focusedPaneID
            else { return nil }
            return (.zoom(pane, navigates: false), HerdrScreenModel.zoomParams(pane, zoomed: true))
        case .focus(let place):
            return (step, place.focusParams)
        case .create(let creation):
            return (step, creation.params)
        case .close(let place, let group):
            return (step, place.closeParams(group: group))
        }
    }

    /// Why a command can't go now, if it can't: Herdr refuses commands from a hidden session; a zoom
    /// outside a request focuses its pane, so it goes only while no request is in progress and that pane
    /// is the focused one; and the layout question goes only while the tab it asks about is still zoomed.
    private func refusal(of command: HerdrCommandLane.Command, in snapshot: HerdrSnapshot) -> HerdrCommandError? {
        guard let request, request.kind != .hide else { return .notSent }
        switch command.purpose {
        case .zoom(let pane, _):
            return request.inProgress || snapshot.focusedPaneID != pane ? .notSent : nil
        case .layout(let pane):
            let zoomed = snapshot.tabs.contains { $0.tabID == snapshot.focusedTabID && $0.zoomed }
            return request.inProgress || snapshot.focusedPaneID != pane || !zoomed ? .notSent : nil
        case .unzoom, .other:
            return nil
        }
    }

    private func send(_ item: HerdrCommandLane.Item, params: any Encodable & Sendable, in snapshot: HerdrSnapshot) {
        commandIDs += 1
        let id = "c\(commandIDs)"
        guard let outbox, let message = try? HerdrClientMessage.endpointRequest(
            bootID: snapshot.bootID,
            id: id,
            method: item.method,
            params: params
        ) else {
            finish(HerdrCommandLane.InFlight(id: id, item: item, sentAfter: snapshot.revision),
                   with: .failure(.notSent))
            return
        }
        lane.sent(item, id: id, after: snapshot.revision)
        outbox.send([message])
        let connection = self.connection
        Task { [weak self, commandTimeout] in
            try? await Task.sleep(for: commandTimeout)
            await self?.expire(id, connection: connection)
        }
    }

    fileprivate func receive(_ chunk: HerdrResponseChunk, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        if var set = surfaceSets[chunk.requestID] {
            set.data += chunk.data
            guard chunk.isFinal else {
                surfaceSets[chunk.requestID] = set
                return
            }
            surfaceSets[chunk.requestID] = nil
            return surfaceSetAnswered(set, data: set.data)
        }
        guard let (inFlight, data) = lane.receive(chunk) else { return }
        let answeredAfter = presentation.snapshot?.revision ?? inFlight.sentAfter
        finish(inFlight, with: HerdrCommandLane.result(of: data).map {
            HerdrCommandReply(json: $0, sentAfter: inFlight.sentAfter, answeredAfter: answeredAfter)
        })
        dispatch()
    }

    /// Herdr's client retires a command that didn't answer in time: it fails, the lane frees, and the late
    /// reply is dropped.
    private func expire(_ id: String, connection: UInt64) {
        guard state == .running, connection == self.connection, let inFlight = lane.expire(id) else { return }
        finish(inFlight, with: .failure(.timedOut(method: inFlight.item.method)))
        dispatch()
    }

    /// What Herdr's answer, or a command's failure, does. A zoom's answer records Remux's zoom and the tab's
    /// layout whichever request asked, since Herdr applied it, and a step's answer holds the lane until a
    /// snapshot shows where it took the session; a step of a request a newer one replaced changes nothing
    /// else.
    private func finish(_ inFlight: HerdrCommandLane.InFlight, with result: Result<HerdrCommandReply, HerdrCommandError>) {
        switch inFlight.item {
        case .step(let id, let step):
            if step.isZoom {
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: false)
            }
            var effect = Self.effect(of: step, result)
            // A pane a creation made may be listed by the snapshots that came while it was in flight.
            for snapshot in inFlight.snapshots { effect?.note(snapshot) }
            if let effect { hold(until: effect, seen: inFlight.snapshots) }
            guard var request, request.id == id, request.inProgress else { return }
            switch (step, result) {
            case (.leave, _), (.zoomReached, _):
                break
            case (.zoom, .success), (.create, .success), (.close, .success):
                if !step.isZoom {
                    continuation.yield(.answered(request: id, step: step, failure: nil, connection: connection))
                }
                if let effect {
                    request.target = effect.target
                    request.answer = (effect.sentAfter, effect.answeredAfter)
                }
            case (.zoom(_, navigates: false), .failure):
                request.target = nil
            case (.zoom(_, navigates: true), .failure):
                break
            case (.focus, .success(let reply)):
                continuation.yield(.answered(request: id, step: step, failure: nil, connection: connection))
                request.answer = (reply.sentAfter, reply.answeredAfter)
            case (.focus(let place), .failure(let failure)):
                continuation.yield(.answered(request: id, step: step, failure: failure, connection: connection))
                // The session stays where Herdr has it.
                if request.target == .place(place) { request.target = nil }
            case (.create, .failure(let failure)), (.close, .failure(let failure)):
                // Nothing was made or closed; the session stays where Herdr has it.
                continuation.yield(.answered(request: id, step: step, failure: failure, connection: connection))
                request.target = nil
            }
            self.request = request
            checkOvertaken()
            completeIfReady()
        case .command(let command):
            switch command.purpose {
            case .zoom:
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: true)
            case .layout:
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: false)
            case .unzoom(_, let closed):
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: false)
                closed?()
            case .other(let answered):
                answered(result)
            }
        }
    }

    /// Where a step's answer took the session, if anywhere: Remux's zoom off the tab left takes it nowhere,
    /// a creation to the pane Herdr made, and a close wherever Herdr shows the session without the place.
    private static func effect(
        of step: HerdrCommandLane.Step,
        _ result: Result<HerdrCommandReply, HerdrCommandError>
    ) -> StepEffect? {
        guard case .success(let reply) = result else { return nil }
        let target: Target
        switch step {
        case .leave, .zoomReached:
            return nil
        case .zoom(let pane, _):
            guard let zoom = try? HerdrPaneZoomResult(reply: reply.json) else { return nil }
            target = .zoom(pane: pane, tabID: zoom.layout.tabID, zoomed: zoom.zoomed)
        case .focus(let place):
            target = .place(place)
        case .create:
            guard let pane = HerdrCreation.pane(madeIn: reply.json) else { return nil }
            target = .made(pane: pane, listed: false)
        case .close(let place, _):
            target = .closed(place)
        }
        return StepEffect(target: target, sentAfter: reply.sentAfter, answeredAfter: reply.answeredAfter)
    }

    /// The lane waits for a snapshot showing the step's effect, unless one already did while it was in
    /// flight or the newest does.
    private func hold(until effect: StepEffect, seen: [HerdrSnapshot]) {
        guard !seen.contains(where: effect.target.isShown(in:)), let snapshot = presentation.snapshot,
              !effect.isSettled(by: snapshot)
        else { return }
        unsettled = effect
    }

    /// A command that doesn't go or can't be answered.
    private func fail(_ command: HerdrCommandLane.Command, _ failure: HerdrCommandError) {
        finish(HerdrCommandLane.InFlight(id: "", item: .command(command), sentAfter: 0), with: .failure(failure))
    }

    /// Records a zoom Herdr applied. Ownership agrees with the snapshots already seen: once one of those
    /// showed the zoom, the newest tells what became of it since, as another client may have undone it; a
    /// snapshot from before the zoom tells nothing yet.
    private func zoomAnswered(
        _ result: Result<HerdrCommandReply, HerdrCommandError>,
        seen: [HerdrSnapshot],
        reportsFailure: Bool
    ) {
        let bootID = presentation.snapshot?.bootID ?? bootID ?? ""
        switch result.flatMap({ reply in
            Result { try HerdrPaneZoomResult(reply: reply.json) }.mapError { HerdrCommandError.failed(code: "invalid_response", message: $0.localizedDescription) }
        }) {
        case .success(let zoom):
            ownedZoom.record(zoom, bootID: bootID)
            if seen.contains(where: { $0.tabs.contains { $0.tabID == zoom.layout.tabID && $0.zoomed == zoom.zoomed } }),
               let snapshot = presentation.snapshot {
                ownedZoom.reconcile(with: snapshot)
            }
            continuation.yield(.zoomAnswered(zoom, bootID: bootID, failure: nil, reportsFailure: reportsFailure, connection: connection))
        case .failure(let failure):
            continuation.yield(.zoomAnswered(nil, bootID: bootID, failure: failure, reportsFailure: reportsFailure, connection: connection))
        }
    }

    /// Once overtaken, the request sends nothing more.
    private func checkOvertaken() {
        guard var request, request.inProgress, !request.overtaken, let snapshot = presentation.snapshot,
              request.isOvertaken(by: snapshot)
        else { return }
        request.overtaken = true
        self.request = request
        lane.dropSteps()
    }

    /// The screen's size changed while a request is in progress: only a frame at the new size completes
    /// it, as Herdr's client drops its evidence on a resize.
    fileprivate func resize(columns: UInt16, rows: UInt16, connection: UInt64) {
        guard connection == self.connection, request?.inProgress == true else { return }
        request?.columns = max(columns, 1)
        request?.rows = max(rows, 1)
        request?.received = nil
    }

    /// Herdr's client checks the pair again at completion: a snapshot that arrived after the received
    /// frame waits for its own frame. The request completes once nothing of its own is left in the lane.
    /// The held completing frame is drawn now, and frames are drawn as they come from then on.
    private func completeIfReady() {
        guard let request, request.inProgress, !lane.hasWork(for: request.id),
              let floor = request.floor, let received = request.received,
              let (snapshot, surface) = presentation.presented,
              surface.projectionRevision == received.projectionRevision,
              received.projectionRevision >= floor,
              received.columns == request.columns, received.rows == request.rows,
              request.admits(snapshot, drawnAs: surface)
        else { return }
        self.request?.completed = true
        self.request?.snapshots.removeAll()
        cancelDeadline()
        draw(surface, snapshot: snapshot)
        continuation.yield(.activated(request: request.id, connection: connection))
    }

    private func startDeadline(for id: UInt64, until due: ContinuousClock.Instant) {
        deadline?.cancel()
        let connection = self.connection
        deadline = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.expire(request: id, connection: connection)
        }
    }

    private func cancelDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    /// The deadline passed: it fires only for the current request, still in progress.
    private func expire(request id: UInt64, connection: UInt64) {
        guard state == .running, connection == self.connection, request?.id == id, request?.inProgress == true
        else { return }
        continuation.yield(.timedOut(request: id, connection: connection))
    }

    fileprivate func receive(_ snapshot: HerdrSnapshot, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        presentation.receive(snapshot)
        lane.record(snapshot)
        ownedZoom.reconcile(with: snapshot)
        unsettled?.note(snapshot)
        if unsettled?.isSettled(by: snapshot) == true { unsettled = nil }
        request?.record(snapshot)
        bordersMayHaveChanged = true
        checkOvertaken()
        paintPresented()
        dispatch()
    }

    fileprivate func receive(_ output: HerdrSurfaceDecoder.Output, connection: UInt64) {
        guard state == .running, connection == self.connection else { return }
        switch output {
        case .surface(let surface):
            images.receive(surface.graphics)
            do {
                try presentation.receive(surface)
            } catch {
                state = .idle
                continuation.yield(.failed(.wire(error), connection: connection))
                return
            }
            bordersMayHaveChanged = true
        case .patch(let patch):
            // A rejected patch leaves the current frame until the next full surface.
            _ = presentation.receive(patch)
        }
        paintPresented()
    }

    /// What `paneID`'s terminal shows of Herdr's pane; nil while it has no terminal.
    func content(ofPane paneID: String) -> HerdrPaneContent? {
        panes[paneID]?.content
    }

    /// A new cell size, from the screen's font or scale: the terminals keep their grids.
    func setCellSize(widthPx: UInt32, heightPx: UInt32) {
        guard state != .stopped, widthPx > 0, heightPx > 0,
              widthPx != cellWidthPx || heightPx != cellHeightPx
        else { return }
        cellWidthPx = widthPx
        cellHeightPx = heightPx
        for (paneID, var pane) in panes {
            let result = pane.producer.resize(
                columns: pane.painted.area.width,
                rows: pane.painted.area.height,
                cellWidthPx: widthPx,
                cellHeightPx: heightPx
            )
            guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
                fail(paneID: paneID)
                continue
            }
            wake(&pane, paneID: paneID)
            panes[paneID] = pane
        }
    }

    /// Ends the engine: nothing is painted or woken again, and every producer is freed. Renderers keep
    /// the terminals they hold until they close.
    func stop() {
        guard state != .stopped else { return }
        state = .stopped
        endRequests()
        panes.removeAll()
        failedPaneIDs.removeAll()
        continuation.finish()
    }

    /// Draws the presented frame unless frames are held; a request in progress takes it as its newest
    /// frame, counted even when no cell changed, since it is the screen Herdr shows now.
    private func paintPresented() {
        guard let (snapshot, surface) = presentation.presented,
              PaintedSurface(of: surface) != paintedSurface
        else { return }
        if !holdsFrames { draw(surface, snapshot: snapshot) }
        if request?.inProgress == true {
            request?.received = (surface.projectionRevision, surface.frame.width, surface.frame.height)
            completeIfReady()
        }
    }

    private func draw(_ surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) {
        paintedSurface = PaintedSurface(of: surface)
        if surface.bootID != bootID {
            // Pane ids belong to one server boot.
            panes.removeAll()
            failedPaneIDs.removeAll()
            bootID = surface.bootID
        }
        let cursor = HerdrPanePainter.paneCursor(of: surface)
        for pane in surface.panes {
            paint(
                HerdrPanePainter.Painted(frame: surface.frame, area: pane.innerRect, cursor: cursor),
                content: HerdrPaneContent(of: pane),
                images: HerdrPaneImages.Scene(surface.graphics, pane: pane),
                paneID: pane.paneID
            )
        }
        let listed = Set(surface.panes.map(\.paneID))
        panes = panes.filter { listed.contains($0.key) }
        failedPaneIDs.formIntersection(listed)
        if bordersMayHaveChanged {
            borders = HerdrBorderLine.lines(in: surface)
            bordersMayHaveChanged = false
        }
        let frame = PresentedFrame(
            bootID: surface.bootID,
            projectionRevision: surface.projectionRevision,
            paneIDs: listed,
            focusedPaneID: surface.panes.first(where: \.focused)?.paneID
        )
        if frame != presentedFrame {
            presentedFrame = frame
            continuation.yield(.presented(
                bootID: frame.bootID,
                projectionRevision: frame.projectionRevision,
                paneIDs: frame.paneIDs,
                focusedPaneID: frame.focusedPaneID,
                connection: connection
            ))
        }
        publishLayout(of: surface, snapshot: snapshot)
        publishScroll(of: surface)
    }

    private func paint(
        _ next: HerdrPanePainter.Painted,
        content: HerdrPaneContent,
        images scene: HerdrPaneImages.Scene,
        paneID: String
    ) {
        let area = next.area
        guard area.width > 0, area.height > 0 else {
            // A pane with no text area has no terminal; it gets a new one when it has room again.
            panes.removeValue(forKey: paneID)
            failedPaneIDs.remove(paneID)
            return
        }
        guard !failedPaneIDs.contains(paneID) else { return }
        guard var pane = panes[paneID] else {
            createPane(paneID: paneID, painted: next, content: content, images: scene)
            return
        }
        let result: ghostty_terminal_producer_result_e
        if pane.painted.area.width == area.width, pane.painted.area.height == area.height {
            let bytes = HerdrPanePainter.update(from: pane.painted, to: next)
                + pane.images.update(to: scene, from: images)
            guard !bytes.isEmpty else {
                pane.painted = next
                pane.content = content
                panes[paneID] = pane
                return
            }
            result = pane.producer.feed(bytes)
        } else {
            pane.images.terminalResized()
            result = pane.producer.resizeAndFeed(
                columns: area.width,
                rows: area.height,
                cellWidthPx: cellWidthPx,
                cellHeightPx: cellHeightPx,
                bytes: HerdrPanePainter.repaint(next) + pane.images.update(to: scene, from: images)
            )
        }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(paneID: paneID)
            return
        }
        pane.painted = next
        pane.content = content
        wake(&pane, paneID: paneID)
        panes[paneID] = pane
    }

    private func createPane(
        paneID: String,
        painted: HerdrPanePainter.Painted,
        content: HerdrPaneContent,
        images scene: HerdrPaneImages.Scene
    ) {
        let producer: any HerdrPaneProducing
        let terminal: HerdrRetainedTerminal
        do {
            producer = try makeProducer(painted.area.width, painted.area.height)
            terminal = try producer.retainTerminal()
        } catch {
            fail(paneID: paneID)
            return
        }
        // The cell size goes in with the first paint, before the terminal is shown.
        var paneImages = HerdrPaneImages()
        let result = producer.resizeAndFeed(
            columns: painted.area.width,
            rows: painted.area.height,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            bytes: HerdrPanePainter.repaint(painted) + paneImages.update(to: scene, from: images)
        )
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(paneID: paneID)
            return
        }
        panes[paneID] = Pane(producer: producer, terminal: terminal, painted: painted, content: content, images: paneImages)
        continuation.yield(.paneTerminal(paneID: paneID, terminal: terminal))
    }

    /// The tab's panes come from the snapshot, which lists a zoomed tab's undrawn panes too, in Herdr's
    /// order; a drawn pane it doesn't list follows them.
    private func publishLayout(of surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) {
        let tab = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }
        var paneIDs = tab.map { tab in snapshot.panes.filter { $0.tabID == tab.tabID }.map(\.paneID) } ?? []
        for pane in surface.panes where !paneIDs.contains(pane.paneID) {
            paneIDs.append(pane.paneID)
        }
        let next = HerdrPaneLayout(
            bootID: surface.bootID,
            tab: tab.map { HerdrPaneLayout.Tab(tabID: $0.tabID, label: $0.label, zoomed: $0.zoomed) },
            columns: surface.frame.width,
            rows: surface.frame.height,
            panes: paneIDs.map { paneID in
                HerdrPaneLayout.Pane(
                    paneID: paneID,
                    innerRect: surface.panes.first { $0.paneID == paneID }?.innerRect,
                    name: Self.name(ofPane: paneID, in: snapshot),
                    path: Self.path(ofPane: paneID, in: snapshot)
                )
            },
            borders: borders,
            hasPopup: surface.popup != nil
        )
        guard next != layout else { return }
        layout = next
        continuation.yield(.layout(next))
    }

    private func publishScroll(of surface: HerdrPaneSurfaceFrame) {
        var next: [String: HerdrPaneScroll] = [:]
        for pane in surface.panes {
            next[pane.paneID] = HerdrPaneScroll(of: pane)
        }
        guard next != paneScrolls else { return }
        paneScrolls = next
        continuation.yield(.paneScroll(next))
    }

    /// The pane's name as Herdr's pane navigator lists it within its tab: its manual label or its
    /// agent's name, else its title, else its agent's kind, else "terminal", numbered by its place
    /// among the tab's panes when the tab has more than one. The navigator also names the tab and, for
    /// a one-pane tab, may name the pane after its tab or workspace; those parts are left out, since
    /// the pane sheet shows one tab. The snapshot carries a title only for an agent's pane.
    private static func name(ofPane paneID: String, in snapshot: HerdrSnapshot) -> String {
        let pane = snapshot.panes.first { $0.paneID == paneID }
        let paneName = pane?.label ?? snapshot.automaticName(ofPane: paneID)
        let tabPanes = pane.map { pane in snapshot.panes.filter { $0.tabID == pane.tabID } } ?? []
        guard tabPanes.count > 1, let index = tabPanes.firstIndex(where: { $0.paneID == paneID }) else {
            return paneName
        }
        return "\(paneName) · \(index + 1)"
    }

    /// The directory of the pane's foreground program, as tmux's current path is, else of its shell.
    private static func path(ofPane paneID: String, in snapshot: HerdrSnapshot) -> String {
        let pane = snapshot.panes.first { $0.paneID == paneID }
        return [pane?.foregroundCWD, pane?.cwd].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private func wake(_ pane: inout Pane, paneID: String) {
        guard let renderer = pane.renderer else { return }
        guard ghostty_terminal_surface_terminal_changed(renderer.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            pane.renderer = nil
            continuation.yield(.rendererWakeFailed(paneID: paneID))
            return
        }
    }

    /// Frees the pane's producer; a renderer over its terminal keeps the last frame Ghostty accepted.
    private func fail(paneID: String) {
        panes.removeValue(forKey: paneID)
        failedPaneIDs.insert(paneID)
        continuation.yield(.paneTerminalFailed(paneID: paneID))
    }

    // MARK: - Renderer registration

    /// Admits a renderer over the pane's current terminal to the engine's wakes. One renderer per pane.
    func register(
        _ surface: HerdrRendererSurface,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) -> Result<Void, HerdrRendererRegistrationError> {
        guard state != .stopped else { return .failure(.engineEnded) }
        guard var pane = panes[paneID], pane.terminal === terminal else { return .failure(.terminalGone) }
        guard pane.renderer == nil else { return .failure(.alreadyRegistered) }
        // A paint between the renderer's creation and now didn't wake it.
        guard ghostty_terminal_surface_terminal_changed(surface.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            return .failure(.rendererWakeFailed)
        }
        pane.renderer = surface
        panes[paneID] = pane
        return .success(())
    }

    /// After this returns, the engine never wakes `surface` again, so its owner may free it.
    func unregister(_ surface: HerdrRendererSurface, paneID: String) {
        guard var pane = panes[paneID], pane.renderer == surface else { return }
        pane.renderer = nil
        panes[paneID] = pane
    }
}

/// The lifetime fence for a renderer over a Herdr pane's terminal: registration and unregistration
/// go through the engine, so an unregistration completes only once no wake of that surface can run.
@MainActor
final class HerdrPaneRendererFence: TerminalPaneRendererFence {
    private let engine: HerdrTerminalEngine
    private let paneID: String
    private let terminal: HerdrRetainedTerminal

    init(engine: HerdrTerminalEngine, paneID: String, terminal: HerdrRetainedTerminal) {
        self.engine = engine
        self.paneID = paneID
        self.terminal = terminal
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, paneID, terminal] in
            let result = await engine.register(surface, paneID: paneID, terminal: terminal)
            completion(result.mapError { $0 as any Error })
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, paneID] in
            await engine.unregister(surface, paneID: paneID)
            completion()
        }
    }
}
