import Foundation
import Observation

/// A Herdr session's agents as this phone shows them: the one owner of their state, which views read
/// directly.
///
/// Each agent's status follows Herdr's client's rules (`endpoint_agent_state.rs`). Herdr's `done` only
/// says no client in front has looked at the pane, so each client decides for itself: an agent that is
/// idle after finishing work reads as done until its pane is on this phone's screen. Work counts as
/// finished when Herdr recorded a completion at the agent's current state change, or, for a snapshot sent
/// without that record, when this phone saw the agent working. Completions from before the phone first
/// heard from a server boot count as seen.
///
/// The agents are in the snapshot's order, which is Herdr's agent list's by default
/// (`agent_panel_sort = "spaces"`). A tab, a workspace or the session shows its most urgent agent, as
/// Herdr's client rolls tabs and workspaces up from the statuses it shows (`project_aggregate_status`).
/// Views are told only when what they show changes; when the phone saw each agent's state change isn't
/// shown, so it changes nothing views follow.
@Observable
final class HerdrAgentPresentation {
    /// One agent as the sheets show it.
    struct Agent: Identifiable, Equatable, Sendable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        /// As Herdr's agent list names it (`client/shell/agent_sidebar.rs` `agent_row`).
        let name: String
        /// What runs in its pane, which its mark shows.
        let program: TerminalProgram
        let workspaceName: String?
        /// Its tab, when the workspace has more than one or the tab has a label of its own, as Herdr's
        /// agent list places it.
        let tabName: String?
        /// The name the user gave it, unless its tab already says it.
        let givenName: String?
        let state: TerminalAgentState

        var id: String { paneID }

        /// Its workspace, then its tab, as Herdr's agent list places it.
        var place: String {
            [workspaceName, tabName].compactMap { $0 }.joined(separator: " › ")
        }
    }

    /// The server boot the agents' pane ids belong to.
    private(set) var bootID: String?
    private(set) var agents: [Agent] = []
    /// The title each agent's program sets for itself, by pane, word for word. Program-owned text: its
    /// contents are not a contract for Remux to parse. It is apart from `agents`, which every dot follows: a
    /// title can change many times a minute, and only the rows that show titles should hear of it.
    private(set) var titles: [String: String] = [:]
    /// When this phone saw each agent's current state change, by pane.
    @ObservationIgnored private(set) var recency: [String: HerdrAgentRecency] = [:]

    /// The newest state change of each agent that was on screen.
    @ObservationIgnored private var acknowledged: [String: UInt64] = [:]
    /// The state change at which each agent finished work it hasn't started again since.
    @ObservationIgnored private var completed: [String: UInt64] = [:]
    @ObservationIgnored private var working: Set<String> = []
    /// The snapshot's agents, each with the names of its workspace and of its tab when its place has one.
    @ObservationIgnored private var reported: [(agent: HerdrSnapshot.Agent, workspace: String?, tab: String?)] = []

    /// Returns whether what the phone shows of the agents changed. `now` is when the phone has the snapshot.
    @discardableResult
    func project(
        _ snapshot: HerdrSnapshot,
        completions: [String: UInt64]?,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        if bootID != snapshot.bootID {
            bootID = snapshot.bootID
            acknowledged = Dictionary(snapshot.agents.map { ($0.paneID, $0.stateChangeSeq) }) { $1 }
            completed.removeAll()
            working.removeAll()
            recency.removeAll()
        }
        recency = Dictionary(snapshot.agents.map { agent -> (String, HerdrAgentRecency) in
            if let previous = recency[agent.paneID], previous.stateChange == agent.stateChangeSeq {
                return (agent.paneID, previous)
            }
            return (agent.paneID, HerdrAgentRecency(seen: now, stateChange: agent.stateChangeSeq))
        }) { $1 }
        let paneIDs = Set(snapshot.agents.map(\.paneID))
        acknowledged = acknowledged.filter { paneIDs.contains($0.key) }
        completed = completed.filter { paneIDs.contains($0.key) }
        working.formIntersection(paneIDs)
        for agent in snapshot.agents {
            let paneID = agent.paneID
            switch agent.agentStatus {
            case .working:
                working.insert(paneID)
                completed[paneID] = nil
            case .blocked:
                completed[paneID] = nil
            case .idle, .done:
                let observedWork = working.remove(paneID) != nil
                let finished = completions.map { $0[paneID] == agent.stateChangeSeq }
                    ?? (observedWork || completed[paneID] == agent.stateChangeSeq)
                completed[paneID] = finished ? agent.stateChangeSeq : nil
            case .unknown:
                working.remove(paneID)
                completed[paneID] = nil
            }
        }
        reported = snapshot.agents.map { agent in
            let workspace = snapshot.workspaces.first { $0.workspaceID == agent.workspaceID }
            let tabs = snapshot.tabs.filter { $0.workspaceID == agent.workspaceID }
            let tab = tabs.first { $0.tabID == agent.tabID }.flatMap { tabs.count > 1 || $0.customLabel ? $0 : nil }
            return (agent, workspace?.label, tab?.label)
        }
        return update()
    }

    /// The panes on this phone's screen: their agents' current states count as seen. Returns whether what
    /// the phone shows of the agents changed.
    @discardableResult
    func acknowledge(panes paneIDs: Set<String>) -> Bool {
        var seen = false
        for (agent, _, _) in reported where paneIDs.contains(agent.paneID) {
            if acknowledged[agent.paneID, default: 0] < agent.stateChangeSeq {
                acknowledged[agent.paneID] = agent.stateChangeSeq
                seen = true
            }
        }
        return seen && update()
    }

    func state(ofPane paneID: String) -> TerminalAgentState? {
        agents.first { $0.paneID == paneID }?.state
    }

    /// The tab's most urgent agent, if it has any.
    func status(ofTab tabID: String) -> TerminalAgentStatus? {
        agents.lazy.filter { $0.tabID == tabID }.map(\.state.status).max()
    }

    /// The workspace's most urgent agent, across its tabs, if it has any.
    func status(ofWorkspace workspaceID: String) -> TerminalAgentStatus? {
        agents.lazy.filter { $0.workspaceID == workspaceID }.map(\.state.status).max()
    }

    /// The session's most urgent agent, if it has any.
    var status: TerminalAgentStatus? {
        agents.lazy.map(\.state.status).max()
    }

    /// Only a change is set, so views reading the agents are told only then.
    private func update() -> Bool {
        let next = reported.map { agent, workspace, tab in
            let shown = status(of: agent)
            let given = agent.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return Agent(
                paneID: agent.paneID,
                workspaceID: agent.workspaceID,
                tabID: agent.tabID,
                name: agent.listName,
                program: agent.program,
                workspaceName: workspace,
                tabName: tab,
                givenName: given == tab ? nil : given,
                state: TerminalAgentState(shown.terminalStatus, word: agent.label(for: shown))
            )
        }
        let nextTitles = Dictionary(reported.compactMap { agent, _, _ in agent.activity.map { (agent.paneID, $0) } }) { $1 }
        if nextTitles != titles {
            titles = nextTitles
        }
        guard next != agents else { return false }
        agents = next
        return true
    }

    private func status(of agent: HerdrSnapshot.Agent) -> HerdrAgentStatus {
        switch agent.agentStatus {
        case .idle, .done:
            guard let completion = completed[agent.paneID],
                  acknowledged[agent.paneID].map({ $0 < completion }) ?? true
            else { return .idle }
            return .done
        case let status:
            return status
        }
    }
}

/// When this phone saw an agent's current state change, so the newest change comes first across sessions,
/// as Herdr's client counts the changes it sees itself (`client/shell/endpoints.rs` `agent_recency`):
/// change numbers from different servers can't be compared. Changes in one snapshot are in Herdr's order.
struct HerdrAgentRecency: Comparable, Sendable {
    let seen: ContinuousClock.Instant
    let stateChange: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seen, lhs.stateChange) < (rhs.seen, rhs.stateChange)
    }
}

extension HerdrSnapshot.Agent {
    /// The agent's name as Herdr's agent list names it (`client/shell/agent_sidebar.rs` `agent_row`).
    var listName: String {
        displayAgent ?? name ?? agent ?? title ?? "agent"
    }

    /// The agent's kind: Herdr's name for an agent it knows, found from any name Herdr takes for it
    /// (`detect/mod.rs` `parse_agent_label`), else the name its hooks report.
    var kind: String? {
        guard let label = agent?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        var name = label.lowercased()
        if let suffix = Self.launcherSuffixes.first(where: name.hasSuffix) {
            name.removeLast(suffix.count)
        }
        name = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? name
        return Self.knownKinds[name] ?? label
    }

    /// What the agent is, for its mark: its kind, else the name Herdr's agent list gives it.
    var program: TerminalProgram {
        .agent(kind ?? listName)
    }

    /// What Herdr drops from the end of a name before it looks the name up (`normalized_agent_lookup_name`).
    private static let launcherSuffixes = [".exe", ".cmd", ".bat", ".ps1", ".js"]

    /// Herdr's names for the agents it knows, by each name it takes for them (`detect/mod.rs` `lookup_agent`).
    private static let knownKinds: [String: String] = {
        let names: [String: [String]] = [
            "pi": ["pi"],
            "claude": ["claude", "claude-code"],
            "codex": ["codex"],
            "gemini": ["gemini"],
            "cursor": ["cursor", "cursor-agent"],
            "devin": ["devin", "devin-cli", "devin cli"],
            "agy": ["agy", "antigravity", "antigravity-cli"],
            "cline": ["cline", ".cline"],
            "omp": ["omp"],
            "mastracode": ["mastracode", "mastra-code", "mastra code"],
            "opencode": ["opencode", "opencode2", "open-code"],
            "copilot": ["copilot", "github-copilot", "ghcs"],
            "kimi": ["kimi", "kimi-code", "kimi code"],
            "kiro": ["kiro", "kiro-cli"],
            "droid": ["droid"],
            "amp": ["amp", "amp-local"],
            "grok": ["grok", "grok-build"],
            "hermes": ["hermes", "hermes-agent"],
            "kilo": ["kilo", "kilo-code", "kilo code"],
            "qodercli": ["qodercli", "qoderclicn", "qoder", "qodercn"],
            "qwen": ["qwen", "qwen-code", "qwen code"],
            "letta": ["letta", "letta-code", "letta code"],
            "maki": ["maki"],
            "muse": ["muse", "muse-code", "muse-cli"],
        ]
        return Dictionary(uniqueKeysWithValues: names.flatMap { kind, names in names.map { ($0, kind) } })
    }()

    /// The terminal title Herdr supplies without its spinner, otherwise the integration-reported title.
    /// Both are program-owned text: their contents are not a contract for Remux to parse.
    var activity: String? {
        [terminalTitleStripped, title].lazy
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension HerdrAgentStatus {
    var terminalStatus: TerminalAgentStatus {
        switch self {
        case .unknown: .unknown
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .blocked: .blocked
        }
    }
}
