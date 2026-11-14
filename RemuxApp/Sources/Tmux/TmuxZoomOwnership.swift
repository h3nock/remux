import Foundation

/// Remux records each zoom it makes on the zoomed window, as the tmux user
/// option `@remux-zoom-owner`, so a reconnect or an app restart can tell its
/// own zooms from anyone else's and still release them. The owner is the saved
/// server's id: stable on this install, different on every other device.
///
/// The native client pairs exactly one reply block with each command, so these
/// are plain commands (never `if-shell`, whose nested commands add blocks).
/// What each one decides is a `set-option -F` format, which tmux evaluates when
/// the command runs, so the server decides from the window as it is then.
struct TmuxZoomOwner: Equatable, Sendable {
    static let optionName = "@remux-zoom-owner"

    let id: String

    init(serverID: UUID) {
        id = serverID.uuidString
    }

    /// Sent ahead of a zoom: marks the window as this owner's only if the
    /// zoom that follows creates it, that is the window is not zoomed yet and
    /// has a pane to zoom.
    func claimCommand(windowID: TmuxWindowID) -> String {
        let option = Self.optionName
        return "set-option -F -w -t @\(windowID.rawValue) \(option) "
            + "'#{?#{||:#{window_zoomed_flag},#{==:#{window_panes},1}},#{\(option)},\(id)}'"
    }

    /// Clears the window's mark only if it is this owner's and the window is
    /// not zoomed, so a zoom claimed after the decision to forget keeps its
    /// mark.
    func forgetCommand(windowID: TmuxWindowID) -> String {
        let option = Self.optionName
        return "set-option -F -w -t @\(windowID.rawValue) \(option) "
            + "'#{?#{&&:#{==:#{\(option)},\(id)},#{!=:#{window_zoomed_flag},1}},,#{\(option)}}'"
    }

    /// The window's zoom and mark as tmux has them when it runs, in the line
    /// shape of `marksQuery`.
    func readbackCommand(windowID: TmuxWindowID) -> String {
        "display-message -p -t @\(windowID.rawValue) '#{window_id} #{window_zoomed_flag} #{\(Self.optionName)}'"
    }

    static let marksQuery = "list-windows -F '#{window_id} #{window_zoomed_flag} #{\(optionName)}'"

    /// Parses a `marksQuery` or readback reply. Lines that are not
    /// `@id flag [owner]` are skipped.
    func marks(fromQueryReply reply: String) -> [TmuxZoomMark] {
        reply.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  fields[0].first == "@",
                  let rawWindowID = UInt64(fields[0].dropFirst()),
                  fields[1] == "0" || fields[1] == "1"
            else { return nil }
            let owner = fields.count == 3 ? String(fields[2]) : ""
            return TmuxZoomMark(
                windowID: TmuxWindowID(rawWindowID),
                zoomed: fields[1] == "1",
                isOwn: owner == id
            )
        }
    }
}

struct TmuxZoomMark: Equatable, Sendable {
    let windowID: TmuxWindowID
    let zoomed: Bool
    /// The window carries this owner's mark.
    let isOwn: Bool
}

/// Every command line Remux sends that changes a window's zoom, one window per
/// line: once one member fails tmux skips the rest of its line, so a line that
/// spanned windows would leave the others alone after one closed.
///
/// `resize-pane -Z` toggles, which goes wrong when another client, or one of
/// Remux's own earlier commands, changed the window first. A bare
/// `resize-pane -t T` only ever unzooms, so `resize-pane -t T ; resize-pane -Z
/// -t T` ends zoomed on T's pane from any start state, and does nothing to a
/// window with one pane; no other client's command runs between members of
/// one line. Without an owner the claim, forget and readback members are left
/// out.
struct TmuxZoomCommands: Sendable {
    let owner: TmuxZoomOwner?

    /// One command line for one window.
    struct Group: Equatable, Sendable {
        let windowID: TmuxWindowID
        let commands: [String]
        /// The last member reads the window's zoom and mark back.
        let readsBack: Bool
        /// The line claims the zoom it may create for this owner.
        let claims: Bool
        /// Whether the window is zoomed once tmux has run the line; nil for a
        /// line that leaves its zoom as it is.
        let endsZoomed: Bool?
    }

    enum SplitForm: Sendable {
        /// The window was zoomed; tmux unzooms it to split, so the new pane is
        /// zoomed in its place.
        case keepingZoom
        /// The window had one pane and the zoom default is on: the new pane,
        /// which the split makes active, is zoomed.
        case creatingZoom
    }

    /// Zooms `paneID`, or the window's active pane when it is nil.
    func ensureZoomed(windowID: TmuxWindowID, paneID: TmuxPaneID? = nil) -> Group {
        let target = paneID.map { "%\($0.rawValue)" } ?? "@\(windowID.rawValue)"
        return group(
            windowID,
            claiming: true,
            ["resize-pane -t \(target)", "resize-pane -Z -t \(target)"],
            endsZoomed: true
        )
    }

    func ensureUnzoomed(windowID: TmuxWindowID) -> Group {
        group(windowID, ["resize-pane -t @\(windowID.rawValue)"], forgetting: true, endsZoomed: false)
    }

    /// Asks tmux to drop this owner's mark if its zoom is gone; nil without an
    /// owner, which keeps no marks.
    func forgetAndReadback(windowID: TmuxWindowID) -> Group? {
        guard owner != nil else { return nil }
        return group(windowID, [], forgetting: true, endsZoomed: nil)
    }

    func split(_ splitCommand: String, windowID: TmuxWindowID, form: SplitForm) -> Group {
        let rezoom = ["resize-pane -t @\(windowID.rawValue)", "resize-pane -Z -t @\(windowID.rawValue)"]
        switch form {
        case .keepingZoom:
            return Group(
                windowID: windowID,
                commands: [splitCommand] + rezoom,
                readsBack: false,
                claims: false,
                endsZoomed: true
            )
        case .creatingZoom:
            return group(windowID, leading: [splitCommand], claiming: true, rezoom, endsZoomed: true)
        }
    }

    /// Closes a pane of a zoomed window and zooms the pane tmux makes active,
    /// if any is left; with one left the zoom is gone and its mark forgotten.
    func closePaneOfZoomedWindow(
        paneID: TmuxPaneID,
        windowID: TmuxWindowID,
        leavesSeveralPanes: Bool
    ) -> Group {
        group(
            windowID,
            leading: ["kill-pane -t %\(paneID.rawValue)"],
            ["resize-pane -t @\(windowID.rawValue)", "resize-pane -Z -t @\(windowID.rawValue)"],
            forgetting: true,
            endsZoomed: leavesSeveralPanes
        )
    }

    private func group(
        _ windowID: TmuxWindowID,
        leading: [String] = [],
        claiming: Bool = false,
        _ commands: [String],
        forgetting: Bool = false,
        endsZoomed: Bool?
    ) -> Group {
        guard let owner else {
            return Group(
                windowID: windowID,
                commands: leading + commands,
                readsBack: false,
                claims: false,
                endsZoomed: endsZoomed
            )
        }
        return Group(
            windowID: windowID,
            commands: leading
                + (claiming ? [owner.claimCommand(windowID: windowID)] : [])
                + commands
                + (forgetting ? [owner.forgetCommand(windowID: windowID)] : [])
                + [owner.readbackCommand(windowID: windowID)],
            readsBack: true,
            claims: claiming,
            endsZoomed: endsZoomed
        )
    }
}

/// Which windows the multi-pane zoom default changes: each window once while
/// it has more than one pane, unless the user chose its zoom.
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

    /// - Parameters:
    ///   - zoomingWindowIDs: windows with a zoom command line still
    ///     unanswered, whose zoom the topology may not show yet.
    ///   - afterSettingChange: the user just changed the default, which goes
    ///     to those windows at once whatever the topology shows. Otherwise
    ///     they wait, unresolved, for a topology that follows their answer.
    mutating func windowIDsNeedingChange(
        in topology: TmuxSessionController.TopologySnapshot,
        zoomingWindowIDs: Set<TmuxWindowID> = [],
        afterSettingChange: Bool = false
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
            let zooming = zoomingWindowIDs.contains(window.id)
            if zooming, !afterSettingChange { continue }

            resolvedWindowIDs.insert(window.id)
            if zooming || window.zoomed != isEnabled {
                targets.append(window.id)
            }
        }
        return targets
    }

    mutating func recordWindowChoice(_ windowID: TmuxWindowID) {
        resolvedWindowIDs.insert(windowID)
    }
}
