@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import NIOCore

private enum RemuxConnectionTimeouts {
    static let terminalSSHConnect: TimeAmount = .seconds(10)
    static let tmuxControlNoResponse: TimeAmount = .seconds(15)
    static let sftpSSHConnect: TimeAmount = .seconds(15)
    static let sftpOperation: TimeAmount = .seconds(15)
}

struct RemuxAppDependencies: Sendable {
    let profileRepository: any ConnectionProfileRepository
    let settingsRepository: any TerminalSettingsRepository
    let keyboardSettingsRepository: any KeyboardSettingsRepository
    let shortcutRepository: any ShortcutRepository
    let credentialStore: any SSHCredentialStore
    let trustedHostStore: TrustedHostStore
    private let sshRootService: RemuxSSHRootService
    private let transportFactory: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) -> any TmuxControlTransport
    private let sshConnectionPrewarmer: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) async -> Void
    private let attachmentTransferServiceFactory: @Sendable (
        _ target: TmuxConnectionTarget,
        _ trustedHostStore: TrustedHostStore,
        _ sshRootService: RemuxSSHRootService
    ) -> any GhosttyAttachmentTransferService
    private let debugConnectionSeeder: @Sendable (
        _ profileRepository: any ConnectionProfileRepository,
        _ credentialStore: any SSHCredentialStore
    ) async throws -> Bool

    init(
        profileRepository: any ConnectionProfileRepository,
        settingsRepository: any TerminalSettingsRepository,
        keyboardSettingsRepository: any KeyboardSettingsRepository,
        shortcutRepository: any ShortcutRepository,
        credentialStore: any SSHCredentialStore,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService = RemuxSSHRootService(),
        transportFactory: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) -> any TmuxControlTransport = RemuxAppDependencies.liveTransport,
        sshConnectionPrewarmer: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) async -> Void = RemuxAppDependencies.liveSSHConnectionPrewarmer,
        attachmentTransferServiceFactory: @escaping @Sendable (
            _ target: TmuxConnectionTarget,
            _ trustedHostStore: TrustedHostStore,
            _ sshRootService: RemuxSSHRootService
        ) -> any GhosttyAttachmentTransferService = RemuxAppDependencies.liveAttachmentTransferService,
        debugConnectionSeeder: @escaping @Sendable (
            _ profileRepository: any ConnectionProfileRepository,
            _ credentialStore: any SSHCredentialStore
        ) async throws -> Bool = RemuxAppDependencies.liveDebugConnectionSeeder
    ) {
        self.profileRepository = profileRepository
        self.settingsRepository = settingsRepository
        self.keyboardSettingsRepository = keyboardSettingsRepository
        self.shortcutRepository = shortcutRepository
        self.credentialStore = credentialStore
        self.trustedHostStore = trustedHostStore
        self.sshRootService = sshRootService
        self.transportFactory = transportFactory
        self.sshConnectionPrewarmer = sshConnectionPrewarmer
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
        self.debugConnectionSeeder = debugConnectionSeeder
    }

    static func launch() -> Result<RemuxAppDependencies, Error> {
        Result {
#if DEBUG || REMUX_LIVE_UI_TESTING
            if ProcessInfo.processInfo.environment["REMUX_UI_TESTING"] == "1" {
                return try uiTesting()
            }
#endif
            return try live()
        }
    }

    static func live() throws -> RemuxAppDependencies {
#if DEBUG || REMUX_LIVE_UI_TESTING
        let environment = ProcessInfo.processInfo.environment
        let usesEphemeralDebugStorage = environment[DebugLiveEnvironmentKey.ephemeralStorage] == "1"
        let root: URL
        let credentialStore: any SSHCredentialStore
        if usesEphemeralDebugStorage {
            root = try ApplicationStorage.remuxRoot(
                overridePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RemuxLiveDebug-\(UUID().uuidString)", isDirectory: true)
                    .path
            )
            credentialStore = InMemorySSHCredentialStore()
        } else {
            root = try ApplicationStorage.remuxRoot()
            credentialStore = KeychainSSHCredentialStore()
        }
#else
        let root = try ApplicationStorage.remuxRoot()
        let credentialStore: any SSHCredentialStore = KeychainSSHCredentialStore()
#endif
        return RemuxAppDependencies(
            profileRepository: FileBackedConnectionProfileRepository(rootURL: root),
            settingsRepository: FileBackedTerminalSettingsRepository(rootURL: root),
            keyboardSettingsRepository: FileBackedKeyboardSettingsRepository(rootURL: root),
            shortcutRepository: FileBackedShortcutRepository(rootURL: root),
            credentialStore: credentialStore,
            trustedHostStore: TrustedHostStore(rootURL: root)
        )
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        transportFactory(target, trustedHostStore, sshRootService)
    }

    func prewarmSSHConnection(for target: TmuxConnectionTarget) async {
        await sshConnectionPrewarmer(target, trustedHostStore, sshRootService)
    }

    func makeAttachmentTransferService(for target: TmuxConnectionTarget) -> any GhosttyAttachmentTransferService {
        attachmentTransferServiceFactory(target, trustedHostStore, sshRootService)
    }

    func closeIdleSSHConnections(forServerID serverID: SavedServer.ID) {
        Task {
            await sshRootService.closeIdleConnections(forServerID: serverID)
        }
    }

    private static func liveTransport(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) -> any TmuxControlTransport {
        SSHTmuxControlTransport(
            configuration: sshConfiguration(
                for: target,
                trustedHostStore: trustedHostStore,
                traceFlowID: "session.open.\(target.workspace.id.uuidString)"
            ),
            sshRootService: sshRootService
        )
    }

    private static func liveSSHConnectionPrewarmer(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) async {
        let trace = RemuxTransportStartupTrace(flowID: nil)
        let configuration = sshConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            traceFlowID: nil
        )
        guard let rootKey = configuration.sshRootKey else { return }

        await sshRootService.prewarmConnection(
            for: rootKey,
            configuration: configuration.sshRootConfiguration,
            trace: trace,
            reason: "library"
        )
    }

    static func sshConfiguration(
        for target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        traceFlowID: String?
    ) -> SSHTmuxControlConfiguration {
        SSHTmuxControlConfiguration(
            host: target.server.host,
            port: target.server.port,
            authenticationMethod: {
                try authenticationMethod(for: target.sshAuth)
            },
            hostKeyValidator: trustedHostStore.validator(for: target.server),
            connectTimeout: RemuxConnectionTimeouts.terminalSSHConnect,
            controlNoResponseTimeout: RemuxConnectionTimeouts.tmuxControlNoResponse,
            tmuxExecutable: target.server.tmuxExecutablePath ?? "tmux",
            sessionName: target.workspace.sessionName,
            traceFlowID: traceFlowID,
            sshRootKey: RemuxSSHRootKey(target: target)
        )
    }

    static func attachmentSSHRootConfiguration(
        for target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore
    ) -> RemuxSSHRootConfiguration {
        sshRootConfiguration(
            for: target,
            trustedHostStore: trustedHostStore,
            connectTimeout: RemuxConnectionTimeouts.sftpSSHConnect
        )
    }

    private static func liveAttachmentTransferService(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        sshRootService: RemuxSSHRootService
    ) -> any GhosttyAttachmentTransferService {
        let rootConfiguration = attachmentSSHRootConfiguration(
            for: target,
            trustedHostStore: trustedHostStore
        )
        let provider = RemuxCitadelSFTPClientProvider(
            sshRootService: sshRootService,
            rootKey: RemuxSSHRootKey(target: target),
            rootConfiguration: rootConfiguration,
            operationTimeout: RemuxConnectionTimeouts.sftpOperation
        )
        return GhosttyAttachmentSFTPClientProviderTransferService(provider: provider)
    }

    private static func sshRootConfiguration(
        for target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore,
        connectTimeout: TimeAmount
    ) -> RemuxSSHRootConfiguration {
        RemuxSSHRootConfiguration(
            host: target.server.host,
            port: target.server.port,
            authenticationMethod: {
                try authenticationMethod(for: target.sshAuth)
            },
            hostKeyValidator: trustedHostStore.validator(for: target.server),
            connectTimeout: connectTimeout
        )
    }

    private static func authenticationMethod(for auth: ResolvedSSHAuth) throws -> SSHAuthenticationMethod {
        switch auth.credential {
        case .password(let password):
            return .passwordBased(username: auth.username, password: password)
        case .privateKey(let credential):
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let decryptionKey = credential.passphrase.map { Data($0.utf8) }
            switch inspection.keyType {
            case .ed25519:
                return try .ed25519(
                    username: auth.username,
                    privateKey: Curve25519.Signing.PrivateKey(
                        sshEd25519: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .rsa:
                return try .rsa(
                    username: auth.username,
                    privateKey: Insecure.RSA.PrivateKey(
                        sshRsa: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP256:
                return try .p256(
                    username: auth.username,
                    privateKey: P256.Signing.PrivateKey(
                        sshEcdsaP256: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP384:
                return try .p384(
                    username: auth.username,
                    privateKey: P384.Signing.PrivateKey(
                        sshEcdsaP384: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP521:
                return try .p521(
                    username: auth.username,
                    privateKey: P521.Signing.PrivateKey(
                        sshEcdsaP521: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            }
        }
    }

#if DEBUG || REMUX_LIVE_UI_TESTING
    private enum DebugLiveEnvironmentKey {
        static let ephemeralStorage = "REMUX_DEBUG_EPHEMERAL_STORAGE"
    }

    static func uiTesting() throws -> RemuxAppDependencies {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemuxUITesting", isDirectory: true)

        return RemuxAppDependencies(
            profileRepository: InMemoryConnectionProfileRepository(),
            settingsRepository: InMemoryTerminalSettingsRepository(),
            keyboardSettingsRepository: InMemoryKeyboardSettingsRepository(),
            shortcutRepository: InMemoryShortcutRepository(),
            credentialStore: InMemorySSHCredentialStore(),
            trustedHostStore: TrustedHostStore(rootURL: root),
            transportFactory: { _, _, _ in
                DeterministicTmuxControlTransport(chunks: [])
            },
            sshConnectionPrewarmer: { _, _, _ in
            }
        )
    }
#endif

#if DEBUG || REMUX_LIVE_UI_TESTING
    @discardableResult
    func seedDebugConnectionIfRequested() async throws -> Bool {
        try await debugConnectionSeeder(profileRepository, credentialStore)
    }

    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        try await DebugConnectionProfileSeeder.seedIfRequested(
            profileRepository: profileRepository,
            credentialStore: credentialStore
        )
    }
#else
    private static func liveDebugConnectionSeeder(
        profileRepository: any ConnectionProfileRepository,
        credentialStore: any SSHCredentialStore
    ) async throws -> Bool {
        false
    }
#endif
}

#if DEBUG || REMUX_LIVE_UI_TESTING
private actor InMemoryConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer] = []
    private var workspaces: [SavedWorkspace] = []
    private var identities: [SSHIdentity] = []

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let serverIDs = Set(servers.map(\.id))
        return ConnectionLibrarySnapshot(
            servers: servers.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            workspaces: workspaces.filter { serverIDs.contains($0.serverID) },
            identities: identities.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServer(_ server: SavedServer) async throws {
        upsert(server, into: &servers)
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        upsert(workspace, into: &workspaces)
    }

    func saveIdentity(_ identity: SSHIdentity) async throws {
        upsert(identity, into: &identities)
    }

    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws {
        upsert(identity, into: &identities)
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func deleteIdentity(id: SSHIdentity.ID) async throws {
        identities.removeAll { $0.id == id }
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}

private actor InMemoryTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings = TerminalSettings.default

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        self.settings = settings
    }
}

private actor InMemoryKeyboardSettingsRepository: KeyboardSettingsRepository {
    private var settings = KeyboardSettings.default

    func loadSettings() async throws -> KeyboardSettings {
        settings
    }

    func saveSettings(_ settings: KeyboardSettings) async throws {
        self.settings = try settings.validated()
    }
}

private actor InMemoryShortcutRepository: ShortcutRepository {
    private var snapshot: ShortcutStoreSnapshot
    private let starters: [StarterShortcut]

    init(
        snapshot: ShortcutStoreSnapshot = ShortcutStoreSnapshot(),
        starters: [StarterShortcut] = StarterShortcuts.all
    ) {
        self.snapshot = snapshot
        self.starters = starters
    }

    func loadSnapshot() async throws -> ShortcutStoreSnapshot {
        snapshot.installMissingStarters(starters)
        return snapshot
    }

    func saveSnapshot(_ snapshot: ShortcutStoreSnapshot) async throws {
        self.snapshot = snapshot
    }
}

private actor InMemorySSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential] = [:]

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
#endif
