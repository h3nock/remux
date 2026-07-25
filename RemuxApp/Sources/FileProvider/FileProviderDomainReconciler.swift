import FileProvider
import Foundation

struct FileProviderDomainRecord: Equatable, Sendable {
    let serverID: SavedServer.ID
    let displayName: String

    fileprivate var rawIdentifier: String {
        serverID.uuidString.lowercased()
    }
}

protocol FileProviderDomainRegistering: Sendable {
    func records() async throws -> [FileProviderDomainRecord]
    func add(_ record: FileProviderDomainRecord) async throws
    func remove(serverID: SavedServer.ID) async throws
}

protocol FileProviderDomainReconciling: Sendable {
    func reconcile() async throws
}

actor FileProviderDomainReconciler: FileProviderDomainReconciling {
    private let profiles: any ConnectionProfileRepository
    private let credentials: any SSHCredentialStore
    private let trust: TrustedHostStore
    private let registry: any FileProviderDomainRegistering
    private let reconciliationGate = FileProviderDomainReconciliationGate()

    init(
        profiles: any ConnectionProfileRepository,
        credentials: any SSHCredentialStore,
        trust: TrustedHostStore,
        registry: any FileProviderDomainRegistering
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.trust = trust
        self.registry = registry
    }

    func reconcile() async throws {
        await reconciliationGate.acquire()

        do {
            try await reconcileDomains()
            await reconciliationGate.release()
        } catch {
            await reconciliationGate.release()
            throw error
        }
    }

    private func reconcileDomains() async throws {
        let snapshot = try await profiles.loadSnapshot()
        let trustedServerIDs = Set(try trust.loadIdentities().map(\.serverID))
        var desiredRecords: [FileProviderDomainRecord] = []

        for server in snapshot.servers where trustedServerIDs.contains(server.id) {
            guard try await credentials.loadCredential(identityID: server.identityID) != nil else {
                continue
            }

            desiredRecords.append(
                FileProviderDomainRecord(serverID: server.id, displayName: server.displayName)
            )
        }

        let existingRecords = try await registry.records()

        for record in existingRecords
        where desiredRecords.first(where: { $0.serverID == record.serverID }) != record {
            try await registry.remove(serverID: record.serverID)
        }

        for record in desiredRecords
        where existingRecords.first(where: { $0.serverID == record.serverID }) != record {
            try await registry.add(record)
        }
    }
}

final class NSFileProviderDomainRegistry: FileProviderDomainRegistering, @unchecked Sendable {
    func records() async throws -> [FileProviderDomainRecord] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FileProviderDomainRecord], Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains.compactMap { domain in
                        guard let serverID = UUID(uuidString: domain.identifier.rawValue) else {
                            return nil
                        }

                        return FileProviderDomainRecord(
                            serverID: serverID,
                            displayName: domain.displayName
                        )
                    })
                }
            }
        }
    }

    func add(_ record: FileProviderDomainRecord) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: record.rawIdentifier),
            displayName: record.displayName
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func remove(serverID: SavedServer.ID) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: serverID.uuidString.lowercased()),
            displayName: ""
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

private actor FileProviderDomainReconciliationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard !isHeld else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }

        isHeld = true
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }

        waiters.removeFirst().resume()
    }
}
