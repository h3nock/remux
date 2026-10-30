import Combine
import XCTest
@testable import Remux

/// The places Remux lists and moves to in a Herdr session, from Herdr's snapshot.
final class HerdrPlacesTests: XCTestCase {
    /// The outline lists the snapshot's workspaces in Herdr's order, each with its tabs and their panes.
    func testTheOutlineListsWorkspacesWithTheirTabsInHerdrsOrder() throws {
        let outline = HerdrSessionOutline(try snapshot(workspaces: ["api", "web"], focusedWorkspace: "web"), after: nil)

        XCTAssertEqual(outline.workspaces.map(\.label), ["api", "web"])
        XCTAssertEqual(outline.workspaces[0].tabs.map(\.id), ["api-t1", "api-t2"])
        XCTAssertEqual(outline.workspaces[0].tabs[1].paneIDs, ["api-t2-p1", "api-t2-p2"])
        XCTAssertEqual(outline.focusedWorkspaceID, "web")
        XCTAssertEqual(outline.workspace(containingTab: "web-t2")?.id, "web")
    }

    /// The Tabs sheet offers the workspaces this phone was in, the newest first, then the rest in Herdr's
    /// order, so its first three capsules follow the user and More holds the rest.
    func testWorkspacesComeByRecencyThenInHerdrsOrder() throws {
        let names = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var outline: HerdrSessionOutline?
        for visit in ["c", "f", "a", "f"] {
            outline = HerdrSessionOutline(try snapshot(workspaces: names, focusedWorkspace: visit), after: outline)
        }
        XCTAssertEqual(outline?.workspacesByRecency.map(\.id), ["f", "a", "c", "b", "d", "e", "g", "h"])

        // The same rule at four workspaces.
        var four: HerdrSessionOutline?
        for visit in ["d", "b"] {
            four = HerdrSessionOutline(try snapshot(workspaces: Array(names.prefix(4)), focusedWorkspace: visit), after: four)
        }
        XCTAssertEqual(four?.workspacesByRecency.map(\.id), ["b", "d", "a", "c"])
    }

    /// A workspace that closes leaves the order; a new server boot has new workspaces, so it starts over.
    func testRecencyDropsClosedWorkspacesAndStartsOverOnANewBoot() throws {
        var outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b", "c"], focusedWorkspace: "c"), after: nil)
        outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b", "c"], focusedWorkspace: "b"), after: outline)
        outline = HerdrSessionOutline(try snapshot(workspaces: ["a", "b"], focusedWorkspace: "b"), after: outline)
        XCTAssertEqual(outline.workspacesByRecency.map(\.id), ["b", "a"])

        let restarted = HerdrSessionOutline(
            try snapshot(boot: "new", workspaces: ["a", "b", "c"], focusedWorkspace: "a"),
            after: outline
        )
        XCTAssertEqual(restarted.workspacesByRecency.map(\.id), ["a", "b", "c"])
    }

    /// The places publish only when the outline changes, not with each snapshot.
    @MainActor
    func testThePlacesPublishOnlyWhenTheOutlineChanges() throws {
        let places = HerdrSessionPlaces()
        var published = 0
        let subscription = places.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        XCTAssertTrue(places.update(with: try snapshot(workspaces: ["a", "b"], focusedWorkspace: "a")))
        XCTAssertFalse(places.update(with: try snapshot(revision: 2, workspaces: ["a", "b"], focusedWorkspace: "a")))
        XCTAssertTrue(places.update(with: try snapshot(revision: 3, workspaces: ["a", "b"], focusedWorkspace: "b")))
        XCTAssertEqual(published, 2)
    }

    /// Each place is reached with the command Herdr's client sends for it, and shows its tab.
    func testEachPlaceHasHerdrsFocusCommandAndReachesItsTab() throws {
        let snapshot = try snapshot(workspaces: ["a", "b"], focusedWorkspace: "a", activeTabs: ["b": "b-t2"])
        XCTAssertEqual(HerdrPlace.pane("b-t2-p2").focusMethod, "pane.focus")
        XCTAssertEqual(HerdrPlace.tab("b-t1").focusParams, ["tab_id": "b-t1"])
        XCTAssertEqual(HerdrPlace.workspace("b").focusMethod, "workspace.focus")
        XCTAssertEqual(HerdrPlace.workspace("b").focusParams, ["workspace_id": "b"])

        XCTAssertEqual(snapshot.tabID(reachedBy: .pane("b-t2-p2")), "b-t2")
        XCTAssertEqual(snapshot.tabID(reachedBy: .tab("b-t1")), "b-t1")
        XCTAssertEqual(snapshot.tabID(reachedBy: .workspace("b")), "b-t2", "a workspace shows this phone's tab there")
        XCTAssertNil(snapshot.tabID(reachedBy: .tab("gone")))
        XCTAssertTrue(snapshot.isAt(.workspace("a")))
        XCTAssertTrue(snapshot.isAt(.tab("a-t1")))
        XCTAssertFalse(snapshot.isAt(.tab("b-t1")))
    }

    /// New Tab and New Workspace ask for what they make to be focused, as Herdr's client does.
    func testCreationsAskHerdrToFocusWhatTheyMake() throws {
        func encoded(_ creation: HerdrCreation) throws -> [String: AnyHashable] {
            let data = try JSONEncoder().encode(creation.params)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        }
        XCTAssertEqual(HerdrCreation.tab(workspaceID: "w2").method, "tab.create")
        XCTAssertEqual(try encoded(.tab(workspaceID: "w2")), ["workspace_id": "w2", "focus": true])
        XCTAssertEqual(HerdrCreation.workspace(source: "w1").method, "workspace.create")
        XCTAssertEqual(try encoded(.workspace(source: "w1")), ["source_workspace_id": "w1", "focus": true])
        XCTAssertEqual(HerdrCreation.split(pane: "w1:p1", workspaceID: "w1", direction: .down).method, "pane.split")
        XCTAssertEqual(
            try encoded(.split(pane: "w1:p1", workspaceID: "w1", direction: .down)),
            ["workspace_id": "w1", "target_pane_id": "w1:p1", "direction": "down", "focus": true]
        )
    }

    /// A workspace's close always asks, saying what closes with it; a tab's or a pane's asks only when it
    /// would close its workspace, as Herdr's client asks, and agreeing closes the tab or pane itself.
    func testACloseAsksWhereHerdrsClientAsks() throws {
        let outline = HerdrSessionOutline(try closingSnapshot([
            ("api", [["api-p1"], ["api-p2", "api-p3"]], nil),
            ("web", [["web-p1"]], nil),
        ]), after: nil)

        let workspace = try XCTUnwrap(outline.closeConfirmation(before: .workspace("api")))
        XCTAssertEqual([workspace.label, "\(workspace.tabCount)", "\(workspace.paneCount)"], ["api", "2", "3"])
        XCTAssertFalse(workspace.closesGroup)
        XCTAssertEqual(workspace.request, .close(.workspace("api"), group: false))
        XCTAssertEqual(workspace.bootID, "boot")
        XCTAssertEqual(workspace.dialog, GhosttyCloseConfirmation(
            title: "Close Workspace?",
            message: "“api” and its 2 tabs and 3 panes will close.",
            action: "Close Workspace"
        ))

        XCTAssertNil(outline.closeConfirmation(before: .tab("api-t1")), "a tab that leaves its workspace another asked")
        XCTAssertNil(outline.closeConfirmation(before: .pane("api-p2")), "a pane that leaves its tab another asked")
        XCTAssertNil(outline.closeConfirmation(before: .pane("api-p1")), "the only pane of one of two tabs asked")

        let lastTab = try XCTUnwrap(outline.closeConfirmation(before: .tab("web-t1")))
        XCTAssertEqual([lastTab.label, "\(lastTab.tabCount)", "\(lastTab.paneCount)"], ["web", "1", "1"])
        XCTAssertEqual(lastTab.dialog.message, "“web” and its 1 tab and 1 pane will close.")
        XCTAssertEqual(lastTab.request, .close(.tab("web-t1"), group: false))
        let onlyPane = try XCTUnwrap(outline.closeConfirmation(before: .pane("web-p1")))
        XCTAssertEqual(onlyPane.request, .close(.pane("web-p1"), group: false))
    }

    /// A worktree group's root, whose repository's other workspaces are all linked worktrees, closes with
    /// them, and its confirmation says so; a linked worktree closes alone. A tab or pane whose close would
    /// close the group isn't asked about here: Herdr's server asks for that.
    func testAWorktreeGroupsRootClosesWithItsLinkedWorktrees() throws {
        let outline = HerdrSessionOutline(try closingSnapshot([
            ("app", [["app-p1"]], ("repo", false)),
            ("feature", [["feature-p1", "feature-p2"]], ("repo", true)),
            ("fix", [["fix-p1"], ["fix-p2"]], ("repo", true)),
            ("notes", [["notes-p1"]], nil),
        ]), after: nil)

        let root = try XCTUnwrap(outline.closeConfirmation(ofWorkspace: "app"))
        XCTAssertTrue(root.closesGroup)
        XCTAssertEqual([root.otherWorkspaceCount, root.tabCount, root.paneCount], [2, 4, 5])
        XCTAssertEqual(root.request, .close(.workspace("app"), group: true))
        XCTAssertEqual(root.dialog, GhosttyCloseConfirmation(
            title: "Close Worktree Group?",
            message: "“app” and its 2 other workspaces will close, with 4 tabs and 5 panes.",
            action: "Close Worktree Group"
        ))
        let linked = try XCTUnwrap(outline.closeConfirmation(ofWorkspace: "feature"))
        XCTAssertFalse(linked.closesGroup)
        XCTAssertEqual(linked.request, .close(.workspace("feature"), group: false))
        XCTAssertNil(outline.closeConfirmation(before: .tab("app-t1")), "the group's close was asked before Herdr's server")
        XCTAssertNotNil(outline.closeConfirmation(before: .pane("notes-p1")))

        let twoRoots = HerdrSessionOutline(try closingSnapshot([
            ("app", [["app-p1"]], ("repo", false)),
            ("clone", [["clone-p1"]], ("repo", false)),
        ]), after: nil)
        XCTAssertEqual(twoRoots.closeConfirmation(ofWorkspace: "app")?.closesGroup, false, "a second checkout made a group")
    }

    /// A rename starts with the place's name and Herdr's automatic name as the placeholder: a tab's number,
    /// a pane's name without its manual label, and a workspace's label while it is Herdr's.
    func testARenameStartsWithTheNameAndHerdrsAutomaticOne() throws {
        let json = """
        {"boot_id":"boot","revision":1,"focused_workspace_id":"w1","focused_tab_id":"t2","focused_pane_id":"p1",
         "workspaces":[{"workspace_id":"w1","active_tab_id":"t2","number":1,"label":"api","custom_label":false,"focused":true,"agent_status":"idle"},
                       {"workspace_id":"w2","active_tab_id":"t3","number":2,"label":"docs","custom_label":true,"focused":false,"agent_status":"idle"}],
         "tabs":[{"tab_id":"t1","workspace_id":"w1","number":1,"label":"1","custom_label":false,"zoomed":false,"focused":false,"agent_status":"idle"},
                 {"tab_id":"t2","workspace_id":"w1","number":2,"label":"build","custom_label":true,"zoomed":false,"focused":true,"agent_status":"idle"},
                 {"tab_id":"t3","workspace_id":"w2","number":1,"label":"1","custom_label":false,"zoomed":false,"focused":false,"agent_status":"idle"}],
         "panes":[\(HerdrServerScript.snapshotPane("p1", tab: "t2", label: "server")),\(HerdrServerScript.snapshotPane("p2", tab: "t2"))],
         "agents":[\(HerdrServerScript.snapshotAgent("p2", agent: "claude", tab: "t2", status: .working, stateChange: 1))]}
        """
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.renameField(for: .tab("t2")), TerminalRenameField(name: "build", placeholder: "2"))
        XCTAssertEqual(snapshot.renameField(for: .tab("t3")), TerminalRenameField(name: "1", placeholder: "1"))
        XCTAssertEqual(snapshot.renameField(for: .pane("p1")), TerminalRenameField(name: "server", placeholder: "terminal"))
        XCTAssertEqual(snapshot.renameField(for: .pane("p2")), TerminalRenameField(name: "", placeholder: "claude"))
        XCTAssertEqual(snapshot.renameField(for: .workspace("w1")), TerminalRenameField(name: "api", placeholder: "api"))
        XCTAssertEqual(snapshot.renameField(for: .workspace("w2")), TerminalRenameField(name: "docs", placeholder: "Name"))
        XCTAssertNil(snapshot.renameField(for: .tab("gone")))
        XCTAssertTrue(snapshot.isOnScreen(.pane("p2")))
        XCTAssertTrue(snapshot.isOnScreen(.workspace("w1")))
        XCTAssertFalse(snapshot.isOnScreen(.tab("t1")))
    }

    /// Closes and renames carry the place's id under its own key, as Herdr's client sends them; only a
    /// workspace's close says whether it closes its worktree group.
    func testClosesAndRenamesSendHerdrsClientsParams() throws {
        func encoded(_ params: HerdrPlaceParams) throws -> [String: AnyHashable] {
            let data = try JSONEncoder().encode(params)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        }
        XCTAssertEqual(HerdrPlace.pane("p1").closeMethod, "pane.close")
        XCTAssertEqual(try encoded(HerdrPlace.pane("p1").closeParams(group: true)), ["pane_id": "p1"])
        XCTAssertEqual(HerdrPlace.tab("t1").closeMethod, "tab.close")
        XCTAssertEqual(try encoded(HerdrPlace.tab("t1").closeParams(group: false)), ["tab_id": "t1"])
        XCTAssertEqual(HerdrPlace.workspace("w1").closeMethod, "workspace.close")
        XCTAssertEqual(try encoded(HerdrPlace.workspace("w1").closeParams(group: true)), ["workspace_id": "w1", "close_group": true])
        XCTAssertEqual(HerdrPlace.tab("t1").renameMethod, "tab.rename")
        XCTAssertEqual(try encoded(HerdrPlace.tab("t1").renameParams("build")), ["tab_id": "t1", "label": "build"])
        XCTAssertEqual(HerdrPlace.pane("p1").renameMethod, "pane.rename")
        XCTAssertEqual(try encoded(HerdrPlace.pane("p1").renameParams("")), ["pane_id": "p1", "label": ""])
        XCTAssertEqual(HerdrPlace.workspace("w1").renameMethod, "workspace.rename")
    }

    /// Workspaces in Herdr's order, each with its tabs' panes and, when in a repository, its worktree key
    /// and whether it is a linked worktree. This phone is in the first workspace's first tab.
    private func closingSnapshot(
        _ workspaces: [(name: String, tabs: [[String]], worktree: (key: String, linked: Bool)?)]
    ) throws -> HerdrSnapshot {
        let first = workspaces[0]
        let entries = workspaces.enumerated().map { index, workspace in
            let worktree = workspace.worktree.map {
                #"{"key":"\#($0.key)","label":"repo","is_linked_worktree":\#($0.linked)}"#
            } ?? "null"
            return #"{"workspace_id":"\#(workspace.name)","active_tab_id":"\#(workspace.name)-t1","number":\#(index + 1),"label":"\#(workspace.name)","custom_label":true,"focused":\#(index == 0),"agent_status":"idle","worktree":\#(worktree)}"#
        }
        let tabs = workspaces.flatMap { workspace in
            workspace.tabs.indices.map { index in
                #"{"tab_id":"\#(workspace.name)-t\#(index + 1)","workspace_id":"\#(workspace.name)","number":\#(index + 1),"label":"\#(index + 1)","custom_label":false,"zoomed":false,"focused":\#(workspace.name == first.name && index == 0),"agent_status":"idle"}"#
            }
        }
        let panes = workspaces.flatMap { workspace in
            workspace.tabs.enumerated().flatMap { index, panes in
                panes.map { HerdrServerScript.snapshotPane($0, workspace: workspace.name, tab: "\(workspace.name)-t\(index + 1)") }
            }
        }
        let json = """
        {"boot_id":"boot","revision":1,"focused_workspace_id":"\(first.name)","focused_tab_id":"\(first.name)-t1",
         "focused_pane_id":"\(first.tabs[0][0])","workspaces":[\(entries.joined(separator: ","))],
         "tabs":[\(tabs.joined(separator: ","))],"panes":[\(panes.joined(separator: ","))],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }

    /// Workspaces named by `workspaces`, each with tabs `<name>-t1` (one pane) and `<name>-t2` (two
    /// panes), this phone in `focusedWorkspace` at its tab from `activeTabs`, else its first.
    private func snapshot(
        boot: String = "boot",
        revision: UInt64 = 1,
        workspaces: [String],
        focusedWorkspace: String,
        activeTabs: [String: String] = [:]
    ) throws -> HerdrSnapshot {
        let focusedTab = activeTabs[focusedWorkspace] ?? "\(focusedWorkspace)-t1"
        let entries = workspaces.enumerated().map { index, name in
            #"{"workspace_id":"\#(name)","active_tab_id":"\#(activeTabs[name] ?? "\(name)-t1")","number":\#(index + 1),"label":"\#(name)","custom_label":true,"focused":\#(name == focusedWorkspace),"agent_status":"idle"}"#
        }
        let tabs = workspaces.flatMap { name in
            ["t1", "t2"].enumerated().map { index, tab in
                #"{"tab_id":"\#(name)-\#(tab)","workspace_id":"\#(name)","number":\#(index + 1),"label":"\#(tab)","custom_label":false,"zoomed":false,"focused":\#("\(name)-\(tab)" == focusedTab),"agent_status":"idle"}"#
            }
        }
        let panes = workspaces.flatMap { name in
            [("t1", 1), ("t2", 2)].flatMap { tab, count in
                (1...count).map { pane in
                    HerdrServerScript.snapshotPane("\(name)-\(tab)-p\(pane)", workspace: name, tab: "\(name)-\(tab)")
                }
            }
        }
        let json = """
        {"boot_id":"\(boot)","revision":\(revision),"focused_workspace_id":"\(focusedWorkspace)","focused_tab_id":"\(focusedTab)",
         "focused_pane_id":null,"workspaces":[\(entries.joined(separator: ","))],"tabs":[\(tabs.joined(separator: ","))],
         "panes":[\(panes.joined(separator: ","))],"agents":[]}
        """
        return try JSONDecoder().decode(HerdrSnapshot.self, from: Data(json.utf8))
    }
}
