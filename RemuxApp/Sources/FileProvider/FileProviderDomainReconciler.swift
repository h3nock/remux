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
    private var reconciliationTask: Task<Void, Error>?

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
        if let reconciliationTask {
            try await reconciliationTask.value
            return
        }

        let task = Task {
            try await self.reconcileDomains()
        }
        reconciliationTask = task

        do {
            try await task.value
            reconciliationTask = nil
        } catch {
            reconciliationTask = nil
            throw error
        }
    }

    private func reconcileDomains() async throws {
        let snapshot = try await profiles.loadSnapshot()
        let trustedIdentities = try trust.loadIdentities()
        var desiredRecords: [FileProviderDomainRecord] = []

        for server in snapshot.servers where trustedIdentities.contains(where: {
            $0.serverID == server.id && $0.host == server.host
        }) {
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
