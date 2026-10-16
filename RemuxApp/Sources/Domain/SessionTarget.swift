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
        let inspection = try credential.inspect()
        return ResolvedSSHAuth(
            identityID: identityID,
            username: username,
            displayLabel: displayLabel,
            authFingerprint: [
                credential.secureEnclaveKey == nil ? "private-key" : "secure-enclave",
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
    var herdrExecutablePath: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String,
        identityID: SSHIdentity.ID,
        tmuxExecutablePath: String? = nil,
        herdrExecutablePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.identityID = identityID
        self.tmuxExecutablePath = tmuxExecutablePath
        self.herdrExecutablePath = herdrExecutablePath
    }
}

/// The multiplexer that hosts a saved session.
enum SessionBackend: String, Codable, Sendable {
    case tmux
    case herdr

    var displayName: String {
        switch self {
        case .tmux: "tmux"
        case .herdr: "Herdr"
        }
    }

    /// The name a new session starts with: Herdr's own default, and none for tmux.
    var defaultSessionName: String {
        switch self {
        case .tmux: ""
        case .herdr: "default"
        }
    }

    /// The oldest version Remux runs. For tmux it's the oldest the terminal library's control-mode client
    /// accepts: it closes the session on anything older.
    var minimumSupportedVersion: String {
        switch self {
        case .tmux: "3.1"
        case .herdr: HerdrVersion.minimumSupported.description
        }
    }
}

/// Names a session on a server. Session names are only unique per backend, so
/// a tmux and a Herdr session with the same name are different sessions.
struct SessionLocator: Hashable, Sendable {
    let backend: SessionBackend
    let name: String
}

/// A Herdr session as Remux's bridge reaches it: the server's address, the account and the Herdr it runs, and
/// the session's name. Saved servers that reach the same one reach the same session, whatever their names, and
/// one edited to reach another machine reaches another session.
struct HerdrSessionAddress: Hashable, Codable, Sendable {
    let host: String
    let port: Int
    let username: String
    let herdrExecutablePath: String?
    let session: String
}

extension HerdrSessionAddress {
    init(_ target: SessionTarget) {
        self.init(
            host: target.server.host,
            port: target.server.port,
            username: target.sshAuth.username,
            herdrExecutablePath: target.server.herdrExecutablePath,
            session: target.workspace.sessionName
        )
    }
}

/// A session a backend's discovery listed on a server.
struct DiscoveredSession: Equatable, Sendable {
    let name: String
    /// tmux lists only running sessions. Herdr lists stopped ones too, and opening one starts it.
    let isRunning: Bool
    /// Why Herdr can't reach a session it lists, as its `connection_error` says; such a session isn't
    /// offered, since opening it would try to start it.
    var unavailableReason: String? = nil
}

/// What a backend's discovery found on a server: where its program is, and its sessions.
struct SessionListing: Equatable, Sendable {
    let executablePath: String
    let sessions: [DiscoveredSession]
}

struct SavedWorkspace: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let serverID: SavedServer.ID
    let backend: SessionBackend
    var sessionName: String
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        serverID: SavedServer.ID,
        backend: SessionBackend = .tmux,
        sessionName: String,
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.backend = backend
        self.sessionName = sessionName
        self.lastOpenedAt = lastOpenedAt
    }

    // Workspaces saved before backends existed have no backend and are tmux.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverID = try container.decode(SavedServer.ID.self, forKey: .serverID)
        backend = try container.decodeIfPresent(SessionBackend.self, forKey: .backend) ?? .tmux
        sessionName = try container.decode(String.self, forKey: .sessionName)
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
    }

    var locator: SessionLocator {
        SessionLocator(backend: backend, name: sessionName)
    }
}

/// How opening a session treats one that isn't there. Remux creates a session only when asked: New Session and
/// Restart. Herdr creates a session on first use itself, so only tmux reads this.
enum SessionOpening: Equatable, Sendable {
    /// Attach to the session by its exact name; a session that's gone stays gone.
    case attach
    /// Attach to it, or create it when it isn't there.
    case create
}

struct SessionTarget: Equatable, Sendable {
    let server: SavedServer
    let workspace: SavedWorkspace
    let sshAuth: ResolvedSSHAuth
    let terminalSettings: TerminalSettings
    var opening: SessionOpening

    var locator: SessionLocator {
        workspace.locator
    }

    init(
        server: SavedServer,
        workspace: SavedWorkspace,
        sshAuth: ResolvedSSHAuth,
        terminalSettings: TerminalSettings = .default,
        opening: SessionOpening = .attach
    ) {
        self.server = server
        self.workspace = workspace
        self.sshAuth = sshAuth
        self.terminalSettings = terminalSettings
        self.opening = opening
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
        /// Tailscale asked to verify the connection, and it wasn't verified in time.
        case verificationExpired
        /// The session is gone from the server: it was ended or killed, or it never existed.
        case sessionEnded
        case keyUnlock
        case hostKey
        case profile
        /// The session's program isn't installed on the server, or can't be run there.
        case backendUnavailable(SessionBackend)
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
            case .keyUnlock:
                "key_unlock"
            case .authentication:
                "authentication"
            case .verificationExpired:
                "verification_expired"
            case .sessionEnded:
                "session_ended"
            case .hostKey:
                "host_key"
            case .profile:
                "profile"
            case .backendUnavailable(let backend):
                "\(backend.rawValue)_unavailable"
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
    /// What went wrong. The session's screen shows it for a backend problem or an exit, whose words come from
    /// where it happened; every other kind has the same words there each time, and this is for diagnostics.
    let message: String
    /// The server's own words, shown under `message`.
    let detail: String?
    let hostKeyChallenge: SSHHostKeyTrustChallenge?

    init(
        kind: Kind,
        message: String,
        detail: String? = nil,
        hostKeyChallenge: SSHHostKeyTrustChallenge? = nil
    ) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.hostKeyChallenge = hostKeyChallenge
    }

    var allowsAutomaticReconnect: Bool {
        switch kind {
        case .transportIO:
            true
        case .serverUnreachable,
             .authentication,
             .verificationExpired,
             .sessionEnded,
             .keyUnlock,
             .hostKey,
             .profile,
             .backendUnavailable,
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
    /// Restart on an ended session: a new, empty one with its name.
    case restart

    var isAutomatic: Bool {
        switch self {
        case .foreground, .transportLoss:
            true
        case .activeSessionTap, .manualButton, .restart:
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
        case .restart:
            "restart"
        }
    }
}

// Root-visible terminal state for library display and reconnect policy.
// TerminalReadinessProjector.runtimeState reports .connected only with a
// writable protocol attachment and a selected pane whose attached renderer
// has published its first frame.
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
    var herdrExecutablePath: String = ""
    var authenticationKind: SSHAuthenticationKind = .password
    var password: String = ""
    var secureEnclaveKey: SecureEnclaveSSHKey?
    var privateKeyPEM: String = ""
    var privateKeyFileName: String = ""
    var privateKeyPassphrase: String = ""
    var backend: SessionBackend = .tmux
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
        self.herdrExecutablePath = server.herdrExecutablePath ?? ""
        self.backend = workspace.backend
        self.sessionName = workspace.sessionName
    }

    init(
        server: SavedServer,
        workspace: SavedWorkspace,
        identity: SSHIdentity,
        credential: SSHCredential?
    ) {
        self.init(server: server, workspace: workspace)
        self.authenticationKind = identity.authenticationKind

        switch credential {
        case .some(.password(let password)):
            self.password = password
        case .some(.privateKey(let credential)):
            self.secureEnclaveKey = credential.secureEnclaveKey
            self.privateKeyPEM = credential.privateKeyPEM
            self.privateKeyPassphrase = credential.passphrase ?? ""
        case .none:
            break
        }
    }

    /// Whether the server's last check of `backend`, made with `server`'s saved settings, is about what this
    /// draft names: the same account at the same address and the same executable path. The sign-in method
    /// doesn't change what is installed for the account, so it doesn't count.
    func checksSameExecutable(as server: SavedServer, for backend: SessionBackend) -> Bool {
        let draftPath = switch backend {
        case .tmux: tmuxExecutablePath
        case .herdr: herdrExecutablePath
        }
        let path = draftPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.trimmingCharacters(in: .whitespacesAndNewlines) == server.host
            && Int(port) == server.port
            && username.trimmingCharacters(in: .whitespacesAndNewlines) == server.username
            && (path.isEmpty ? nil : path) == server.executablePath(for: backend)
    }
}

struct TmuxConnectionDraftValidation: Equatable, Sendable {
    var displayName: String?
    var host: String?
    var port: String?
    var username: String?
    var tmuxExecutablePath: String?
    var herdrExecutablePath: String?
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
            herdrExecutablePath == nil &&
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
    let herdrExecutablePath: String?
    let credential: Credential

    func savedServer(identityID: SSHIdentity.ID) -> SavedServer {
        SavedServer(
            id: serverID,
            displayName: displayName,
            host: host,
            port: port,
            username: username,
            identityID: identityID,
            tmuxExecutablePath: tmuxExecutablePath,
            herdrExecutablePath: herdrExecutablePath
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

    /// Why an executable path can't be used, or nil when it is empty (automatic) or usable.
    static func executablePathProblem(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.hasPrefix("/") {
            return "Enter an absolute path beginning with /."
        }
        if trimmed.contains("\n") || trimmed.contains("\r") || trimmed.contains("\0") {
            return "Executable path contains invalid characters."
        }
        return nil
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

        validation.tmuxExecutablePath = executablePathProblem(draft.tmuxExecutablePath)
        validation.herdrExecutablePath = executablePathProblem(draft.herdrExecutablePath)
        let trimmedHerdrExecutablePath = draft.herdrExecutablePath
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let credential: ValidatedTmuxServerDraft.Credential
        switch draft.authenticationKind {
        case .password:
            if password.isEmpty {
                validation.password = "Password is required."
            }
            credential = .password(password)

        case .privateKey:
            if privateKeyPEM.isEmpty && draft.secureEnclaveKey == nil {
                validation.privateKey = "Private key is required."
            } else {
                do {
                    let inspection = try SSHPrivateKeyCredential(privateKeyPEM: privateKeyPEM, secureEnclaveKey: draft.secureEnclaveKey).inspect()
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
                    passphrase: privateKeyPassphrase,
                    secureEnclaveKey: draft.secureEnclaveKey
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
                herdrExecutablePath: trimmedHerdrExecutablePath.isEmpty ? nil : trimmedHerdrExecutablePath,
                credential: credential
            )
        )
    }

    /// Herdr's own rule for session names (`session::validate_name`), or nil for a usable name.
    static func herdrSessionNameProblem(_ name: String) -> String? {
        if name.isEmpty {
            return "Herdr session name is required."
        }
        if name.utf8.count > 64 {
            return "Use 64 characters or fewer."
        }
        if name == "." || name == ".." {
            return "A Herdr session can't be named . or .."
        }
        let allowed = name.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
        return allowed ? nil : "Use only letters, numbers, dots, underscores and hyphens."
    }

    static func validateWorkspace(
        _ draft: TmuxConnectionDraft,
        serverID: SavedServer.ID,
        existingWorkspaceID: SavedWorkspace.ID?
    ) -> TmuxWorkspaceDraftValidationResult {
        var validation = TmuxConnectionDraftValidation.empty
        let sessionName = draft.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        let savedName: String
        switch draft.backend {
        case .tmux:
            if sessionName.isEmpty {
                validation.sessionName = "tmux session name is required."
            }
            savedName = TmuxSessionName.kept(sessionName)
        case .herdr:
            validation.sessionName = herdrSessionNameProblem(sessionName)
            savedName = sessionName
        }

        guard validation.isValid else {
            return .invalid(validation)
        }

        return .valid(
            ValidatedTmuxWorkspaceDraft(
                workspace: SavedWorkspace(
                    id: existingWorkspaceID ?? UUID(),
                    serverID: serverID,
                    backend: draft.backend,
                    sessionName: savedName,
                    lastOpenedAt: Date()
                )
            )
        )
    }
}

/// A session's name as tmux keeps it: tmux turns ':' and '.' into '_' when it names a session, so `work.api` is
/// `work_api` on the server, and attaching by `work.api` would look for pane `api`.
enum TmuxSessionName {
    static func kept(_ name: String) -> String {
        String(name.map { $0 == ":" || $0 == "." ? "_" : $0 })
    }
}

private extension TmuxConnectionDraftValidation {
    mutating func merge(_ other: TmuxConnectionDraftValidation) {
        displayName = displayName ?? other.displayName
        host = host ?? other.host
        port = port ?? other.port
        username = username ?? other.username
        tmuxExecutablePath = tmuxExecutablePath ?? other.tmuxExecutablePath
        herdrExecutablePath = herdrExecutablePath ?? other.herdrExecutablePath
        password = password ?? other.password
        privateKey = privateKey ?? other.privateKey
        privateKeyPassphrase = privateKeyPassphrase ?? other.privateKeyPassphrase
        sessionName = sessionName ?? other.sessionName
    }
}

extension ResolvedSSHAuth {
    var usesSecureEnclaveKey: Bool {
        if case .privateKey(let key) = credential { return key.secureEnclaveKey != nil }
        return false
    }

    var requiresInteractiveAuthentication: Bool {
        switch credential {
        case .none: true
        case .password: false
        case .privateKey(let key): key.secureEnclaveKey != nil
        }
    }
}
