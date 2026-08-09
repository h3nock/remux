import Foundation

enum SSHAuthResolverError: Error, Equatable, LocalizedError, Sendable {
    case missingIdentity(SSHIdentity.ID)
    case missingCredential(UUID)
    case credentialKindMismatch(
        identityID: SSHIdentity.ID,
        expected: SSHAuthenticationKind,
        actual: SSHAuthenticationKind
    )

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            "Remux could not find the saved SSH identity for this server."
        case .missingCredential:
            "Remux could not find the saved SSH credential for this identity."
        case .credentialKindMismatch:
            "Remux found an SSH credential that does not match the selected identity type."
        }
    }
}

struct SSHAuthResolver: Sendable {
    private let credentialStore: any SSHCredentialStore

    init(credentialStore: any SSHCredentialStore) {
        self.credentialStore = credentialStore
    }

    func resolve(
        server: SavedServer,
        in snapshot: ConnectionLibrarySnapshot
    ) async throws -> ResolvedSSHAuth {
        let identityID = server.identityID

        guard let identity = snapshot.identity(id: identityID) else {
            throw SSHAuthResolverError.missingIdentity(identityID)
        }

        guard let credential = try await credentialStore.loadCredential(
            identityID: identity.id
        ) else {
            throw SSHAuthResolverError.missingCredential(identity.id)
        }

        guard identity.authenticationKind == credential.authenticationKind else {
            throw SSHAuthResolverError.credentialKindMismatch(
                identityID: identity.id,
                expected: identity.authenticationKind,
                actual: credential.authenticationKind
            )
        }

        switch credential {
        case .password(let password):
            return .password(
                username: server.username,
                password: password,
                identityID: identity.id,
                displayLabel: identity.name
            )
        case .privateKey(let credential):
            return try .privateKey(
                username: server.username,
                credential: credential,
                identityID: identity.id,
                displayLabel: identity.name
            )
        case .none:
            return .none(
                username: server.username,
                identityID: identity.id,
                displayLabel: identity.name
            )
        }
    }
}
