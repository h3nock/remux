import Foundation

enum SSHPublicKeyInstallDraftError: Error, Equatable, LocalizedError {
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "IP or hostname is required."
        case .invalidPort:
            "Port must be between 1 and 65535."
        case .invalidUsername:
            "Username is required."
        case .invalidPrivateKey:
            "Import a valid OpenSSH private key."
        }
    }
}

struct ActiveTerminalSession: Identifiable, Equatable, Sendable {
    let id: SavedWorkspace.ID
    var target: TmuxConnectionTarget
    var instanceID: UUID
    var runtimeState: TerminalRuntimeState
    var automaticReconnectAttemptedSources: Set<TerminalReconnectSource>

    init(
        target: TmuxConnectionTarget,
        instanceID: UUID = UUID(),
        runtimeState: TerminalRuntimeState = .connecting,
        automaticReconnectAttemptedSources: Set<TerminalReconnectSource> = []
    ) {
        self.id = target.workspace.id
        self.target = target
        self.instanceID = instanceID
        self.runtimeState = runtimeState
        self.automaticReconnectAttemptedSources = automaticReconnectAttemptedSources
    }

    mutating func replaceRuntime(source: TerminalReconnectSource) {
        instanceID = UUID()
        runtimeState = .reconnecting(source)
        if !source.isAutomatic {
            automaticReconnectAttemptedSources.removeAll()
        }
    }

    mutating func applyRuntimeState(_ state: TerminalRuntimeState) {
        runtimeState = state
        if TerminalRuntimeStateProjection.isRootVisibleConnected(state) {
            automaticReconnectAttemptedSources.removeAll()
        }
    }

    mutating func markAutomaticReconnectAttempted(source: TerminalReconnectSource) -> Bool {
        guard source.isAutomatic else { return true }
        return automaticReconnectAttemptedSources.insert(source).inserted
    }
}

struct TerminalRuntimeAttemptKey: Hashable, Sendable {
    let workspaceID: SavedWorkspace.ID
    let instanceID: UUID

    init(workspaceID: SavedWorkspace.ID, instanceID: UUID) {
        self.workspaceID = workspaceID
        self.instanceID = instanceID
    }

    init(session: ActiveTerminalSession) {
        self.init(workspaceID: session.id, instanceID: session.instanceID)
    }
}

struct ActiveTerminalScreenEntry: Identifiable {
    let id: SavedWorkspace.ID
    let instanceID: UUID
    let runtimeAttemptKey: TerminalRuntimeAttemptKey
    let presentation: GhosttySurfaceScreenPresentation
    let model: TmuxScreenModel
    let attachmentTransferServiceFactory: @Sendable () -> any GhosttyAttachmentTransferService

    init(
        session: ActiveTerminalSession,
        model: TmuxScreenModel,
        attachmentTransferServiceFactory: @escaping @Sendable () -> any GhosttyAttachmentTransferService
    ) {
        self.id = session.id
        self.instanceID = session.instanceID
        self.runtimeAttemptKey = TerminalRuntimeAttemptKey(session: session)
        self.presentation = GhosttySurfaceScreenPresentation(
            workspaceID: session.target.workspace.id,
            sessionName: session.target.workspace.sessionName,
            terminalTheme: session.target.terminalSettings.theme,
            loadingTitle: TerminalRuntimeStatusPresentation.projection(
                for: session.runtimeState
            ).loadingTitle ?? TerminalRuntimeStatusPresentation.defaultLoadingTitle
        )
        self.model = model
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
    }
}

struct TmuxSessionDiscoveryState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    static let idle = TmuxSessionDiscoveryState(
        phase: .idle,
        lastSuccessfulSessionNames: nil
    )

    let phase: Phase
    let lastSuccessfulSessionNames: [String]?

    var sessionNames: [String] {
        lastSuccessfulSessionNames ?? []
    }

    var isLoading: Bool {
        phase == .loading
    }

    func startingRefresh() -> Self {
        Self(
            phase: .loading,
            lastSuccessfulSessionNames: lastSuccessfulSessionNames
        )
    }

    func finishingRefresh(with sessionNames: [String]) -> Self {
        Self(
            phase: .loaded,
            lastSuccessfulSessionNames: sessionNames
        )
    }

    func failingRefresh() -> Self {
        Self(
            phase: .failed,
            lastSuccessfulSessionNames: lastSuccessfulSessionNames
        )
    }

    func cancellingRefresh() -> Self {
        guard let lastSuccessfulSessionNames else { return .idle }
        return Self(
            phase: .loaded,
            lastSuccessfulSessionNames: lastSuccessfulSessionNames
        )
    }

    func confirmingExistingSession(named sessionName: String) -> Self {
        guard var lastSuccessfulSessionNames,
              !lastSuccessfulSessionNames.contains(sessionName) else {
            return self
        }
        lastSuccessfulSessionNames.append(sessionName)
        return Self(
            phase: phase,
            lastSuccessfulSessionNames: lastSuccessfulSessionNames
        )
    }
}

enum TmuxSessionReconciliation {
    static func includesSavedWorkspace(
        _ workspace: SavedWorkspace,
        discoveryStates: [SavedServer.ID: TmuxSessionDiscoveryState]
    ) -> Bool {
        guard let discoveredNames = discoveryStates[workspace.serverID]?
            .lastSuccessfulSessionNames else {
            return true
        }
        return discoveredNames.contains(workspace.sessionName)
    }
}

@MainActor
final class RemuxRootModel: ObservableObject {
    private struct TmuxSessionRefresh {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let libraryPrewarmServerLimit = 3

    private struct EditServerTrustSnapshot {
        let setupID: UUID
        let serverID: SavedServer.ID
        let identity: TrustedHostIdentity?
    }

    private struct SetupAction: Equatable {
        let id: UUID
        let setupID: UUID
    }

    typealias TerminalScreenModelFactory = @MainActor @Sendable (
        TmuxConnectionTarget,
        UUID,
        @escaping TmuxScreenModel.TransportFactory,
        @escaping (TerminalRuntimeStateUpdate) -> Void,
        TmuxSessionController.ClientSize?
    ) -> TmuxScreenModel

    enum SetupMode: Equatable {
        case newServer
        case newWorkspace(SavedServer.ID)
        case editServer(SavedServer.ID, reconnectWorkspaceID: SavedWorkspace.ID?)
        case editWorkspace(SavedServer.ID, SavedWorkspace.ID)

        var existingServerID: SavedServer.ID? {
            switch self {
            case .newServer:
                nil
            case .newWorkspace(let serverID), .editServer(let serverID, _), .editWorkspace(let serverID, _):
                serverID
            }
        }

        var existingWorkspaceID: SavedWorkspace.ID? {
            switch self {
            case .newServer, .newWorkspace, .editServer:
                nil
            case .editWorkspace(_, let workspaceID):
                workspaceID
            }
        }
    }

    enum SetupCancelDestination: Equatable {
        case library
        case terminal(SavedWorkspace.ID)
    }

    struct ConnectionSetupState: Equatable {
        var draft: TmuxConnectionDraft
        var validation: TmuxConnectionDraftValidation
        let mode: SetupMode
        let cancelDestination: SetupCancelDestination

        init(
            draft: TmuxConnectionDraft,
            validation: TmuxConnectionDraftValidation = .empty,
            mode: SetupMode,
            cancelDestination: SetupCancelDestination = .library
        ) {
            self.draft = draft
            self.validation = validation
            self.mode = mode
            self.cancelDestination = cancelDestination
        }
    }

    enum State: Equatable {
        case loading
        case library
        case setup(ConnectionSetupState)
        case terminal(SavedWorkspace.ID)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var library: ConnectionLibrarySnapshot = .empty
    @Published private(set) var terminalSettings: TerminalSettings = .default
    @Published private(set) var activeSessions: [ActiveTerminalSession] = []
    @Published private(set) var isSetupActionInProgress = false
    @Published private(set) var tmuxSessionDiscoveryStates: [SavedServer.ID: TmuxSessionDiscoveryState] = [:]

    var setupSessionID: UUID? {
        currentSetupID
    }

    var activeTerminalScreenEntries: [ActiveTerminalScreenEntry] {
        activeSessions.map { session in
            let model = terminalScreenModel(for: session)
            let attachmentTarget = model.runtimeConnectionTarget
            return ActiveTerminalScreenEntry(
                session: session,
                model: model,
                attachmentTransferServiceFactory: { [dependencies, attachmentTarget] in
                    dependencies.makeAttachmentTransferService(for: attachmentTarget)
                }
            )
        }
    }

    private let dependencies: RemuxAppDependencies
    private let preparedTransportCoordinator: RemuxPreparedTransportCoordinator
    private let librarySSHPrewarmCoordinator: RemuxLibrarySSHPrewarmCoordinator
    private let terminalScreenModelFactory: TerminalScreenModelFactory
    private var terminalScreenModels: [TerminalRuntimeAttemptKey: TmuxScreenModel] = [:]
    private var currentAppLifecyclePhase: GhosttyAppLifecyclePhase?
    private var currentSetupID: UUID?
    private var activeSetupAction: SetupAction?
    private var editServerTrustSnapshot: EditServerTrustSnapshot?
    private var tmuxSessionRefreshes: [SavedServer.ID: TmuxSessionRefresh] = [:]

    init(
        dependencies: RemuxAppDependencies,
        terminalScreenModelFactory: TerminalScreenModelFactory? = nil
    ) {
        self.dependencies = dependencies
        self.preparedTransportCoordinator = RemuxPreparedTransportCoordinator { target in
            dependencies.makeTransport(for: target)
        }
        self.librarySSHPrewarmCoordinator = RemuxLibrarySSHPrewarmCoordinator(
            limit: Self.libraryPrewarmServerLimit,
            authResolver: { server, snapshot in
                try await SSHAuthResolver(
                    credentialStore: dependencies.credentialStore
                ).resolve(server: server, in: snapshot)
            },
            sshConnectionPrewarmer: { target in
                await dependencies.prewarmSSHConnection(for: target)
            }
        )
        self.terminalScreenModelFactory = terminalScreenModelFactory ?? Self.makeDefaultTerminalScreenModel
    }

    deinit {
        MainActor.assumeIsolated {
            for refresh in tmuxSessionRefreshes.values {
                refresh.task.cancel()
            }
            stopAllTerminalScreenModels()
        }
    }

    func load() async {
        guard activeSetupAction == nil else { return }
        let expectedSetupID = currentSetupID
        do {
#if DEBUG || REMUX_LIVE_UI_TESTING
            try await dependencies.seedDebugConnectionIfRequested()
#endif

            let terminalSettings = try await dependencies.settingsRepository.loadSettings()
            dependencies.applyHostKeyPolicy(allowInsecureRSA: terminalSettings.allowInsecureRSAHostKeys)
            let library = try await dependencies.profileRepository.loadSnapshot()
            guard activeSetupAction == nil, currentSetupID == expectedSetupID else { return }
            self.terminalSettings = terminalSettings
            self.library = library
            finishSetupSession(expectedSetupID)
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
            scheduleLaunchTmuxSessionDiscovery()
        } catch {
            guard activeSetupAction == nil, currentSetupID == expectedSetupID else { return }
            finishSetupSession(expectedSetupID)
            transitionToFailed(error)
        }
    }

    func showLibrary() async {
        guard activeSetupAction == nil else { return }
        let expectedSetupID = currentSetupID
        do {
            let terminalSettings = try await dependencies.settingsRepository.loadSettings()
            dependencies.applyHostKeyPolicy(allowInsecureRSA: terminalSettings.allowInsecureRSAHostKeys)
            let library = try await dependencies.profileRepository.loadSnapshot()
            guard activeSetupAction == nil, currentSetupID == expectedSetupID else { return }
            self.terminalSettings = terminalSettings
            self.library = library
            finishSetupSession(expectedSetupID)
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            guard activeSetupAction == nil, currentSetupID == expectedSetupID else { return }
            finishSetupSession(expectedSetupID)
            transitionToFailed(error)
        }
    }

    func beginNewServer() {
        guard activeSetupAction == nil else { return }
        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        state = .setup(
            ConnectionSetupState(
                draft: TmuxConnectionDraft(),
                mode: .newServer
            )
        )
    }

    func beginNewWorkspace(
        for serverID: SavedServer.ID,
        cancelDestination: SetupCancelDestination = .library
    ) async {
        guard activeSetupAction == nil else { return }
        guard let server = library.server(id: serverID) else { return }

        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        let workspace = SavedWorkspace(
            serverID: serverID,
            sessionName: ""
        )
        state = .setup(
            ConnectionSetupState(
                draft: TmuxConnectionDraft(server: server, workspace: workspace),
                mode: .newWorkspace(serverID),
                cancelDestination: cancelDestination
            )
        )
    }

    func beginEditServer(serverID: SavedServer.ID) async {
        await beginEditServer(serverID: serverID, reconnectWorkspaceID: nil)
    }

    func beginServerRepair(for workspaceID: SavedWorkspace.ID) async {
        guard let workspace = library.workspace(id: workspaceID) else {
            return
        }

        await beginEditServer(serverID: workspace.serverID, reconnectWorkspaceID: workspaceID)
    }

    func beginCredentialRepair(for workspaceID: SavedWorkspace.ID) async {
        guard let workspace = library.workspace(id: workspaceID) else {
            return
        }

        await beginEditServer(serverID: workspace.serverID, reconnectWorkspaceID: workspaceID)
    }

    private func beginEditServer(
        serverID: SavedServer.ID,
        reconnectWorkspaceID: SavedWorkspace.ID?
    ) async {
        guard activeSetupAction == nil else { return }
        guard let server = library.server(id: serverID) else { return }
        let setupID = UUID()
        currentSetupID = setupID
        editServerTrustSnapshot = nil

        let identity: SSHIdentity
        let credential: SSHCredential
        do {
            (identity, credential) = try await loadDraftIdentityCredential(for: server)
        } catch {
            guard activeSetupAction == nil, currentSetupID == setupID else { return }
            finishSetupSession(setupID)
            transitionToFailed(error)
            return
        }
        guard activeSetupAction == nil, currentSetupID == setupID else { return }
        let workspace = reconnectWorkspaceID.flatMap { library.workspace(id: $0) }
            ?? library.workspaces(for: serverID).first
            ?? SavedWorkspace(serverID: serverID, sessionName: "")
        do {
            editServerTrustSnapshot = EditServerTrustSnapshot(
                setupID: setupID,
                serverID: serverID,
                identity: try dependencies.trustedHostStore.identity(for: serverID)
            )
        } catch {
            finishSetupSession(setupID)
            transitionToFailed(error)
            return
        }
        state = .setup(
            ConnectionSetupState(
                draft: TmuxConnectionDraft(
                    server: server,
                    workspace: workspace,
                    identity: identity,
                    credential: credential
                ),
                mode: .editServer(serverID, reconnectWorkspaceID: reconnectWorkspaceID)
            )
        )
    }

    func beginEditWorkspace(serverID: SavedServer.ID, workspaceID: SavedWorkspace.ID) async {
        guard activeSetupAction == nil else { return }
        guard
            let server = library.server(id: serverID),
            let workspace = library.workspace(id: workspaceID)
        else {
            return
        }

        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        state = .setup(
            ConnectionSetupState(
                draft: TmuxConnectionDraft(server: server, workspace: workspace),
                mode: .editWorkspace(serverID, workspaceID)
            )
        )
    }

    func updateDraft(_ mutation: (inout TmuxConnectionDraft) -> Void) {
        guard activeSetupAction == nil else { return }
        guard case .setup(var setup) = state else { return }
        mutation(&setup.draft)
        state = .setup(setup)
    }

    func publicKeyInstallTarget(
        for draft: TmuxConnectionDraft
    ) throws -> SSHPublicKeyInstallTarget {
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw SSHPublicKeyInstallDraftError.invalidHost
        }
        guard let port = Int(draft.port), (1...65_535).contains(port) else {
            throw SSHPublicKeyInstallDraftError.invalidPort
        }
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw SSHPublicKeyInstallDraftError.invalidUsername
        }
        guard let inspection = try? SSHPrivateKeyInspector.inspect(draft.privateKeyPEM) else {
            throw SSHPublicKeyInstallDraftError.invalidPrivateKey
        }
        let passphrase = draft.privateKeyPassphrase.isEmpty
            ? nil
            : draft.privateKeyPassphrase

        return SSHPublicKeyInstallTarget(
            serverID: draft.serverID,
            host: host,
            port: port,
            username: username,
            privateKey: SSHPrivateKeyCredential(
                privateKeyPEM: inspection.normalizedPEM,
                passphrase: passphrase
            ),
            publicKeyLine: inspection.publicKeyLine
        )
    }

    func preflightPublicKeyInstallation(
        _ draft: TmuxConnectionDraft,
        setupSessionID: UUID?
    ) async throws -> SSHPublicKeyPreflightOutcome {
        try requireSetupInstallerAccess(setupSessionID)
        return try await dependencies.publicKeyInstaller.preflight(
            publicKeyInstallTarget(for: draft)
        )
    }

    func appendPublicKey(
        _ draft: TmuxConnectionDraft,
        password: String,
        setupSessionID: UUID?
    ) async throws {
        try requireSetupInstallerAccess(setupSessionID)
        try await dependencies.publicKeyInstaller.append(
            publicKeyInstallTarget(for: draft),
            password: password
        )
    }

    func verifyPublicKeyInstallation(
        _ draft: TmuxConnectionDraft,
        setupSessionID: UUID?
    ) async throws {
        try requireSetupInstallerAccess(setupSessionID)
        try await dependencies.publicKeyInstaller.verify(
            publicKeyInstallTarget(for: draft)
        )
    }

    func trustSetupHostKey(
        _ challenge: SSHHostKeyTrustChallenge,
        setupSessionID: UUID?
    ) throws {
        try requireSetupInstallerAccess(setupSessionID)
        try dependencies.trustedHostStore.trustHostKey(challenge)
    }

    private func requireSetupInstallerAccess(_ setupSessionID: UUID?) throws {
        guard activeSetupAction == nil,
              let setupSessionID,
              currentSetupID == setupSessionID,
              case .setup = state else {
            throw CancellationError()
        }
    }

    func cancelSetup() async {
        guard case .setup(let setup) = state else { return }
        guard let action = beginSetupAction() else { return }
        defer { finishSetupAction(action) }

        switch setup.mode {
        case .newServer:
            do {
                try dependencies.trustedHostStore.deleteIdentity(for: setup.draft.serverID)
            } catch {
                NSLog(
                    "Remux provisional trusted-host cleanup failed for server %@: %@",
                    setup.draft.serverID.uuidString,
                    String(describing: error)
                )
            }
        case .editServer(let serverID, _):
            do {
                try restoreEditServerTrustSnapshot(
                    for: serverID,
                    setupID: action.setupID
                )
            } catch {
                finishSetupSession(action.setupID)
                transitionToFailed(error)
                return
            }
        default:
            break
        }
        discardEditServerTrustSnapshot(setupID: action.setupID)

        switch setup.cancelDestination {
        case .library:
            await showLibrary(after: action)

        case .terminal(let workspaceID):
            finishSetupSession(action.setupID)
            showActiveSession(workspaceID)
        }
    }

    func saveAndConnect() async {
        guard case .setup(let setup) = state else { return }
        guard let action = beginSetupAction() else { return }
        defer { finishSetupAction(action) }

        switch setup.mode {
        case .editServer(let serverID, let reconnectWorkspaceID):
            await saveServer(
                setup,
                serverID: serverID,
                reconnectWorkspaceID: reconnectWorkspaceID,
                action: action
            )

        case .editWorkspace(let serverID, let workspaceID):
            await saveWorkspace(setup, serverID: serverID, workspaceID: workspaceID)

        case .newServer:
            await saveProfileAndConnect(setup)

        case .newWorkspace(let serverID):
            await saveNewWorkspaceAndConnect(setup, serverID: serverID)
        }
    }

    private func saveProfileAndConnect(_ setup: ConnectionSetupState) async {
        switch TmuxConnectionDraftValidator.validate(
            setup.draft,
            existingServerID: setup.mode.existingServerID,
            existingWorkspaceID: setup.mode.existingWorkspaceID
        ) {
        case .invalid(let validation):
            state = .setup(setupWithValidation(validation, from: setup))

        case .valid(let submission):
            let identityCredential: SSHIdentityCredentialPair
            do {
                identityCredential = try makeIdentityCredentialPair(from: submission.server)
            } catch {
                state = .setup(
                    setupWithValidation(
                        privateKeyValidation(from: error),
                        from: setup
                    )
                )
                return
            }
            let identity = identityCredential.identity
            let server = submission.server.savedServer(identityID: identity.id)
            var savedCredential = false
            do {
                try await dependencies.credentialStore.saveCredential(
                    identityCredential.credential,
                    identityID: identity.id
                )
                savedCredential = true
                try await dependencies.profileRepository.saveIdentityProfile(
                    identity: identity,
                    server: server,
                    workspace: submission.workspace
                )
                library = try await dependencies.profileRepository.loadSnapshot()
                let sshAuth = try await resolveSSHAuth(for: server)
                activate(
                    server: server,
                    workspace: submission.workspace,
                    sshAuth: sshAuth
                )
            } catch {
                await cleanupCreatedCredential(identity, savedCredential: savedCredential)
                transitionToFailed(error)
            }
        }
    }

    private func saveServer(
        _ setup: ConnectionSetupState,
        serverID: SavedServer.ID,
        reconnectWorkspaceID: SavedWorkspace.ID?,
        action: SetupAction
    ) async {
        guard isCurrentSetupAction(action) else { return }
        switch TmuxConnectionDraftValidator.validateServer(
            setup.draft,
            existingServerID: serverID
        ) {
        case .invalid(let validation):
            state = .setup(setupWithValidation(validation, from: setup))

        case .valid(let submission):
            let updatedIdentityCredential: SSHIdentityCredentialPair
            let previousIdentity: SSHIdentity
            do {
                guard let existingServer = library.server(id: serverID) else {
                    throw ConnectionProfileRepositoryError.missingServer(serverID)
                }
                guard let identity = library.identity(id: existingServer.identityID) else {
                    throw SSHAuthResolverError.missingIdentity(existingServer.identityID)
                }
                previousIdentity = identity
                updatedIdentityCredential = try makeUpdatedIdentityCredentialPair(
                    from: submission,
                    existingIdentity: identity
                )
            } catch let error as SSHPrivateKeyInspectionError {
                state = .setup(
                    setupWithValidation(
                        privateKeyValidation(from: error),
                        from: setup
                    )
                )
                return
            } catch {
                failEditServerSave(error, serverID: serverID, action: action)
                return
            }

            do {
                guard library.server(id: serverID) != nil else {
                    throw ConnectionProfileRepositoryError.missingServer(serverID)
                }

                invalidateTmuxSessionRefresh(for: serverID)
                let server = submission.savedServer(identityID: updatedIdentityCredential.identity.id)
                cancelLibrarySSHPrewarm()
                let previousCredential = try await dependencies.credentialStore.loadCredential(
                    identityID: updatedIdentityCredential.identity.id
                )
                guard isCurrentSetupAction(action) else { return }
                try await dependencies.credentialStore.saveCredential(
                    updatedIdentityCredential.credential,
                    identityID: updatedIdentityCredential.identity.id
                )
                guard isCurrentSetupAction(action) else {
                    await restoreCredential(
                        previousCredential,
                        identityID: updatedIdentityCredential.identity.id
                    )
                    return
                }
                do {
                    try await dependencies.profileRepository.saveIdentity(
                        updatedIdentityCredential.identity
                    )
                    guard isCurrentSetupAction(action) else {
                        await restoreCredential(
                            previousCredential,
                            identityID: updatedIdentityCredential.identity.id
                        )
                        await restoreIdentity(previousIdentity)
                        return
                    }
                    try await dependencies.profileRepository.saveServer(server)
                    guard isCurrentSetupAction(action) else { return }
                    discardEditServerTrustSnapshot(setupID: action.setupID)
                } catch {
                    await restoreCredential(
                        previousCredential,
                        identityID: updatedIdentityCredential.identity.id
                    )
                    await restoreIdentity(previousIdentity)
                    throw error
                }
                let library = try await dependencies.profileRepository.loadSnapshot()
                guard isCurrentSetupAction(action) else { return }
                self.library = library
                let updatedSSHAuth = try await resolveSSHAuth(for: server)
                guard isCurrentSetupAction(action) else { return }
                closePreparedTransports(forServerID: server.id)
                dependencies.closeIdleSSHConnections(forServerID: server.id)
                RemuxActiveSessionCollection.refreshServer(
                    server,
                    sshAuth: updatedSSHAuth,
                    in: &activeSessions
                )
                refreshDisconnectedTerminalScreenModels(serverID: server.id)

                guard let reconnectWorkspaceID else {
                    finishSetupSession(action.setupID)
                    state = .library
                    return
                }

                guard var workspace = library.workspace(id: reconnectWorkspaceID) else {
                    finishSetupSession(action.setupID)
                    state = .library
                    return
                }

                workspace.lastOpenedAt = Date()
                try await dependencies.profileRepository.saveWorkspace(workspace)
                guard isCurrentSetupAction(action) else { return }
                let reloadedLibrary = try await dependencies.profileRepository.loadSnapshot()
                guard isCurrentSetupAction(action) else { return }
                self.library = reloadedLibrary
                finishSetupSession(action.setupID)
                activate(
                    server: server,
                    workspace: workspace,
                    sshAuth: updatedSSHAuth
                )
            } catch {
                failEditServerSave(error, serverID: serverID, action: action)
            }
        }
    }

    private func failEditServerSave(
        _ error: any Error,
        serverID: SavedServer.ID,
        action: SetupAction
    ) {
        guard isCurrentSetupAction(action) else { return }
        do {
            try restoreEditServerTrustSnapshot(
                for: serverID,
                setupID: action.setupID
            )
        } catch let restoreError {
            NSLog(
                "Remux trusted-host restore failed: %@",
                String(describing: restoreError)
            )
        }
        finishSetupSession(action.setupID)
        transitionToFailed(error)
    }

    private func restoreEditServerTrustSnapshot(
        for serverID: SavedServer.ID,
        setupID: UUID
    ) throws {
        guard let snapshot = editServerTrustSnapshot,
              snapshot.setupID == setupID,
              snapshot.serverID == serverID else {
            return
        }
        try dependencies.trustedHostStore.restoreIdentity(
            snapshot.identity,
            for: serverID
        )
        editServerTrustSnapshot = nil
    }

    private func discardEditServerTrustSnapshot(setupID: UUID) {
        guard editServerTrustSnapshot?.setupID == setupID else { return }
        editServerTrustSnapshot = nil
    }

    private func beginSetupAction() -> SetupAction? {
        guard activeSetupAction == nil, let currentSetupID else { return nil }
        let action = SetupAction(id: UUID(), setupID: currentSetupID)
        activeSetupAction = action
        isSetupActionInProgress = true
        return action
    }

    private func finishSetupAction(_ action: SetupAction) {
        guard activeSetupAction == action else { return }
        activeSetupAction = nil
        isSetupActionInProgress = false
        guard currentSetupID == action.setupID else { return }
        guard case .setup = state else {
            finishSetupSession(action.setupID)
            return
        }
    }

    private func isCurrentSetupAction(_ action: SetupAction) -> Bool {
        activeSetupAction == action && currentSetupID == action.setupID
    }

    private func finishSetupSession(_ setupID: UUID?) {
        guard currentSetupID == setupID else { return }
        currentSetupID = nil
        if editServerTrustSnapshot?.setupID == setupID {
            editServerTrustSnapshot = nil
        }
    }

    private func showLibrary(after action: SetupAction) async {
        do {
            let terminalSettings = try await dependencies.settingsRepository.loadSettings()
            guard isCurrentSetupAction(action) else { return }
            let library = try await dependencies.profileRepository.loadSnapshot()
            guard isCurrentSetupAction(action) else { return }
            self.terminalSettings = terminalSettings
            self.library = library
            finishSetupSession(action.setupID)
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            guard isCurrentSetupAction(action) else { return }
            finishSetupSession(action.setupID)
            transitionToFailed(error)
        }
    }

    private func saveNewWorkspaceAndConnect(
        _ setup: ConnectionSetupState,
        serverID: SavedServer.ID
    ) async {
        switch TmuxConnectionDraftValidator.validateWorkspace(
            setup.draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) {
        case .invalid(let validation):
            state = .setup(setupWithValidation(validation, from: setup))

        case .valid(let submission):
            do {
                guard let server = library.server(id: serverID) else {
                    state = .library
                    return
                }

                cancelLibrarySSHPrewarm()
                try await dependencies.profileRepository.saveWorkspace(submission.workspace)
                library = try await dependencies.profileRepository.loadSnapshot()

                let sshAuth = try await resolveSSHAuth(for: server)

                activate(
                    server: server,
                    workspace: submission.workspace,
                    sshAuth: sshAuth
                )
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func saveWorkspace(
        _ setup: ConnectionSetupState,
        serverID: SavedServer.ID,
        workspaceID: SavedWorkspace.ID
    ) async {
        switch TmuxConnectionDraftValidator.validateWorkspace(
            setup.draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        ) {
        case .invalid(let validation):
            state = .setup(setupWithValidation(validation, from: setup))

        case .valid(let submission):
            do {
                cancelLibrarySSHPrewarm()
                var workspace = submission.workspace
                if let existing = library.workspace(id: workspaceID) {
                    workspace.lastOpenedAt = existing.lastOpenedAt
                }

                try await dependencies.profileRepository.saveWorkspace(workspace)
                library = try await dependencies.profileRepository.loadSnapshot()
                closePreparedTransport(for: workspace.id)
                RemuxActiveSessionCollection.refreshWorkspace(
                    workspace,
                    in: &activeSessions
                )
                state = .library
                scheduleLibrarySSHPrewarm(snapshot: library)
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func setupWithValidation(
        _ validation: TmuxConnectionDraftValidation,
        from setup: ConnectionSetupState
    ) -> ConnectionSetupState {
        var updated = setup
        updated.validation = validation
        return updated
    }

    func connect(to workspaceID: SavedWorkspace.ID) async {
        guard
            let workspace = library.workspace(id: workspaceID),
            let server = library.server(id: workspace.serverID)
        else {
            GhosttyRuntimeTrace.flowEnd(
                sessionOpenFlowID(workspaceID),
                event: "model.connect.missingProfile",
                fields: ["workspaceID": workspaceID.uuidString]
            )
            return
        }

        await connect(server: server, workspace: workspace)
    }

    func connectToDiscoveredSession(
        named sessionName: String,
        on serverID: SavedServer.ID
    ) async {
        guard !sessionName.isEmpty,
              let server = library.server(id: serverID) else {
            return
        }
        let workspace = library.workspaces(for: serverID).first {
            $0.sessionName == sessionName
        } ?? SavedWorkspace(serverID: serverID, sessionName: sessionName)
        await connect(server: server, workspace: workspace)
    }

    private func connect(
        server: SavedServer,
        workspace: SavedWorkspace
    ) async {
        let workspaceID = workspace.id
        let flow = sessionOpenFlowID(workspaceID)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.connect.begin",
            fields: ["workspaceID": workspaceID.uuidString]
        )
        cancelTmuxSessionRefreshForInteractiveConnection(serverID: server.id)

        let sshAuth: ResolvedSSHAuth
        do {
            sshAuth = try await resolveSSHAuth(for: server)
        } catch {
            GhosttyRuntimeTrace.flowEnd(
                flow,
                event: "model.connect.authResolutionFailed",
                fields: [
                    "workspaceID": workspaceID.uuidString,
                    "server": server.displayName,
                    "error": String(describing: error),
                ]
            )
            transitionToFailed(error)
            return
        }

        var openedWorkspace = workspace
        openedWorkspace.lastOpenedAt = Date()

        // Activate before the bookkeeping: persisting lastOpenedAt and
        // refreshing the library ordering measured 16-23ms of disk work
        // on the open critical path. Activating first lets the screen
        // build while the save runs; the awaits stay sequential in this
        // call so later mutations (delete, edit) cannot interleave with
        // a dangling save and resurrect a removed profile.
        activate(server: server, workspace: openedWorkspace, sshAuth: sshAuth)

        do {
            try await dependencies.profileRepository.saveProfile(server: server, workspace: openedWorkspace)
            GhosttyRuntimeTrace.flowEvent(
                flow,
                event: "model.connect.profileSaved",
                fields: [
                    "server": server.displayName,
                    "session": openedWorkspace.sessionName,
                ]
            )
            library = try await dependencies.profileRepository.loadSnapshot()
            GhosttyRuntimeTrace.flowEvent(flow, event: "model.connect.libraryReloaded")
        } catch {
            // The session is already active; failing to persist
            // bookkeeping must not tear it down.
            GhosttyRuntimeTrace.flowEvent(
                flow,
                event: "model.connect.profileSaveFailed",
                fields: ["error": String(describing: error)]
            )
        }
    }

    func tmuxSessionDiscoveryState(
        for serverID: SavedServer.ID?
    ) -> TmuxSessionDiscoveryState {
        guard let serverID else { return .idle }
        return tmuxSessionDiscoveryStates[serverID] ?? .idle
    }

    func refreshTmuxSessions() {
        for server in library.servers {
            refreshTmuxSessions(for: server.id)
        }
    }

    /// Coalesces launch and explicit refresh requests for one server. A
    /// completed result must still match the server profile it started with;
    /// editing or deleting that server makes the result stale.
    func refreshTmuxSessions(for serverID: SavedServer.ID) {
        guard tmuxSessionRefreshes[serverID] == nil,
              let server = library.server(id: serverID) else {
            return
        }

        let refreshID = UUID()
        tmuxSessionDiscoveryStates[serverID] = tmuxSessionDiscoveryState(for: serverID)
            .startingRefresh()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performTmuxSessionRefresh(
                for: server,
                refreshID: refreshID
            )
        }
        tmuxSessionRefreshes[serverID] = TmuxSessionRefresh(id: refreshID, task: task)
    }

    func showActiveSession(_ id: SavedWorkspace.ID) {
        GhosttyRuntimeTrace.flowEvent(
            sessionShowFlowID(id),
            event: "model.showActiveSession.begin",
            fields: ["workspaceID": id.uuidString]
        )
        guard RemuxActiveSessionCollection.containsWorkspace(id, in: activeSessions) else {
            GhosttyRuntimeTrace.flowEnd(
                sessionShowFlowID(id),
                event: "model.showActiveSession.missing",
                fields: ["workspaceID": id.uuidString]
            )
            state = .library
            return
        }

        if RemuxActiveSessionCollection.session(id, in: activeSessions)?.runtimeState.disconnectedReason != nil {
            reconnectActiveSession(id, source: .activeSessionTap)
            GhosttyRuntimeTrace.flowEnd(
                sessionShowFlowID(id),
                event: "model.showActiveSession.reconnect",
                fields: ["workspaceID": id.uuidString]
            )
            return
        }

        state = .terminal(id)
        GhosttyRuntimeTrace.flowEnd(
            sessionShowFlowID(id),
            event: "model.showActiveSession.end",
            fields: ["workspaceID": id.uuidString]
        )
    }

    func reconnectActiveSession(
        _ id: SavedWorkspace.ID,
        source: TerminalReconnectSource
    ) {
        guard let currentSession = RemuxActiveSessionCollection.session(id, in: activeSessions) else {
            state = .library
            return
        }

        GhosttyRuntimeTrace.flowBegin(
            sessionReconnectFlowID(id),
            event: "model.reconnect.begin",
            fields: [
                "source": source.traceLabel,
                "workspaceID": id.uuidString,
            ]
        )
        cancelLibrarySSHPrewarm()
        closePreparedTransport(for: id)
        closePreparedTransports(
            forServerID: currentSession.target.server.id,
            excludingWorkspaceID: id
        )
        guard let session = RemuxActiveSessionCollection.runtimeReplacementSession(
            workspaceID: id,
            source: source,
            in: activeSessions
        ) else {
            state = .library
            return
        }
        prepareTransport(for: session.target, reason: .reconnect)
        replaceTerminalScreenModel(for: session)
        RemuxActiveSessionCollection.replaceRuntime(with: session, in: &activeSessions)
        state = .terminal(id)
        applyCurrentAppLifecyclePhase(to: session)
        GhosttyRuntimeTrace.flowEvent(
            sessionReconnectFlowID(id),
            event: "model.reconnect.recreated",
            fields: [
                "instanceID": session.instanceID.uuidString,
                "source": source.traceLabel,
                "workspaceID": id.uuidString,
            ]
        )
    }

    func trustHostKeyAndReconnect(_ id: SavedWorkspace.ID) {
        guard let session = RemuxActiveSessionCollection.session(id, in: activeSessions),
              let challenge = session.runtimeState.disconnectedReason?.hostKeyChallenge else {
            return
        }

        do {
            try dependencies.trustedHostStore.trustHostKey(challenge)
            reconnectActiveSession(id, source: .manualButton)
        } catch {
            transitionToFailed(error)
        }
    }

    @discardableResult
    func handleTerminalRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate
    ) -> ActiveSessionRuntimeTransitionOutcome {
        let outcome = RemuxActiveSessionCollection.applyRuntimeStateUpdate(
            update,
            to: &activeSessions,
            requestedReconnectSource: automaticReconnectSource(for: update)
        )
        traceTerminalRuntimeStateUpdate(update, outcome: outcome)
        switch outcome {
        case .applied(.connected),
             .automaticReconnectStarted(_, .connected),
             .automaticReconnectSkipped(_, .connected):
            if let session = RemuxActiveSessionCollection.session(
                update.workspaceID,
                in: activeSessions
            ) {
                let serverID = session.target.server.id
                let discoveryState = tmuxSessionDiscoveryState(for: serverID)
                tmuxSessionDiscoveryStates[serverID] = discoveryState
                    .confirmingExistingSession(named: session.target.workspace.sessionName)
                if discoveryState.phase == .idle || discoveryState.phase == .failed {
                    refreshTmuxSessions(for: serverID)
                }
            }
        case .missingSession, .staleInstance, .applied,
             .automaticReconnectStarted, .automaticReconnectSkipped:
            break
        }
        if case .automaticReconnectStarted(let source, _) = outcome {
            reconnectActiveSession(update.workspaceID, source: source)
        }
        return outcome
    }

    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        currentAppLifecyclePhase = phase
        if phase == .background {
            cancelAllTmuxSessionRefreshes()
        }
        let models = Array(terminalScreenModels.values)
        for model in models {
            model.handleAppLifecyclePhase(phase)
        }

        guard phase == .active,
              case .terminal(let selectedID) = state,
              let session = RemuxActiveSessionCollection.session(
                  selectedID,
                  in: activeSessions
              )
        else { return }
        terminalScreenModels[TerminalRuntimeAttemptKey(session: session)]?
            .terminalScreenAdapter
            .reclaimActiveTmuxViewport()
    }

    func disconnectActiveSession(_ id: SavedWorkspace.ID) {
        // Fallback selection follows the order users see in the switcher
        // and library, not internal activation order.
        let displayedIndex = RemuxActiveSessionCollection.sortedForDisplay(activeSessions)
            .firstIndex { $0.id == id }
        closePreparedTransport(for: id)
        stopTerminalScreenModels(workspaceID: id)
        RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)

        guard case .terminal(let selectedID) = state, selectedID == id else {
            return
        }

        let remaining = RemuxActiveSessionCollection.sortedForDisplay(activeSessions)
        if let displayedIndex, !remaining.isEmpty {
            state = .terminal(remaining[min(displayedIndex, remaining.count - 1)].id)
            return
        }

        state = .library
        scheduleLibrarySSHPrewarm(snapshot: library)
    }

    func deleteServer(_ id: SavedServer.ID) async {
        do {
            let deletedServer = library.server(id: id)
            invalidateTmuxSessionRefresh(for: id)
            try await dependencies.profileRepository.deleteServer(id: id)
            try dependencies.trustedHostStore.deleteIdentity(for: id)
            var snapshot = try await dependencies.profileRepository.loadSnapshot()
            if let identityID = deletedServer?.identityID,
               !snapshot.servers.contains(where: { $0.identityID == identityID }) {
                if let identity = library.identity(id: identityID) ?? snapshot.identity(id: identityID) {
                    try await dependencies.credentialStore.deleteCredential(
                        identityID: identity.id
                    )
                }
                try await dependencies.profileRepository.deleteIdentity(id: identityID)
                snapshot = try await dependencies.profileRepository.loadSnapshot()
            }
            closePreparedTransports(forServerID: id)
            dependencies.closeIdleSSHConnections(forServerID: id)
            stopTerminalScreenModels(serverID: id)
            RemuxActiveSessionCollection.removeServer(id, from: &activeSessions)
            library = snapshot
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func deleteWorkspace(_ id: SavedWorkspace.ID) async {
        do {
            try await dependencies.profileRepository.deleteWorkspace(id: id)
            closePreparedTransport(for: id)
            stopTerminalScreenModels(workspaceID: id)
            RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)
            library = try await dependencies.profileRepository.loadSnapshot()
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func updateTerminalSettings(_ mutation: (inout TerminalSettings) -> Void) async {
        do {
            var updated = terminalSettings
            mutation(&updated)
            try await dependencies.settingsRepository.saveSettings(updated)
            terminalSettings = updated
            dependencies.applyHostKeyPolicy(allowInsecureRSA: updated.allowInsecureRSAHostKeys)
            try applyTerminalSettingsToActiveSessions(updated)
        } catch {
            transitionToFailed(error)
        }
    }

    func makeTransport(for target: TmuxConnectionTarget) -> any TmuxControlTransport {
        preparedTransportCoordinator.claimOrCreateTransport(for: target)
    }

    private func applyTerminalSettingsToActiveSessions(_ settings: TerminalSettings) throws {
        RemuxActiveSessionCollection.refreshTerminalSettings(
            settings,
            in: &activeSessions
        )

        for session in activeSessions {
            let key = TerminalRuntimeAttemptKey(session: session)
            guard let model = terminalScreenModels[key] else { continue }
            try model.applyTerminalSettings(settings)
        }
    }

    private func refreshDisconnectedTerminalScreenModels(serverID: SavedServer.ID) {
        for session in activeSessions where session.target.server.id == serverID {
            let key = TerminalRuntimeAttemptKey(session: session)
            guard terminalScreenModels[key]?.isDisconnected == true else { continue }
            replaceTerminalScreenModel(for: session)
            applyCurrentAppLifecyclePhase(to: session)
        }
    }

    func terminalScreenModel(for session: ActiveTerminalSession) -> TmuxScreenModel {
        let key = TerminalRuntimeAttemptKey(session: session)
        guard let model = terminalScreenModels[key] else {
            preconditionFailure("Missing terminal screen model for active runtime attempt")
        }
        return model
    }

    func hasTerminalScreenModel(for session: ActiveTerminalSession) -> Bool {
        terminalScreenModels[TerminalRuntimeAttemptKey(session: session)] != nil
    }

    private func closePreparedTransport(for workspaceID: SavedWorkspace.ID) {
        preparedTransportCoordinator.remove(workspaceID: workspaceID)
    }

    private func closePreparedTransports(forServerID serverID: SavedServer.ID) {
        closePreparedTransports(forServerID: serverID, excludingWorkspaceID: nil)
    }

    private func closePreparedTransports(
        forServerID serverID: SavedServer.ID,
        excludingWorkspaceID: SavedWorkspace.ID?
    ) {
        preparedTransportCoordinator.remove(
            serverID: serverID,
            excludingWorkspaceID: excludingWorkspaceID
        )
    }

    private func activate(
        server: SavedServer,
        workspace: SavedWorkspace,
        sshAuth: ResolvedSSHAuth
    ) {
        let flow = sessionOpenFlowID(workspace.id)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.activate.begin",
            fields: [
                "server": server.displayName,
                "session": workspace.sessionName,
                "workspaceID": workspace.id.uuidString,
            ]
        )
        cancelLibrarySSHPrewarm()
        closePreparedTransports(forServerID: server.id, excludingWorkspaceID: workspace.id)
        let target = target(server: server, workspace: workspace, sshAuth: sshAuth)
        let activeSession = ActiveTerminalSession(target: target)
        prepareTransport(for: target, reason: .activation)
        replaceTerminalScreenModel(for: activeSession)
        RemuxActiveSessionCollection.upsertActivatedSession(
            activeSession,
            in: &activeSessions
        )

        state = .terminal(workspace.id)
        applyCurrentAppLifecyclePhase(to: activeSession)
        GhosttyRuntimeTrace.flowEvent(
            flow,
            event: "model.activate.end",
            fields: [
                "activeSessions": "\(activeSessions.count)",
                "workspaceID": workspace.id.uuidString,
            ]
        )
    }

    private func resolveSSHAuth(for server: SavedServer) async throws -> ResolvedSSHAuth {
        try await SSHAuthResolver(
            credentialStore: dependencies.credentialStore
        ).resolve(server: server, in: library)
    }

    private struct SSHIdentityCredentialPair {
        let identity: SSHIdentity
        let credential: SSHCredential
    }

    private func makeIdentityCredentialPair(
        from draft: ValidatedTmuxServerDraft
    ) throws -> SSHIdentityCredentialPair {
        switch draft.credential {
        case .password(let password):
            let identity = SSHIdentity(
                name: draft.displayName,
                authenticationKind: .password
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: .password(password)
            )

        case .privateKey(let credential):
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let identity = SSHIdentity(
                name: draft.displayName,
                authenticationKind: .privateKey,
                publicFingerprint: inspection.publicFingerprint
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: .privateKey(credential)
            )
        }
    }

    private func makeUpdatedIdentityCredentialPair(
        from draft: ValidatedTmuxServerDraft,
        existingIdentity: SSHIdentity
    ) throws -> SSHIdentityCredentialPair {
        switch draft.credential {
        case .password(let password):
            let identity = SSHIdentity(
                id: existingIdentity.id,
                name: draft.displayName,
                authenticationKind: .password
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: .password(password)
            )

        case .privateKey(let credential):
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let identity = SSHIdentity(
                id: existingIdentity.id,
                name: draft.displayName,
                authenticationKind: .privateKey,
                publicFingerprint: inspection.publicFingerprint
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: .privateKey(credential)
            )
        }
    }

    private func privateKeyValidation(from error: Error) -> TmuxConnectionDraftValidation {
        var validation = TmuxConnectionDraftValidation.empty
        if let error = error as? SSHPrivateKeyInspectionError {
            validation.privateKey = error.localizedDescription
        } else {
            validation.privateKey = "Private key could not be read."
        }
        return validation
    }

    private func loadDraftIdentityCredential(
        for server: SavedServer
    ) async throws -> (SSHIdentity, SSHCredential) {
        guard let identity = library.identity(id: server.identityID) else {
            throw SSHAuthResolverError.missingIdentity(server.identityID)
        }
        guard let credential = try await dependencies.credentialStore.loadCredential(
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
        return (identity, credential)
    }

    private func cleanupCreatedCredential(
        _ identity: SSHIdentity,
        savedCredential: Bool
    ) async {
        if savedCredential {
            do {
                try await dependencies.credentialStore.deleteCredential(identityID: identity.id)
            } catch {
                NSLog(
                    "Remux SSH credential cleanup failed: %@",
                    String(describing: error)
                )
            }
        }
    }

    private func restoreCredential(
        _ credential: SSHCredential?,
        identityID: SSHIdentity.ID
    ) async {
        do {
            if let credential {
                try await dependencies.credentialStore.saveCredential(
                    credential,
                    identityID: identityID
                )
            } else {
                try await dependencies.credentialStore.deleteCredential(identityID: identityID)
            }
        } catch {
            NSLog(
                "Remux SSH credential restore failed: %@",
                String(describing: error)
            )
        }
    }

    private func restoreIdentity(_ identity: SSHIdentity) async {
        do {
            try await dependencies.profileRepository.saveIdentity(identity)
        } catch {
            NSLog(
                "Remux SSH identity restore failed: %@",
                String(describing: error)
            )
        }
    }

    private func target(
        server: SavedServer,
        workspace: SavedWorkspace,
        sshAuth: ResolvedSSHAuth
    ) -> TmuxConnectionTarget {
        TmuxConnectionTarget(
            server: server,
            workspace: workspace,
            sshAuth: sshAuth,
            terminalSettings: terminalSettings
        )
    }

    private func performTmuxSessionRefresh(
        for server: SavedServer,
        refreshID: UUID
    ) async {
        defer { finishTmuxSessionRefresh(for: server.id, refreshID: refreshID) }

        do {
            let sshAuth = try await resolveSSHAuth(for: server)
            guard isCurrentTmuxSessionRefresh(server, refreshID: refreshID) else { return }
            let discoveryTarget = target(
                server: server,
                workspace: SavedWorkspace(serverID: server.id, sessionName: ""),
                sshAuth: sshAuth
            )
            let names = try await dependencies.discoverTmuxSessions(for: discoveryTarget)
            guard isCurrentTmuxSessionRefresh(server, refreshID: refreshID) else { return }
            tmuxSessionDiscoveryStates[server.id] = tmuxSessionDiscoveryState(for: server.id)
                .finishingRefresh(with: Self.normalizedTmuxSessionNames(names))
        } catch is CancellationError {
            guard isCurrentTmuxSessionRefresh(server, refreshID: refreshID) else { return }
            tmuxSessionDiscoveryStates[server.id] = tmuxSessionDiscoveryState(for: server.id)
                .cancellingRefresh()
            return
        } catch {
            guard isCurrentTmuxSessionRefresh(server, refreshID: refreshID) else { return }
            // Discovery is auxiliary to an already-running terminal. Keep its
            // failure inside the sheet rather than replacing the app route.
            tmuxSessionDiscoveryStates[server.id] = tmuxSessionDiscoveryState(for: server.id)
                .failingRefresh()
        }
    }

    private func scheduleLaunchTmuxSessionDiscovery() {
        Task(priority: .utility) { @MainActor [weak self] in
            await Task.yield()
            self?.refreshTmuxSessions()
        }
    }

    private static func normalizedTmuxSessionNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func isCurrentTmuxSessionRefresh(
        _ server: SavedServer,
        refreshID: UUID
    ) -> Bool {
        tmuxSessionRefreshes[server.id]?.id == refreshID
            && library.server(id: server.id) == server
    }

    private func finishTmuxSessionRefresh(
        for serverID: SavedServer.ID,
        refreshID: UUID
    ) {
        guard tmuxSessionRefreshes[serverID]?.id == refreshID else { return }
        tmuxSessionRefreshes.removeValue(forKey: serverID)
    }

    private func invalidateTmuxSessionRefresh(for serverID: SavedServer.ID) {
        tmuxSessionRefreshes.removeValue(forKey: serverID)?.task.cancel()
        tmuxSessionDiscoveryStates.removeValue(forKey: serverID)
    }

    private func cancelTmuxSessionRefreshForInteractiveConnection(
        serverID: SavedServer.ID
    ) {
        guard let refresh = tmuxSessionRefreshes.removeValue(forKey: serverID) else { return }
        refresh.task.cancel()
        tmuxSessionDiscoveryStates[serverID] = tmuxSessionDiscoveryState(for: serverID)
            .cancellingRefresh()
    }

    private func cancelAllTmuxSessionRefreshes() {
        let refreshes = tmuxSessionRefreshes
        tmuxSessionRefreshes.removeAll()
        for (serverID, refresh) in refreshes {
            refresh.task.cancel()
            tmuxSessionDiscoveryStates[serverID] = tmuxSessionDiscoveryState(for: serverID)
                .cancellingRefresh()
        }
    }

    private static func makeDefaultTerminalScreenModel(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TmuxScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        initialClientSize: TmuxSessionController.ClientSize?
    ) -> TmuxScreenModel {
        TmuxScreenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: onRuntimeStateChange,
            initialClientSize: initialClientSize
        )
    }

    private func replaceTerminalScreenModel(for session: ActiveTerminalSession) {
        // Carry the previous attempt's viewport into the replacement so
        // it attaches already sized (captures land at this width).
        let carriedClientSize = terminalScreenModels.first(where: {
            $0.key.workspaceID == session.id
        })?.value.carriedClientSize
        stopTerminalScreenModels(workspaceID: session.id)
        let key = TerminalRuntimeAttemptKey(session: session)
        let transportFactory: TmuxScreenModel.TransportFactory = { [preparedTransportCoordinator] target in
            preparedTransportCoordinator.claimOrCreateTransport(for: target)
        }
        let model = terminalScreenModelFactory(
            session.target,
            session.instanceID,
            transportFactory,
            { [weak self] update in
                guard let self else { return }
                _ = self.handleTerminalRuntimeStateUpdate(update)
            },
            carriedClientSize
        )
        terminalScreenModels[key] = model
    }

    private func applyCurrentAppLifecyclePhase(to session: ActiveTerminalSession) {
        if let currentAppLifecyclePhase {
            terminalScreenModels[TerminalRuntimeAttemptKey(session: session)]?
                .handleAppLifecyclePhase(currentAppLifecyclePhase)
        }
    }

    private func stopTerminalScreenModels(workspaceID: SavedWorkspace.ID) {
        stopTerminalScreenModels { key, _ in
            key.workspaceID == workspaceID
        }
    }

    private func stopTerminalScreenModels(serverID: SavedServer.ID) {
        stopTerminalScreenModels { key, _ in
            return activeSessions.contains {
                $0.id == key.workspaceID && $0.target.server.id == serverID
            }
        }
    }

    private func stopAllTerminalScreenModels() {
        stopTerminalScreenModels { _, _ in true }
    }

    private func stopTerminalScreenModels(
        where shouldStop: (TerminalRuntimeAttemptKey, TmuxScreenModel) -> Bool
    ) {
        let removed = terminalScreenModels.filter(shouldStop)
        for key in removed.keys {
            terminalScreenModels[key] = nil
        }
        for model in removed.values {
            // Teardown ordering (surface unregister/free before terminal
            // release, link before controller) is owned by the model; the
            // task retains it until shutdown completes.
            Task { await model.stop() }
        }
    }

    private func transitionToFailed(_ error: any Error) {
        stopAllTerminalScreenModels()
        activeSessions.removeAll()
        state = .failed(String(describing: error))
    }

    private func automaticReconnectSource(
        for update: TerminalRuntimeStateUpdate
    ) -> TerminalReconnectSource? {
        guard case .terminal(let selectedID) = state, selectedID == update.workspaceID else {
            return nil
        }
        guard let reason = update.state.disconnectedReason,
              reason.allowsAutomaticReconnect else {
            return nil
        }

        switch update.source {
        case .foreground:
            return .foreground
        case .runtime:
            return .transportLoss
        case .readiness:
            return nil
        }
    }

    private func traceTerminalRuntimeStateUpdate(
        _ update: TerminalRuntimeStateUpdate,
        outcome: ActiveSessionRuntimeTransitionOutcome
    ) {
        switch outcome {
        case .missingSession:
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.missingSession",
                fields: ["instanceID": update.instanceID.uuidString]
            )
        case .staleInstance(let currentInstanceID, let staleInstanceID):
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.stale",
                fields: [
                    "currentInstanceID": currentInstanceID.uuidString,
                    "staleInstanceID": staleInstanceID.uuidString,
                ]
            )
        case .applied(let state),
             .automaticReconnectStarted(_, let state),
             .automaticReconnectSkipped(_, let state):
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.applied",
                fields: [
                    "instanceID": update.instanceID.uuidString,
                    "source": update.source.traceLabel,
                    "state": state.traceLabel,
                    "workspaceID": update.workspaceID.uuidString,
                ]
            )
        }

        if case .automaticReconnectSkipped(let source, _) = outcome {
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionReconnectFlowID(update.workspaceID),
                event: "model.reconnect.autoSkipped",
                fields: [
                    "reason": "already_attempted",
                    "source": source.traceLabel,
                    "workspaceID": update.workspaceID.uuidString,
                ]
            )
        }
    }

    private func prepareTransport(
        for target: TmuxConnectionTarget,
        reason: RemuxPreparedTransportPrepareReason
    ) {
        preparedTransportCoordinator.prepareTransport(for: target, reason: reason)
    }

    private func scheduleLibrarySSHPrewarm(snapshot: ConnectionLibrarySnapshot) {
        let activeServerIDs = RemuxActiveSessionCollection.activeServerIDs(
            in: activeSessions
        )
        librarySSHPrewarmCoordinator.schedule(
            snapshot: snapshot,
            activeServerIDs: activeServerIDs,
            terminalSettings: terminalSettings,
            currentContext: { [weak self] in
                guard let self else { return nil }
                return RemuxLibrarySSHPrewarmCurrentContext(
                    snapshot: library,
                    isLibraryVisible: state == .library,
                    activeServerIDs: RemuxActiveSessionCollection.activeServerIDs(
                        in: activeSessions
                    ),
                    terminalSettings: terminalSettings
                )
            },
            onEligibleTarget: { [weak self] target in
                self?.prepareTransport(for: target, reason: .library)
            }
        )
    }

    private func cancelLibrarySSHPrewarm() {
        librarySSHPrewarmCoordinator.cancel()
    }

    private func sessionOpenFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.open.\(workspaceID.uuidString)"
    }

    private func sessionShowFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.show.\(workspaceID.uuidString)"
    }

    private func sessionReconnectFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.reconnect.\(workspaceID.uuidString)"
    }
}
