import Foundation
import XCTest
@testable import Remux

final class SessionSwitcherProjectionTests: XCTestCase {
    func testAvailableSessionsFollowServerOrderWithNamesSortedWithinEachServer() {
        let zulu = makeServer(name: "Zulu")
        let alpha = makeServer(name: "Alpha")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [zulu, alpha], workspaces: []),
            activeSessions: [],
            discoveries: [
                zulu.id: loadedDiscovery(["z", "a"]),
                alpha.id: loadedDiscovery(["b"]),
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.availableSessions.map(\.id.serverID), [zulu.id, zulu.id, alpha.id])
        XCTAssertEqual(projection.availableSessions.map(\.id.locator.name), ["a", "z", "b"])
    }

    /// Herdr's sessions join tmux's in one list sorted by name. A tmux and a Herdr session with the same
    /// name are different sessions, and Herdr's stopped sessions are listed too.
    func testAvailableSessionsMixBothBackendsByName() {
        let server = makeServer(name: "Mini")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: []),
            activeSessions: [],
            discoveries: [
                server.id: loadedDiscovery(["main", "default"], herdr: [
                    DiscoveredSession(name: "default", isRunning: true),
                    DiscoveredSession(name: "agents", isRunning: false),
                ]),
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.availableSessions.map(\.id.locator), [
            SessionLocator(backend: .herdr, name: "agents"),
            SessionLocator(backend: .tmux, name: "default"),
            SessionLocator(backend: .herdr, name: "default"),
            SessionLocator(backend: .tmux, name: "main"),
        ])
        XCTAssertEqual(projection.availableSessions.map(\.isRunning), [false, true, true, true])
    }

    /// A Herdr session Herdr can't reach is listed with its reason, so the sheet shows it unavailable.
    func testAnUnreachableHerdrSessionIsListedWithItsReason() {
        let server = makeServer(name: "Mini")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: []),
            activeSessions: [],
            discoveries: [
                server.id: loadedDiscovery([], herdr: [
                    DiscoveredSession(name: "locked", isRunning: false, unavailableReason: "Permission denied"),
                    DiscoveredSession(name: "open", isRunning: true),
                ]),
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.availableSessions.map(\.unavailableReason), ["Permission denied", nil])
    }

    /// A saved session that its server's newest list marks unavailable shows so under Recent, with Herdr's
    /// reason, as it does under Available: the reason has one owner, the server's discovery, keyed by the
    /// session's backend and name. A tmux session of the same name, or another Herdr session, stays offered.
    func testASavedSessionHerdrCannotReachIsUnavailableUnderRecent() {
        let server = makeServer(name: "Mini")
        let locked = SavedWorkspace(serverID: server.id, backend: .herdr, sessionName: "locked")
        let lockedTmux = SavedWorkspace(serverID: server.id, backend: .tmux, sessionName: "locked")
        let open = SavedWorkspace(serverID: server.id, backend: .herdr, sessionName: "open")
        let discovery = loadedDiscovery(["locked"], herdr: [
            DiscoveredSession(name: "locked", isRunning: false, unavailableReason: "Permission denied"),
            DiscoveredSession(name: "open", isRunning: true),
        ])
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: [locked, lockedTmux, open]),
            activeSessions: [],
            discoveries: [server.id: discovery],
            selectedSessionID: nil
        )

        let recent = Dictionary(uniqueKeysWithValues: projection.recentSessions.map { ($0.id, $0.unavailableReason) })
        XCTAssertEqual(recent[locked.id], .some("Permission denied"))
        XCTAssertEqual(recent[lockedTmux.id], .some(nil))
        XCTAssertEqual(recent[open.id], .some(nil))
        XCTAssertEqual(discovery.unavailableReason(of: locked.locator), "Permission denied")
        XCTAssertNil(discovery.unavailableReason(of: lockedTmux.locator))
    }

    /// The switcher names a server only when none of its sessions could be listed. A missing Herdr, even
    /// where a Herdr session is saved, leaves the server's tmux sessions listed.
    func testOnlyAServerNoneOfWhoseSessionsCouldBeListedIsUnchecked() {
        let herdrMissing = makeServer(name: "Herdr Missing")
        let unreachable = makeServer(name: "Unreachable")
        let saved = SavedWorkspace(serverID: herdrMissing.id, backend: .herdr, sessionName: "default")
        var missing = loadedDiscovery(["main"])
        missing.herdr = SessionDiscoveryState.idle.failingRefresh(problem: .notFound)
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [herdrMissing, unreachable], workspaces: [saved]),
            activeSessions: [],
            discoveries: [
                herdrMissing.id: missing,
                unreachable.id: ServerSessionDiscovery.idle.mapping { $0.failingRefresh() },
            ],
            selectedSessionID: nil
        )
        XCTAssertEqual(projection.uncheckedServerIDs, [unreachable.id])
    }

    @MainActor
    func testLastOpenedPresentationUsesJustNowForRecentDates() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            SessionLastOpenedText.value(
                for: referenceDate.addingTimeInterval(-30),
                relativeTo: referenceDate
            ),
            "Opened just now"
        )
    }

    func testProjectionPreservesCanonicalActiveOrderAndMarksSelection() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let newest = makeWorkspace(
            server: production,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        let selected = makeWorkspace(
            server: macMini,
            name: "codex",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [production, macMini],
                workspaces: [newest, selected]
            ),
            activeSessions: [
                makeSession(server: production, workspace: newest),
                makeSession(server: macMini, workspace: selected),
            ],
            selectedSessionID: selected.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [newest.id, selected.id])
        XCTAssertEqual(projection.activeSessions.map(\.sessionName), ["api", "codex"])
        XCTAssertEqual(projection.activeSessions.map(\.serverName), ["Production", "Mac Mini"])
        XCTAssertEqual(projection.activeSessions.map(\.isSelected), [false, true])
    }

    func testProjectionKeepsEveryActiveRuntimeWhenNamesMatch() {
        let server = makeServer(name: "Production")
        let first = makeWorkspace(
            server: server,
            name: "shared",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let second = makeWorkspace(
            server: server,
            name: "shared",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: [first, second]),
            activeSessions: [
                makeSession(server: server, workspace: first),
                makeSession(server: server, workspace: second),
            ],
            discoveries: [server.id: loadedDiscovery(["shared"])],
            selectedSessionID: second.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(projection.activeSessions.map(\.isSelected), [false, true])
        XCTAssertTrue(projection.availableSessions.isEmpty)
    }

    func testProjectionSeparatesConfirmedRecentFromGlobalAvailableSessions() {
        let production = makeServer(name: "Production")
        let staging = makeServer(name: "Staging")
        let active = makeWorkspace(
            server: production,
            name: "active",
            lastOpenedAt: Date(timeIntervalSince1970: 300)
        )
        let recent = makeWorkspace(
            server: production,
            name: "recent",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let missing = makeWorkspace(
            server: production,
            name: "gone",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [production, staging],
                workspaces: [active, recent, missing]
            ),
            activeSessions: [makeSession(server: production, workspace: active)],
            discoveries: [
                production.id: loadedDiscovery(["active", "recent", "remote"]),
                staging.id: loadedDiscovery(["logs"]),
            ],
            selectedSessionID: active.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [active.id])
        XCTAssertEqual(projection.recentSessions.map(\.id), [recent.id])
        XCTAssertEqual(
            projection.availableSessions.map(\.id),
            [
                RemoteSessionIdentity(serverID: production.id, locator: SessionLocator(backend: .tmux, name: "remote")),
                RemoteSessionIdentity(serverID: staging.id, locator: SessionLocator(backend: .tmux, name: "logs")),
            ]
        )
        XCTAssertFalse(projection.recentSessions.contains { $0.id == missing.id })
        XCTAssertFalse(
            projection.availableSessions.contains { $0.id.locator.name == "recent" }
        )
        XCTAssertEqual(projection.availableSessions(on: production.id).map(\.id.locator.name), ["remote"])
        XCTAssertEqual(projection.availableSessions(on: staging.id).map(\.id.locator.name), ["logs"])
    }

    func testSameNamedTmuxAndHerdrSessionsStayDistinct() {
        let server = makeServer(name: "Production")
        let herdrOps = SavedWorkspace(
            serverID: server.id,
            backend: .herdr,
            sessionName: "ops",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let herdrAgents = SavedWorkspace(
            serverID: server.id,
            backend: .herdr,
            sessionName: "agents",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: [herdrOps, herdrAgents]),
            activeSessions: [],
            discoveries: [server.id: loadedDiscovery(["ops"])],
            selectedSessionID: nil
        )

        // tmux discovery neither hides Herdr sessions it doesn't list nor
        // treats a Herdr "ops" as the tmux "ops" it does list.
        XCTAssertEqual(projection.recentSessions.map(\.id), [herdrOps.id, herdrAgents.id])
        XCTAssertEqual(
            projection.availableSessions.map(\.id),
            [RemoteSessionIdentity(serverID: server.id, locator: SessionLocator(backend: .tmux, name: "ops"))]
        )
    }

    func testProjectionKeepsLargeAvailableInventoryOutOfQuickSheet() {
        let server = makeServer(name: "Production")
        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: []),
            activeSessions: [],
            discoveries: [
                server.id: loadedDiscovery(["one", "two", "three", "four", "five"]),
            ],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.availableSessions.count, 5)
        XCTAssertEqual(projection.inlineAvailableSessions.count, 3)
        XCTAssertEqual(projection.hiddenAvailableSessionCount, 2)
        XCTAssertEqual(
            projection.availableSessions(on: server.id),
            projection.availableSessions
        )
        XCTAssertEqual(
            projection.inlineAvailableSessions.map(\.id.locator.name),
            Array(projection.availableSessions.prefix(3)).map(\.id.locator.name)
        )
    }

    func testProjectionIncludesEveryInactiveWorkspaceInRecentOrder() {
        let server = makeServer(name: "Mac Mini")
        let workspaces = (0..<7).map { index in
            makeWorkspace(
                server: server,
                name: "session-\(index)",
                lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(servers: [server], workspaces: workspaces),
            activeSessions: [],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.recentSessions.count, 7)
        XCTAssertEqual(
            projection.recentSessions.map(\.sessionName),
            (0..<7).reversed().map { "session-\($0)" }
        )
        XCTAssertEqual(projection.recentSessions.map(\.serverName), Array(repeating: "Mac Mini", count: 7))
    }

    func testProjectionExcludesActiveWorkspaceFromRecentSessionsByIdentity() {
        let server = makeServer(name: "Production")
        let persistedActive = makeWorkspace(
            server: server,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        var runtimeActive = persistedActive
        runtimeActive.lastOpenedAt = Date(timeIntervalSince1970: 300)
        let recent = makeWorkspace(
            server: server,
            name: "logs",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [server],
                workspaces: [persistedActive, recent]
            ),
            activeSessions: [makeSession(server: server, workspace: runtimeActive)],
            selectedSessionID: runtimeActive.id
        )

        XCTAssertEqual(projection.activeSessions.map(\.id), [runtimeActive.id])
        XCTAssertEqual(projection.recentSessions.map(\.id), [recent.id])
    }

    func testProjectionOmitsWorkspaceWhoseServerIsUnavailable() {
        let savedServer = makeServer(name: "Production")
        let missingServer = makeServer(name: "Removed")
        let available = makeWorkspace(
            server: savedServer,
            name: "api",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let orphan = makeWorkspace(
            server: missingServer,
            name: "orphan",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        let projection = SessionSwitcherProjection(
            snapshot: snapshot(
                servers: [savedServer],
                workspaces: [available, orphan]
            ),
            activeSessions: [],
            selectedSessionID: nil
        )

        XCTAssertEqual(projection.recentSessions.map(\.id), [available.id])
    }

    func testOrderedServersPlacesCurrentServerFirstAndPreservesLibraryOrder() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let staging = makeServer(name: "Staging")

        let ordered = SessionSwitcherProjection.orderedServers(
            [production, staging, macMini],
            currentServerID: staging.id
        )

        XCTAssertEqual(ordered.map(\.id), [staging.id, production.id, macMini.id])
        XCTAssertEqual(
            SessionSwitcherProjection.orderedServers([production, macMini], currentServerID: nil),
            [production, macMini]
        )
    }

    private func snapshot(
        servers: [SavedServer],
        workspaces: [SavedWorkspace]
    ) -> ConnectionLibrarySnapshot {
        ConnectionLibrarySnapshot(servers: servers, workspaces: workspaces)
    }

    private func makeWorkspace(
        server: SavedServer,
        name: String,
        lastOpenedAt: Date
    ) -> SavedWorkspace {
        SavedWorkspace(
            serverID: server.id,
            sessionName: name,
            lastOpenedAt: lastOpenedAt
        )
    }

    private func makeSession(
        server: SavedServer,
        workspace: SavedWorkspace
    ) -> ActiveTerminalSession {
        let auth = ResolvedSSHAuth.password(
            username: server.username,
            password: "test-password",
            identityID: server.identityID,
            displayLabel: server.displayName
        )
        return ActiveTerminalSession(
            target: SessionTarget(
                server: server,
                workspace: workspace,
                sshAuth: auth
            ),
            runtimeState: .connected
        )
    }

    /// The session the user is in is marked on its row, as a list marks its current choice, unless the row
    /// is open over its workspaces, which mark the one the user is in.
    func testTheSessionYoureInIsMarkedOnItsRowUnlessItListsItsWorkspaces() {
        let current = item(.herdr, "default", on: "devbox", selected: true)
        let other = item(.herdr, "train", on: "gpu-box")
        XCTAssertTrue(current.showsCheckmark(disclosure: nil), "a session without workspaces listed")
        XCTAssertTrue(current.showsCheckmark(disclosure: false), "a collapsed session")
        XCTAssertFalse(current.showsCheckmark(disclosure: true), "an expanded session")
        XCTAssertFalse([nil, false, true].contains { other.showsCheckmark(disclosure: $0) })
    }

    // MARK: - Agents

    private func item(
        _ backend: SessionBackend,
        _ sessionName: String,
        on serverName: String,
        _ runtimeState: TerminalRuntimeState = .connected,
        selected: Bool = false
    ) -> ActiveSessionSwitcherItem {
        ActiveSessionSwitcherItem(
            id: UUID(),
            backend: backend,
            sessionName: sessionName,
            serverName: serverName,
            runtimeState: runtimeState,
            isSelected: selected
        )
    }

    /// Every agent's state change in these sessions was seen at the same time, so only state and order decide.
    private let seen = ContinuousClock.now

    private func agents(_ statuses: [(pane: String, status: HerdrAgentStatus)]) throws -> HerdrAgentPresentation {
        try HerdrSnapshotJSON.presentation(statuses, seen: seen)
    }

    private func working(_ pane: String, stateChange: UInt64) -> String {
        HerdrServerScript.snapshotAgent(pane, agent: "claude", status: .working, stateChange: stateChange)
    }

    private func panes(_ entries: [SessionAgentsProjection.Entry]) -> [String] {
        entries.map(\.agent.paneID)
    }

    /// The Agents list has every agent of the open Herdr sessions in one list, as Herdr's client lists all its
    /// machines' agents by priority: connected sessions' agents first, then blocked, done, working, idle, and
    /// those whose state isn't known yet. Each session is named by its server and, unless it is Herdr's
    /// default session, its name.
    func testTheAgentsListPutsTheMostUrgentFirstAndDisconnectedSessionsLast() throws {
        let tmux = item(.tmux, "main", on: "mac-mini")
        let devbox = item(.herdr, "default", on: "devbox")
        let quiet = item(.herdr, "notes", on: "devbox")
        let training = item(.herdr, "train", on: "gpu-box", .reconnecting(.transportLoss))
        let laptop = item(.herdr, "web", on: "laptop")
        let unreported = item(.herdr, "fresh", on: "gpu-box")
        let agents = [
            devbox.id: try agents([("w1:p1", .working), ("w1:p2", .idle), ("w1:p3", .blocked)]),
            quiet.id: try agents([]),
            training.id: try agents([("w1:p1", .blocked)]),
            laptop.id: try agents([("w1:p1", .done), ("w1:p2", .unknown)]),
        ]
        let projection = SessionAgentsProjection(
            activeSessions: [tmux, devbox, quiet, training, laptop, unreported],
            agents: { agents[$0] }
        )
        XCTAssertEqual(
            projection.entries.map(\.session.id),
            [devbox.id, laptop.id, devbox.id, devbox.id, laptop.id, training.id]
        )
        XCTAssertEqual(panes(projection.entries), ["w1:p3", "w1:p1", "w1:p1", "w1:p2", "w1:p2", "w1:p1"])
        XCTAssertEqual(projection.entries.first?.session.serverName, "devbox")
        XCTAssertNil(projection.entries.first?.session.sessionName, "Herdr's default session isn't named.")
        XCTAssertEqual(projection.entries.last?.session.serverName, "gpu-box")
        XCTAssertEqual(projection.entries.last?.session.sessionName, "train")
        XCTAssertEqual(projection.entries.last?.session.isStale, true)
        XCTAssertEqual(projection.entries.first?.session.bootID, "boot")
        XCTAssertTrue(projection.namesSessions)
    }

    /// Among agents in the same state, the one whose state changed most recently comes first, as Herdr's
    /// client counts the changes it sees itself: two servers' change numbers can't be compared, so when the
    /// phone saw the change decides, and Herdr's numbers only order the changes of one snapshot. A snapshot
    /// that doesn't change an agent's state leaves it where it was.
    func testTheNewestStateChangeComesFirstAcrossSessions() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let training = item(.herdr, "train", on: "gpu-box")
        let start = ContinuousClock.now
        let devboxAgents = HerdrAgentPresentation()
        let trainingAgents = HerdrAgentPresentation()
        let agents = [devbox.id: devboxAgents, training.id: trainingAgents]
        func sessions() -> [SavedWorkspace.ID] {
            SessionAgentsProjection(activeSessions: [devbox, training], agents: { agents[$0] }).entries.map(\.session.id)
        }

        devboxAgents.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [working("w1:p1", stateChange: 1)]), completions: nil, now: start)
        trainingAgents.project(
            try HerdrSnapshotJSON.twoWorkspaces(agents: [working("w1:p1", stateChange: 5)]),
            completions: nil,
            now: start + .seconds(1)
        )
        XCTAssertEqual(sessions(), [training.id, devbox.id])

        devboxAgents.project(
            try HerdrSnapshotJSON.twoWorkspaces(revision: 2, agents: [working("w1:p1", stateChange: 2)]),
            completions: nil,
            now: start + .seconds(2)
        )
        XCTAssertEqual(sessions(), [devbox.id, training.id], "a newer change, though its number is lower")

        trainingAgents.project(
            try HerdrSnapshotJSON.twoWorkspaces(revision: 2, agents: [working("w1:p1", stateChange: 5)]),
            completions: nil,
            now: start + .seconds(3)
        )
        XCTAssertEqual(sessions(), [devbox.id, training.id], "a snapshot with the same change")

        let oneSnapshot = HerdrAgentPresentation()
        oneSnapshot.project(
            try HerdrSnapshotJSON.twoWorkspaces(agents: [working("w1:p1", stateChange: 3), working("w1:p2", stateChange: 7)]),
            completions: nil,
            now: start
        )
        let projection = SessionAgentsProjection(activeSessions: [devbox], agents: { _ in oneSnapshot })
        XCTAssertEqual(panes(projection.entries), ["w1:p2", "w1:p1"])
        XCTAssertFalse(projection.namesSessions, "one session's agents")
    }

    /// The list has a section for each state that has agents, in the order of how much each needs the user:
    /// Blocked, Done, Working, Idle. An agent whose state isn't known yet is in Idle. A state without agents
    /// has no section. The agents of a session that isn't connected are in a last section named by that
    /// session's status, whatever their states.
    func testTheListHasASectionForEachStateThatHasAgents() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let training = item(.herdr, "train", on: "gpu-box", .reconnecting(.transportLoss))
        let agents = [
            devbox.id: try agents([("w1:p1", .working), ("w1:p2", .unknown), ("w1:p3", .blocked), ("w1:p4", .idle)]),
            training.id: try agents([("w1:p1", .working), ("w1:p2", .blocked)]),
        ]
        let projection = SessionAgentsProjection(activeSessions: [devbox, training], agents: { agents[$0] })
        XCTAssertEqual(projection.sections.map(\.group), [.blocked, .working, .idle, .notConnected("Reconnecting")])
        XCTAssertEqual(projection.sections.map(\.group.title), ["Blocked", "Working", "Idle", "Reconnecting"])
        XCTAssertEqual(projection.sections.map { panes($0.entries) }, [
            ["w1:p3"], ["w1:p1"], ["w1:p2", "w1:p4"], ["w1:p2", "w1:p1"],
        ])
        XCTAssertEqual(projection.entries, projection.sections.flatMap(\.entries))
        XCTAssertEqual(projection.sections.last?.group.status, nil)
    }

    /// A row is its agent in one section. When the agent changes state the row in its old section goes and a
    /// new one comes in its new section, which is what makes the list fade it between the two places (the
    /// user's decision of 11 November 2026: sliding the same row there blinks over a long distance).
    func testAnAgentThatChangesStateIsANewRowInItsNewSection() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let presentation = HerdrAgentPresentation()
        func entry() throws -> SessionAgentsProjection.Entry {
            try XCTUnwrap(SessionAgentsProjection(activeSessions: [devbox], agents: { _ in presentation }).entries.first)
        }
        presentation.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [working("w1:p1", stateChange: 1)]), completions: nil)
        let before = try entry()
        presentation.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [working("w1:p1", stateChange: 1)]), completions: nil)
        XCTAssertEqual(try entry().id, before.id, "A snapshot that changes nothing keeps the row.")

        presentation.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [
            HerdrServerScript.snapshotAgent("w1:p1", agent: "claude", status: .blocked, stateChange: 2),
        ]), completions: nil)
        let blocked = try entry()
        XCTAssertEqual(blocked.agent.paneID, before.agent.paneID)
        XCTAssertEqual(blocked.group, .blocked)
        XCTAssertNotEqual(blocked.id, before.id)
    }

    /// Home shows the list's first three agents, whatever their states, and says there are more only when
    /// there are. Its last row says what all the agents are doing, section by section in the list's order,
    /// and gives shorter lines that leave whole sections off the end for a row too narrow.
    func testHomeShowsTheFirstThreeAgentsAndWhatAllOfThemAreDoing() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let training = item(.herdr, "train", on: "gpu-box", .reconnecting(.transportLoss))
        let agents = [
            devbox.id: try agents([
                ("w1:p1", .idle), ("w1:p2", .working), ("w1:p3", .blocked), ("w1:p4", .idle), ("w1:p5", .done),
            ]),
            training.id: try agents([("w1:p1", .blocked)]),
        ]
        let projection = SessionAgentsProjection(activeSessions: [devbox, training], agents: { agents[$0] })
        XCTAssertEqual(panes(projection.homeEntries), ["w1:p3", "w1:p5", "w1:p2"])
        XCTAssertTrue(projection.hasMoreThanHomeShows)
        XCTAssertEqual(projection.summaries, [
            "1 blocked · 1 done · 1 working · 2 idle · 1 reconnecting",
            "1 blocked · 1 done · 1 working · 2 idle",
            "1 blocked · 1 done · 1 working",
            "1 blocked · 1 done",
            "1 blocked",
        ])

        let few = [devbox.id: try self.agents([("w1:p1", .idle), ("w1:p2", .working), ("w1:p3", .idle)])]
        let small = SessionAgentsProjection(activeSessions: [devbox], agents: { few[$0] })
        XCTAssertEqual(panes(small.homeEntries), ["w1:p2", "w1:p1", "w1:p3"])
        XCTAssertFalse(small.hasMoreThanHomeShows)
        XCTAssertEqual(small.summaries.first, "1 working · 2 idle")
    }

    /// The line under an agent's heading is always in one order, the general before the specific: machine,
    /// session, workspace › tab, then the name the user gave the agent. Too long, it loses whole names, never
    /// letters: the session first, then the workspace, which leaves "…" so the tab still reads as a tab, then
    /// the given name, then the machine. The place's last name always stays.
    func testAnAgentsPlaceLosesWholeNamesInAFixedOrder() {
        XCTAssertEqual(
            SessionAgentsProjection.placeLines(
                machine: "mac mini", session: "work", workspace: "remux-herdr", tab: "keyboard", givenName: "fixer"
            ),
            [
                "mac mini · work · remux-herdr › keyboard · fixer",
                "mac mini · remux-herdr › keyboard · fixer",
                "mac mini · … › keyboard · fixer",
                "mac mini · … › keyboard",
                "… › keyboard",
            ]
        )
        // One session's agents: no machine or session to name.
        XCTAssertEqual(
            SessionAgentsProjection.placeLines(machine: nil, session: nil, workspace: "api", tab: "auth", givenName: nil),
            ["api › auth", "… › auth"]
        )
        // Without a tab the workspace is the last name of the place, so it stays.
        XCTAssertEqual(
            SessionAgentsProjection.placeLines(machine: "devbox", session: nil, workspace: "web", tab: nil, givenName: "fixer"),
            ["devbox · web · fixer", "devbox · web", "web"]
        )
        XCTAssertEqual(
            SessionAgentsProjection.placeLines(machine: nil, session: nil, workspace: nil, tab: nil, givenName: nil),
            []
        )
    }

    /// A row names its machine, and its session unless that is Herdr's default one, only when the list has
    /// agents from more than one session.
    func testARowNamesItsMachineAndSessionOnlyAmongSeveralSessions() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let training = item(.herdr, "train", on: "gpu-box")
        let agents = [devbox.id: try agents([("w1:p1", .working)]), training.id: try agents([("w1:p1", .blocked)])]
        let both = SessionAgentsProjection(activeSessions: [devbox, training], agents: { agents[$0] })
        XCTAssertEqual(both.entries.map { $0.placeLines(namesSession: both.namesSessions).first }, [
            "gpu-box · train · api › agents", "devbox · api › agents",
        ])
        let one = SessionAgentsProjection(activeSessions: [devbox], agents: { agents[$0] })
        XCTAssertEqual(one.entries.first?.placeLines(namesSession: one.namesSessions).first, "api › agents")
    }

    /// A row leads with the title its agent's program sets, word for word, and falls back to the agent's name.
    /// The name the user gave the agent isn't repeated under a heading that already says it.
    func testARowLeadsWithItsAgentsOwnTitle() throws {
        let devbox = item(.herdr, "default", on: "devbox")
        let presentation = HerdrAgentPresentation()
        func entry(name: String?, stripped: String?) throws -> SessionAgentsProjection.Entry {
            presentation.project(try HerdrSnapshotJSON.twoWorkspaces(agents: [HerdrServerScript.snapshotAgent(
                "w1:p1", name: name, terminalTitleStripped: stripped, agent: "claude", tab: "t2"
            )]), completions: nil)
            return try XCTUnwrap(SessionAgentsProjection(activeSessions: [devbox], agents: { _ in presentation }).entries.first)
        }
        let titled = try entry(name: "fixer", stripped: "remux | Fix [tests] (2/3)")
        XCTAssertEqual(titled.heading, "remux | Fix [tests] (2/3)")
        XCTAssertEqual(titled.placeLines(namesSession: false).first, "api › auth · fixer")

        let untitled = try entry(name: "fixer", stripped: nil)
        XCTAssertEqual(untitled.heading, "fixer")
        XCTAssertEqual(untitled.placeLines(namesSession: false).first, "api › auth", "The heading already says the name.")
        XCTAssertEqual(try entry(name: nil, stripped: nil).heading, "claude")
    }

    /// One touch opens one agent: a second open within half a second of the first is dropped, since a row that
    /// fades into a new place as a finger lifts can report the tap twice.
    func testOneTouchOpensOneAgent() {
        var gate = AgentOpenGate()
        let start = ContinuousClock.now
        XCTAssertTrue(gate.admits(at: start))
        XCTAssertFalse(gate.admits(at: start + .milliseconds(30)))
        XCTAssertFalse(gate.admits(at: start + .milliseconds(499)))
        XCTAssertTrue(gate.admits(at: start + .milliseconds(600)))
    }

    private func loadedDiscovery(
        _ tmuxNames: [String],
        herdr: [DiscoveredSession]? = nil
    ) -> ServerSessionDiscovery {
        ServerSessionDiscovery(
            tmux: SessionDiscoveryState.idle.finishingRefresh(with: SessionListing(
                executablePath: "/usr/bin/tmux",
                sessions: tmuxNames.map { DiscoveredSession(name: $0, isRunning: true) }
            )),
            herdr: herdr.map {
                SessionDiscoveryState.idle.finishingRefresh(
                    with: SessionListing(executablePath: "/usr/local/bin/herdr", sessions: $0)
                )
            } ?? .idle
        )
    }

    private func makeServer(name: String) -> SavedServer {
        SavedServer(
            displayName: name,
            host: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).example.test",
            username: "tester",
            identityID: UUID()
        )
    }
}
