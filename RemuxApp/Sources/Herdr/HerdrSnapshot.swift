import Foundation

/// `shell.snapshot.v1`: this connection's view of the session (Herdr's `ClientShellSnapshot`). It
/// carries no geometry; pane geometry is only in surfaces. Unknown JSON fields are ignored.
struct HerdrSnapshot: Equatable, Sendable, Decodable {
    let bootID: String
    /// Per connection; the `projectionRevision` of the surfaces rendered against it.
    let revision: UInt64
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]

    struct Workspace: Equatable, Sendable, Decodable {
        let workspaceID: String
        let activeTabID: String
        let number: Int
        let label: String
        let customLabel: Bool
        let focused: Bool
        let agentStatus: HerdrAgentStatus

        private enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case activeTabID = "active_tab_id"
            case number, label
            case customLabel = "custom_label"
            case focused
            case agentStatus = "agent_status"
        }
    }

    struct Tab: Equatable, Sendable, Decodable {
        let tabID: String
        let workspaceID: String
        let number: Int
        let label: String
        let customLabel: Bool
        let zoomed: Bool
        let focused: Bool
        let agentStatus: HerdrAgentStatus

        private enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case number, label
            case customLabel = "custom_label"
            case zoomed, focused
            case agentStatus = "agent_status"
        }
    }

    struct Pane: Equatable, Sendable, Decodable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let label: String?
        let cwd: String?
        let foregroundCWD: String?
        let focused: Bool

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case label, cwd
            case foregroundCWD = "foreground_cwd"
            case focused
        }
    }

    struct Agent: Equatable, Sendable, Decodable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let name: String?
        let displayAgent: String?
        let agent: String?
        let title: String?
        let terminalTitle: String?
        let terminalTitleStripped: String?
        let agentStatus: HerdrAgentStatus
        let stateChangeSeq: UInt64

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case name
            case displayAgent = "display_agent"
            case agent, title
            case terminalTitle = "terminal_title"
            case terminalTitleStripped = "terminal_title_stripped"
            case agentStatus = "agent_status"
            case stateChangeSeq = "state_change_seq"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case revision
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces, tabs, panes, agents
    }
}

/// Unknown statuses read as `unknown`, as in Herdr's own decoder.
enum HerdrAgentStatus: String, Equatable, Sendable, Decodable {
    case idle, working, blocked, done, unknown

    init(from decoder: Decoder) throws {
        self = HerdrAgentStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
