import CryptoKit
import Foundation

enum SSHAuthenticationKind: String, Codable, Sendable {
    case password
    case privateKey
    case none
}

struct SSHIdentity: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var authenticationKind: SSHAuthenticationKind
    var publicFingerprint: String?

    init(
        id: UUID = UUID(),
        name: String,
        authenticationKind: SSHAuthenticationKind,
        publicFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.authenticationKind = authenticationKind
        self.publicFingerprint = publicFingerprint
    }
}

struct ResolvedSSHAuth: Equatable, Sendable {
    enum Credential: Equatable, Sendable {
        case password(String)
        case privateKey(SSHPrivateKeyCredential)
        case none
    }

    let identityID: UUID
    let username: String
    let displayLabel: String
    let authFingerprint: String
    let credential: Credential

    private init(
        identityID: UUID,
        username: String,
        displayLabel: String,
        authFingerprint: String,
        credential: Credential
    ) {
        self.identityID = identityID
        self.username = username
        self.displayLabel = displayLabel
        self.authFingerprint = authFingerprint
        self.credential = credential
    }

    static func password(
        username: String,
        password: String,
        identityID: UUID,
        displayLabel: String
    ) -> ResolvedSSHAuth {
        ResolvedSSHAuth(
            identityID: identityID,
            username: username,
            displayLabel: displayLabel,
            authFingerprint: "password:\(fingerprint(password))",
            credential: .password(password)
        )
    }

    static func privateKey(
        username: String,
        credential: SSHPrivateKeyCredential,
        identityID: UUID,
        displayLabel: String
    ) throws -> ResolvedSSHAuth {
        let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
        return ResolvedSSHAuth(
            identityID: identityID,
            username: username,
            displayLabel: displayLabel,
            authFingerprint: [
                "private-key",
                inspection.publicFingerprint,
                fingerprint(credential.passphrase ?? ""),
            ].joined(separator: ":"),
            credential: .privateKey(credential)
        )
    }

    static func none(
        username: String,
        identityID: UUID,
        displayLabel: String
    ) -> ResolvedSSHAuth {
        ResolvedSSHAuth(
            identityID: identityID,
            username: username,
            displayLabel: displayLabel,
            authFingerprint: "none",
            credential: .none
        )
    }

    private static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SavedServer: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var displayName: String
    var host: String
    var port: Int
    var username: String
    var identityID: SSHIdentity.ID
    var tmuxExecutablePath: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String,
        identityID: SSHIdentity.ID,
        tmuxExecutablePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.identityID = identityID
        self.tmuxExecutablePath = tmuxExecutablePath
    }
}

struct SavedWorkspace: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let serverID: SavedServer.ID
    var sessionName: String
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        serverID: SavedServer.ID,
        sessionName: String,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.sessionName = sessionName
        self.lastOpenedAt = lastOpenedAt
    }
}

struct TmuxConnectionTarget: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
    let sshAuth: ResolvedSSHAuth
    let terminalSettings: TerminalSettings

    init(
        server: SavedServer,
        workspace: SavedWorkspace,
        sshAuth: ResolvedSSHAuth,
        terminalSettings: TerminalSettings = .default
    ) {
        self.server = server
        self.workspace = workspace
        self.sshAuth = sshAuth
        self.terminalSettings = terminalSettings
    }
}

struct SSHHostKeyTrustChallenge: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unknown
        case changed
    }

    let kind: Kind
    let serverID: SavedServer.ID
    let host: String
    let trustedKeyType: String?
    let trustedOpenSSHPublicKey: String?
    let receivedKeyType: String
    let receivedOpenSSHPublicKey: String
}

extension SSHHostKeyTrustChallenge {
    var receivedKeyFingerprint: String? {
        let parts = receivedOpenSSHPublicKey.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return nil
        }

        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:\(digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))"
    }
}

struct TerminalDisconnectReason: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case transportIO
        case serverUnreachable
        case authentication
        case hostKey
        case profile
        case tmuxUnavailable
        case remoteExit
        case runtime
        case userClosed
        case unknown

        var traceLabel: String {
            switch self {
            case .transportIO:
                "transport_io"
            case .serverUnreachable:
                "server_unreachable"
            case .authentication:
                "authentication"
            case .hostKey:
                "host_key"
            case .profile:
                "profile"
            case .tmuxUnavailable:
                "tmux_unavailable"
            case .remoteExit:
                "remote_exit"
            case .runtime:
                "runtime"
            case .userClosed:
                "user_closed"
            case .unknown:
                "unknown"
            }
        }
    }

    let kind: Kind
    let message: String
    let hostKeyChallenge: SSHHostKeyTrustChallenge?

    init(
        kind: Kind,
        message: String,
        hostKeyChallenge: SSHHostKeyTrustChallenge? = nil
    ) {
        self.kind = kind
        self.message = message
        self.hostKeyChallenge = hostKeyChallenge
    }

    var allowsAutomaticReconnect: Bool {
        switch kind {
        case .transportIO:
            true
        case .serverUnreachable,
             .authentication,
             .hostKey,
             .profile,
             .tmuxUnavailable,
             .remoteExit,
             .runtime,
             .userClosed,
             .unknown:
            false
        }
    }
}

enum TerminalReconnectSource: Equatable, Hashable, Sendable {
    case activeSessionTap
    case foreground
    case manualButton
    case transportLoss

    var isAutomatic: Bool {
        switch self {
        case .foreground, .transportLoss:
            true
        case .activeSessionTap, .manualButton:
            false
        }
    }

    var traceLabel: String {
        switch self {
        case .activeSessionTap:
            "active_session_tap"
        case .foreground:
            "foreground"
        case .manualButton:
            "manual_button"
        case .transportLoss:
            "transport_loss"
        }
    }
}

// Root-visible terminal state for library display and reconnect policy.
// `.connected` is produced from the current runtime/readiness contract:
// running plus a focused surface. It is not the input-ready gate and does not
// require writable transport.
enum TerminalRuntimeState: Equatable, Sendable {
    case connecting
    case reconnecting(TerminalReconnectSource)
    case connected
    case disconnected(TerminalDisconnectReason)

    var disconnectedReason: TerminalDisconnectReason? {
        if case .disconnected(let reason) = self { return reason }
        return nil
    }

    var traceLabel: String {
        switch self {
        case .connecting:
            "connecting"
        case .reconnecting(let source):
            "reconnecting_\(source.traceLabel)"
        case .connected:
            "connected"
        case .disconnected(let reason):
            "disconnected_\(reason.kind.traceLabel)"
        }
    }
}

enum TerminalRuntimeStateProjection {
    static func isRootVisibleConnected(_ state: TerminalRuntimeState) -> Bool {
        state == .connected
    }
}

enum TerminalRuntimeStateUpdateSource: Equatable, Sendable {
    case foreground
    case readiness
    case runtime

    var traceLabel: String {
        switch self {
        case .foreground:
            "foreground"
        case .readiness:
            "readiness"
        case .runtime:
            "runtime"
        }
    }
}

struct TerminalRuntimeStateUpdate: Equatable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let instanceID: UUID
    let state: TerminalRuntimeState
    let source: TerminalRuntimeStateUpdateSource
}

struct TerminalRuntimeStateReportTracker: Equatable, Sendable {
    private var lastReportedState: TerminalRuntimeState?
    private var foregroundReportedDisconnectedState: TerminalRuntimeState?

    mutating func shouldReport(
        state: TerminalRuntimeState,
        source: TerminalRuntimeStateUpdateSource
    ) -> Bool {
        let stateChanged = lastReportedState != state
        let isForegroundDisconnect = source == .foreground && state.disconnectedReason != nil

        if stateChanged {
            lastReportedState = state
            foregroundReportedDisconnectedState = isForegroundDisconnect ? state : nil
            return true
        }

        guard isForegroundDisconnect,
              foregroundReportedDisconnectedState != state
        else {
            return false
        }

        foregroundReportedDisconnectedState = state
        return true
    }
}

struct TmuxConnectionDraft: Equatable, Sendable {
    let serverID: SavedServer.ID
    var displayName: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var tmuxExecutablePath: String = ""
    var authenticationKind: SSHAuthenticationKind = .password
    var password: String = ""
    var privateKeyPEM: String = ""
    var privateKeyFileName: String = ""
    var privateKeyPassphrase: String = ""
    var sessionName: String = ""

    init(serverID: SavedServer.ID = UUID()) {
        self.serverID = serverID
    }

    init(server: SavedServer, workspace: SavedWorkspace) {
        self.init(serverID: server.id)
        self.displayName = server.displayName
        self.host = server.host
        self.port = String(server.port)
        self.username = server.username
        self.tmuxExecutablePath = server.tmuxExecutablePath ?? ""
        self.sessionName = workspace.sessionName
    }

    init(
        server: SavedServer,
        workspace: SavedWorkspace,
        identity: SSHIdentity,
        credential: SSHCredential
    ) {
        self.init(server: server, workspace: workspace)
        self.authenticationKind = identity.authenticationKind == .none ? .password : identity.authenticationKind

        switch credential {
        case .password(let password):
            self.password = password
        case .privateKey(let credential):
            self.privateKeyPEM = credential.privateKeyPEM
            self.privateKeyPassphrase = credential.passphrase ?? ""
        case .none:
            break
        }
    }
}

struct TmuxConnectionDraftValidation: Equatable, Sendable {
    var displayName: String?
    var host: String?
    var port: String?
    var username: String?
    var tmuxExecutablePath: String?
    var password: String?
    var privateKey: String?
    var privateKeyPassphrase: String?
    var sessionName: String?

    static let empty = TmuxConnectionDraftValidation()

    var isValid: Bool {
        displayName == nil &&
            host == nil &&
            port == nil &&
            username == nil &&
            tmuxExecutablePath == nil &&
            password == nil &&
            privateKey == nil &&
            privateKeyPassphrase == nil &&
            sessionName == nil
    }
}

struct ValidatedTmuxConnectionDraft: Equatable, Sendable {
    let server: ValidatedTmuxServerDraft
    let workspace: SavedWorkspace
}

struct ValidatedTmuxServerDraft: Equatable, Sendable {
    enum Credential: Equatable, Sendable {
        case password(String)
        case privateKey(SSHPrivateKeyCredential)
        case none

        var authenticationKind: SSHAuthenticationKind {
            switch self {
            case .password:
                .password
            case .privateKey:
                .privateKey
            case .none:
                .none
            }
        }
    }

    let serverID: SavedServer.ID
    let displayName: String
    let host: String
    let port: Int
    let username: String
    let tmuxExecutablePath: String?
    let credential: Credential

    func savedServer(identityID: SSHIdentity.ID) -> SavedServer {
        SavedServer(
            id: serverID,
            displayName: displayName,
            host: host,
            port: port,
            username: username,
            identityID: identityID,
            tmuxExecutablePath: tmuxExecutablePath
        )
    }
}

struct ValidatedTmuxWorkspaceDraft: Equatable, Sendable {
    let workspace: SavedWorkspace
}

enum TmuxConnectionDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxConnectionDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxServerDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxServerDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxWorkspaceDraftValidationResult: Equatable, Sendable {
    case valid(ValidatedTmuxWorkspaceDraft)
    case invalid(TmuxConnectionDraftValidation)
}

enum TmuxConnectionDraftValidator {
    static func validate(
        _ draft: TmuxConnectionDraft,
        existingServerID: SavedServer.ID?,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxConnectionDraftValidationResult {
        let serverResult = validateServer(draft, existingServerID: existingServerID)
        let workspaceServerID: SavedServer.ID
        if case .valid(let serverSubmission) = serverResult {
            workspaceServerID = serverSubmission.serverID
        } else {
            workspaceServerID = existingServerID ?? UUID()
        }

        let workspaceResult = validateWorkspace(
            draft,
            serverID: workspaceServerID,
            existingWorkspaceID: existingWorkspaceID
        )

        if case .valid(let serverSubmission) = serverResult,
           case .valid(let workspaceSubmission) = workspaceResult {
            return .valid(
                ValidatedTmuxConnectionDraft(
                    server: serverSubmission,
                    workspace: workspaceSubmission.workspace
                )
            )
        }

        var validation = TmuxConnectionDraftValidation.empty
        if case .invalid(let serverValidation) = serverResult {
            validation.merge(serverValidation)
        }
        if case .invalid(let workspaceValidation) = workspaceResult {
            validation.merge(workspaceValidation)
        }
        return .invalid(validation)
    }

    static func validateServer(
        _ draft: TmuxConnectionDraft,
        existingServerID: SavedServer.ID?
    ) -> TmuxServerDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty
        let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTmuxExecutablePath = draft.tmuxExecutablePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tmuxExecutablePath = trimmedTmuxExecutablePath.isEmpty
            ? nil
            : trimmedTmuxExecutablePath
        let password = draft.password
        let privateKeyPEM = draft.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKeyPassphrase = draft.privateKeyPassphrase.isEmpty ? nil : draft.privateKeyPassphrase

        if displayName.isEmpty {
            validation.displayName = "Name is required."
        }

        if host.isEmpty {
            validation.host = "IP or hostname is required."
        }

        guard let port = Int(draft.port), (1...65_535).contains(port) else {
            validation.port = "Port must be between 1 and 65535."
            return .invalid(validation)
        }

        let serverID = existingServerID ?? draft.serverID
        if username.isEmpty {
            validation.username = "Username is required."
        }

        if let tmuxExecutablePath {
            if !tmuxExecutablePath.hasPrefix("/") {
                validation.tmuxExecutablePath = "Enter an absolute path beginning with /."
            } else if tmuxExecutablePath.contains("\n") ||
                        tmuxExecutablePath.contains("\r") ||
                        tmuxExecutablePath.contains("\0") {
                validation.tmuxExecutablePath = "Executable path contains invalid characters."
            }
        }

        let credential: ValidatedTmuxServerDraft.Credential
        switch draft.authenticationKind {
        case .password:
            credential = password.isEmpty ? .none : .password(password)

        case .privateKey:
            if privateKeyPEM.isEmpty {
                validation.privateKey = "Private key is required."
            } else {
                do {
                    let inspection = try SSHPrivateKeyInspector.inspect(privateKeyPEM)
                    if inspection.isEncrypted && privateKeyPassphrase == nil {
                        validation.privateKeyPassphrase = "Passphrase is required for encrypted private keys."
                    }
                } catch {
                    if let error = error as? LocalizedError {
                        validation.privateKey = error.errorDescription ?? "Private key could not be read."
                    } else {
                        validation.privateKey = "Private key could not be read."
                    }
                }
            }
            credential = .privateKey(
                SSHPrivateKeyCredential(
                    privateKeyPEM: privateKeyPEM,
                    passphrase: privateKeyPassphrase
                )
            )

        case .none:
            credential = .none
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        return .valid(
            ValidatedTmuxServerDraft(
                serverID: serverID,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                tmuxExecutablePath: tmuxExecutablePath,
                credential: credential
            )
        )
    }

    static func validateWorkspace(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxWorkspaceDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty
        let sessionName = draft.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        if sessionName.isEmpty {
            validation.sessionName = "tmux session name is required."
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        return .valid(
            ValidatedTmuxWorkspaceDraft(
                workspace: SavedWorkspace(
                    id: existingWorkspaceID ?? UUID(),
                    serverID: serverID,
                    sessionName: sessionName,
                    lastOpenedAt: Date()
                )
            )
        )
    }
}

private extension TmuxConnectionDraftValidation {
    mutating func merge(_ other: TmuxConnectionDraftValidation) {
        displayName = displayName ?? other.displayName
        host = host ?? other.host
        port = port ?? other.port
        username = username ?? other.username
        tmuxExecutablePath = tmuxExecutablePath ?? other.tmuxExecutablePath
        password = password ?? other.password
        privateKey = privateKey ?? other.privateKey
        privateKeyPassphrase = privateKeyPassphrase ?? other.privateKeyPassphrase
        sessionName = sessionName ?? other.sessionName
    }
}
