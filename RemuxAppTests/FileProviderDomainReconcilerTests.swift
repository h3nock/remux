import XCTest
@testable import Remux

final class FileProviderDomainReconcilerTests: XCTestCase {
    func testOnlyServersWithCredentialAndTrustedHostBecomeDomains() async throws {
        let fixture = try await DomainFixture(
            passwordServer: .eligible,
            keyServer: .missingTrust,
            thirdServer: .missingCredential
        )

        try await fixture.reconciler.reconcile()

        let records = await fixture.registry.currentRecords()
        XCTAssertEqual(records, [
            FileProviderDomainRecord(
                serverID: fixture.passwordServer.id,
                displayName: "Password"
            )
        ])
    }

    func testReconcileAddsRenamesAndRemovesToMatchDesiredSet() async throws {
        let fixture = try await DomainFixture(
            passwordServer: .eligible,
            keyServer: .missingTrust,
            thirdServer: .missingCredential,
            existing: [
                .init(serverID: UUID(), displayName: "Removed"),
                .init(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "Old Password"),
            ]
        )
        let reconciler = fixture.reconciler
        let registry = fixture.registry
        let expectedRecords = fixture.expectedRecords
        let removedServerID = fixture.existingRecords[0].serverID
        let passwordServerID = fixture.passwordServer.id

        async let firstReconciliation: Void = reconciler.reconcile()
        async let secondReconciliation: Void = reconciler.reconcile()
        try await firstReconciliation
        try await secondReconciliation

        let records = await registry.currentRecords()
        let maximumConcurrentMutationCount = await registry.currentMaximumConcurrentMutationCount()
        let mutations = await registry.currentMutations()
        XCTAssertEqual(records, expectedRecords)
        XCTAssertEqual(maximumConcurrentMutationCount, 1)
        XCTAssertEqual(mutations, [
            .remove(removedServerID),
            .remove(passwordServerID),
            .add(.init(serverID: passwordServerID, displayName: "Password")),
        ])
    }
}

private final class DomainFixture {
    enum Eligibility {
        case eligible
        case missingTrust
        case missingCredential
    }

    let passwordServer: SavedServer
    let registry: InMemoryFileProviderDomainRegistry
    let reconciler: FileProviderDomainReconciler
    let existingRecords: [FileProviderDomainRecord]
    let expectedRecords: [FileProviderDomainRecord]

    init(
        passwordServer: Eligibility = .eligible,
        keyServer: Eligibility = .eligible,
        thirdServer: Eligibility = .eligible,
        existing: [FileProviderDomainRecord] = []
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profiles = FileBackedConnectionProfileRepository(rootURL: root)
        let credentials = KeychainSSHCredentialStore(service: "dev.remux.tests.\(UUID().uuidString)")
        let trust = TrustedHostStore(rootURL: root)

        let servers = [
            Self.server(id: "00000000-0000-0000-0000-000000000001", name: "Password"),
            Self.server(id: "00000000-0000-0000-0000-000000000002", name: "Key"),
            Self.server(id: "00000000-0000-0000-0000-000000000003", name: "Third"),
        ]
        let eligibility = [passwordServer, keyServer, thirdServer]

        for (server, eligibility) in zip(servers, eligibility) {
            try await profiles.saveServer(server)

            if eligibility != .missingCredential {
                try await credentials.saveCredential(.password("secret"), identityID: server.identityID)
            }
        }

        try trust.replaceIdentities(
            zip(servers, eligibility).compactMap { server, eligibility in
                guard eligibility != .missingTrust else { return nil }
                return TrustedHostIdentity(
                    serverID: server.id,
                    host: server.host,
                    keyType: "ssh-ed25519",
                    openSSHPublicKey: "ssh-ed25519 \(server.id.uuidString)",
                    trustedAt: Date(timeIntervalSince1970: 1)
                )
            }
        )

        self.passwordServer = servers[0]
        self.registry = InMemoryFileProviderDomainRegistry(records: existing)
        self.reconciler = FileProviderDomainReconciler(
            profiles: profiles,
            credentials: credentials,
            trust: trust,
            registry: registry
        )
        self.existingRecords = existing
        self.expectedRecords = zip(servers, eligibility).compactMap { server, eligibility in
            guard eligibility == .eligible else { return nil }
            return .init(serverID: server.id, displayName: server.displayName)
        }
    }

    private static func server(id: String, name: String) -> SavedServer {
        SavedServer(
            id: UUID(uuidString: id)!,
            displayName: name,
            host: "\(name.lowercased()).example.test",
            username: "demo",
            identityID: UUID(uuidString: id)!
        )
    }
}

private actor InMemoryFileProviderDomainRegistry: FileProviderDomainRegistering {
    enum Mutation: Equatable {
        case add(FileProviderDomainRecord)
        case remove(SavedServer.ID)
    }

    private var storedRecords: [FileProviderDomainRecord]
    private var mutations: [Mutation] = []
    private var maximumConcurrentMutationCount = 0
    private var activeMutationCount = 0

    init(records: [FileProviderDomainRecord]) {
        self.storedRecords = records
    }

    func records() async throws -> [FileProviderDomainRecord] {
        storedRecords
    }

    func currentRecords() -> [FileProviderDomainRecord] {
        storedRecords
    }

    func currentMutations() -> [Mutation] {
        mutations
    }

    func currentMaximumConcurrentMutationCount() -> Int {
        maximumConcurrentMutationCount
    }

    func add(_ record: FileProviderDomainRecord) async throws {
        try await mutate(.add(record)) {
            storedRecords.append(record)
        }
    }

    func remove(serverID: SavedServer.ID) async throws {
        try await mutate(.remove(serverID)) {
            storedRecords.removeAll { $0.serverID == serverID }
        }
    }

    private func mutate(_ mutation: Mutation, body: () -> Void) async throws {
        activeMutationCount += 1
        maximumConcurrentMutationCount = max(maximumConcurrentMutationCount, activeMutationCount)
        try await Task.sleep(for: .milliseconds(10))
        body()
        mutations.append(mutation)
        activeMutationCount -= 1
    }
}
