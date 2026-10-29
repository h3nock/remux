import Foundation

/// A place in a Herdr session that Remux takes this phone to, with the command Herdr's client sends for
/// it: a pane (`pane.focus`), a tab (`tab.focus`), or a workspace, which shows the tab this phone last
/// had there (`workspace.focus`).
enum HerdrPlace: Hashable, Sendable {
    case pane(String)
    case tab(String)
    case workspace(String)

    var focusMethod: String {
        switch self {
        case .pane: HerdrScreenModel.paneFocusMethod
        case .tab: "tab.focus"
        case .workspace: "workspace.focus"
        }
    }

    var focusParams: [String: String] {
        switch self {
        case .pane(let id): ["pane_id": id]
        case .tab(let id): ["tab_id": id]
        case .workspace(let id): ["workspace_id": id]
        }
    }

    /// What a failed move says it couldn't do.
    var focusFailureLabel: String {
        switch self {
        case .pane: "select pane"
        case .tab: "select tab"
        case .workspace: "select workspace"
        }
    }

    var closeMethod: String {
        switch self {
        case .pane: "pane.close"
        case .tab: "tab.close"
        case .workspace: "workspace.close"
        }
    }

    var renameMethod: String {
        switch self {
        case .pane: "pane.rename"
        case .tab: "tab.rename"
        case .workspace: "workspace.rename"
        }
    }

    var closeFailureLabel: String {
        switch self {
        case .pane: "close pane"
        case .tab: "close tab"
        case .workspace: "close workspace"
        }
    }

    var renameFailureLabel: String {
        switch self {
        case .pane: "rename pane"
        case .tab: "rename tab"
        case .workspace: "rename workspace"
        }
    }

    /// Herdr's client's close of the place; a workspace's says whether it closes its worktree group.
    func closeParams(group: Bool) -> HerdrPlaceParams {
        guard case .workspace = self else { return HerdrPlaceParams(place: self) }
        return HerdrPlaceParams(place: self, closeGroup: group)
    }

    func renameParams(_ name: String) -> HerdrPlaceParams {
        HerdrPlaceParams(place: self, label: name)
    }
}

/// The params of a close or rename: the place's id under its own key, and what else the command takes.
struct HerdrPlaceParams: Encodable, Equatable, Sendable {
    let place: HerdrPlace
    var closeGroup: Bool?
    var label: String?

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case closeGroup = "close_group"
        case label
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch place {
        case .pane(let id): try container.encode(id, forKey: .paneID)
        case .tab(let id): try container.encode(id, forKey: .tabID)
        case .workspace(let id): try container.encode(id, forKey: .workspaceID)
        }
        try container.encodeIfPresent(closeGroup, forKey: .closeGroup)
        try container.encodeIfPresent(label, forKey: .label)
    }
}

/// A pane Remux asks Herdr to make, in a new tab, a new workspace or beside a pane, focused as Herdr's
/// client makes them (`tab.create`, `workspace.create`, `pane.split`). Herdr's answer names the pane.
enum HerdrCreation: Equatable, Sendable {
    /// A tab in the workspace.
    case tab(workspaceID: String)
    /// A workspace whose pane starts in a directory Herdr's settings take from `source`'s focused pane.
    case workspace(source: String?)
    /// A pane beside `pane` in its tab, as Herdr's client splits the focused pane of its workspace.
    case split(pane: String, workspaceID: String?, direction: SplitDirection)

    enum SplitDirection: String, Encodable, Sendable {
        case right
        case down
    }

    var method: String {
        switch self {
        case .tab: "tab.create"
        case .workspace: "workspace.create"
        case .split: "pane.split"
        }
    }

    var params: Params {
        switch self {
        case .tab(let workspaceID):
            Params(workspaceID: workspaceID)
        case .workspace(let source):
            Params(sourceWorkspaceID: source)
        case .split(let pane, let workspaceID, let direction):
            Params(workspaceID: workspaceID, targetPaneID: pane, direction: direction)
        }
    }

    var failureLabel: String {
        switch self {
        case .tab: "new tab"
        case .workspace: "new workspace"
        case .split: "split pane"
        }
    }

    /// The place on the tab the new pane goes in, when that tab is there already: a split's pane. New
    /// Tab and New Workspace make their tab.
    var tabPlace: HerdrPlace? {
        guard case .split(let pane, _, _) = self else { return nil }
        return .pane(pane)
    }

    /// The pane Herdr made, from its answer (`api/schema/response.rs`): the first pane of a new tab or
    /// workspace (`root_pane`), or a split's (`pane`).
    static func pane(madeIn reply: Data) -> String? {
        struct Reply: Decodable {
            struct Result: Decodable {
                let rootPane: Pane?
                let pane: Pane?

                private enum CodingKeys: String, CodingKey {
                    case rootPane = "root_pane"
                    case pane
                }
            }

            struct Pane: Decodable {
                let paneID: String

                private enum CodingKeys: String, CodingKey {
                    case paneID = "pane_id"
                }
            }

            let result: Result
        }
        guard let result = try? JSONDecoder().decode(Reply.self, from: reply).result else { return nil }
        return (result.rootPane ?? result.pane)?.paneID
    }

    struct Params: Encodable, Sendable {
        var workspaceID: String?
        var sourceWorkspaceID: String?
        var targetPaneID: String?
        var direction: SplitDirection?
        let focus = true

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case sourceWorkspaceID = "source_workspace_id"
            case targetPaneID = "target_pane_id"
            case direction
            case focus
        }
    }
}

/// Where Remux takes a Herdr session: a place there already, the pane a creation makes, or where Herdr
/// shows the session once a place on screen closes.
enum HerdrDestination: Equatable, Sendable {
    case place(HerdrPlace)
    case creation(HerdrCreation)
    /// The close of the workspace on screen, the tab on screen or one of its panes (`HerdrRequest.close`);
    /// `group` closes a worktree group's root with its linked worktrees.
    case closing(HerdrPlace, group: Bool)

    /// The place it names, which must still be on the server for it to go: the place, the workspace or
    /// pane a creation starts from, or the place a close closes.
    var origin: HerdrPlace? {
        switch self {
        case .place(let place), .closing(let place, _): place
        case .creation(.tab(let workspaceID)): .workspace(workspaceID)
        case .creation(.workspace(let source)): source.map(HerdrPlace.workspace)
        case .creation(.split(let pane, _, _)): .pane(pane)
        }
    }
}

/// What Remux asks of a Herdr session, which goes only on the server boot its ids came from, while the place
/// it names is still there (`HerdrScreenModel.ask(_:bootID:)`).
enum HerdrRequest: Equatable, Sendable {
    case go(HerdrDestination)
    /// Herdr's client's close of `place`; `group` closes a worktree group's root with its linked worktrees.
    case close(HerdrPlace, group: Bool)
    /// A new name for `place`, as typed; an empty one clears a pane's manual name.
    case rename(HerdrPlace, name: String)

    var origin: HerdrPlace? {
        switch self {
        case .go(let destination): destination.origin
        case .close(let place, _), .rename(let place, _): place
        }
    }
}

extension HerdrSnapshot {
    /// The tab a move to `place` shows: a pane's tab, the tab, or the tab this phone has in the workspace.
    func tabID(reachedBy place: HerdrPlace) -> String? {
        switch place {
        case .pane(let id): panes.first { $0.paneID == id }?.tabID
        case .tab(let id): tabs.contains { $0.tabID == id } ? id : nil
        case .workspace(let id): workspaces.first { $0.workspaceID == id }?.activeTabID
        }
    }

    /// Whether this phone is at `place` already.
    func isAt(_ place: HerdrPlace) -> Bool {
        switch place {
        case .pane(let id): focusedPaneID == id
        case .tab(let id): focusedTabID == id
        case .workspace(let id): focusedWorkspaceID == id
        }
    }

    /// The name Herdr's pane navigator gives the pane without a manual label: its agent's name, else its
    /// title, else its agent's kind, else "terminal". The snapshot carries a title only for an agent's pane.
    func automaticName(ofPane paneID: String) -> String {
        let agent = agents.first { $0.paneID == paneID }
        return agent?.name ?? agent?.title ?? agent?.terminalTitleStripped ?? agent?.agent ?? agent?.displayAgent
            ?? "terminal"
    }

    /// What runs in the pane: its agent, by kind, else a terminal.
    func program(ofPane paneID: String) -> TerminalProgram {
        guard let agent = agents.first(where: { $0.paneID == paneID }) else { return .terminal }
        return .agent(agent.kind ?? agent.listName)
    }

    /// The description Herdr supplies: an agent's title, or a plain pane's name or folder.
    /// Missing descriptions stay empty; the program's mark already identifies what is running.
    func activity(ofPane paneID: String) -> String {
        if let agent = agents.first(where: { $0.paneID == paneID }) { return agent.activity ?? "" }
        guard let pane = panes.first(where: { $0.paneID == paneID }) else { return "" }
        if let label = pane.label, !label.isEmpty { return label }
        return (pane.foregroundCWD ?? pane.cwd).map { ($0 as NSString).lastPathComponent } ?? ""
    }

    /// What the rename alert for `place` starts with: its name, and Herdr's automatic name as the
    /// placeholder. A tab's automatic name is its number in its workspace (`workspace.rs`
    /// `tab_display_name`); a pane's field starts empty without a manual label. Herdr's snapshot doesn't
    /// carry a workspace's automatic name once the user named it.
    func renameField(for place: HerdrPlace) -> HerdrRenameField? {
        switch place {
        case .pane(let id):
            guard let pane = panes.first(where: { $0.paneID == id }) else { return nil }
            return HerdrRenameField(name: pane.label ?? "", placeholder: automaticName(ofPane: id))
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.tabID == id }),
                  let index = tabs.filter({ $0.workspaceID == tab.workspaceID }).firstIndex(where: { $0.tabID == id })
            else { return nil }
            return HerdrRenameField(name: tab.label, placeholder: String(index + 1))
        case .workspace(let id):
            guard let workspace = workspaces.first(where: { $0.workspaceID == id }) else { return nil }
            return HerdrRenameField(name: workspace.label, placeholder: workspace.customLabel ? "Name" : workspace.label)
        }
    }

    /// Whether `place` is what this phone shows: the workspace on screen, the tab on screen, or one of its
    /// panes.
    func isOnScreen(_ place: HerdrPlace) -> Bool {
        switch place {
        case .workspace(let id): focusedWorkspaceID == id
        case .tab(let id): focusedTabID == id
        case .pane(let id): panes.contains { $0.paneID == id && $0.tabID == focusedTabID }
        }
    }

    /// Whether `place` is still on the server.
    func contains(_ place: HerdrPlace) -> Bool {
        switch place {
        case .pane(let id): panes.contains { $0.paneID == id }
        case .tab(let id): tabs.contains { $0.tabID == id }
        case .workspace(let id): workspaces.contains { $0.workspaceID == id }
        }
    }
}

/// A Herdr session's workspaces and their tabs as Remux lists them, from its newest snapshot, in Herdr's
/// order. It also remembers the workspaces this phone was in, which the Tabs sheet offers first.
struct HerdrSessionOutline: Equatable, Sendable {
    struct Workspace: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        /// Whether `label` is the user's, not Herdr's automatic name.
        let hasCustomLabel: Bool
        let tabs: [Tab]
        let worktree: HerdrSnapshot.Workspace.Worktree?

        var paneCount: Int { tabs.reduce(0) { $0 + $1.paneIDs.count } }
    }

    struct Tab: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        /// Whether `label` is the user's, not Herdr's automatic name, the tab's number.
        let hasCustomLabel: Bool
        let paneIDs: [String]
    }

    let bootID: String
    let workspaces: [Workspace]
    let focusedWorkspaceID: String?
    /// The workspaces this phone was in, the newest first. Workspace ids belong to a server boot, so a new
    /// boot starts over.
    private let visited: [String]

    init(_ snapshot: HerdrSnapshot, after previous: HerdrSessionOutline?) {
        bootID = snapshot.bootID
        let tabs = Dictionary(grouping: snapshot.tabs, by: \.workspaceID)
        let panes = Dictionary(grouping: snapshot.panes, by: \.tabID)
        workspaces = snapshot.workspaces.map { workspace in
            Workspace(
                id: workspace.workspaceID,
                label: workspace.label,
                hasCustomLabel: workspace.customLabel,
                tabs: (tabs[workspace.workspaceID] ?? []).map { tab in
                    Tab(
                        id: tab.tabID,
                        label: tab.label,
                        hasCustomLabel: tab.customLabel,
                        paneIDs: (panes[tab.tabID] ?? []).map(\.paneID)
                    )
                },
                worktree: workspace.worktree
            )
        }
        focusedWorkspaceID = snapshot.focusedWorkspaceID
        let earlier = previous?.bootID == snapshot.bootID ? previous?.visited ?? [] : []
        let existing = Set(snapshot.workspaces.map(\.workspaceID))
        visited = ([snapshot.focusedWorkspaceID].compactMap { $0 } + earlier.filter { $0 != snapshot.focusedWorkspaceID })
            .filter(existing.contains)
    }

    /// The workspaces this phone was in, the newest first, then the rest in Herdr's order.
    var workspacesByRecency: [Workspace] {
        visited.compactMap { workspace($0) } + workspaces.filter { !visited.contains($0.id) }
    }

    func workspace(_ id: String) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    func workspace(containingTab tabID: String) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tabID } }
    }

    func workspace(containingPane paneID: String) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.paneIDs.contains(paneID) } }
    }

    /// The workspace `place` is, or is in.
    func workspace(containing place: HerdrPlace) -> Workspace? {
        switch place {
        case .workspace(let id): workspace(id)
        case .tab(let id): workspace(containingTab: id)
        case .pane(let id): workspace(containingPane: id)
        }
    }

    // MARK: Closing

    /// What Herdr's client asks before closing `place`, if it asks (`overlay_input.rs`
    /// `request_tab_close`, `request_pane_close`, `open_close_confirmation`): a workspace always; its only
    /// tab, or the only pane of its only tab, since that closes the workspace. A tab or pane whose close
    /// would close a worktree group isn't asked about here, as in Herdr's client: Herdr's server asks for
    /// that (`confirmation_required`), and its workspace's close is asked then (`closeConfirmation(ofWorkspace:)`).
    func closeConfirmation(before place: HerdrPlace) -> HerdrCloseConfirmation? {
        let workspace: Workspace
        switch place {
        case .workspace(let id):
            return closeConfirmation(ofWorkspace: id)
        case .tab(let id):
            guard let found = self.workspace(containingTab: id), found.tabs.count == 1 else { return nil }
            workspace = found
        case .pane(let id):
            guard let found = self.workspace(containingPane: id), found.tabs.count == 1, found.paneCount == 1
            else { return nil }
            workspace = found
        }
        guard let confirmation = closeConfirmation(ofWorkspace: workspace.id), !confirmation.closesGroup else {
            return nil
        }
        return confirmation.closing(place)
    }

    /// The close of workspace `id` as Herdr's client asks about it: a worktree group's root, whose linked
    /// worktrees are all that share its repository, closes with them (`sidebar.rs`
    /// `workspace_close_is_group`, `app/actions.rs` `workspace_group_close_indices`).
    func closeConfirmation(ofWorkspace id: String) -> HerdrCloseConfirmation? {
        guard let workspace = workspace(id) else { return nil }
        let group = closingGroup(of: workspace)
        return HerdrCloseConfirmation(
            bootID: bootID,
            label: workspace.label,
            tabCount: group.reduce(0) { $0 + $1.tabs.count },
            paneCount: group.reduce(0) { $0 + $1.paneCount },
            otherWorkspaceCount: group.count - 1,
            request: .close(.workspace(id), group: group.count > 1)
        )
    }

    /// The workspaces a close of `workspace` closes: with a root checkout whose repository's other
    /// workspaces are all linked worktrees, and at least one, all of them; otherwise itself.
    private func closingGroup(of workspace: Workspace) -> [Workspace] {
        guard let worktree = workspace.worktree, !worktree.isLinkedWorktree else { return [workspace] }
        let others = workspaces.filter { $0.id != workspace.id && $0.worktree?.key == worktree.key }
        guard !others.isEmpty, others.allSatisfy({ $0.worktree?.isLinkedWorktree == true }) else { return [workspace] }
        return [workspace] + others
    }
}

/// The text field of a rename alert: the place's name, and Herdr's automatic name as its placeholder.
struct HerdrRenameField: Equatable, Sendable {
    let name: String
    let placeholder: String
}

/// What a close Herdr's client asks about first closes: a workspace, its tabs and panes, and for a worktree
/// group's root the group's other workspaces with theirs. `request` is what goes once the user agrees: the
/// tab's or pane's own close, or the workspace's, on the server boot it was asked about.
struct HerdrCloseConfirmation: Equatable, Sendable {
    let bootID: String
    let label: String
    let tabCount: Int
    let paneCount: Int
    let otherWorkspaceCount: Int
    let request: HerdrRequest

    var closesGroup: Bool { otherWorkspaceCount > 0 }

    func closing(_ place: HerdrPlace) -> HerdrCloseConfirmation {
        HerdrCloseConfirmation(
            bootID: bootID,
            label: label,
            tabCount: tabCount,
            paneCount: paneCount,
            otherWorkspaceCount: otherWorkspaceCount,
            request: .close(place, group: false)
        )
    }
}

/// A session's outline for the views that list its places, such as the Sessions sheet. It publishes
/// only when the outline changes, not with every snapshot.
@MainActor
final class HerdrSessionPlaces: ObservableObject {
    @Published private(set) var outline: HerdrSessionOutline?

    /// Returns whether the outline changed.
    func update(with snapshot: HerdrSnapshot) -> Bool {
        let next = HerdrSessionOutline(snapshot, after: outline)
        guard next != outline else { return false }
        outline = next
        return true
    }
}
