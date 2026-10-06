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
                validation.tmuxExecutablePath,
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
        static let credentialsFile = "REMUX_DEBUG_CREDENTIALS_FILE"
        static let sessionName = "REMUX_DEBUG_TMUX_SESSION"
        static let tmuxExecutablePath = "REMUX_DEBUG_TMUX_EXECUTABLE_PATH"
    }

    /// A JSON file holding the credential, such as the live UI tests' SSH
    /// configuration. When given, it replaces REMUX_DEBUG_SERVER_PASSWORD. A
    /// private key is only read from a file, because XCTest records the app's
    /// launch environment in every result bundle.
    private struct CredentialsFile: Decodable {
        var password: String?
        var privateKeyPEM: String?
        var privateKeyPassphrase: String?
    }

    /// The tmux session the seeded profile opens, when seeding is requested.
    static func seededSessionName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard environment[Key.enabled] == "1" else { return nil }
        return environment[Key.sessionName] ?? "base"
    }

    @discardableResult
    static func seedIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        guard let seededSessionName = seededSessionName(environment: environment) else {
            return false
        }

        let credentials = try environment[Key.credentialsFile].map {
            try JSONDecoder().decode(
                CredentialsFile.self,
                from: Data(contentsOf: URL(fileURLWithPath: $0))
            )
        } ?? CredentialsFile(password: environment[Key.password])
        let existingProfile = try await profileRepository.loadProfile()
        let draft = TmuxConnectionDraft(
            displayName: environment[Key.displayName] ?? "Example Server",
            host: environment[Key.host] ?? "",
            port: environment[Key.port] ?? "22",
            username: environment[Key.username] ?? "",
            password: credentials.password ?? "",
            privateKey: credentials.privateKeyPEM,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            sessionName: seededSessionName,
            tmuxExecutablePath: environment[Key.tmuxExecutablePath] ?? ""
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
            let credential: SSHCredential?
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
                credential = nil
            }
            let server = submission.server.savedServer(identityID: identity.id)
            if let credential {
                try await credentialStore.saveCredential(
                    credential,
                    identityID: identity.id
                )
            }
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
        sessionName: String,
        tmuxExecutablePath: String
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
        } else if password.isEmpty {
            self.authenticationKind = .none
        } else {
            self.password = password
        }
        self.sessionName = sessionName
        self.tmuxExecutablePath = tmuxExecutablePath
    }
}
#endif
