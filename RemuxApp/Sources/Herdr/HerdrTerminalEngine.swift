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

    /// The session's popup, which Herdr sends only to a client on the tab it was opened on. Its grid is
    /// the one Herdr gives this client (`popup_size.rs`): its command's cells or percentage of the
    /// client's area, else half of it each way. The popup's program runs at the grid of the client that
    /// last used the tab, and a client sized otherwise gets as much of that as its own grid holds.
    struct Popup: Equatable, Sendable {
        let terminalID: String
        /// Its terminal's name in Herdr, else "popup", as Herdr's client titles the popup's box.
        let title: String
        let columns: UInt16
        let rows: UInt16
        /// Whether its program reads the mouse.
        var mouseReporting = false
    }

    let bootID: String
    let tab: Tab?
    /// The pane Herdr had focused in the snapshot the frame was drawn against.
    let focusedPaneID: String?
    let columns: UInt16
    let rows: UInt16
    /// The tab's panes in Herdr's order, as the snapshot lists them, also those the frame doesn't draw.
    let panes: [Pane]
    /// The lines Herdr draws around and between the panes, which the crop leaves out of the panes.
    let borders: [HerdrBorderLine]
    /// The popup open over the tab, which Herdr leaves out of a surface too small to box it. It takes the
    /// tab's input meanwhile: Herdr drops pane input from a client on that tab.
    let popup: Popup?

    /// Whether this frame says the popup of terminal `terminalID`, open over tab `tabID`, closed: it is a frame
    /// of that tab, big enough to box a popup in, that doesn't show it. Herdr shows a popup only on the tab it
    /// was opened on (`server/headless/render.rs`), and leaves an open one out of a surface under 6 x 4 cells
    /// (`popup_size.rs` `resolve_popup_geometry`), so no other frame says anything of it.
    func showsClosed(popup terminalID: String, openedOn tabID: String?) -> Bool {
        tab?.tabID == tabID && columns >= 6 && rows >= 4 && popup?.terminalID != terminalID
    }
}

/// A terminal of the tab's, which the engine paints from Herdr's frame and Remux sends input to: a pane's
/// text area, by Herdr's pane id, or the popup's whole frame.
enum HerdrTerminalTarget: Hashable, Sendable {
    case pane(String)
    /// The popup's terminal, by Herdr's terminal id.
    case popup(String)
}

/// How input the engine was asked to send went (`HerdrEngineFeed.send(_:to:)`).
enum HerdrInputSend: Sendable {
    case sent
    /// Herdr wouldn't take it as it arrives, so it didn't go.
    case notTaken
    /// The session isn't shown, and Herdr drops input on a hidden surface.
    case inactive
    case ended
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
    let alternateScreenActive: Bool

    init(of pane: HerdrSurfacePane) {
        revision = pane.contentRevision
        alternateScreenActive = pane.alternateScreenActive
        offsetFromBottom = pane.scroll?.offsetFromBottom
        top = HerdrPaneScroll(of: pane).scrollState.offset
        columns = pane.innerRect.width
        rows = pane.innerRect.height
    }
}

/// What the engine tells its main-actor owner, in order.
enum HerdrEngineUpdate: Sendable {
    case findChanged(TerminalFindPresentation?, connection: UInt64)
    /// A new terminal for a pane, already painted; the owner creates its renderer with a
    /// `HerdrPaneRendererFence`. It replaces an earlier terminal for the same pane, whose renderer the
    /// owner closes.
    case paneTerminal(paneID: String, terminal: HerdrRetainedTerminal)
    /// A frame the engine drew on `connection`, whenever its layout, the snapshot it was drawn against or
    /// its terminals changed: the tab's layout, and that snapshot's revision, whose agents the user sees once
    /// the frame is on screen. Follows the terminals of the new panes and popup it lists.
    case drawn(HerdrPaneLayout, projectionRevision: UInt64, connection: UInt64)
    /// Each listed pane's scrolling, whenever any of it changed. Kept out of the layout because the
    /// history grows with every line a program prints.
    case paneScroll([String: HerdrPaneScroll])
    /// Ghostty couldn't make or paint the pane's terminal. It isn't painted again until the pane leaves
    /// the layout or a new connection begins; a terminal it already had keeps its last frame.
    case paneTerminalFailed(paneID: String)
    /// Waking the pane's renderer failed and its registration is dropped, as for a tmux pane.
    case rendererWakeFailed(paneID: String)
    /// As `paneTerminal`, for the popup open over the tab while its frame is painted (`setPaintsPopup`),
    /// whose renderer the owner creates with a `HerdrPaneRendererFence` for `.popup(terminalID)`.
    case popupTerminal(terminalID: String, terminal: HerdrRetainedTerminal)
    /// As `paneTerminalFailed`, for the popup: it isn't painted again until it closes or a new
    /// connection begins.
    case popupTerminalFailed(terminalID: String)
    /// As `rendererWakeFailed`, for the popup's renderer.
    case popupRendererWakeFailed(terminalID: String)
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
    /// place, a focus or a creation: why it failed, or nil when it worked, and for a creation the pane Herdr
    /// made. Reported only while `request` is current, in order with its other events.
    case answered(request: UInt64, step: HerdrCommandLane.Step, failure: HerdrCommandError?, made: String?, connection: UInt64)
    /// Herdr answered a zoom Remux sent, of a request's step or not: the tab's layout, for the pane
    /// sheet's map, or why it failed or didn't go. `reportsFailure` for the zoom button's, whose
    /// outcome the screen reports.
    case zoomAnswered(HerdrPaneZoomResult?, bootID: String, failure: HerdrCommandError?, reportsFailure: Bool, connection: UInt64)
    /// Herdr refused the show of the current view request `request`, for `reason`.
    case showRefused(request: UInt64, reason: String, connection: UInt64)
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

    /// The connection ended: its commands fail, and an end waiting for Remux's zooms to come off goes.
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

    /// Remux's zooms off as the session ends, before the connection closes, each step within `stepTime`;
    /// `done` once the last is answered, or once none can go (`HerdrTerminalEngine.releaseZooms`).
    func releaseZooms(within stepTime: Duration, done: @escaping @Sendable () -> Void) async {
        await engine.releaseZooms(within: stepTime, done: done, connection: connection)
    }

    func resize(columns: UInt16, rows: UInt16) async {
        await engine.resize(columns: columns, rows: rows, connection: connection)
    }

    /// Input for `target`, sent when Herdr takes it as it arrives (`HerdrTerminalEngine.send(_:to:connection:)`).
    func send(_ events: [HerdrInputEvent], to target: HerdrTerminalTarget) async -> HerdrInputSend {
        await engine.send(events, to: target, connection: connection)
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

/// Which tabs the setting zooms as the session comes to them: a tab with more than one pane that isn't
/// zoomed yet, unless the user unzoomed it with the zoom button. Remux zooms a tab only as the session comes
/// to it, never others ahead: a zoom focuses its target, and a tab's pane focus is shared with every client.
struct HerdrZoomPolicy: Equatable, Sendable {
    var zoomsMultipaneTabs: Bool
    var unzoomedByUser: Set<HerdrTabKey>

    func zooms(_ tabID: String, in snapshot: HerdrSnapshot) -> Bool {
        zoomsMultipaneTabs && snapshot.panes.count(where: { $0.tabID == tabID }) > 1
            && !snapshot.tabs.contains { $0.tabID == tabID && $0.zoomed }
            && !unzoomedByUser.contains(HerdrTabKey(bootID: snapshot.bootID, tabID: tabID))
    }
}

/// Hands each Herdr session's zooms on the phone to one engine at a time, by generation. A session ended and
/// opened again while its end still takes Remux's zooms off has two engines on it, or more when it is opened
/// again once more. Every claim waits for the same stop of the release under way on the engine holding the
/// zooms (`HerdrTerminalEngine.stopRelease`), so nothing is unzoomed under the new attachment, and that engine
/// saves until it has stopped, so a zoom Herdr answers meanwhile is kept. Only the newest claim then holds the
/// zooms, as a newer generation, and reads the record; an engine whose generation is older never saves again.
final class HerdrZoomKeepers: @unchecked Sendable {
    /// A claim on a session's zooms, which saves while no newer claim on the session was made.
    struct Claim: Sendable {
        let session: HerdrSessionAddress
        let generation: UInt64
    }

    private struct Keeping {
        /// The generation of the claim holding the zooms, the one that saves.
        var generation: UInt64 = 0
        /// The newest claim made, which holds the zooms once the stop under way is over.
        var newest: UInt64 = 0
        /// The engine whose claim holds the zooms.
        weak var holder: HerdrTerminalEngine?
        /// The stop of the holder's release, which every claim made meanwhile waits for.
        var stopping: Task<Void, Never>?
    }

    private let store: any HerdrOwnedZoomStore
    private let lock = NSLock()
    private var sessions: [HerdrSessionAddress: Keeping] = [:]

    init(store: any HerdrOwnedZoomStore) {
        self.store = store
    }

    /// A claim on `session`'s zooms for `engine`, and the zooms the phone keeps for it, once the release under
    /// way on the engine holding them has stopped; nil when a newer claim was made meanwhile.
    func claim(_ session: HerdrSessionAddress, for engine: HerdrTerminalEngine) async -> (Claim, HerdrOwnedZooms)? {
        let (generation, stopping) = lock.withLock { () -> (UInt64, Task<Void, Never>?) in
            var keeping = sessions[session] ?? Keeping()
            keeping.newest += 1
            if keeping.stopping == nil, let holder = keeping.holder, holder !== engine {
                keeping.stopping = Task { await holder.stopRelease() }
            }
            sessions[session] = keeping
            return (keeping.newest, keeping.stopping)
        }
        await stopping?.value
        return lock.withLock {
            guard var keeping = sessions[session], keeping.newest == generation else { return nil }
            keeping.generation = generation
            keeping.holder = engine
            keeping.stopping = nil
            sessions[session] = keeping
            return (Claim(session: session, generation: generation), store.zooms(of: session))
        }
    }

    /// Whether `claim` still holds its session's zooms.
    func holds(_ claim: Claim) -> Bool {
        lock.withLock { sessions[claim.session]?.generation == claim.generation }
    }

    /// Saves `zooms` for `claim`'s session while the claim holds its zooms.
    func save(_ zooms: HerdrOwnedZooms, for claim: Claim) {
        lock.withLock {
            guard sessions[claim.session]?.generation == claim.generation else { return }
            store.save(zooms, of: claim.session)
        }
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
        /// show, and on a move from another tab. A move carries on the zoom of the request it took over.
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
        /// How the answered command moves this client's view (`takesInput`).
        let change: ViewChange

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

    /// How a command Remux sends moves the tab Herdr shows this client, which decides the input Herdr takes
    /// (`InputView`).
    fileprivate enum ViewChange {
        /// `pane.focus`, `tab.focus` or `workspace.focus`: the place's tab, its zoom unchanged
        /// (`app/actions.rs` `focus_pane_in_workspace`, `server/headless/client_views.rs`
        /// `apply_shell_navigation_request`).
        case focus(HerdrPlace)
        /// `pane.zoom`, which focuses the pane and then zooms or unzooms its tab, zooming nothing in a tab of
        /// one pane (`app/actions.rs` `apply_pane_zoom`).
        case zoom(pane: String, on: Bool)
        /// The setting's zoom of the tab the steps before it reach, on the pane Herdr focuses there: before
        /// it goes, whether the setting zooms that tab can turn on panes Herdr hasn't made yet.
        case zoomReached(HerdrZoomPolicy)
        /// A split beside the pane, which Herdr focuses in its tab, unzoomed (`workspace/tab.rs`).
        case split(of: String)
        /// The pane closed, its tab unzoomed (`workspace/tab.rs` `detach_pane`), or gone with its last pane.
        case close(String)
        /// A tab or workspace made, or the tab or workspace on screen closed: the tab Herdr shows then is
        /// one Remux can't tell. Also Remux's zooms coming off as the session ends, after which no input goes.
        case elsewhere

        /// The change a lane command makes: the zoom button's zoom, and a step of Remux's zooms coming off. The
        /// layout question zooms the tab as it is, and the other commands move nothing.
        init?(_ command: HerdrCommandLane.Command) {
            switch command.purpose {
            case .zoom(let pane, let zoomed): self = .zoom(pane: pane, on: zoomed)
            case .release: self = .elsewhere
            case .layout, .other, .find: return nil
            }
        }

        /// The change a step sends, where it moves the view.
        init?(sent step: HerdrCommandLane.Step) {
            switch step {
            case .zoom(let pane, _): self = .zoom(pane: pane, on: true)
            case .zoomReached(let policy): self = .zoomReached(policy)
            case .focus(let place): self = .focus(place)
            case .create(.split(let pane, _, _)): self = .split(of: pane)
            case .create: self = .elsewhere
            case .close(.pane(let pane), _): self = .close(pane)
            case .close: self = .elsewhere
            }
        }
    }

    /// The tab Herdr shows this client, as far as Remux can tell, for the input Herdr takes there: any pane
    /// of the tab, or only its focused pane while it is zoomed (`server/headless/client_views.rs`
    /// `shell_client_views_pane`). Panes closed since the snapshot take none.
    fileprivate struct InputView {
        var tabID: String?
        var zoomed: Bool
        /// The tab's focused pane, where Remux can tell it.
        var focusedPane: String?
        var closed: Set<String> = []

        init(_ snapshot: HerdrSnapshot) {
            tabID = snapshot.focusedTabID
            zoomed = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }?.zoomed ?? false
            focusedPane = snapshot.focusedPaneID
        }

        func takes(_ pane: String, in snapshot: HerdrSnapshot) -> Bool {
            guard let tabID, !closed.contains(pane), panes(of: tabID, in: snapshot).contains(pane) else { return false }
            return !zoomed || pane == focusedPane
        }

        /// The view once Herdr applied `change`. A command that fails leaves the view as it was before it,
        /// which input has met already.
        mutating func apply(_ change: ViewChange, in snapshot: HerdrSnapshot) {
            switch change {
            case .focus(.pane(let pane)):
                show(snapshot.panes.first { $0.paneID == pane }?.tabID, focusing: pane, in: snapshot)
            case .focus(.tab(let tab)):
                if tab != tabID { show(tab, focusing: nil, in: snapshot) }
            case .focus(.workspace(let workspace)):
                let tab = snapshot.workspaces.first { $0.workspaceID == workspace }?.activeTabID
                if tab != tabID { show(tab, focusing: nil, in: snapshot) }
            case .zoom(let pane, let on):
                show(snapshot.panes.first { $0.paneID == pane }?.tabID, focusing: pane, in: snapshot)
                zoomed = on && tabID.map { panes(of: $0, in: snapshot).count > 1 } == true
            case .zoomReached(let policy):
                guard let tabID, policy.zoomsMultipaneTabs,
                      !policy.unzoomedByUser.contains(HerdrTabKey(bootID: snapshot.bootID, tabID: tabID))
                else { return }
                zoomed = true
            case .split(let pane):
                show(snapshot.panes.first { $0.paneID == pane }?.tabID, focusing: nil, in: snapshot)
                zoomed = false
            case .close(let pane):
                closed.insert(pane)
                guard let tabID, snapshot.panes.contains(where: { $0.paneID == pane && $0.tabID == tabID }) else { return }
                zoomed = false
                let left = panes(of: tabID, in: snapshot)
                if left.isEmpty { self.tabID = nil }
                if focusedPane == pane || left.count == 1 { focusedPane = left.count == 1 ? left.first : nil }
            case .elsewhere:
                tabID = nil
            }
        }

        private mutating func show(_ tab: String?, focusing pane: String?, in snapshot: HerdrSnapshot) {
            if tab != tabID { zoomed = snapshot.tabs.first { $0.tabID == tab }?.zoomed ?? false }
            tabID = tab
            focusedPane = pane
        }

        private func panes(of tab: String, in snapshot: HerdrSnapshot) -> [String] {
            snapshot.panes.filter { $0.tabID == tab && !closed.contains($0.paneID) }.map(\.paneID)
        }
    }

    /// A `client_shell.surface.set` Herdr hasn't answered, and the reply's chunks so far.
    private struct SurfaceSet {
        /// The show it is, or nil for a hide.
        let show: UInt64?
        var data: [UInt8] = []
    }

    /// Makes a producer for a terminal of the given columns and rows.
    typealias ProducerFactory = @Sendable (_ columns: UInt16, _ rows: UInt16) throws -> any HerdrPaneProducing

    /// One terminal the engine paints, a pane's or the popup's.
    private struct Painting {
        let producer: any HerdrPaneProducing
        /// The terminal handed to the owner; a renderer registers only over this one.
        let terminal: HerdrRetainedTerminal
        /// What the terminal shows: the last paint Ghostty accepted.
        var painted: HerdrPanePainter.Painted
        /// Herdr's pane as of that paint; nil for the popup, whose history Remux doesn't read.
        var content: HerdrPaneContent?
        /// The images the terminal holds and shows, as of that paint. The popup's images aren't drawn.
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
    private var terminals: [HerdrTerminalTarget: Painting] = [:]
    /// Listed terminals Ghostty couldn't make or paint, until the next connection.
    private var failedTerminals: Set<HerdrTerminalTarget> = []
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
    private var find: HerdrFindState?
    private var findBlocksInput = false
    private var findGeneration: UInt64 = 0
    private var findTimer: Task<Void, Never>?
    private var findTimerToken: UInt64 = 0
    private var findEditedAt: ContinuousClock.Instant?
    /// Where the connection's requests go out.
    private var outbox: (any HerdrOutbound)?
    /// The methods the connection's welcome offered, and how long a command may stay unanswered.
    private var methods: Set<String> = []
    private var commandTimeout: Duration = .seconds(60)
    private var commandIDs: UInt64 = 0
    private var surfaceSets: [String: SurfaceSet] = [:]
    /// The tabs Remux zoomed, which it undoes as the session ends. Kept across connections, and on the
    /// phone through `zoomClaim`, so a new connection or a new engine for the session, also after Herdr's
    /// server restarted, undoes them all the same.
    private var ownedZooms = HerdrOwnedZooms()
    /// The engine's claim on the session's zooms (`keepOwnedZooms`), made once.
    private var zoomClaim: (keepers: HerdrZoomKeepers, claim: HerdrZoomKeepers.Claim)?
    private var claimsZooms = false
    /// A newer claim on the session's zooms stopped the release here (`stopRelease`): none starts again.
    private var releaseStopped = false
    /// Remux's zooms coming off as the session ends (`releaseZooms`).
    private var release: Release?
    /// The newest answered step whose effect Herdr's snapshots don't show yet. Herdr can answer before it
    /// sends the snapshot showing the answer, so the next step waits for that snapshot, going from where the
    /// step before it took the session.
    private var unsettled: StepEffect?
    /// The commands Herdr answered whose effect no snapshot shows yet, the steps and the zoom button's zooms, in
    /// the order Herdr applied them, which is the order of their answers, since one command is in flight at a
    /// time. Input that goes now reaches Herdr after them (`takesInput`), and the session's end unzooms nothing
    /// meanwhile (`releaseZooms`).
    private var unshown: [StepEffect] = []
    private var layout: HerdrPaneLayout?
    private var paneScrolls: [String: HerdrPaneScroll] = [:]
    /// Herdr's border lines in the frame painted last. A patch never changes them, since
    /// `HerdrPresentation` takes only patches inside the panes' text areas and scrollbar columns, so
    /// they are read again only once a surface or a snapshot may have changed what is presented.
    private var borders: [HerdrBorderLine] = []
    private var bordersMayHaveChanged = true
    private var paintsPopup = false
    private var paintsPopupRevision: UInt64 = 0
    /// The popup open as the frames drawn last tell, and the tab of the frame that showed it: Herdr sends a
    /// popup only to a client on the tab it was opened on (`server/headless/render.rs`), and takes its input
    /// only from one there (`takesInput`). Only a frame that says it closed forgets it
    /// (`HerdrPaneLayout.showsClosed`).
    private var popupTab: (terminalID: String, tabID: String?)?
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

    // MARK: - Input

    /// Input for `target` goes now, in the connection's order with the lane's commands, when Herdr takes it as
    /// it arrives (`takesInput`); a press's release goes whatever the view, as Herdr takes it there.
    fileprivate func send(_ events: [HerdrInputEvent], to target: HerdrTerminalTarget, connection: UInt64) -> HerdrInputSend {
        guard state == .running, connection == self.connection, let outbox else { return .ended }
        guard outbox.isSurfaceActive else { return .inactive }
        if findBlocksInput, !events.allSatisfy(\.releasesPress) {
            guard case .pane(let paneID) = target, let scroll = paneScrolls[paneID],
                  !scroll.mouseReporting, !scroll.alternateScreenActive,
                  events.allSatisfy(\.isHistoryWheel) else { return .notTaken }
        }
        guard events.allSatisfy(\.releasesPress) || takesInput(target) else { return .notTaken }
        switch target {
        case .pane(let pane):
            outbox.send([.paneInput(paneID: pane, events: events)])
        case .popup(let terminalID):
            outbox.send([.popupInput(terminalID: terminalID, events: events)])
        }
        return .sent
    }

    /// Whether Herdr takes input for `target` that goes now. Herdr applies each command the moment it reads
    /// it, in the connection's order with input (`server/headless/client_views.rs`
    /// `handle_client_shell_api_request`). It drops a pane's input while it doesn't show this client the pane
    /// (`server/headless.rs` `ClientShellPaneInput`), and a popup's while this client isn't on the popup's tab
    /// (`ClientShellPopupInput`, `popup_owner_tab_id`), the tab of the frame that showed it (`popupTab`). The
    /// view input meets is the newest snapshot's, moved by the commands Herdr answered that no snapshot shows
    /// yet, in their order. The commands still to come (`changesToCome`) may fail, which leaves the view as it
    /// was, so input must be taken in each view they lead through. Where Remux can't tell where a command
    /// takes the view, input is refused.
    private func takesInput(_ target: HerdrTerminalTarget) -> Bool {
        guard let snapshot = presentation.snapshot else { return false }
        let takes: (InputView) -> Bool
        switch target {
        case .pane(let pane):
            takes = { $0.takes(pane, in: snapshot) }
        case .popup(let terminalID):
            guard let popupTab, popupTab.terminalID == terminalID, let tabID = popupTab.tabID else { return false }
            takes = { $0.tabID == tabID }
        }
        var view = InputView(snapshot)
        for effect in unshown { view.apply(effect.change, in: snapshot) }
        guard takes(view) else { return false }
        for change in changesToCome {
            view.apply(change, in: snapshot)
            guard takes(view) else { return false }
        }
        return true
    }

    /// The view changes of the commands Herdr hasn't answered, in the order it applies them: the command in
    /// flight unless a snapshot since it went shows its effect, and the current request's steps not yet sent,
    /// which take the session where the user goes.
    private var changesToCome: [ViewChange] {
        var changes = lane.inFlight.flatMap(inFlightChange).map { [$0] } ?? []
        if let request, request.inProgress, !request.overtaken {
            changes += lane.steps.compactMap(ViewChange.init(sent:))
        }
        return changes
    }

    /// The change the command in flight makes, unless a snapshot that came while it was in flight shows its
    /// effect already, as the reply's does (`unsettledEffect`): Herdr applied it, and the newest snapshot tells
    /// what became of it since, as another client may have moved the session on.
    private func inFlightChange(_ inFlight: HerdrCommandLane.InFlight) -> ViewChange? {
        let change: ViewChange?
        switch inFlight.item {
        case .step(_, let step): change = ViewChange(sent: step)
        case .command(let command): change = ViewChange(command)
        }
        guard let change else { return nil }
        let shown = inFlight.snapshots.contains { snapshot in
            switch change {
            case .focus(let place):
                Target.place(place).isShown(in: snapshot)
            case .zoom(let pane, let on):
                snapshot.panes.first { $0.paneID == pane }
                    .map { Target.zoom(pane: pane, tabID: $0.tabID, zoomed: on).isShown(in: snapshot) } ?? false
            case .close(let pane):
                Target.closed(.pane(pane)).isShown(in: snapshot)
            case .zoomReached, .split, .elsewhere:
                false
            }
        }
        return shown ? nil : change
    }

    // MARK: - Find

    func performFind(_ intent: HerdrFindIntent, connection: UInt64) {
        guard self.connection == connection else { return }
        switch intent {
        case .begin(let pane): beginFind(inPane: pane, connection: connection)
        case .query(let query): updateFind(query, connection: connection)
        case .navigate(let step): navigateFind(step, connection: connection)
        case .end: endFind(connection: connection)
        case .resumeInput:
            endFind(connection: connection)
            findBlocksInput = false
        }
    }

    func beginFind(inPane paneID: String, connection: UInt64) {
        guard state == .running, self.connection == connection,
              methods.contains("pane.copy_search"), methods.contains("pane.scroll"),
              let bootID = presentation.snapshot?.bootID else { return }
        endFind()
        findGeneration &+= 1
        findBlocksInput = true
        find = HerdrFindState(paneID: paneID, bootID: bootID, generation: findGeneration)
        publishFind()
    }

    func updateFind(_ query: String, connection: UInt64) {
        guard self.connection == connection, var find, query != find.query else { return }
        cancelFindTimer(); lane.dropWaitingFind()
        findGeneration &+= 1
        find.generation = findGeneration; find.query = query
        find.invalidate(); find.needsReveal = true; find.direction = 1
        find.retryAvailable = true; find.waitingRevision = nil; find.waitsForQuiet = false; find.isDue = false
        self.find = find; findEditedAt = .now
        if query.utf8.count > 4096 {
            self.find?.presentation.status = "Query too long"
        } else if !query.isEmpty {
            scheduleFind(after: .milliseconds(120))
        }
        repaintFind(); publishFind()
    }

    func navigateFind(_ step: Int, connection: UInt64) {
        guard self.connection == connection, var find, let result = find.result,
              result.total > 0, let current = find.desiredIndex, step == 1 || step == -1 else { return }
        cancelFindTimer(); lane.dropWaitingFind()
        find.desiredIndex = step > 0 ? (current == result.total - 1 ? 0 : current + 1)
            : (current == 0 ? result.total - 1 : current - 1)
        find.direction = step; find.needsReveal = true; find.retryAvailable = true
        find.origin = find.selectedRange?.start ?? find.origin
        find.showResult(); self.find = find; findEditedAt = .now
        repaintFind(); publishFind(); advanceFind()
    }

    func endFind(connection: UInt64? = nil) {
        guard connection == nil || connection == self.connection else { return }
        cancelFindTimer(); lane.dropWaitingFind()
        guard find != nil else { return }
        find = nil; findEditedAt = nil
        repaintFind(); publishFind()
    }

    private func publishFind() {
        continuation.yield(.findChanged(find?.presentation, connection: connection))
    }

    private func cancelFindTimer() {
        findTimerToken &+= 1; findTimer?.cancel(); findTimer = nil
    }

    private func scheduleFind(after delay: Duration) {
        cancelFindTimer()
        let token = findTimerToken
        findTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.findTimerFired(token)
        }
    }

    private func findTimerFired(_ token: UInt64) {
        guard token == findTimerToken, find != nil else { return }
        findTimer = nil
        if let revision = find?.waitingRevision, let pane = find?.paneID,
           content(ofPane: pane)?.revision == revision { return }
        find?.isDue = true
        advanceFind()
    }

    private func queueFind(_ intent: HerdrFindCommand) {
        lane.dropWaitingFind()
        lane.append(HerdrCommandLane.Command(method: intent.method, params: [String: String](), purpose: .find(intent)))
    }

    /// Revision-dependent parameters are materialized only when the serial lane can send them.
    private func prepareFindCommand(_ intent: HerdrFindCommand) -> HerdrCommandLane.Command? {
        guard var find, intent.generation == find.generation else { return nil }
        guard !holdsFrames,
              layout?.focusedPaneID == find.paneID, layout?.popup == nil,
              let content = content(ofPane: find.paneID) else {
            self.find?.isDue = true
            return nil
        }
        switch intent {
        case .search:
            guard !find.query.isEmpty, find.query.utf8.count <= 4096 else { return nil }
            guard content.revision.isMultiple(of: 2) else {
                self.find?.waitingRevision = content.revision
                return nil
            }
            if find.origin == nil { find.origin = HerdrFindPoint(row: UInt32(clamping: content.top), col: 0) }
            let request = find.request(for: content)
            find.content = content; find.isDue = false
            self.find = find
            GhosttyRuntimeTrace.perf("find.request generation=\(find.generation) bytes=\(find.query.utf8.count) revision=\(content.revision)")
            return HerdrCommandLane.Command(method: intent.method, params: request,
                purpose: .find(.search(generation: find.generation, request: request, content: content)))
        case .reveal:
            guard let result = find.result, result.content_revision == content.revision,
                  let range = find.selectedRange,
                  let scroll = paneScrolls[find.paneID] else { return nil }
            let targetTop = UInt64(range.start.row).subtractingReportingOverflow(UInt64(content.rows / 3))
            let top = targetTop.overflow ? 0 : targetTop.partialValue
            let offset = scroll.maxLinesFromBottom - min(top, scroll.maxLinesFromBottom)
            find.needsReveal = false; self.find = find
            struct Params: Encodable, Sendable { let pane_id: String; let offset_from_bottom: UInt64 }
            return HerdrCommandLane.Command(method: intent.method,
                params: Params(pane_id: find.paneID, offset_from_bottom: offset), purpose: .find(intent))
        }
    }

    private func advanceFind() {
        guard var find, !find.query.isEmpty, find.query.utf8.count <= 4096, !holdsFrames else { return }
        if case .command(let command)? = lane.inFlight?.item,
           case .find(let intent) = command.purpose, intent.generation == find.generation { return }
        if let range = find.selectedRange, find.needsReveal,
           let content = content(ofPane: find.paneID), find.result?.content_revision == content.revision {
            if UInt64(range.start.row) >= content.top, UInt64(range.start.row) < content.top + UInt64(content.rows) {
                find.needsReveal = false; self.find = find
                traceFindCommit()
            } else {
                queueFind(.reveal(generation: find.generation)); dispatch()
            }
        } else if find.result != nil, find.selected == nil, find.desiredIndex != nil {
            queueFind(.search(generation: find.generation, request: nil, content: nil)); dispatch()
        } else if find.isDue {
            self.find?.isDue = false
            queueFind(.search(generation: find.generation, request: nil, content: nil)); dispatch()
        }
    }

    private func findAnswered(_ intent: HerdrFindCommand, result answer: Result<HerdrCommandReply, HerdrCommandError>) {
        guard var find, find.generation == intent.generation else { return }
        switch intent {
        case .reveal:
            if case .failure = answer {
                find.needsReveal = false
                find.presentation.status = "Couldn’t show match"; self.find = find; publishFind()
            } else {
                traceFindCommit()
                // Navigation can replace the destination while a sent scroll drains.
                advanceFind()
            }
        case .search(_, let request?, let source?):
            do {
                let reply = try answer.get()
                let result = try HerdrFindResult.decode(reply.json, request: request, columns: source.columns)
                guard let current = content(ofPane: find.paneID), current.revision == source.revision,
                      current.columns == source.columns, current.rows == source.rows,
                      current.alternateScreenActive == source.alternateScreenActive
                else { staleFind(revision: source.revision); return }
                find.result = result; find.content = current
                if find.desiredIndex == nil {
                    // (0,0) has no predecessor in the unsigned API. Its returned
                    // window can still contain that exact, freshly matched anchor.
                    find.desiredIndex = result.matches.firstIndex(where: { $0.start == find.origin })
                        .map { result.windowStart + $0 } ?? result.current_global
                }
                find.origin = find.selectedRange?.start ?? find.origin
                find.waitingRevision = nil; find.waitsForQuiet = false; find.isDue = false
                find.showResult(); self.find = find
                repaintFind(); publishFind(); advanceFind()
            } catch HerdrCommandError.failed(code: "stale_content", message: _) {
                staleFind(revision: source.revision)
            } catch {
                find.presentation = TerminalFindPresentation(status: "Search failed")
                self.find = find; publishFind()
            }
        case .search:
            break
        }
    }

    private func staleFind(revision: UInt64) {
        guard var find else { return }
        find.invalidate(); find.waitingRevision = revision; find.isDue = false
        if find.retryAvailable { find.retryAvailable = false }
        else { find.waitsForQuiet = true; scheduleFind(after: .milliseconds(200)) }
        self.find = find
        repaintFind(); publishFind()
        if !find.waitsForQuiet, let content = content(ofPane: find.paneID),
           content.revision != revision, content.revision.isMultiple(of: 2) {
            self.find?.waitingRevision = nil; self.find?.isDue = true
            advanceFind()
        }
    }

    /// Called before the matching terminal paint; invalid ranges never reach the new frame.
    private func reconcileFind(with surface: HerdrPaneSurfaceFrame) {
        guard var find else { return }
        let previousPresentation = find.presentation
        guard find.bootID == surface.bootID, surface.popup == nil else { endFind(); return }
        guard let pane = surface.panes.first(where: { $0.paneID == find.paneID }), pane.focused else {
            if request?.inProgress != true { endFind() }
            return
        }
        let content = HerdrPaneContent(of: pane)
        let resized = find.content.map { $0.columns != content.columns || $0.rows != content.rows } ?? false
        let changed = resized || (find.content.map { $0.revision != content.revision
            || $0.alternateScreenActive != content.alternateScreenActive } ?? true)
        let remapped = find.content.map { $0.columns != content.columns
            || $0.alternateScreenActive != content.alternateScreenActive } ?? true
        if find.origin == nil || remapped { find.origin = HerdrFindPoint(row: UInt32(clamping: content.top), col: 0) }
        if changed, find.result != nil {
            find.invalidate(); find.needsReveal = false; find.waitsForQuiet = true
        }
        // A smaller viewport can hide the active hit. Re-find it at the new
        // geometry before revealing; output-only refreshes keep the reading position.
        if resized { find.needsReveal = true }
        find.content = content; self.find = find
        if changed, find.waitsForQuiet { scheduleFind(after: .milliseconds(200)) }
        if let old = find.waitingRevision, old != content.revision,
           content.revision.isMultiple(of: 2), !find.waitsForQuiet {
            self.find?.waitingRevision = nil; self.find?.isDue = true
        }
        if find.presentation != previousPresentation { publishFind() }
    }

    private func repaintFind() {
        for target in terminals.keys {
            guard case .pane(let paneID) = target, var painting = terminals[target] else { continue }
            var next = painting.painted
            next.find = find?.paneID == paneID ? HerdrFindDecoration(find: find, content: painting.content) : nil
            guard next.find != painting.painted.find else { continue }
            let bytes = HerdrPanePainter.update(from: painting.painted, to: next)
            guard painting.producer.feed(bytes) == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else { fail(target); continue }
            painting.painted = next; wake(&painting, target: target); terminals[target] = painting
        }
    }

    /// Producer commit timing; the renderer presents the resulting frame separately.
    private func traceFindCommit() {
        guard let find, let range = find.selectedRange, let content = content(ofPane: find.paneID),
              find.result?.content_revision == content.revision,
              UInt64(range.start.row) >= content.top, UInt64(range.start.row) < content.top + UInt64(content.rows)
        else { return }
        if let start = findEditedAt {
            GhosttyRuntimeTrace.perf("find.committed generation=\(find.generation) elapsed=\(start.duration(to: .now))")
            findEditedAt = nil
        }
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
        failedTerminals.removeAll()
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
        endFind()
        cancelDeadline()
        outbox = nil
        surfaceSets.removeAll()
        unsettled = nil
        unshown.removeAll()
        let (inFlight, waiting) = lane.takeAll()
        if case .command(let command)? = inFlight?.item { fail(command, .connectionEnded) }
        waiting.forEach { fail($0, .connectionEnded) }
        endRelease()
    }

    // MARK: - Showing

    /// Frames are drawn as they come, except while hidden and during a view request. Frames Herdr sends
    /// as a hide goes out show what leaving did, so the frame from before the hide stays until the next
    /// show; and a show's frame from before its zoom would flash the unzoomed tab, as a move's would flash
    /// the tab reached unzoomed, so a request draws only the frame that completes it.
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
    /// where Herdr has the session. None starts once the session's end takes Remux's zooms off.
    @discardableResult
    fileprivate func start(_ view: HerdrView, within deadline: Duration, connection: UInt64) -> UInt64? {
        guard state == .running, connection == self.connection, let outbox, release == nil else { return nil }
        endFind()
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

    /// The steps that take the session to `destination`. The tab left keeps its zoom, Remux's included, as
    /// tmux's windows do. For a pane: the setting's zoom of its tab when the request zooms, which takes the
    /// session there, then the pane's focus, which marks its tab's agents seen, as Herdr's client goes to a
    /// pane. A tab or workspace shows a pane the snapshot doesn't name before the session is there, so its
    /// focus goes first and the setting's zoom follows on the pane it shows. A creation's command goes, and
    /// the setting's zoom follows on the pane it made whether or not the request zooms, since Herdr gives its
    /// tab a new pane. A close of what is on screen goes, and the setting's zoom follows on the tab Herdr
    /// shows then: Herdr unzooms a tab it takes a pane from (`workspace/tab.rs` `detach_pane`). The setting
    /// zooms only a tab not zoomed yet (`HerdrZoomPolicy`). A place the session is at already still gets its
    /// focus.
    private func plan(
        to destination: HerdrDestination,
        zooms: Bool,
        policy: HerdrZoomPolicy,
        in snapshot: HerdrSnapshot?
    ) -> [HerdrCommandLane.Step] {
        switch destination {
        case .place(let place):
            var steps: [HerdrCommandLane.Step] = []
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
            return [.create(creation), .zoomReached(policy)]
        case .closing(let place, let group):
            return [.close(place, group: group), .zoomReached(policy)]
        }
    }

    /// Hides the session at once: the request in progress ends, its steps not yet sent don't go, and the
    /// commands waiting fail, since Herdr refuses commands from a hidden session. Remux's zooms stay, as
    /// tmux's do while the session is off screen, so the leave sends nothing first. Focus goes before the
    /// hide, while still active: deactivation keeps the stored focus, so without it the next show's focus
    /// would be ignored.
    private func hide(outbox: any HerdrOutbound, snapshot: HerdrSnapshot?) {
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

    /// A command for the lane, which goes in the lane's order; none goes once the session's end takes
    /// Remux's zooms off.
    fileprivate func enqueue(_ command: HerdrCommandLane.Command, connection: UInt64) {
        guard state == .running, connection == self.connection else { return fail(command, .connectionEnded) }
        guard release == nil else { return fail(command, .notSent) }
        lane.append(command)
        dispatch()
    }

    // MARK: - Zoom ownership

    /// The phone keeps Remux's zooms of `session`, which `keepers` hands to one engine at a time: the engine
    /// claims them once, takes over those kept for the session once the release under way on the engine holding
    /// them has stopped, checks them against each snapshot (`HerdrOwnedZooms.reconcile`), and saves every change
    /// while its claim is the newest.
    func keepOwnedZooms(of session: HerdrSessionAddress, from keepers: HerdrZoomKeepers) async {
        guard state != .stopped, !claimsZooms else { return }
        claimsZooms = true
        guard let (claim, zooms) = await keepers.claim(session, for: self), state != .stopped else { return }
        zoomClaim = (keepers, claim)
        ownedZooms = zooms
    }

    /// A newer claim on the session's zooms (`HerdrZoomKeepers`) stops the release under way: it sends no more
    /// unzooms, finishes the step in flight, goes back to the tab it started on, and ends; this returns once it
    /// has.
    fileprivate func stopRelease() async {
        releaseStopped = true
        guard release != nil else { return }
        if release?.stopping == nil { release?.stopping = [] }
        dispatch()
        if release != nil {
            await withCheckedContinuation { release?.stopping?.append($0) }
        }
    }

    private func updateOwnedZooms(_ change: (inout HerdrOwnedZooms) -> Void) {
        let before = ownedZooms
        change(&ownedZooms)
        guard ownedZooms != before, let zoomClaim else { return }
        zoomClaim.keepers.save(ownedZooms, for: zoomClaim.claim)
    }

    /// Remux's zooms coming off as the session ends, one tab at a time: a tab off screen is focused first,
    /// since the snapshot names only the focused tab's focused pane, and the unzoom names that pane, so it
    /// reaches only its tab (`app/api/panes.rs` `resolve_optional_pane`); a pane gone meanwhile is refused.
    /// Herdr's unzoom focuses its target (`app/actions.rs` `apply_pane_zoom`), so a focus another client made
    /// in that tab during the round trip goes back to the pane the snapshot showed. The tab on screen at the
    /// start goes last, and the release ends there: Herdr's next client starts where this one leaves its view
    /// (`server/headless.rs`, `ClientShellLocation::from_snapshot`), since each command moves Herdr's default
    /// to this client's view (`server/headless/client_views.rs` `set_default_shell_target_from_client`). The
    /// focus moves only this client's view (`apply_shell_navigation_request`), though Herdr sends its focus
    /// events for each tab visited (`send_shell_navigation_focus_events`).
    private struct Release {
        /// The tabs left, in order, from the release's start: once the lane is free and the newest snapshot
        /// shows where the last step took the session.
        var tabs: [String]?
        /// The tab on screen as the release starts, where it ends.
        var start: String?
        /// Whether Herdr's answers may have left this client's view on another tab than `start`.
        var away = false
        /// Whether the focus back to `start` went, the release's last step.
        var returning = false
        /// Whether Herdr refused the focus back as busy, still handling a step the release gave up on; it goes
        /// again once Herdr is free (`retryFocusBack`).
        var backRefused = false
        /// The tab focused for its unzoom, until a snapshot shows the session there.
        var focusing: String?
        /// Once a newer claim on the session's zooms stops the release, the claims waiting for it to end
        /// (`stopRelease`).
        var stopping: [CheckedContinuation<Void, Never>]?
        /// Herdr's time for each step, from the ask or Herdr's answer before it.
        let stepTime: Duration
        /// Names the newest step's time, so an older one's end is dropped.
        var step: UInt64 = 0
        var deadline: Task<Void, Never>?
        let done: @Sendable () -> Void
    }

    /// Takes Remux's zooms off as the session ends. Nothing else goes from here on: the steps and commands not
    /// sent yet are dropped. A command in flight goes first, since Herdr takes one command at a time, and the
    /// release waits for the snapshots showing the commands Herdr answered, since it goes over the tabs a
    /// snapshot shows zoomed, from where the session is. A hidden session's surface is made active first,
    /// without focus, since Herdr takes commands only from an active one (`endpoint_requests.rs`). Each step has
    /// `stepTime`, Herdr's time for a show, from the ask or Herdr's answer before it; one that takes longer
    /// leaves the zooms left, with the phone's record of them, and the release goes on to its focus back to the
    /// tab it started on. The connection's end ends it at once. An engine a newer claim on the zooms stopped, or
    /// replaced, takes nothing off (`HerdrZoomKeepers`). `done` once the release has ended, or at once when
    /// nothing goes.
    fileprivate func releaseZooms(within stepTime: Duration, done: @escaping @Sendable () -> Void, connection: UInt64) {
        guard state == .running, connection == self.connection, outbox != nil, release == nil, !releaseStopped,
              zoomClaim.map({ $0.keepers.holds($0.claim) }) ?? true,
              methods.contains(HerdrScreenModel.paneZoomMethod),
              !ownedZooms.tabIDs.isEmpty || lane.inFlight?.item.method == HerdrScreenModel.paneZoomMethod
        else { return done() }
        lane.dropSteps()
        lane.takeWaiting().forEach { fail($0, .notSent) }
        release = Release(stepTime: stepTime, done: done)
        startReleaseStep()
        dispatch()
    }

    /// The release's next command against Herdr's newest snapshot, with the lane free: the unzoom of the tab
    /// the session is on, or the focus of the next tab. Each tab is checked again as its turn comes
    /// (`releases`): one no longer Remux's is skipped, also the one being focused, whose snapshot may then
    /// never come. Once a newer claim stops it, only the focus back goes (`finishRelease`).
    private func advanceRelease(outbox: any HerdrOutbound, in snapshot: HerdrSnapshot) {
        guard var release else { return }
        if release.returning {
            guard release.backRefused else { return endRelease() }
            return
        }
        guard release.stopping == nil else { return finishRelease(in: snapshot) }
        guard unshown.isEmpty else { return }
        if release.tabs == nil {
            let tabs = ownedZooms.tabsToRelease(in: snapshot)
            release.tabs = tabs
            release.start = snapshot.focusedTabID
            if !tabs.isEmpty, request.map({ $0.kind == .hide }) ?? true,
               let message = surfaceSet(active: true, show: nil, in: snapshot) {
                outbox.send([message])
                outbox.setSurfaceActive(true)
            }
        }
        if let focusing = release.focusing {
            guard snapshot.focusedTabID == focusing || !releases(focusing, in: snapshot) else {
                self.release = release
                return
            }
            release.focusing = nil
        }
        while let tab = release.tabs?.first {
            guard releases(tab, in: snapshot) else {
                release.tabs?.removeFirst()
                continue
            }
            let command: HerdrCommandLane.Command
            if snapshot.focusedTabID == tab {
                release.tabs?.removeFirst()
                guard let pane = snapshot.focusedPaneID else { continue }
                command = HerdrCommandLane.Command(
                    method: HerdrScreenModel.paneZoomMethod,
                    params: HerdrScreenModel.zoomParams(pane, zoomed: false),
                    purpose: .release(.unzoom(tabID: tab))
                )
            } else {
                let place = HerdrPlace.tab(tab)
                guard methods.contains(place.focusMethod) else {
                    release.tabs?.removeFirst()
                    continue
                }
                release.focusing = tab
                command = HerdrCommandLane.Command(
                    method: place.focusMethod,
                    params: place.focusParams,
                    purpose: .release(.focus(tabID: tab))
                )
            }
            self.release = release
            send(.command(command), params: command.params, in: snapshot)
            return
        }
        self.release = release
        finishRelease(in: snapshot)
    }

    /// The release's last step: the focus back to the tab it started on, when Herdr's answers may have left
    /// this client's view on another, with a step's time of its own whatever came before; then its end.
    private func finishRelease(in snapshot: HerdrSnapshot) {
        guard var release, release.away, !release.returning, release.start != nil, lane.isIdle else {
            return endRelease()
        }
        release.returning = true
        self.release = release
        startReleaseStep()
        sendFocusBack(in: snapshot)
    }

    /// The focus back to the tab the release started on (`finishRelease`).
    private func sendFocusBack(in snapshot: HerdrSnapshot) {
        guard let start = release?.start, methods.contains(HerdrPlace.tab(start).focusMethod) else {
            return endRelease()
        }
        let place = HerdrPlace.tab(start)
        let back = HerdrCommandLane.Command(
            method: place.focusMethod,
            params: place.focusParams,
            purpose: .release(.back(tabID: start))
        )
        send(.command(back), params: back.params, in: snapshot)
    }

    /// Herdr answered a command Remux had given up on, which frees it for the next
    /// (`server/headless/endpoint_requests.rs`, `shell_endpoint_command_in_flight`): a focus back it refused as
    /// busy meanwhile goes again, within its step's time.
    private func retryFocusBack() {
        guard var release, release.backRefused, lane.isIdle, let snapshot = presentation.snapshot else { return }
        release.backRefused = false
        self.release = release
        sendFocusBack(in: snapshot)
    }

    /// Whether the release takes the zoom off `tab`: the snapshot has it zoomed, and Remux's record still has
    /// it, which each snapshot keeps in step with Herdr's tabs (`HerdrOwnedZooms.reconcile`), so a zoom another
    /// client made again on the tab isn't taken off.
    private func releases(_ tab: String, in snapshot: HerdrSnapshot) -> Bool {
        ownedZooms.tabIDs.contains(tab) && snapshot.tabs.contains { $0.tabID == tab && $0.zoomed }
    }

    /// Herdr answered the release's focus of `tab`: one that went took this client's view there, and one that
    /// failed leaves that tab's zoom.
    private func releaseFocusAnswered(_ tab: String, failed: Bool) {
        guard var release else { return }
        if !failed {
            release.away = tab != release.start
        } else if release.focusing == tab {
            release.focusing = nil
            release.tabs?.removeAll { $0 == tab }
        }
        self.release = release
    }

    /// The release's next step has Herdr's time for a show from now.
    private func startReleaseStep() {
        guard var release else { return }
        release.step += 1
        release.deadline?.cancel()
        let step = release.step
        let connection = self.connection
        release.deadline = Task { [weak self, stepTime = release.stepTime] in
            try? await Task.sleep(for: stepTime)
            guard !Task.isCancelled else { return }
            await self?.releaseStepExpired(step, connection: connection)
        }
        self.release = release
    }

    /// A step's time passed, while it is the newest step's: the release goes on to its focus back, giving up
    /// the step of its own in flight, whose answer is dropped and whose focus may have taken the view away; it
    /// ends once the focus back's time passes too.
    private func releaseStepExpired(_ step: UInt64, connection: UInt64) {
        guard connection == self.connection, var release, release.step == step else { return }
        guard !release.returning, let snapshot = presentation.snapshot else { return endRelease() }
        if let inFlight = lane.inFlight, case .command(let command) = inFlight.item,
           case .release(let given) = command.purpose, let expired = lane.expire(inFlight.id) {
            if case .focus = given { release.away = true }
            self.release = release
            finish(expired, with: .failure(.timedOut(method: command.method)))
        }
        finishRelease(in: snapshot)
    }

    private func endRelease() {
        guard let release else { return }
        self.release = nil
        release.deadline?.cancel()
        release.stopping?.forEach { $0.resume() }
        release.done()
    }

    /// The one place a command is let go: whenever the lane is free, its next item goes, in the lane's
    /// order, if it may go now against Herdr's newest snapshot. This runs in the same turn as the start,
    /// answer, timeout or snapshot that made it due, so nothing changes between the check and the send. A
    /// step goes from where the step before it took the session, so it waits for the snapshot showing that.
    /// Once the session's end takes Remux's zooms off, only the release's commands go.
    private func dispatch() {
        guard state == .running, lane.isIdle, let outbox, let snapshot = presentation.snapshot else { return }
        guard release == nil else { return advanceRelease(outbox: outbox, in: snapshot) }
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
                if case .find(let intent) = command.purpose {
                    guard let prepared = prepareFindCommand(intent) else { continue }
                    item = .command(prepared)
                    params = prepared.params
                } else {
                    params = command.params
                }
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

    /// What a step sends against Herdr's newest snapshot, as it goes, or nil when it doesn't go. The setting's
    /// zoom goes only while its pane's tab isn't zoomed, as another client may have zoomed it since the step was
    /// planned, and a show's goes while the pane it zooms is still focused; the zoom of a tab reached goes as a
    /// show's zoom of the pane Herdr focused there, while the snapshot shows the request's target and the
    /// setting zooms that tab; a step that takes the session somewhere goes as long as the request isn't
    /// overtaken.
    private func command(
        for step: HerdrCommandLane.Step,
        of request: ViewRequest,
        in snapshot: HerdrSnapshot
    ) -> (HerdrCommandLane.Step, any Encodable & Sendable)? {
        switch step {
        case .zoom(let pane, let navigates):
            let tabID = snapshot.panes.first { $0.paneID == pane }?.tabID
            guard navigates || snapshot.focusedPaneID == pane,
                  !snapshot.tabs.contains(where: { $0.tabID == tabID && $0.zoomed })
            else { return nil }
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
        case .release, .other, .find:
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
        guard let (inFlight, data) = lane.receive(chunk) else {
            if chunk.isFinal { retryFocusBack() }
            return
        }
        // A step of the session's end has its time from Herdr's answer before it.
        startReleaseStep()
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
            if let effect, let held = unsettledEffect(effect, seen: inFlight.snapshots) {
                unsettled = held
                unshown.append(held)
            }
            guard var request, request.id == id, request.inProgress else { return }
            switch (step, result) {
            case (.zoomReached, _):
                break
            case (.zoom, .success), (.create, .success), (.close, .success):
                if !step.isZoom {
                    var made: String?
                    if case .made(let pane, _)? = effect?.target { made = pane }
                    continuation.yield(.answered(request: id, step: step, failure: nil, made: made, connection: connection))
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
                continuation.yield(.answered(request: id, step: step, failure: nil, made: nil, connection: connection))
                request.answer = (reply.sentAfter, reply.answeredAfter)
            case (.focus(let place), .failure(let failure)):
                continuation.yield(.answered(request: id, step: step, failure: failure, made: nil, connection: connection))
                // The session stays where Herdr has it.
                if request.target == .place(place) { request.target = nil }
            case (.create, .failure(let failure)), (.close, .failure(let failure)):
                // Nothing was made or closed; the session stays where Herdr has it.
                continuation.yield(.answered(request: id, step: step, failure: failure, made: nil, connection: connection))
                request.target = nil
            }
            self.request = request
            checkOvertaken()
            completeIfReady()
        case .command(let command):
            switch command.purpose {
            case .zoom(let pane, _):
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: true)
                if case .success(let reply) = result, let zoom = try? HerdrPaneZoomResult(reply: reply.json),
                   let effect = unsettledEffect(StepEffect(
                       target: .zoom(pane: pane, tabID: zoom.layout.tabID, zoomed: zoom.zoomed),
                       sentAfter: reply.sentAfter,
                       answeredAfter: reply.answeredAfter,
                       change: .zoom(pane: pane, on: zoom.zoomed)
                   ), seen: inFlight.snapshots) {
                    unshown.append(effect)
                }
            case .layout:
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: false)
            case .release(.focus(let tab)):
                releaseFocusAnswered(tab, failed: (try? result.get()) == nil)
            case .release(.unzoom):
                zoomAnswered(result, seen: inFlight.snapshots, reportsFailure: false)
                // The pane named may have moved to another tab meanwhile, which the unzoom then took the view to.
                if var release, case .success(let reply) = result, let zoom = try? HerdrPaneZoomResult(reply: reply.json) {
                    release.away = zoom.layout.tabID != release.start
                    self.release = release
                }
            case .release(.back):
                if case .failure(.failed(code: "endpoint_busy", _)) = result { release?.backRefused = true }
            case .find(let intent):
                findAnswered(intent, result: result)
            case .other(let answered):
                answered(result)
            }
        }
    }

    /// Where a step's answer took the session, if anywhere: a creation to the pane Herdr made, and a close
    /// wherever Herdr shows the session without the place.
    private static func effect(
        of step: HerdrCommandLane.Step,
        _ result: Result<HerdrCommandReply, HerdrCommandError>
    ) -> StepEffect? {
        guard case .success(let reply) = result else { return nil }
        let target: Target
        switch step {
        case .zoomReached:
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
        guard let change = ViewChange(sent: step) else { return nil }
        return StepEffect(target: target, sentAfter: reply.sentAfter, answeredAfter: reply.answeredAfter, change: change)
    }

    /// `effect`, unless a snapshot that came while its command was in flight, or the newest, shows it. The lane
    /// waits for a step's effect that no snapshot shows yet (`unsettled`).
    private func unsettledEffect(_ effect: StepEffect, seen: [HerdrSnapshot]) -> StepEffect? {
        guard !seen.contains(where: effect.target.isShown(in:)), let snapshot = presentation.snapshot,
              !effect.isSettled(by: snapshot)
        else { return nil }
        return effect
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
            updateOwnedZooms { owned in
                owned.record(zoom)
                if seen.contains(where: { $0.tabs.contains { $0.tabID == zoom.layout.tabID && $0.zoomed == zoom.zoomed } }),
                   let snapshot = presentation.snapshot {
                    owned.reconcile(with: snapshot)
                }
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
        updateOwnedZooms { $0.reconcile(with: snapshot) }
        unsettled?.note(snapshot)
        if unsettled?.isSettled(by: snapshot) == true { unsettled = nil }
        for index in unshown.indices { unshown[index].note(snapshot) }
        unshown.removeAll { $0.isSettled(by: snapshot) }
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
        terminals[.pane(paneID)]?.content
    }

    /// A new cell size, from the screen's font or scale: the terminals keep their grids.
    func setCellSize(widthPx: UInt32, heightPx: UInt32) {
        guard state != .stopped, widthPx > 0, heightPx > 0,
              widthPx != cellWidthPx || heightPx != cellHeightPx
        else { return }
        cellWidthPx = widthPx
        cellHeightPx = heightPx
        for (target, var painting) in terminals {
            let result = painting.producer.resize(
                columns: painting.painted.area.width,
                rows: painting.painted.area.height,
                cellWidthPx: widthPx,
                cellHeightPx: heightPx
            )
            guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
                fail(target)
                continue
            }
            wake(&painting, target: target)
            terminals[target] = painting
        }
    }

    /// Ends the engine: nothing is painted or woken again, and every producer is freed. Renderers keep
    /// the terminals they hold until they close.
    func stop() {
        guard state != .stopped else { return }
        state = .stopped
        endRequests()
        terminals.removeAll()
        failedTerminals.removeAll()
        continuation.finish()
    }

    /// Whether the popup's frame is painted into a terminal of its own, as Herdr sends it to this client: only
    /// while the popup can't be attached, since an attached popup comes in a stream of its own. Turned on,
    /// it paints the frame on screen. Only a newer `revision` than the last applies, since the owner's calls
    /// may arrive out of order.
    func setPaintsPopup(_ paints: Bool, revision: UInt64) {
        guard state != .stopped, revision > paintsPopupRevision else { return }
        paintsPopupRevision = revision
        guard paints != paintsPopup else { return }
        paintsPopup = paints
        if paints {
            if !holdsFrames, let (_, surface) = presentation.presented { paintPopup(of: surface) }
        } else {
            terminals = terminals.filter { if case .popup = $0.key { false } else { true } }
            failedTerminals = failedTerminals.filter { if case .popup = $0 { false } else { true } }
        }
    }

    /// The popup's terminal shows its whole frame, which is the popup's text area.
    private func paintPopup(of surface: HerdrPaneSurfaceFrame) {
        guard paintsPopup, let popup = surface.popup else { return }
        let whole = HerdrSurfaceRect(x: 0, y: 0, width: popup.frame.width, height: popup.frame.height)
        _ = paint(
            HerdrPanePainter.Painted(frame: popup.frame, area: whole, cursor: popup.frame.cursor),
            content: nil,
            images: HerdrPaneImages.Scene(),
            target: .popup(popup.terminalID)
        )
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
            // Pane and terminal ids belong to one server boot.
            terminals.removeAll()
            failedTerminals.removeAll()
            popupTab = nil
            bootID = surface.bootID
        }
        reconcileFind(with: surface)
        let cursor = HerdrPanePainter.paneCursor(of: surface)
        var madeTerminal = false
        for pane in surface.panes {
            let made = paint(
                HerdrPanePainter.Painted(
                    frame: surface.frame, area: pane.innerRect, cursor: cursor,
                    find: find?.paneID == pane.paneID ? HerdrFindDecoration(find: find, content: HerdrPaneContent(of: pane)) : nil
                ),
                content: HerdrPaneContent(of: pane),
                images: HerdrPaneImages.Scene(surface.graphics, pane: pane),
                target: .pane(pane.paneID)
            )
            madeTerminal = madeTerminal || made
        }
        paintPopup(of: surface)
        let listed = Set(surface.panes.map(\.paneID))
        var shown = Set(listed.map(HerdrTerminalTarget.pane))
        if paintsPopup, let popup = surface.popup { shown.insert(.popup(popup.terminalID)) }
        terminals = terminals.filter { shown.contains($0.key) }
        failedTerminals.formIntersection(shown)
        if bordersMayHaveChanged {
            borders = HerdrBorderLine.lines(in: surface)
            bordersMayHaveChanged = false
        }
        let frame = PresentedFrame(bootID: surface.bootID, projectionRevision: surface.projectionRevision, paneIDs: listed)
        let next = layout(of: surface, snapshot: snapshot)
        if let popup = next.popup {
            popupTab = (popup.terminalID, next.tab?.tabID)
        } else if let popupTab, next.showsClosed(popup: popupTab.terminalID, openedOn: popupTab.tabID) {
            self.popupTab = nil
        }
        if madeTerminal || next != layout || frame != presentedFrame {
            layout = next
            presentedFrame = frame
            continuation.yield(.drawn(next, projectionRevision: surface.projectionRevision, connection: connection))
        }
        publishScroll(of: surface)
        advanceFind()
        traceFindCommit()
    }

    /// Returns whether the target got a new terminal.
    private func paint(
        _ next: HerdrPanePainter.Painted,
        content: HerdrPaneContent?,
        images scene: HerdrPaneImages.Scene,
        target: HerdrTerminalTarget
    ) -> Bool {
        let area = next.area
        guard area.width > 0, area.height > 0 else {
            // A pane with no text area has no terminal; it gets a new one when it has room again.
            terminals.removeValue(forKey: target)
            failedTerminals.remove(target)
            return false
        }
        guard !failedTerminals.contains(target) else { return false }
        guard var painting = terminals[target] else {
            return create(target, painted: next, content: content, images: scene)
        }
        let result: ghostty_terminal_producer_result_e
        if painting.painted.area.width == area.width, painting.painted.area.height == area.height {
            let bytes = HerdrPanePainter.update(from: painting.painted, to: next)
                + painting.images.update(to: scene, from: images)
            guard !bytes.isEmpty else {
                painting.painted = next
                painting.content = content
                terminals[target] = painting
                return false
            }
            result = painting.producer.feed(bytes)
        } else {
            painting.images.terminalResized()
            result = painting.producer.resizeAndFeed(
                columns: area.width,
                rows: area.height,
                cellWidthPx: cellWidthPx,
                cellHeightPx: cellHeightPx,
                bytes: HerdrPanePainter.repaint(next) + painting.images.update(to: scene, from: images)
            )
        }
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(target)
            return false
        }
        painting.painted = next
        painting.content = content
        wake(&painting, target: target)
        terminals[target] = painting
        return false
    }

    /// Returns whether the target got its terminal.
    private func create(
        _ target: HerdrTerminalTarget,
        painted: HerdrPanePainter.Painted,
        content: HerdrPaneContent?,
        images scene: HerdrPaneImages.Scene
    ) -> Bool {
        let producer: any HerdrPaneProducing
        let terminal: HerdrRetainedTerminal
        do {
            producer = try makeProducer(painted.area.width, painted.area.height)
            terminal = try producer.retainTerminal()
        } catch {
            fail(target)
            return false
        }
        // The cell size goes in with the first paint, before the terminal is shown.
        var terminalImages = HerdrPaneImages()
        let result = producer.resizeAndFeed(
            columns: painted.area.width,
            rows: painted.area.height,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            bytes: HerdrPanePainter.repaint(painted) + terminalImages.update(to: scene, from: images)
        )
        guard result == GHOSTTY_TERMINAL_PRODUCER_RESULT_OK else {
            fail(target)
            return false
        }
        terminals[target] = Painting(
            producer: producer,
            terminal: terminal,
            painted: painted,
            content: content,
            images: terminalImages
        )
        switch target {
        case .pane(let paneID): continuation.yield(.paneTerminal(paneID: paneID, terminal: terminal))
        case .popup(let terminalID): continuation.yield(.popupTerminal(terminalID: terminalID, terminal: terminal))
        }
        return true
    }

    /// The tab's panes come from the snapshot, which lists a zoomed tab's undrawn panes too, in Herdr's
    /// order; a drawn pane it doesn't list follows them.
    private func layout(of surface: HerdrPaneSurfaceFrame, snapshot: HerdrSnapshot) -> HerdrPaneLayout {
        let tab = snapshot.tabs.first { $0.tabID == snapshot.focusedTabID }
        var paneIDs = tab.map { tab in snapshot.panes.filter { $0.tabID == tab.tabID }.map(\.paneID) } ?? []
        for pane in surface.panes where !paneIDs.contains(pane.paneID) {
            paneIDs.append(pane.paneID)
        }
        return HerdrPaneLayout(
            bootID: surface.bootID,
            tab: tab.map { HerdrPaneLayout.Tab(tabID: $0.tabID, label: $0.label, zoomed: $0.zoomed) },
            focusedPaneID: snapshot.focusedPaneID,
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
            popup: surface.popup.map {
                HerdrPaneLayout.Popup(
                    terminalID: $0.terminalID,
                    title: $0.title,
                    columns: $0.frame.width,
                    rows: $0.frame.height,
                    mouseReporting: $0.mouseReporting
                )
            }
        )
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

    private func wake(_ painting: inout Painting, target: HerdrTerminalTarget) {
        guard let renderer = painting.renderer else { return }
        guard ghostty_terminal_surface_terminal_changed(renderer.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            painting.renderer = nil
            switch target {
            case .pane(let paneID): continuation.yield(.rendererWakeFailed(paneID: paneID))
            case .popup(let terminalID): continuation.yield(.popupRendererWakeFailed(terminalID: terminalID))
            }
            return
        }
    }

    /// Frees the terminal's producer; a renderer over its terminal keeps the last frame Ghostty accepted.
    private func fail(_ target: HerdrTerminalTarget) {
        terminals.removeValue(forKey: target)
        failedTerminals.insert(target)
        switch target {
        case .pane(let paneID): continuation.yield(.paneTerminalFailed(paneID: paneID))
        case .popup(let terminalID): continuation.yield(.popupTerminalFailed(terminalID: terminalID))
        }
    }

    // MARK: - Renderer registration

    /// Admits a renderer over the target's current terminal to the engine's wakes. One renderer per
    /// terminal.
    func register(
        _ surface: HerdrRendererSurface,
        for target: HerdrTerminalTarget,
        terminal: HerdrRetainedTerminal
    ) -> Result<Void, HerdrRendererRegistrationError> {
        guard state != .stopped else { return .failure(.engineEnded) }
        guard var painting = terminals[target], painting.terminal === terminal else { return .failure(.terminalGone) }
        guard painting.renderer == nil else { return .failure(.alreadyRegistered) }
        // A paint between the renderer's creation and now didn't wake it.
        guard ghostty_terminal_surface_terminal_changed(surface.handle) == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            return .failure(.rendererWakeFailed)
        }
        painting.renderer = surface
        terminals[target] = painting
        return .success(())
    }

    func register(
        _ surface: HerdrRendererSurface,
        paneID: String,
        terminal: HerdrRetainedTerminal
    ) -> Result<Void, HerdrRendererRegistrationError> {
        register(surface, for: .pane(paneID), terminal: terminal)
    }

    /// After this returns, the engine never wakes `surface` again, so its owner may free it.
    func unregister(_ surface: HerdrRendererSurface, from target: HerdrTerminalTarget) {
        guard var painting = terminals[target], painting.renderer == surface else { return }
        painting.renderer = nil
        terminals[target] = painting
    }

    func unregister(_ surface: HerdrRendererSurface, paneID: String) {
        unregister(surface, from: .pane(paneID))
    }
}

/// The lifetime fence for a renderer over a terminal the engine paints, a pane's or the popup's:
/// registration and unregistration go through the engine, so an unregistration completes only once no
/// wake of that surface can run.
@MainActor
final class HerdrPaneRendererFence: TerminalPaneRendererFence {
    private let engine: HerdrTerminalEngine
    private let target: HerdrTerminalTarget
    private let terminal: HerdrRetainedTerminal

    init(engine: HerdrTerminalEngine, target: HerdrTerminalTarget, terminal: HerdrRetainedTerminal) {
        self.engine = engine
        self.target = target
        self.terminal = terminal
    }

    convenience init(engine: HerdrTerminalEngine, paneID: String, terminal: HerdrRetainedTerminal) {
        self.init(engine: engine, target: .pane(paneID), terminal: terminal)
    }

    func registerRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, target, terminal] in
            let result = await engine.register(surface, for: target, terminal: terminal)
            completion(result.mapError { $0 as any Error })
        }
    }

    func unregisterRenderer(
        _ surface: ghostty_terminal_surface_t,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let surface = HerdrRendererSurface(handle: surface)
        Task { [engine, target] in
            await engine.unregister(surface, from: target)
            completion()
        }
    }
}
