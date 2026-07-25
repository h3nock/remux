import XCTest
@testable import Remux

final class FileProviderSharedStorageMigratorTests: XCTestCase {
    func testMigrationCopiesProfilesTrustAndEveryReferencedCredentialBeforeMarkingComplete() async throws {
        let fixture = try MigrationFixture()
        try await fixture.seedLegacy(password: "secret")

        try await fixture.migrator.migrateIfNeeded()

        let sharedSnapshot = try await fixture.sharedProfiles.loadSnapshot()
        let sharedCredential = try await fixture.sharedCredentials.loadCredential(identityID: fixture.identity.id)
        let legacySnapshot = try await fixture.legacyProfiles.loadSnapshot()
        let legacyCredential = try await fixture.legacyCredentials.loadCredential(identityID: fixture.identity.id)

        XCTAssertEqual(sharedSnapshot, fixture.legacySnapshot)
        XCTAssertEqual(try fixture.sharedTrust.loadIdentities(), fixture.expectedTrust)
        XCTAssertEqual(sharedCredential, .password("secret"))
        XCTAssertEqual(legacySnapshot, fixture.legacySnapshot)
        XCTAssertEqual(try fixture.legacyTrust.loadIdentities(), fixture.expectedTrust)
        XCTAssertEqual(legacyCredential, .password("secret"))
        XCTAssertTrue(fixture.markerExists)
    }

    func testMigrationCopiesPrivateKeyCredentialWithPassphrase() async throws {
        let fixture = try MigrationFixture(identityAuthenticationKind: .privateKey)
        let credential = SSHCredential.privateKey(
            SSHPrivateKeyCredential(
                privateKeyPEM: """
                -----BEGIN OPENSSH PRIVATE KEY-----
                private-key-fixture
                -----END OPENSSH PRIVATE KEY-----
                """,
                passphrase: "passphrase-fixture"
            )
        )
        try await fixture.seedLegacy(credential: credential)

        try await fixture.migrator.migrateIfNeeded()

        let sharedCredential = try await fixture.sharedCredentials.loadCredential(identityID: fixture.identity.id)
        XCTAssertEqual(sharedCredential, credential)
    }

    func testMigrationFailureLeavesSourceIntactDoesNotMarkAndRetriesIdempotently() async throws {
        let fixture = try MigrationFixture(sharedCredentials: FailingOnceCredentialStore())
        try await fixture.seedLegacy(password: "secret")

        await XCTAssertThrowsErrorAsync {
            try await fixture.migrator.migrateIfNeeded()
        }

        XCTAssertFalse(fixture.markerExists)
        let legacySnapshot = try await fixture.legacyProfiles.loadSnapshot()
        let legacyCredential = try await fixture.legacyCredentials.loadCredential(identityID: fixture.identity.id)

        XCTAssertEqual(legacySnapshot, fixture.legacySnapshot)
        XCTAssertEqual(try fixture.legacyTrust.loadIdentities(), fixture.expectedTrust)
        XCTAssertEqual(legacyCredential, .password("secret"))

        try await fixture.migrator.migrateIfNeeded()
        try await fixture.migrator.migrateIfNeeded()

        XCTAssertTrue(fixture.markerExists)
        let sharedSnapshot = try await fixture.sharedProfiles.loadSnapshot()
        let sharedCredential = try await fixture.sharedCredentials.loadCredential(identityID: fixture.identity.id)

        XCTAssertEqual(sharedSnapshot, fixture.legacySnapshot)
        XCTAssertEqual(try fixture.sharedTrust.loadIdentities(), fixture.expectedTrust)
        XCTAssertEqual(sharedCredential, .password("secret"))
    }
}

private final class MigrationFixture {
    let identity: SSHIdentity
    let legacyProfiles: FileBackedConnectionProfileRepository
    let legacyCredentials: InMemorySSHCredentialStore
    let legacyTrust: TrustedHostStore
    let sharedProfiles: FileBackedConnectionProfileRepository
    let sharedCredentials: any SSHCredentialStore
    let sharedTrust: TrustedHostStore
    let markerURL: URL
    let migrator: FileProviderSharedStorageMigrator

    var legacySnapshot: ConnectionLibrarySnapshot {
        ConnectionLibrarySnapshot(
            servers: [server],
            workspaces: [workspace],
            identities: [identity]
        )
    }

    var expectedTrust: [TrustedHostIdentity] {
        [
            TrustedHostIdentity(
                serverID: server.id,
                host: server.host,
                keyType: "ssh-ed25519",
                openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest",
                trustedAt: Date(timeIntervalSince1970: 1)
            )
        ]
    }

    var markerExists: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    private let server: SavedServer
    private let workspace: SavedWorkspace

    init(
        identityAuthenticationKind: SSHAuthenticationKind = .password,
        sharedCredentials: any SSHCredentialStore = InMemorySSHCredentialStore()
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("shared", isDirectory: true)
        markerURL = root.appendingPathComponent("file-provider-shared-storage-migration-v1")

        identity = SSHIdentity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Primary credential",
            authenticationKind: identityAuthenticationKind
        )
        server = SavedServer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "Example Server",
            host: "server.example.test",
            username: "demo",
            identityID: identity.id
        )
        workspace = SavedWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: Date(timeIntervalSince1970: 2)
        )
        legacyProfiles = FileBackedConnectionProfileRepository(rootURL: legacyRoot)
        legacyCredentials = InMemorySSHCredentialStore()
        legacyTrust = TrustedHostStore(rootURL: legacyRoot)
        self.sharedProfiles = FileBackedConnectionProfileRepository(rootURL: sharedRoot)
        self.sharedCredentials = sharedCredentials
        sharedTrust = TrustedHostStore(rootURL: sharedRoot)
        migrator = FileProviderSharedStorageMigrator(
            legacyProfiles: legacyProfiles,
            legacyCredentials: legacyCredentials,
            legacyTrust: legacyTrust,
            sharedProfiles: self.sharedProfiles,
            sharedCredentials: sharedCredentials,
            sharedTrust: sharedTrust,
            markerURL: markerURL
        )
    }

    func seedLegacy(password: String) async throws {
        try await seedLegacy(credential: .password(password))
    }

    func seedLegacy(credential: SSHCredential) async throws {
        try await legacyProfiles.saveIdentity(identity)
        try await legacyProfiles.saveServer(server)
        try await legacyProfiles.saveWorkspace(workspace)
        try legacyTrust.replaceIdentities(expectedTrust)
        try await legacyCredentials.saveCredential(credential, identityID: identity.id)
    }
}

private actor InMemorySSHCredentialStore: SSHCredentialStore {
    private var credentials: [SSHIdentity.ID: SSHCredential] = [:]

    func loadCredential(identityID: SSHIdentity.ID) async throws -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) async throws {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: SSHIdentity.ID) async throws {
        credentials.removeValue(forKey: identityID)
    }
}

private actor FailingOnceCredentialStore: SSHCredentialStore {
    private var shouldFail = true
    private let store = InMemorySSHCredentialStore()

    func loadCredential(identityID: SSHIdentity.ID) async throws -> SSHCredential? {
        try await store.loadCredential(identityID: identityID)
    }

    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) async throws {
        if shouldFail {
            shouldFail = false
            throw Failure.saveCredential
        }

        try await store.saveCredential(credential, identityID: identityID)
    }

    func deleteCredential(identityID: SSHIdentity.ID) async throws {
        try await store.deleteCredential(identityID: identityID)
    }

    private enum Failure: Error {
        case saveCredential
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
