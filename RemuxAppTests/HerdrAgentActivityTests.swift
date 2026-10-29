import XCTest
@testable import Remux

/// What the Tabs sheet's row says of a Herdr agent: its kind, by Herdr's name for it, which picks its mark,
/// and what it is doing.
final class HerdrAgentActivityTests: XCTestCase {
    private func agent(
        agent: String? = nil,
        name: String? = nil,
        displayAgent: String? = nil,
        title: String? = nil,
        terminalTitle: String? = nil
    ) throws -> HerdrSnapshot.Agent {
        let json = HerdrServerScript.snapshotAgent(
            "w1:p1",
            name: name,
            title: title,
            terminalTitleStripped: terminalTitle,
            agent: agent,
            displayAgent: displayAgent
        )
        return try JSONDecoder().decode(HerdrSnapshot.Agent.self, from: Data(json.utf8))
    }

    /// Herdr's names for the agents it knows, from any name it takes for them (`detect/mod.rs`
    /// `parse_agent_label`); an agent it doesn't know keeps its own.
    func testAnAgentsKindIsHerdrsNameForIt() throws {
        let labels = [
            "claude", "Claude-Code", " claude-code ", "/opt/bin/codex", "opencode.exe", "antigravity",
            "GitHub-Copilot", "kiro-cli",
        ]
        XCTAssertEqual(
            try labels.map { try agent(agent: $0).kind },
            ["claude", "claude", "claude", "codex", "opencode", "agy", "copilot", "kiro"]
        )
        XCTAssertEqual(try agent(agent: "my-agent").kind, "my-agent")
        XCTAssertNil(try agent(agent: nil).kind)
        XCTAssertNil(try agent(agent: "  ").kind)
    }

    /// A title's prefixes, project names and IDs belong to its program, across agent kinds.
    func testAnAgentsSuppliedTitleIsNotParsed() throws {
        let titles = [
            ("codex", "codex | Fix the flaky test"),
            ("codex", "codex-a | 01a18438-6b3c-7100-be3f-63285c8e6ca4"),
            ("codex", "01a18438-6b3c-7100-be3f-63285c8e6ca4"),
            ("claude", "Claude Code: Review"),
            ("opencode", "opencode - Plan the release"),
            ("my-agent", "my-agent | Review"),
        ]
        for (kind, title) in titles {
            XCTAssertEqual(try agent(agent: kind, terminalTitle: title).activity, title)
        }
        let title = "codex | 01a18438-6b3c-7100-be3f-63285c8e6ca4"
        XCTAssertEqual(try agent(agent: "codex", title: "Review", terminalTitle: title).activity, title)
    }

    /// Without a terminal title, the title the agent's hooks report; without either, nothing.
    func testAnAgentWithoutATerminalTitleSaysItsReportedTitle() throws {
        XCTAssertEqual(try agent(agent: "pi", title: "Planning").activity, "Planning")
        XCTAssertEqual(try agent(agent: "pi", title: "Planning", terminalTitle: "  ").activity, "Planning")
        XCTAssertNil(try agent(agent: "pi").activity)
    }

    /// Program marks retain their identity when a description is absent. Descriptions come from supplied
    /// titles, pane names or folders, never a synthesized agent or terminal name.
    func testAPaneSaysWhatItsAgentOrItsShellIsDoing() throws {
        let panes = [
            HerdrServerScript.snapshotPane("w1:p4", label: "logs"),
            HerdrServerScript.snapshotPane("w1:p5", cwd: "/srv/api", foregroundCWD: "/srv/api/web"),
            HerdrServerScript.snapshotPane("w1:p6"),
        ]
        let agents = [
            HerdrServerScript.snapshotAgent("w1:p1", terminalTitleStripped: "codex | Fix it", agent: "codex"),
            HerdrServerScript.snapshotAgent("w1:p2", agent: "claude-code"),
            HerdrServerScript.snapshotAgent("w1:p3", name: "reviewer"),
        ]
        let json = """
        {"boot_id":"boot","revision":1,"focused_workspace_id":"w1","focused_tab_id":"t1","focused_pane_id":null,
         "workspaces":[],"tabs":[],"panes":[\(panes.joined(separator: ","))],"agents":[\(agents.joined(separator: ","))]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
        let ids = ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"]
        XCTAssertEqual(
            ids.map(snapshot.program(ofPane:)),
            [.agent("codex"), .agent("claude"), .agent("reviewer"), .terminal, .terminal, .terminal]
        )
        XCTAssertEqual(ids.map(snapshot.activity(ofPane:)), ["codex | Fix it", "", "", "logs", "web", ""])
        XCTAssertEqual(snapshot.activity(ofPane: "missing"), "")
    }
}
