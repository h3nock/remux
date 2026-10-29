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
/// Views are told only when what they show changes.
@Observable
final class HerdrAgentPresentation {
    /// One agent as the sheets show it.
    struct Agent: Identifiable, Equatable, Sendable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        /// As Herdr's agent list names it (`client/shell/agent_sidebar.rs` `agent_row`).
        let name: String
        /// Its workspace, then its tab when the workspace has more than one or the tab has a label of its
        /// own, as Herdr's agent list places it.
        let place: String
        let state: TerminalAgentState

        var id: String { paneID }
    }

    /// The server boot the agents' pane ids belong to.
    private(set) var bootID: String?
    private(set) var agents: [Agent] = []

    /// The newest state change of each agent that was on screen.
    @ObservationIgnored private var acknowledged: [String: UInt64] = [:]
    /// The state change at which each agent finished work it hasn't started again since.
    @ObservationIgnored private var completed: [String: UInt64] = [:]
    @ObservationIgnored private var working: Set<String> = []
    /// The snapshot's agents, each with its name and place.
    @ObservationIgnored private var reported: [(agent: HerdrSnapshot.Agent, name: String, place: String)] = []

    /// Returns whether what the phone shows of the agents changed.
    @discardableResult
    func project(_ snapshot: HerdrSnapshot, completions: [String: UInt64]?) -> Bool {
        if bootID != snapshot.bootID {
            bootID = snapshot.bootID
            acknowledged = Dictionary(snapshot.agents.map { ($0.paneID, $0.stateChangeSeq) }) { $1 }
            completed.removeAll()
            working.removeAll()
        }
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
            return (
                agent,
                agent.listName,
                [workspace?.label, tab?.label].compactMap { $0 }.joined(separator: " › ")
            )
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
        let next = reported.map { agent, name, place in
            let shown = status(of: agent)
            return Agent(
                paneID: agent.paneID,
                workspaceID: agent.workspaceID,
                tabID: agent.tabID,
                name: name,
                place: place,
                state: TerminalAgentState(shown.terminalStatus, word: agent.label(for: shown))
            )
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
