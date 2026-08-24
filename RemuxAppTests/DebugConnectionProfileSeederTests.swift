import XCTest
@testable import Remux

#if DEBUG
final class DebugConnectionProfileSeederTests: XCTestCase {
    func testSeedIsNoopWhenEnvironmentFlagIsMissing() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let credentialStore = InMemorySSHCredentialStore()

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [:],
            profileRepository: repository,
            credentialStore: credentialStore
        )

        XCTAssertFalse(seeded)
        let profile = try await repository.loadProfile()
        XCTAssertNil(profile)
    }

    func testSeedPersistsConnectionProfileAndCredential() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let credentialStore = InMemorySSHCredentialStore()

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_NAME": "Example Server",
                "REMUX_DEBUG_SERVER_HOST": "server.example.com",
                "REMUX_DEBUG_SERVER_PORT": "22",
                "REMUX_DEBUG_SERVER_USERNAME": "demo",
                "REMUX_DEBUG_SERVER_PASSWORD": "debug-password",
                "REMUX_DEBUG_TMUX_SESSION": "base",
            ],
            profileRepository: repository,
            credentialStore: credentialStore
        )

        let profile = try await repository.loadProfile()
        let snapshot = try await repository.loadSnapshot()
        let server = try XCTUnwrap(profile?.0)
        let identity = try XCTUnwrap(snapshot.identity(id: server.identityID))
        let credential = try await credentialStore.loadCredential(identityID: identity.id)
        XCTAssertTrue(seeded)
        XCTAssertEqual(server.displayName, "Example Server")
        XCTAssertEqual(server.host, "server.example.com")
        XCTAssertEqual(server.port, 22)
        XCTAssertEqual(server.username, "demo")
        XCTAssertEqual(profile?.1.sessionName, "base")
        XCTAssertEqual(identity.name, "Example Server")
        XCTAssertEqual(identity.authenticationKind, .password)
        XCTAssertEqual(credential, .password("debug-password"))
    }

    func testSeedPersistsPrivateKeyProfileAndCredential() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let credentialStore = InMemorySSHCredentialStore()
        let inspection = try SSHPrivateKeyInspector.inspect(Self.ed25519Key)

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_NAME": "Example Server",
                "REMUX_DEBUG_SERVER_HOST": "server.example.com",
                "REMUX_DEBUG_SERVER_PORT": "22",
                "REMUX_DEBUG_SERVER_USERNAME": "demo",
                "REMUX_DEBUG_PRIVATE_KEY": Self.ed25519Key,
                "REMUX_DEBUG_PRIVATE_KEY_PASSPHRASE": "debug-passphrase",
                "REMUX_DEBUG_TMUX_SESSION": "base",
            ],
            profileRepository: repository,
            credentialStore: credentialStore
        )

        let profile = try await repository.loadProfile()
        let snapshot = try await repository.loadSnapshot()
        let server = try XCTUnwrap(profile?.0)
        let identity = try XCTUnwrap(snapshot.identity(id: server.identityID))
        let credential = try await credentialStore.loadCredential(identityID: identity.id)
        XCTAssertTrue(seeded)
        XCTAssertEqual(identity.name, "Example Server")
        XCTAssertEqual(identity.authenticationKind, .privateKey)
        XCTAssertEqual(identity.publicFingerprint, inspection.publicFingerprint)
        XCTAssertEqual(
            credential,
            .privateKey(
                SSHPrivateKeyCredential(
                    privateKeyPEM: Self.ed25519Key,
                    passphrase: "debug-passphrase"
                )
            )
        )
    }

    func testSeedPersistsNoneIdentityWithoutCredential() async throws {
        let repository = InMemoryConnectionProfileRepository()
        let credentialStore = InMemorySSHCredentialStore()

        let seeded = try await DebugConnectionProfileSeeder.seedIfRequested(
            environment: [
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_NAME": "Tailscale Server",
                "REMUX_DEBUG_SERVER_HOST": "100.64.0.1",
                "REMUX_DEBUG_SERVER_PORT": "22",
                "REMUX_DEBUG_SERVER_USERNAME": "demo",
                "REMUX_DEBUG_TMUX_SESSION": "base",
            ],
            profileRepository: repository,
            credentialStore: credentialStore
        )

        let snapshot = try await repository.loadSnapshot()
        let identity = try XCTUnwrap(snapshot.identities.first)
        let credential = try await credentialStore.loadCredential(identityID: identity.id)
        XCTAssertTrue(seeded)
        XCTAssertEqual(identity.authenticationKind, .none)
        XCTAssertNil(credential)
    }

    private static let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACA6y4Nl6dWkC0PdxZrJ6S7aYcmBpy9RytK9V0Xz7eIwVQAAAJj3zGE298xh
    NgAAAAtzc2gtZWQyNTUxOQAAACA6y4Nl6dWkC0PdxZrJ6S7aYcmBpy9RytK9V0Xz7eIwVQ
    AAAEB6gaBHbjL56VCVbX8Es1jVLdoaQnikXUxM3SAV105ghzrLg2Xp1aQLQ93FmsnpLtph
    yYGnL1HK0r1XRfPt4jBVAAAAEnJlbXV4LXRlc3QtZml4dHVyZQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

}

private actor InMemoryConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer] = []
    private var workspaces: [SavedWorkspace] = []
    private var identities: [SSHIdentity] = []

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        ConnectionLibrarySnapshot(servers: servers, workspaces: workspaces, identities: identities)
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServer(_ server: SavedServer) async throws {
        upsert(server, into: &servers)
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        upsert(workspace, into: &workspaces)
    }

    func saveIdentity(_ identity: SSHIdentity) async throws {
        upsert(identity, into: &identities)
    }

    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws {
        upsert(identity, into: &identities)
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func deleteIdentity(id: SSHIdentity.ID) async throws {
        identities.removeAll { $0.id == id }
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}

private actor InMemorySSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential] = [:]

    func loadCredential(identityID: UUID) async throws -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: UUID) async throws {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: UUID) async throws {
        credentials.removeValue(forKey: identityID)
    }
}
#endif
