import Foundation

protocol FileProviderSharedStorageMigrating: Sendable {
    func migrateIfNeeded() async throws
}

enum FileProviderSharedStorageMigrationError: Error, Equatable, Sendable {
    case credentialVerificationFailed(SSHIdentity.ID)
    case verificationFailed
}

actor FileProviderSharedStorageMigrator: FileProviderSharedStorageMigrating {
    private let legacyProfiles: any ConnectionProfileRepository
    private let legacyCredentials: any SSHCredentialStore
    private let legacyTrust: TrustedHostStore
    private let sharedProfiles: any ConnectionProfileRepository
    private let sharedCredentials: any SSHCredentialStore
    private let sharedTrust: TrustedHostStore
    private let markerURL: URL
    private let fileManager: FileManager

    init(
        legacyProfiles: any ConnectionProfileRepository,
        legacyCredentials: any SSHCredentialStore,
        legacyTrust: TrustedHostStore,
        sharedProfiles: any ConnectionProfileRepository,
        sharedCredentials: any SSHCredentialStore,
        sharedTrust: TrustedHostStore,
        markerURL: URL,
        fileManager: FileManager = .default
    ) {
        self.legacyProfiles = legacyProfiles
        self.legacyCredentials = legacyCredentials
        self.legacyTrust = legacyTrust
        self.sharedProfiles = sharedProfiles
        self.sharedCredentials = sharedCredentials
        self.sharedTrust = sharedTrust
        self.markerURL = markerURL
        self.fileManager = fileManager
    }

    func migrateIfNeeded() async throws {
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            return
        }

        let snapshot = try await legacyProfiles.loadSnapshot()
        let trustedIdentities = try legacyTrust.loadIdentities()

        for identity in snapshot.identities {
            try await sharedProfiles.saveIdentity(identity)

            if let credential = try await legacyCredentials.loadCredential(identityID: identity.id) {
                try await sharedCredentials.saveCredential(credential, identityID: identity.id)

                guard try await sharedCredentials.loadCredential(identityID: identity.id) == credential else {
                    throw FileProviderSharedStorageMigrationError.credentialVerificationFailed(identity.id)
                }
            }
        }

        for server in snapshot.servers {
            try await sharedProfiles.saveServer(server)
        }

        for workspace in snapshot.workspaces {
            try await sharedProfiles.saveWorkspace(workspace)
        }

        try sharedTrust.replaceIdentities(trustedIdentities)

        guard try await sharedProfiles.loadSnapshot() == snapshot,
              try sharedTrust.loadIdentities() == trustedIdentities else {
            throw FileProviderSharedStorageMigrationError.verificationFailed
        }

        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1".utf8).write(to: markerURL, options: .atomic)
    }
}
