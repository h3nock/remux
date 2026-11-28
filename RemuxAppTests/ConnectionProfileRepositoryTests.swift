import Security
import XCTest
@testable import Remux

final class ConnectionProfileRepositoryTests: XCTestCase {
    func testCustomServerOrderSurvivesReloadRenameInsertAndDelete() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        var alpha = SavedServer(displayName: "Alpha", host: "alpha.example.test", username: "demo")
        let beta = SavedServer(displayName: "Beta", host: "beta.example.test", username: "demo")
        let newest = SavedServer(displayName: "A New Server", host: "new.example.test", username: "demo")
        let workspace = SavedWorkspace(serverID: alpha.id, sessionName: "work")
        try await repository.saveProfile(server: alpha, workspace: workspace)
        try await repository.saveServer(beta)
        let serverData = try Data(contentsOf: root.appendingPathComponent("servers.json"))
        try await repository.saveServerOrder([beta.id, alpha.id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("servers.json")), serverData)

        alpha.displayName = "Z Renamed"
        try await repository.saveServer(alpha)
        try await repository.saveServer(newest)
        let reloaded = FileBackedConnectionProfileRepository(rootURL: root)
        let snapshot = try await reloaded.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [beta, alpha, newest])
        XCTAssertEqual(snapshot.workspaces, [workspace])
        try await reloaded.deleteServer(id: beta.id)
        let afterDelete = try await reloaded.loadSnapshot()
        XCTAssertEqual(afterDelete.servers, [alpha, newest])
    }

    func testServerOrderIgnoresDuplicateAndDeletedIDsWithoutHidingNewServers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let alpha = SavedServer(displayName: "Alpha", host: "alpha.example.test", username: "demo")
        let beta = SavedServer(displayName: "Beta", host: "beta.example.test", username: "demo")
        try await repository.saveServer(alpha)
        try await repository.saveServer(beta)
        try await repository.saveServerOrder([UUID(), beta.id, beta.id])
        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [beta, alpha])
    }

    func testInvalidServerOrderFallsBackWithoutLosingConnections() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let beta = SavedServer(displayName: "Beta", host: "beta.example.test", username: "demo")
        let alpha = SavedServer(displayName: "Alpha", host: "alpha.example.test", username: "demo")
        try await repository.saveServer(beta)
        try await repository.saveServer(alpha)
        try Data("not JSON".utf8).write(to: root.appendingPathComponent("server-order.json"))
        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [alpha, beta])
        try await repository.saveServerOrder([beta.id, alpha.id])
        let repaired = try await repository.loadSnapshot()
        XCTAssertEqual(repaired.servers, [beta, alpha])
    }

    func testFileBackedRepositoryPersistsLatestServerWorkspacePair() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let server = SavedServer(
            displayName: "Example Server",
            host: "server.example.com",
            username: "demo"
        )
        let workspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: Date()
        )

        try await repository.saveProfile(server: server, workspace: workspace)

        let loaded = try await repository.loadProfile()
        XCTAssertEqual(loaded?.0, server)
        XCTAssertEqual(loaded?.1.serverID, server.id)
        XCTAssertEqual(loaded?.1.sessionName, "base")
    }

    func testFileBackedRepositoryPersistsMultipleServersAndWorkspaces() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let serverA = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let serverB = SavedServer(
            displayName: "Beta",
            host: "beta.example.test",
            port: 2200,
            username: "bob"
        )
        let workspaceA = SavedWorkspace(
            serverID: serverA.id,
            sessionName: "base",
            lastOpenedAt: older
        )
        let workspaceB = SavedWorkspace(
            serverID: serverB.id,
            sessionName: "ops",
            lastOpenedAt: newer
        )

        try await repository.saveProfile(server: serverB, workspace: workspaceB)
        try await repository.saveProfile(server: serverA, workspace: workspaceA)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.workspaces(for: serverA.id), [workspaceA])
        XCTAssertEqual(snapshot.latestProfile?.0, serverB)
        XCTAssertEqual(snapshot.latestProfile?.1, workspaceB)
    }

    func testDeleteServerRemovesItsWorkspacesAndKeepsOtherServers() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let serverA = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let serverB = SavedServer(
            displayName: "Beta",
            host: "beta.example.test",
            username: "bob"
        )
        let workspaceA = SavedWorkspace(serverID: serverA.id, sessionName: "base")
        let workspaceB = SavedWorkspace(serverID: serverB.id, sessionName: "ops")
        try await repository.saveProfile(server: serverA, workspace: workspaceA)
        try await repository.saveProfile(server: serverB, workspace: workspaceB)

        try await repository.deleteServer(id: serverA.id)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [serverB])
        XCTAssertEqual(snapshot.workspaces, [workspaceB])
    }

    func testDeleteWorkspaceKeepsServerAndOtherWorkspaces() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let server = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )
        let workspaceA = SavedWorkspace(serverID: server.id, sessionName: "base")
        let workspaceB = SavedWorkspace(serverID: server.id, sessionName: "ops")
        try await repository.saveProfile(server: server, workspace: workspaceA)
        try await repository.saveProfile(server: server, workspace: workspaceB)

        try await repository.deleteWorkspace(id: workspaceA.id)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [server])
        XCTAssertEqual(snapshot.workspaces, [workspaceB])
    }

    func testSaveServerDoesNotCreateOrModifyWorkspaces() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        var server = SavedServer(
            displayName: "Alpha",
            host: "alpha.example.test",
            username: "alice"
        )

        try await repository.saveServer(server)
        server.displayName = "Alpha Updated"
        try await repository.saveServer(server)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.servers, [server])
        XCTAssertEqual(snapshot.workspaces, [])
    }

    func testSaveWorkspaceRequiresExistingServer() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let workspace = SavedWorkspace(serverID: UUID(), sessionName: "ops")

        do {
            try await repository.saveWorkspace(workspace)
            XCTFail("expected missing server")
        } catch ConnectionProfileRepositoryError.missingServer(let serverID) {
            XCTAssertEqual(serverID, workspace.serverID)
        }
    }

    func testFileBackedRepositoryPersistsIdentitiesSeparatelyFromServers() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let identity = SSHIdentity(
            name: "Work key",
            authenticationKind: .privateKey,
            publicFingerprint: "SHA256:abc123"
        )

        try await repository.saveIdentity(identity)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.identities, [identity])
        XCTAssertEqual(snapshot.identity(id: identity.id), identity)
        XCTAssertEqual(snapshot.servers, [])
        XCTAssertEqual(snapshot.workspaces, [])
    }

    func testFileBackedRepositoryDeletesIdentity() async throws {
        let root = temporaryRoot()
        let repository = FileBackedConnectionProfileRepository(rootURL: root)
        let retained = SSHIdentity(name: "Retained", authenticationKind: .password)
        let removed = SSHIdentity(name: "Removed", authenticationKind: .password)
        try await repository.saveIdentity(removed)
        try await repository.saveIdentity(retained)

        try await repository.deleteIdentity(id: removed.id)

        let snapshot = try await repository.loadSnapshot()
        XCTAssertEqual(snapshot.identities, [retained])
        XCTAssertNil(snapshot.identity(id: removed.id))
    }

    func testSavedServerDecodingRequiresIdentityReference() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "displayName": "Legacy",
              "host": "legacy.example.test",
              "port": 22,
              "username": "demo"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(SavedServer.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("expected missing identityID decode failure, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "identityID")
        }
    }

    func testSavedServerCodablePreservesIdentityReference() throws {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Example",
            host: "example.test",
            username: "deploy",
            identityID: identityID,
            tmuxExecutablePath: "/home/deploy/.local/bin/tmux"
        )

        let encoded = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(SavedServer.self, from: encoded)

        XCTAssertEqual(decoded, server)
        XCTAssertEqual(decoded.identityID, identityID)
        XCTAssertEqual(decoded.tmuxExecutablePath, "/home/deploy/.local/bin/tmux")
    }

    func testSavedServerDecodesMissingTmuxExecutablePathAsDefault() throws {
        let id = UUID()
        let identityID = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "displayName": "Existing Server",
              "host": "server.example.test",
              "port": 22,
              "username": "demo",
              "identityID": "\(identityID.uuidString)"
            }
            """.utf8
        )

        let server = try JSONDecoder().decode(SavedServer.self, from: data)

        XCTAssertNil(server.tmuxExecutablePath)
        XCTAssertNil(server.herdrExecutablePath)
    }

    func testSavedServerCodablePreservesHerdrExecutablePath() throws {
        let server = SavedServer(
            displayName: "Example",
            host: "example.test",
            username: "deploy",
            identityID: UUID(),
            herdrExecutablePath: "/home/deploy/.local/bin/herdr"
        )

        let decoded = try JSONDecoder().decode(
            SavedServer.self,
            from: try JSONEncoder().encode(server)
        )

        XCTAssertEqual(decoded, server)
        XCTAssertEqual(decoded.herdrExecutablePath, "/home/deploy/.local/bin/herdr")
    }

    func testWorkspaceSavedBeforeBackendsDecodesAsTmuxWithSameID() throws {
        let workspace = SavedWorkspace(
            serverID: UUID(),
            sessionName: "ops",
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(workspace)) as? [String: Any]
        )
        XCTAssertNotNil(legacy.removeValue(forKey: "backend"))

        let decoded = try JSONDecoder().decode(
            SavedWorkspace.self,
            from: try JSONSerialization.data(withJSONObject: legacy)
        )

        XCTAssertEqual(decoded.id, workspace.id)
        XCTAssertEqual(decoded.backend, .tmux)
        XCTAssertEqual(decoded, workspace)
    }

    func testSavedWorkspaceCodablePreservesBackend() throws {
        let workspace = SavedWorkspace(serverID: UUID(), backend: .herdr, sessionName: "ops")

        let decoded = try JSONDecoder().decode(
            SavedWorkspace.self,
            from: try JSONEncoder().encode(workspace)
        )

        XCTAssertEqual(decoded, workspace)
        XCTAssertEqual(decoded.locator, SessionLocator(backend: .herdr, name: "ops"))
    }

    func testSSHIdentityCodablePreservesFields() throws {
        let id = UUID()
        let identity = SSHIdentity(
            id: id,
            name: "Work key",
            authenticationKind: .privateKey,
            publicFingerprint: "SHA256:abc123"
        )

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(SSHIdentity.self, from: encoded)

        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.id, id)
    }

    func testSSHCredentialCodablePreservesPassword() throws {
        let credential = SSHCredential.password("secret")

        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(SSHCredential.self, from: encoded)

        XCTAssertEqual(decoded, credential)
    }

    func testSSHCredentialCodablePreservesPrivateKey() throws {
        let credential = SSHCredential.privateKey(
            SSHPrivateKeyCredential(
                privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nexample\n-----END OPENSSH PRIVATE KEY-----"
            )
        )

        let encoded = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(SSHCredential.self, from: encoded)

        XCTAssertEqual(decoded, credential)
    }

    /// The Keychain refuses a read while the device is locked; that pauses a connection as a locked device key does,
    /// and any other failed read stays a failed read.
    func testACredentialReadWhileLockedIsTheLockedDeviceError() async {
        let locked = KeychainSSHCredentialStore(service: "dev.remux.tests.locked") { _, _ in errSecInteractionNotAllowed }
        do {
            _ = try await locked.loadCredential(identityID: UUID())
            XCTFail("expected the locked read to fail")
        } catch {
            XCTAssertEqual(error as? SecureEnclaveSSHError, .unavailableWhileLocked, "\(error)")
        }

        let refused = KeychainSSHCredentialStore(service: "dev.remux.tests.refused") { _, _ in errSecAuthFailed }
        do {
            _ = try await refused.loadCredential(identityID: UUID())
            XCTFail("expected the read to fail")
        } catch {
            guard case .loadFailed(errSecAuthFailed)? = error as? KeychainSSHCredentialStoreError else {
                return XCTFail("expected a failed read, got \(error)")
            }
        }
    }

    func testKeychainSSHCredentialStoreUsesIdentityReference() async throws {
        let store = KeychainSSHCredentialStore(service: "dev.remux.tests.\(UUID().uuidString)")
        let identity = SSHIdentity(
            id: UUID(),
            name: "Work password",
            authenticationKind: .password
        )
        let credential = SSHCredential.password("secret")

        try await store.saveCredential(credential, identityID: identity.id)

        let savedCredential = try await store.loadCredential(identityID: identity.id)

        XCTAssertEqual(savedCredential, credential)

        try await store.deleteCredential(identityID: identity.id)
        let deletedCredential = try await store.loadCredential(identityID: identity.id)
        XCTAssertNil(deletedCredential)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
