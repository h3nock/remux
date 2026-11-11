import SwiftUI
import XCTest
@testable import Remux

/// A Herdr snapshot as JSON, with workspaces and tabs of its own, decoded as Remux decodes Herdr's.
enum HerdrSnapshotJSON {
    struct Tab {
        let id: String
        let workspace: String
        let label: String
        var customLabel = false
        /// What Herdr's server rolls up for the tab, which the phone's own statuses replace.
        var agentStatus: HerdrAgentStatus = .unknown
    }

    static func snapshot(
        boot: String = "boot",
        revision: UInt64 = 1,
        workspaces: [(id: String, label: String)],
        tabs: [Tab],
        agents: [String]
    ) throws -> HerdrSnapshot {
        let workspaceEntries = workspaces.enumerated().map { index, workspace in
            """
            {"workspace_id":"\(workspace.id)","active_tab_id":"\(tabs.first { $0.workspace == workspace.id }?.id ?? "")",
             "number":\(index + 1),"label":"\(workspace.label)","custom_label":true,"focused":\(index == 0),
             "agent_status":"unknown"}
            """
        }
        let tabEntries = tabs.enumerated().map { index, tab in
            """
            {"tab_id":"\(tab.id)","workspace_id":"\(tab.workspace)","number":\(index + 1),"label":"\(tab.label)",
             "custom_label":\(tab.customLabel),"zoomed":false,"focused":\(index == 0),
             "agent_status":"\(tab.agentStatus.rawValue)"}
            """
        }
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"\(workspaces.first?.id ?? "")",
         "focused_tab_id":"\(tabs.first?.id ?? "")","focused_pane_id":null,
         "workspaces":[\(workspaceEntries.joined(separator: ","))],"tabs":[\(tabEntries.joined(separator: ","))],
         "panes":[],"agents":[\(agents.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// Workspace `api` (`w1`) with tabs `agents` (`t1`) and `auth` (`t2`), and workspace `web` (`w2`) with
    /// its one tab `main` (`t3`).
    static func twoWorkspaces(revision: UInt64 = 1, agents: [String], webTabLabelled: Bool = false) throws -> HerdrSnapshot {
        try snapshot(
            revision: revision,
            workspaces: [("w1", "api"), ("w2", "web")],
            tabs: [
                Tab(id: "t1", workspace: "w1", label: "agents"),
                Tab(id: "t2", workspace: "w1", label: "auth"),
                Tab(id: "t3", workspace: "w2", label: webTabLabelled ? "dev" : "1", customLabel: webTabLabelled),
            ],
            agents: agents
        )
    }

    /// A session's agents in `statuses` as the phone shows them, in tab `t1`: each working first, so one
    /// whose status is `done` finished work this phone saw. Every agent's state change was seen at `seen`.
    static func presentation(
        _ statuses: [(pane: String, status: HerdrAgentStatus)],
        seen: ContinuousClock.Instant = .now
    ) throws -> HerdrAgentPresentation {
        func agents(finished: Bool) -> [String] {
            statuses.map { pane, status in
                let reported: HerdrAgentStatus = status == .done ? (finished ? .idle : .working) : status
                return HerdrServerScript.snapshotAgent(pane, agent: "claude", status: reported, stateChange: finished ? 2 : 1)
            }
        }
        let presentation = HerdrAgentPresentation()
        presentation.project(try twoWorkspaces(revision: 1, agents: agents(finished: false)), completions: nil, now: seen)
        presentation.project(try twoWorkspaces(revision: 2, agents: agents(finished: true)), completions: nil, now: seen)
        return presentation
    }
}

/// What the sheets show of a Herdr session's agents, as Herdr's client shows them.
final class HerdrAgentsShownTests: XCTestCase {
    private func agent(
        _ paneID: String,
        workspace: String = "w1",
        tab: String = "t1",
        status: HerdrAgentStatus = .working,
        stateChange: UInt64 = 1,
        stateLabels: [(state: String, word: String)] = []
    ) -> String {
        HerdrServerScript.snapshotAgent(
            paneID,
            agent: "claude",
            workspace: workspace,
            tab: tab,
            status: status,
            stateChange: stateChange,
            stateLabels: stateLabels
        )
    }

    /// Herdr's order of how much each status needs the user (`client/shell.rs` `status_priority`):
    /// blocked, done, working, idle, unknown.
    private static let herdrOrder: [HerdrAgentStatus] = [.blocked, .done, .working, .idle, .unknown]

    /// A tab and the session show their most urgent agent by Herdr's order; a tab without agents shows none.
    func testATabAndTheSessionShowTheirMostUrgentAgentInHerdrsOrder() throws {
        for (index, urgent) in Self.herdrOrder.enumerated() {
            for calmer in Self.herdrOrder[index...] {
                let agents = try HerdrSnapshotJSON.presentation([("w1:p1", calmer), ("w1:p2", urgent)])
                XCTAssertEqual(agents.status(ofTab: "t1"), urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertEqual(agents.status, urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertNil(agents.status(ofTab: "t2"))
            }
        }
        XCTAssertNil(try HerdrSnapshotJSON.presentation([]).status)
    }

    /// A workspace shows its most urgent agent across its tabs by Herdr's order, as Herdr's client rolls its
    /// workspaces up; a workspace without agents shows none.
    func testAWorkspaceShowsItsMostUrgentAgentAcrossItsTabsInHerdrsOrder() throws {
        for (index, urgent) in Self.herdrOrder.enumerated() {
            for calmer in Self.herdrOrder[index...] {
                // Each agent works first, so one that then reads idle finished work this phone saw: done.
                func snapshot(_ revision: UInt64) throws -> HerdrSnapshot {
                    let reported = [("w1:p1", "t1", calmer), ("w1:p2", "t2", urgent)].map { pane, tab, status in
                        let sent: HerdrAgentStatus = status == .done ? (revision == 1 ? .working : .idle) : status
                        return agent(pane, tab: tab, status: sent, stateChange: revision)
                    }
                    return try HerdrSnapshotJSON.twoWorkspaces(revision: revision, agents: reported)
                }
                let agents = HerdrAgentPresentation()
                agents.project(try snapshot(1), completions: nil)
                agents.project(try snapshot(2), completions: nil)
                XCTAssertEqual(agents.status(ofWorkspace: "w1"), urgent.terminalStatus, "\(urgent) over \(calmer)")
                XCTAssertNil(agents.status(ofWorkspace: "w2"))
            }
        }
    }

    /// The phone's statuses decide, done until seen on this phone, as Herdr's client rolls its own up: not
    /// the server's roll-up for the tab, nor the server's status for the agent.
    func testThePhonesStatusesDecideNotTheServers() throws {
        func snapshot(_ status: HerdrAgentStatus, stateChange: UInt64) throws -> HerdrSnapshot {
            try HerdrSnapshotJSON.snapshot(
                workspaces: [("w1", "api")],
                tabs: [HerdrSnapshotJSON.Tab(id: "t1", workspace: "w1", label: "agents", agentStatus: .blocked)],
                agents: [agent("w1:p1", status: status, stateChange: stateChange)]
            )
        }
        let agents = HerdrAgentPresentation()
        agents.project(try snapshot(.done, stateChange: 1), completions: nil)
        XCTAssertEqual(agents.status(ofTab: "t1"), .idle)

        agents.project(try snapshot(.working, stateChange: 2), completions: nil)
        agents.project(try snapshot(.idle, stateChange: 3), completions: nil)
        XCTAssertEqual(agents.status(ofTab: "t1"), .done)
        XCTAssertEqual(agents.state(ofPane: "w1:p1"), TerminalAgentState(.done))
        agents.acknowledge(panes: ["w1:p1"])
        XCTAssertEqual(agents.status(ofTab: "t1"), .idle)
    }

    /// An agent is named as Herdr's agent list names it: its display name, else its name, else its kind,
    /// else its title; it is placed in its workspace, then its tab when the workspace has more than one or
    /// the tab has a label of its own.
    func testAnAgentIsNamedAndPlacedAsHerdrsAgentListDoes() throws {
        func named(_ name: String?, displayAgent: String?, agent: String?, title: String?) throws -> String? {
            let agents = HerdrAgentPresentation()
            agents.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [HerdrServerScript.snapshotAgent(
                "w1:p1",
                name: name,
                title: title,
                agent: agent,
                displayAgent: displayAgent
            )]), completions: nil)
            return agents.agents.first?.name
        }
        XCTAssertEqual(try named("fixer", displayAgent: "Claude Code", agent: "claude", title: "Fix tests"), "Claude Code")
        XCTAssertEqual(try named("fixer", displayAgent: nil, agent: "claude", title: "Fix tests"), "fixer")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: "claude", title: "Fix tests"), "claude")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: nil, title: "Fix tests"), "Fix tests")
        XCTAssertEqual(try named(nil, displayAgent: nil, agent: nil, title: nil), "agent")

        func places(webTabLabelled: Bool) throws -> [String] {
            let agents = HerdrAgentPresentation()
            agents.project(try HerdrSnapshotJSON.twoWorkspaces(
                agents: [agent("w1:p1", tab: "t2"), agent("w2:p1", workspace: "w2", tab: "t3")],
                webTabLabelled: webTabLabelled
            ), completions: nil)
            return agents.agents.map(\.place)
        }
        XCTAssertEqual(try places(webTabLabelled: false), ["api › auth", "web"])
        XCTAssertEqual(try places(webTabLabelled: true), ["api › auth", "web › dev"])
    }

    /// An agent carries its program, for its mark, the names of its workspace and tab, and the name the user
    /// gave it unless its tab already says it. The title its program sets is kept by pane, word for word, apart
    /// from the agents themselves: a title that changes tells only the views that show titles.
    func testAnAgentCarriesItsProgramItsPlaceAndTheNameItWasGiven() throws {
        func shown(name: String? = nil, title: String? = nil, stripped: String? = nil) throws -> HerdrAgentPresentation {
            let agents = HerdrAgentPresentation()
            agents.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [HerdrServerScript.snapshotAgent(
                "w1:p1", name: name, title: title, terminalTitleStripped: stripped, agent: "claude-code", tab: "t2"
            )]), completions: nil)
            return agents
        }

        let titled = try shown(name: "fixer", title: "ignored", stripped: "remux | Fix [tests] (2/3)")
        let agent = try XCTUnwrap(titled.agents.first)
        XCTAssertEqual(titled.titles, ["w1:p1": "remux | Fix [tests] (2/3)"])
        XCTAssertEqual(agent.program, .agent("claude"))
        XCTAssertEqual(agent.workspaceName, "api")
        XCTAssertEqual(agent.tabName, "auth")
        XCTAssertEqual(agent.givenName, "fixer")
        XCTAssertEqual(agent.place, "api › auth")

        XCTAssertEqual(try shown(name: "fixer", title: "Fix tests").titles, ["w1:p1": "Fix tests"])
        XCTAssertEqual(try shown(name: "fixer").titles, [:])
        XCTAssertNil(try shown(name: "auth").agents.first?.givenName, "The tab already says the name.")
        XCTAssertNil(try shown(name: "  ").agents.first?.givenName)
        XCTAssertNil(try shown().agents.first?.givenName)

        let before = titled.agents
        XCTAssertFalse(titled.project(try HerdrSnapshotJSON.twoWorkspaces(revision: 2, agents: [HerdrServerScript.snapshotAgent(
            "w1:p1", name: "fixer", terminalTitleStripped: "remux | Fix [tests] (3/3)", agent: "claude-code", tab: "t2"
        )]), completions: nil), "A new title alone is not a change the dots show.")
        XCTAssertEqual(titled.titles, ["w1:p1": "remux | Fix [tests] (3/3)"])
        XCTAssertEqual(titled.agents, before)
    }

    /// An agent's state is in Herdr's words, unless the agent's own labels give the state a word, as
    /// Herdr's client words it.
    func testAnAgentsStateIsInHerdrsWordsUnlessItsLabelsGiveOne() throws {
        func state(_ status: HerdrAgentStatus, labels: [(state: String, word: String)] = []) throws -> TerminalAgentState? {
            let agents = HerdrAgentPresentation()
            agents.project(
                try HerdrSnapshotJSON.twoWorkspaces(agents: [agent("w1:p1", status: status, stateLabels: labels)]),
                completions: nil
            )
            return agents.state(ofPane: "w1:p1")
        }
        XCTAssertEqual(try state(.blocked), TerminalAgentState(.blocked, word: "blocked"))
        XCTAssertEqual(try state(.working), TerminalAgentState(.working, word: "working"))
        XCTAssertEqual(try state(.idle), TerminalAgentState(.idle, word: "idle"))
        XCTAssertEqual(try state(.unknown), TerminalAgentState(.unknown, word: "idle"))
        XCTAssertEqual(try HerdrSnapshotJSON.presentation([("w1:p1", .done)]).state(ofPane: "w1:p1"), TerminalAgentState(.done, word: "done"))

        let labels = [(state: "blocked", word: "needs review"), (state: "idle", word: "ready")]
        XCTAssertEqual(try state(.blocked, labels: labels), TerminalAgentState(.blocked, word: "needs review"))
        XCTAssertEqual(try state(.idle, labels: labels), TerminalAgentState(.idle, word: "ready"))
        XCTAssertEqual(try state(.working, labels: labels), TerminalAgentState(.working, word: "working"))
    }

    /// Views are told only when what they show changes: an agent's state or place, not a snapshot that
    /// changes only the agent's terminal title.
    func testOnlyAChangeTheSheetsShowCounts() throws {
        func snapshot(_ revision: UInt64, status: HerdrAgentStatus, terminalTitle: String, tabLabel: String = "auth") throws -> HerdrSnapshot {
            try HerdrSnapshotJSON.snapshot(
                revision: revision,
                workspaces: [("w1", "api")],
                tabs: [
                    HerdrSnapshotJSON.Tab(id: "t1", workspace: "w1", label: "agents"),
                    HerdrSnapshotJSON.Tab(id: "t2", workspace: "w1", label: tabLabel),
                ],
                agents: [HerdrServerScript.snapshotAgent(
                    "w1:p1",
                    terminalTitleStripped: terminalTitle,
                    agent: "claude",
                    tab: "t2",
                    status: status,
                    stateChange: status == .working ? 1 : 2
                )]
            )
        }
        let agents = HerdrAgentPresentation()
        XCTAssertTrue(agents.project(try snapshot(1, status: .working, terminalTitle: "⠂ Fix tests"), completions: nil))
        XCTAssertFalse(agents.project(try snapshot(2, status: .working, terminalTitle: "⠐ Fix tests"), completions: nil))
        XCTAssertTrue(agents.project(try snapshot(3, status: .working, terminalTitle: "⠐ Fix tests", tabLabel: "tests"), completions: nil))
        XCTAssertEqual(agents.agents.map(\.place), ["api › tests"])
        XCTAssertTrue(agents.project(try snapshot(4, status: .blocked, terminalTitle: "⠐ Fix tests", tabLabel: "tests"), completions: nil))
        XCTAssertFalse(agents.acknowledge(panes: ["w1:p2"]))
    }

    /// Each state takes Herdr's colour from the themes Herdr pairs by default: Catppuccin Mocha in dark
    /// appearance and Latte in light (`app/state.rs` `catppuccin`, `catppuccin_latte`).
    func testStatesTakeHerdrsColoursForTheAppearance() {
        let herdr: [(TerminalAgentStatus, mocha: [Int], latte: [Int])] = [
            (.working, [249, 226, 175], [223, 142, 29]),
            (.blocked, [243, 139, 168], [210, 15, 57]),
            (.done, [148, 226, 213], [23, 146, 153]),
            (.idle, [166, 227, 161], [64, 160, 43]),
            (.unknown, [108, 112, 134], [156, 160, 176]),
        ]
        func rgb(_ status: TerminalAgentStatus, _ style: UIUserInterfaceStyle) -> [Int] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(status.color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue].map { Int(($0 * 255).rounded()) }
        }
        for (status, mocha, latte) in herdr {
            XCTAssertEqual(rgb(status, .dark), mocha, "\(status)")
            XCTAssertEqual(rgb(status, .light), latte, "\(status)")
        }
    }
}
