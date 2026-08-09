import Foundation
import XCTest
@testable import Remux

final class SessionSwitcherProjectionTests: XCTestCase {
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

    func testOrderedServersPlacesCurrentServerFirstThenSortsByName() {
        let production = makeServer(name: "Production")
        let macMini = makeServer(name: "Mac Mini")
        let staging = makeServer(name: "Staging")

        let ordered = SessionSwitcherProjection.orderedServers(
            [production, staging, macMini],
            currentServerID: staging.id
        )

        XCTAssertEqual(ordered.map(\.id), [staging.id, macMini.id, production.id])
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
            target: TmuxConnectionTarget(
                server: server,
                workspace: workspace,
                sshAuth: auth
            ),
            runtimeState: .connected
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
