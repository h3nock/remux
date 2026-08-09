import XCTest
@testable import Remux

final class SSHAuthResolverTests: XCTestCase {
    func testResolvesPasswordIdentityThroughIdentity() async throws {
        let identity = SSHIdentity(
            id: UUID(),
            name: "Work password",
            authenticationKind: .password
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore(credentials: [
            identity.id: .password("secret"),
        ]))

        let auth = try await resolver.resolve(
            server: server,
            in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
        )

        XCTAssertEqual(auth.identityID, identity.id)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testResolvesNoneIdentityThroughIdentity() async throws {
        let identity = SSHIdentity(
            id: UUID(),
            name: "Tailscale node",
            authenticationKind: .none
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore(credentials: [
            identity.id: .none,
        ]))

        let auth = try await resolver.resolve(
            server: server,
            in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
        )

        XCTAssertEqual(auth.identityID, identity.id)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Tailscale node")
        XCTAssertEqual(auth.credential, .none)
    }

    func testMissingIdentityFailsExplicitly() async throws {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identityID
        )
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore())

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [])
            )
            XCTFail("Expected missing identity error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .missingIdentity(identityID))
        }
    }

    func testMissingCredentialFailsExplicitly() async throws {
        let identity = SSHIdentity(
            name: "Work password",
            authenticationKind: .password
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore())

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
            )
            XCTFail("Expected missing credential error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(error, .missingCredential(identity.id))
        }
    }

    func testCredentialKindMismatchFailsExplicitly() async throws {
        let identity = SSHIdentity(
            name: "Work key",
            authenticationKind: .privateKey
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore(credentials: [
            identity.id: .password("secret"),
        ]))

        do {
            _ = try await resolver.resolve(
                server: server,
                in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
            )
            XCTFail("Expected credential kind mismatch error")
        } catch let error as SSHAuthResolverError {
            XCTAssertEqual(
                error,
                .credentialKindMismatch(
                    identityID: identity.id,
                    expected: .privateKey,
                    actual: .password
                )
            )
        }
    }

    func testResolvesPrivateKeyIdentityThroughIdentity() async throws {
        let identity = SSHIdentity(
            name: "Work key",
            authenticationKind: .privateKey,
            publicFingerprint: "SHA256:ut9xpxBjkrwDyq3o7dO0r/opPmzTsBSslfZtdaBGYWk"
        )
        let server = SavedServer(
            displayName: "Server",
            host: "server.example.test",
            username: "deploy",
            identityID: identity.id
        )
        let credential = SSHPrivateKeyCredential(privateKeyPEM: Self.ed25519Key, passphrase: "secret")
        let resolver = SSHAuthResolver(credentialStore: TestSSHCredentialStore(credentials: [
            identity.id: .privateKey(credential),
        ]))

        let auth = try await resolver.resolve(
            server: server,
            in: ConnectionLibrarySnapshot(servers: [server], workspaces: [], identities: [identity])
        )

        XCTAssertEqual(auth.identityID, identity.id)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work key")
        XCTAssertEqual(auth.credential, .privateKey(credential))
    }

    private static let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQAAAJhUdIMJVHSD
    CQAAAAtzc2gtZWQyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQ
    AAAEAuFkLHR6BO6DpN/zM9hdy3psHOh+8TxQMwJaNEWacIvmueKirqd5MQ7XHEYV6f9+wf
    JqM4DiKzrVl8+loP93ORAAAAEnJlbXV4LXRlc3QtZWQyNTUxOQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """
}

private actor TestSSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential]

    init(credentials: [UUID: SSHCredential] = [:]) {
        self.credentials = credentials
    }

    func loadCredential(identityID: UUID) async throws -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: UUID) async throws {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: UUID) async throws {
        credentials[identityID] = nil
    }
}
