import Foundation

#if DEBUG || REMUX_LIVE_UI_TESTING
enum DebugConnectionProfileSeederError: LocalizedError, Sendable {
    case invalidEnvironment(TmuxConnectionDraftValidation)

    var errorDescription: String? {
        switch self {
        case .invalidEnvironment(let validation):
            let messages = [
                validation.displayName,
                validation.host,
                validation.port,
                validation.username,
                validation.password,
                validation.privateKey,
                validation.privateKeyPassphrase,
                validation.sessionName,
            ].compactMap { $0 }
            return "Invalid debug connection seed: \(messages.joined(separator: " "))"
        }
    }
}

enum DebugConnectionProfileSeeder {
    private enum Key {
        static let enabled = "REMUX_DEBUG_SEED_CONNECTION"
        static let displayName = "REMUX_DEBUG_SERVER_NAME"
        static let host = "REMUX_DEBUG_SERVER_HOST"
        static let port = "REMUX_DEBUG_SERVER_PORT"
        static let username = "REMUX_DEBUG_SERVER_USERNAME"
        static let password = "REMUX_DEBUG_SERVER_PASSWORD"
        static let privateKey = "REMUX_DEBUG_PRIVATE_KEY"
        static let privateKeyPassphrase = "REMUX_DEBUG_PRIVATE_KEY_PASSPHRASE"
        static let sessionName = "REMUX_DEBUG_TMUX_SESSION"
    }

    @discardableResult
    static func seedIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        guard environment[Key.enabled] == "1" else { return false }

        let existingProfile = try await profileRepository.loadProfile()
        let draft = TmuxConnectionDraft(
            displayName: environment[Key.displayName] ?? "Example Server",
            host: environment[Key.host] ?? "",
            port: environment[Key.port] ?? "22",
            username: environment[Key.username] ?? "",
            password: environment[Key.password] ?? "",
            privateKey: environment[Key.privateKey],
            privateKeyPassphrase: environment[Key.privateKeyPassphrase],
            sessionName: environment[Key.sessionName] ?? "base"
        )

        switch TmuxConnectionDraftValidator.validate(
            draft,
            existingServerID: existingProfile?.0.id,
            existingWorkspaceID: existingProfile?.1.id
        ) {
        case .invalid(let validation):
            throw DebugConnectionProfileSeederError.invalidEnvironment(validation)

        case .valid(let submission):
            let identity: SSHIdentity
            let credential: SSHCredential
            switch submission.server.credential {
            case .password(let password):
                identity = SSHIdentity(
                    name: submission.server.displayName,
                    authenticationKind: .password
                )
                credential = .password(password)

            case .privateKey(let privateKeyCredential):
                let inspection = try SSHPrivateKeyInspector.inspect(
                    privateKeyCredential.privateKeyPEM
                )
                identity = SSHIdentity(
                    name: submission.server.displayName,
                    authenticationKind: .privateKey,
                    publicFingerprint: inspection.publicFingerprint
                )
                credential = .privateKey(privateKeyCredential)

            case .none:
                identity = SSHIdentity(
                    name: submission.server.displayName,
                    authenticationKind: .none
                )
                credential = .none
            }
            let server = submission.server.savedServer(identityID: identity.id)
            try await credentialStore.saveCredential(
                credential,
                identityID: identity.id
            )
            try await profileRepository.saveIdentityProfile(
                identity: identity,
                server: server,
                workspace: submission.workspace
            )
            return true
        }
    }
}

private extension TmuxConnectionDraft {
    init(
        displayName: String,
        host: String,
        port: String,
        username: String,
        password: String,
        privateKey: String?,
        privateKeyPassphrase: String?,
        sessionName: String
    ) {
        self.init()
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        if let privateKey, !privateKey.isEmpty {
            self.authenticationKind = .privateKey
            self.privateKeyPEM = privateKey
            self.privateKeyFileName = "Debug private key"
            self.privateKeyPassphrase = privateKeyPassphrase ?? ""
        } else {
            self.password = password
        }
        self.sessionName = sessionName
    }
}
#endif
