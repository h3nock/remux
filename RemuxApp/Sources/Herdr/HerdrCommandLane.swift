import Foundation

/// The one command lane of a Herdr connection. Herdr runs one endpoint command at a time for a client and
/// refuses another while one is in flight (`server/headless/endpoint_requests.rs` `endpoint_busy`), so
/// every command Remux sends waits here, and the engine, which owns the lane, decides what goes next in
/// the same turn as the answer or snapshot that frees it.
///
/// The order is one rule: the current view request's steps first, in order; then every other command (a
/// selection read, a link question, the zoom button, the pane sheet's layout question) in the order asked.
/// A request that replaces another drops only the steps that one hadn't sent; the other commands still go.
/// A step waiting for the snapshot that shows where the step before it took the session holds the lane.
/// `client_shell.surface.set` isn't a command here: Herdr answers it even while a command is in flight
/// (`endpoint_requests.rs` checks for it before `endpoint_busy`).
struct HerdrCommandLane {
    /// A step of the current view request. The engine decides what each sends, if anything, as it goes.
    enum Step: Equatable, Sendable {
        /// The setting's zoom of the pane's tab. `navigates` for a move's, which takes the session to the
        /// pane: Herdr's zoom focuses its target (`actions.rs` `apply_pane_zoom`). A show's zooms the pane
        /// already focused.
        case zoom(String, navigates: Bool)
        /// The setting's zoom of the tab the step before it took the session to, on the pane Herdr has
        /// focused there: the snapshot doesn't say which pane a tab or workspace shows before the session
        /// is there, nor which pane a creation makes. It goes as a show's zoom once decided.
        case zoomReached(HerdrZoomPolicy)
        /// The place focused, with Herdr's client's command for it. A pane's also marks its tab's agents
        /// seen (`api/panes.rs` `handle_pane_focus`), as Herdr's client goes to a pane.
        case focus(HerdrPlace)
        /// A new tab, workspace or split pane, which Herdr focuses.
        case create(HerdrCreation)
        /// The close of the workspace on screen, the tab on screen or one of its panes; Herdr shows the
        /// session where it is then. `group` closes a worktree group's root with its linked worktrees.
        case close(HerdrPlace, group: Bool)

        /// Whether the step is a `pane.zoom`: the setting's zoom, or the zoom of a tab reached.
        var isZoom: Bool {
            switch self {
            case .zoom, .zoomReached: true
            case .focus, .create, .close: false
            }
        }

        var method: String {
            switch self {
            case .zoom, .zoomReached: HerdrScreenModel.paneZoomMethod
            case .focus(let place): place.focusMethod
            case .create(let creation): creation.method
            case .close(let place, _): place.closeMethod
            }
        }
    }

    /// A command other than a view request's step, and what it is for.
    struct Command: Sendable {
        enum Purpose {
            /// The zoom button's zoom of `pane`, whose failure the screen reports. It goes only while no
            /// request is in progress and `pane` is focused, since a zoom focuses its pane.
            case zoom(pane: String, zoomed: Bool)
            /// The pane sheet's question for the layout of `pane`'s zoomed tab: the zoom the tab has, which
            /// changes nothing and answers with the layout. It goes as the zoom button's does, and only while
            /// the tab is still zoomed, since another client may have unzoomed it meanwhile and the question
            /// would zoom it again for everyone.
            case layout(pane: String)
            /// A step of Remux's zooms coming off as the session ends (`HerdrTerminalEngine.releaseZooms`). It
            /// goes with the lane free, and nothing else goes from the release's start.
            case release(ReleaseStep)
            /// Anything else, whose caller gets its answer; it goes only while the session is shown.
            case other(answered: @Sendable (Result<HerdrCommandReply, HerdrCommandError>) -> Void)
            case find(HerdrFindCommand)
        }

        /// A step of Remux's zooms coming off as the session ends.
        enum ReleaseStep: Equatable {
            /// The focus of the tab `tabID`, off screen, for its unzoom.
            case focus(tabID: String)
            /// The unzoom of the tab `tabID`, on the pane the snapshot shows focused there.
            case unzoom(tabID: String)
            /// The focus back to the tab `tabID` the session was on as the release started, its last step.
            case back(tabID: String)
        }

        let method: String
        let params: any Encodable & Sendable
        let purpose: Purpose
    }

    enum Item {
        case step(request: UInt64, Step)
        case command(Command)

        var method: String {
            switch self {
            case .step(_, let step): step.method
            case .command(let command): command.method
            }
        }
    }

    /// The command Herdr is answering, and the reply's chunks so far.
    struct InFlight {
        let id: String
        let item: Item
        /// The newest snapshot's revision when it went out.
        let sentAfter: UInt64
        var data: [UInt8] = []
        /// The snapshots that came while it was in flight.
        var snapshots: [HerdrSnapshot] = []
    }

    /// The current view request's steps not yet sent.
    private(set) var steps: [Step] = []
    private var stepsRequest: UInt64?
    private var waiting: [Command] = []
    private(set) var inFlight: InFlight?

    var isIdle: Bool { inFlight == nil }

    /// Whether `request` has a step waiting or in flight.
    func hasWork(for request: UInt64) -> Bool {
        if stepsRequest == request, !steps.isEmpty { return true }
        if case .step(request, _)? = inFlight?.item { return true }
        return false
    }

    /// The steps of a new current request; the previous request's unsent steps don't go.
    mutating func replaceSteps(_ steps: [Step], for request: UInt64) {
        self.steps = steps
        stepsRequest = request
    }

    /// The current request sends nothing more.
    mutating func dropSteps() {
        steps.removeAll()
    }

    mutating func append(_ command: Command) {
        waiting.append(command)
    }

    /// Find has one replaceable unsent intent. Sent requests still drain normally.
    mutating func dropWaitingFind() {
        waiting.removeAll { if case .find = $0.purpose { true } else { false } }
    }

    /// The other commands waiting, which won't go: Herdr refuses commands from a hidden session.
    mutating func takeWaiting() -> [Command] {
        defer { waiting.removeAll() }
        return waiting
    }

    /// The next item in the lane's order; nil when nothing waits.
    var next: Item? {
        if let request = stepsRequest, let step = steps.first { return .step(request: request, step) }
        return waiting.first.map(Item.command)
    }

    /// Takes the next item out of line.
    mutating func removeNext() {
        if stepsRequest != nil, !steps.isEmpty {
            steps.removeFirst()
        } else if !waiting.isEmpty {
            waiting.removeFirst()
        }
    }

    mutating func sent(_ item: Item, id: String, after revision: UInt64) {
        inFlight = InFlight(id: id, item: item, sentAfter: revision)
    }

    mutating func record(_ snapshot: HerdrSnapshot) {
        inFlight?.snapshots.append(snapshot)
    }

    /// A chunk of the reply to the command in flight; the whole reply once its last chunk is in, which
    /// frees the lane. A chunk of any other request is dropped, as a late reply to a command that timed
    /// out.
    mutating func receive(_ chunk: HerdrResponseChunk) -> (InFlight, [UInt8])? {
        guard var current = inFlight, current.id == chunk.requestID else { return nil }
        current.data += chunk.data
        guard chunk.isFinal else {
            inFlight = current
            return nil
        }
        inFlight = nil
        return (current, current.data)
    }

    /// The command in flight, retired when it times out; nil when it was answered first.
    mutating func expire(_ id: String) -> InFlight? {
        guard let current = inFlight, current.id == id else { return nil }
        inFlight = nil
        return current
    }

    /// A reply as Herdr sends it (`{"id", "result"}`), or the failure it carries.
    static func result(of data: [UInt8]) -> Result<Data, HerdrCommandError> {
        struct Failure: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
            }

            let error: Body?
        }
        let json = Data(data)
        if let failure = try? JSONDecoder().decode(Failure.self, from: json), let error = failure.error {
            return .failure(.failed(code: error.code, message: error.message))
        }
        return .success(json)
    }

    /// Everything in the lane, emptied when the connection ends.
    mutating func takeAll() -> (inFlight: InFlight?, waiting: [Command]) {
        defer {
            inFlight = nil
            steps.removeAll()
            stepsRequest = nil
            waiting.removeAll()
        }
        return (inFlight, waiting)
    }
}
