import Foundation
import SwiftUI

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
    var target: SessionTarget
    var instanceID: UUID
    var runtimeState: TerminalRuntimeState
    var automaticReconnectAttemptedSources: Set<TerminalReconnectSource>

    init(
        target: SessionTarget,
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
        target.opening = source == .restart ? .create : .attach
        reconnectRuntime(source: source)
    }

    /// A reconnect that keeps the runtime, which opens a new connection itself.
    mutating func reconnectRuntime(source: TerminalReconnectSource) {
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

/// Why a runtime attempt stops. Ending the session undoes what Remux left on
/// the server (its zooms); a replacement leaves it for the new attempt, which
/// adopts it: from tmux's marks on the server, or from the phone's record of
/// Herdr's.
enum TerminalRuntimeStopReason: Equatable, Sendable {
    case sessionEnded
    case replacedByNewAttempt
}

/// The screen model behind one active session, by the session's backend. The root speaks to both
/// through these operations; the view builds the shared screen over the model's adapter.
@MainActor
enum TerminalRuntime {
    case tmux(TmuxScreenModel)
    case herdr(HerdrScreenModel)

    var target: SessionTarget {
        switch self {
        case .tmux(let model): model.target
        case .herdr(let model): model.target
        }
    }

    /// True when no connection is open or opening, so the root may replace the model.
    var isDisconnected: Bool {
        switch self {
        case .tmux(let model): model.isDisconnected
        case .herdr(let model): model.isDisconnected
        }
    }

    /// Previews read files and forward ports through the tmux transport's SSH connection.
    var terminalPreviewClient: TerminalPreviewClient? {
        switch self {
        case .tmux(let model): model.terminalPreviewClient
        case .herdr: nil
        }
    }

    func handleAppLifecyclePhase(_ phase: GhosttyAppLifecyclePhase) {
        switch self {
        case .tmux(let model): model.handleAppLifecyclePhase(phase)
        case .herdr(let model): model.handleAppLifecyclePhase(phase)
        }
    }

    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        switch self {
        case .tmux(let model): try model.applyTerminalSettings(settings)
        case .herdr(let model): try model.applyTerminalSettings(settings)
        }
    }

    /// Whether the root shows this session; only a shown session draws. A Herdr session is also shown
    /// and hidden on the server; a tmux session stays attached either way, and its screen claims the
    /// viewport once selected.
    func setSelected(_ selected: Bool) {
        switch self {
        case .tmux(let model): model.setSelected(selected)
        case .herdr(let model): model.setSelected(selected)
        }
    }

    func stop(_ reason: TerminalRuntimeStopReason) async {
        switch self {
        case .tmux(let model): await model.stop(reason)
        case .herdr(let model): await model.stop(reason)
        }
    }
}

struct ActiveTerminalScreenEntry: Identifiable {
    let id: SavedWorkspace.ID
    let instanceID: UUID
    let runtimeAttemptKey: TerminalRuntimeAttemptKey
    let presentation: GhosttySurfaceScreenPresentation
    let runtime: TerminalRuntime
    let attachmentTransferServiceFactory: @Sendable () -> any GhosttyAttachmentTransferService

    init(
        session: ActiveTerminalSession,
        runtime: TerminalRuntime,
        attachmentTransferServiceFactory: @escaping @Sendable () -> any GhosttyAttachmentTransferService
    ) {
        self.id = session.id
        self.instanceID = session.instanceID
        self.runtimeAttemptKey = TerminalRuntimeAttemptKey(session: session)
        self.presentation = GhosttySurfaceScreenPresentation(
            workspaceID: session.target.workspace.id,
            sessionName: session.target.workspace.sessionName,
            serverName: session.target.server.displayName,
            terminalTheme: session.target.terminalSettings.theme,
            toolbarKeys: session.target.terminalSettings.toolbarKeys,
            loadingTitle: TerminalRuntimeStatusPresentation.projection(
                for: session.runtimeState
            ).loadingTitle ?? TerminalRuntimeStatusPresentation.defaultLoadingTitle
        )
        self.runtime = runtime
        self.attachmentTransferServiceFactory = attachmentTransferServiceFactory
    }
}

/// One backend's discovery on one server.
struct SessionDiscoveryState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    static let idle = SessionDiscoveryState(
        phase: .idle,
        lastSuccessfulSessions: nil,
        hostKeyChallenge: nil,
        problem: nil,
        executablePath: nil
    )

    let phase: Phase
    let lastSuccessfulSessions: [DiscoveredSession]?
    let hostKeyChallenge: SSHHostKeyTrustChallenge?
    /// Why the last refresh failed, when it was the backend's program on the server.
    let problem: BackendProblem?
    /// Where the last refresh found the backend's program, when it listed its sessions.
    let executablePath: String?

    var sessions: [DiscoveredSession] {
        lastSuccessfulSessions ?? []
    }

    var sessionNames: [String] {
        sessions.map(\.name)
    }

    var isLoading: Bool {
        phase == .loading
    }

    func startingRefresh() -> Self {
        Self(
            phase: .loading,
            lastSuccessfulSessions: lastSuccessfulSessions,
            hostKeyChallenge: nil,
            problem: nil,
            executablePath: nil
        )
    }

    func finishingRefresh(with listing: SessionListing) -> Self {
        Self(
            phase: .loaded,
            lastSuccessfulSessions: listing.sessions,
            hostKeyChallenge: nil,
            problem: nil,
            executablePath: listing.executablePath
        )
    }

    func failingRefresh(
        hostKeyChallenge: SSHHostKeyTrustChallenge? = nil,
        problem: BackendProblem? = nil
    ) -> Self {
        Self(
            phase: .failed,
            lastSuccessfulSessions: lastSuccessfulSessions,
            hostKeyChallenge: hostKeyChallenge,
            problem: problem,
            executablePath: nil
        )
    }

    func cancellingRefresh() -> Self {
        guard let lastSuccessfulSessions else { return .idle }
        return Self(
            phase: .loaded,
            lastSuccessfulSessions: lastSuccessfulSessions,
            hostKeyChallenge: nil,
            problem: nil,
            executablePath: nil
        )
    }

    /// A session that just opened exists and runs, whatever the last list said.
    func confirmingExistingSession(named sessionName: String) -> Self {
        guard var lastSuccessfulSessions else { return self }
        let running = DiscoveredSession(name: sessionName, isRunning: true)
        if let index = lastSuccessfulSessions.firstIndex(where: { $0.name == sessionName }) {
            guard !lastSuccessfulSessions[index].isRunning else { return self }
            lastSuccessfulSessions[index] = running
        } else {
            lastSuccessfulSessions.append(running)
        }
        return Self(
            phase: phase,
            lastSuccessfulSessions: lastSuccessfulSessions,
            hostKeyChallenge: hostKeyChallenge,
            problem: problem,
            executablePath: executablePath
        )
    }
}

/// Discovery on one server: one state per backend. Both run over the server's SSH connection, so a host
/// key to review stops both.
struct ServerSessionDiscovery: Equatable {
    static let idle = ServerSessionDiscovery(tmux: .idle, herdr: .idle)

    var tmux: SessionDiscoveryState
    var herdr: SessionDiscoveryState

    subscript(backend: SessionBackend) -> SessionDiscoveryState {
        get {
            switch backend {
            case .tmux: tmux
            case .herdr: herdr
            }
        }
        set {
            switch backend {
            case .tmux: tmux = newValue
            case .herdr: herdr = newValue
            }
        }
    }

    var hostKeyChallenge: SSHHostKeyTrustChallenge? {
        tmux.hostKeyChallenge ?? herdr.hostKeyChallenge
    }

    /// Why the server's backend can't reach the session, as its newest list says: Herdr marks a session it
    /// can't connect to (`connection_error`). Every row that offers a session, discovered or saved, reads
    /// it here, so none offers one that can't open.
    func unavailableReason(of locator: SessionLocator) -> String? {
        self[locator.backend].sessions.first { $0.name == locator.name }?.unavailableReason
    }

    var isLoading: Bool {
        tmux.isLoading || herdr.isLoading
    }

    var isIdle: Bool {
        tmux.phase == .idle && herdr.phase == .idle
    }

    /// A backend whose sessions haven't been listed: discovery hasn't run for it, or a cancelled refresh ended
    /// before its first result. A refresh cancelled between the two results leaves one backend listed and the
    /// other idle.
    var hasIdleBackend: Bool {
        tmux.phase == .idle || herdr.phase == .idle
    }

    func mapping(_ transform: (SessionDiscoveryState) -> SessionDiscoveryState) -> Self {
        Self(tmux: transform(tmux), herdr: transform(herdr))
    }

    var notices: ServerDiscoveryNotices {
        if let hostKeyChallenge {
            return ServerDiscoveryNotices(hostKey: hostKeyChallenge, checkFailed: false, backendProblems: [:])
        }
        let checkFailed = tmux.phase == .failed && herdr.phase == .failed
            && tmux.problem == nil && herdr.problem == nil
        var backendProblems: [SessionBackend: BackendProblem] = [:]
        for backend in [SessionBackend.tmux, .herdr] where self[backend].phase == .failed {
            backendProblems[backend] = self[backend].problem
        }
        return ServerDiscoveryNotices(
            hostKey: nil,
            checkFailed: checkFailed,
            backendProblems: backendProblems
        )
    }
}

/// What a server's discovery has to say, each where it applies: a host key to review at the top of the
/// server page, a server that couldn't be checked after its saved sessions, and a backend's own problem on
/// that backend's saved sessions and where its path is set. A backend missing from a server where none of its
/// sessions is saved shows nowhere on the server page: most servers have only one of the two.
struct ServerDiscoveryNotices: Equatable {
    static let none = ServerDiscoveryNotices(hostKey: nil, checkFailed: false, backendProblems: [:])

    /// Nothing on the server can be checked until it's reviewed.
    let hostKey: SSHHostKeyTrustChallenge?
    /// Neither backend could be checked, for a reason that isn't either backend's: the server didn't answer,
    /// signing in failed, or the connection dropped.
    let checkFailed: Bool
    let backendProblems: [SessionBackend: BackendProblem]

    /// Nothing that can run was found for either backend, on Automatic or at the path set.
    var isNeitherBackendInstalled: Bool {
        backendProblems[.tmux]?.isNotFound == true && backendProblems[.herdr]?.isNotFound == true
    }

    /// No session on the server could be listed.
    var isServerUnchecked: Bool {
        hostKey != nil || checkFailed
    }

    /// Whether the server page shows a backend's problem: on that backend's saved sessions, or as one line when
    /// neither backend is installed.
    func showsBackendProblem(savedBackends: Set<SessionBackend>) -> Bool {
        isNeitherBackendInstalled || backendProblems.keys.contains(where: savedBackends.contains)
    }
}

enum SessionReconciliation {
    /// Hides a saved session once its backend's discovery succeeds without listing it. Each backend's
    /// discovery says nothing about the other's sessions.
    static func includesSavedWorkspace(
        _ workspace: SavedWorkspace,
        discoveries: [SavedServer.ID: ServerSessionDiscovery]
    ) -> Bool {
        guard let sessions = discoveries[workspace.serverID]?[workspace.backend].lastSuccessfulSessions else {
            return true
        }
        return sessions.contains { $0.name == workspace.sessionName }
    }
}

@MainActor
final class RemuxRootModel: ObservableObject {
    private struct SessionRefresh {
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
        SessionTarget,
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

    struct ConnectionSetupState: Equatable {
        enum SubmissionIssue: Equatable {
            case hostKeyTrustRequired(SSHHostKeyTrustChallenge)
            case verificationFailed(String)
            case saveFailed
        }

        var draft: TmuxConnectionDraft
        var validation: TmuxConnectionDraftValidation
        var submissionIssue: SubmissionIssue?
        let mode: SetupMode

        init(
            draft: TmuxConnectionDraft,
            validation: TmuxConnectionDraftValidation = .empty,
            submissionIssue: SubmissionIssue? = nil,
            mode: SetupMode
        ) {
            self.draft = draft
            self.validation = validation
            self.submissionIssue = submissionIssue
            self.mode = mode
        }
    }

    enum State: Equatable {
        case loading
        case library
        case terminal(SavedWorkspace.ID)
        case failed(String)
    }

    @Published private(set) var state: State = .loading {
        didSet { reconcileRuntimeSelection() }
    }
    @Published private(set) var connectionSetup: ConnectionSetupState?
    @Published private(set) var library: ConnectionLibrarySnapshot = .empty
    @Published private(set) var serverOrderSaveFailed = false
    @Published private(set) var terminalSettings: TerminalSettings = .default {
        didSet { Haptic.follow(terminalSettings) }
    }
    @Published private(set) var terminalSettingsSaveFailed = false
    @Published private(set) var activeSessions: [ActiveTerminalSession] = []
    @Published private(set) var isSetupActionInProgress = false
    @Published private(set) var sessionDiscoveries: [SavedServer.ID: ServerSessionDiscovery] = [:]

    /// The notifications of every open Herdr session, shown one at a time over whatever is on screen.
    let herdrNotifications = HerdrNotificationCenter()

    var setupSessionID: UUID? {
        currentSetupID
    }

    var activeTerminalScreenEntries: [ActiveTerminalScreenEntry] {
        activeSessions.map { session in
            let runtime = terminalRuntime(for: session)
            let attachmentTarget = runtime.target
            return ActiveTerminalScreenEntry(
                session: session,
                runtime: runtime,
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
    private var terminalRuntimes: [TerminalRuntimeAttemptKey: TerminalRuntime] = [:]
    private var currentAppLifecyclePhase: GhosttyAppLifecyclePhase?
    private var currentSetupID: UUID?
    private var activeSetupAction: SetupAction?
    private var editServerTrustSnapshot: EditServerTrustSnapshot?
    private var sessionRefreshes: [SavedServer.ID: SessionRefresh] = [:]
    // Keep the user's order across library reloads, including reads started before a move.
    private var preferredServerOrder: [SavedServer.ID]?
    private var pendingServerOrder: [SavedServer.ID]?
    private var isSavingServerOrder = false

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
        herdrNotifications.sessions = { [weak self] workspaceID in
            self?.herdrNotificationState(of: workspaceID)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            for refresh in sessionRefreshes.values {
                refresh.task.cancel()
            }
            stopAllTerminalRuntimes()
        }
    }

    func load() async {
        guard setupAllowsLibraryReload else { return }
        do {
#if DEBUG || REMUX_LIVE_UI_TESTING
            try await dependencies.seedDebugConnectionIfRequested()
#endif

            let terminalSettings = try await dependencies.settingsRepository.loadSettings()
            dependencies.applyHostKeyPolicy(allowInsecureRSA: terminalSettings.allowInsecureRSAHostKeys)
            let library = try await dependencies.profileRepository.loadSnapshot()
            guard setupAllowsLibraryReload else { return }
            self.terminalSettings = terminalSettings
            updateLibrary(library)
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
            // Each launch check is registered before load returns, so a later
            // request for the same server joins it instead of repeating it.
            refreshSessions()
        } catch {
            guard setupAllowsLibraryReload else { return }
            transitionToFailed(error)
        }
    }

    func showLibrary() async {
        guard setupAllowsLibraryReload else { return }
        do {
            let terminalSettings = try await dependencies.settingsRepository.loadSettings()
            dependencies.applyHostKeyPolicy(allowInsecureRSA: terminalSettings.allowInsecureRSAHostKeys)
            let library = try await dependencies.profileRepository.loadSnapshot()
            guard setupAllowsLibraryReload else { return }
            self.terminalSettings = terminalSettings
            updateLibrary(library)
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            guard setupAllowsLibraryReload else { return }
            transitionToFailed(error)
        }
    }

    private var setupAllowsLibraryReload: Bool {
        activeSetupAction == nil && currentSetupID == nil && connectionSetup == nil
    }

    private func updateLibrary(_ snapshot: ConnectionLibrarySnapshot) {
        library = preferredServerOrder.map { snapshot.orderingServers(by: $0) } ?? snapshot
    }

    func moveServers(from offsets: IndexSet, to destination: Int) {
        var ids = library.servers.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        guard ids != library.servers.map(\.id) else { return }
        preferredServerOrder = ids
        updateLibrary(library)
        retryServerOrderSave()
    }

    func dismissServerOrderSaveFailure() {
        serverOrderSaveFailed = false
    }

    func retryServerOrderSave() {
        guard let preferredServerOrder else { return }
        serverOrderSaveFailed = false
        pendingServerOrder = preferredServerOrder
        guard !isSavingServerOrder else { return }
        isSavingServerOrder = true
        Task {
            while let order = pendingServerOrder {
                pendingServerOrder = nil
                do {
                    try await dependencies.profileRepository.saveServerOrder(order)
                    serverOrderSaveFailed = false
                } catch {
                    serverOrderSaveFailed = pendingServerOrder == nil
                }
            }
            isSavingServerOrder = false
        }
    }

    func beginNewServer() {
        guard activeSetupAction == nil, currentSetupID == nil else { return }
        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        cancelLibrarySSHPrewarm()
        connectionSetup = ConnectionSetupState(
            draft: TmuxConnectionDraft(),
            mode: .newServer
        )
    }

    @discardableResult
    func beginNewWorkspace(for serverID: SavedServer.ID) -> Bool {
        guard activeSetupAction == nil, currentSetupID == nil else { return false }
        guard let server = library.server(id: serverID) else { return false }

        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        cancelLibrarySSHPrewarm()
        let backend = lastUsedBackend(on: serverID)
        let workspace = SavedWorkspace(
            serverID: serverID,
            backend: backend,
            sessionName: backend.defaultSessionName
        )
        connectionSetup = ConnectionSetupState(
            draft: TmuxConnectionDraft(server: server, workspace: workspace),
            mode: .newWorkspace(serverID)
        )
        return true
    }

    /// A new session starts on the kind most recently opened on its server, else tmux.
    private func lastUsedBackend(on serverID: SavedServer.ID) -> SessionBackend {
        library.workspaces
            .filter { $0.serverID == serverID }
            .max { $0.lastOpenedAt < $1.lastOpenedAt }?
            .backend ?? .tmux
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
        guard activeSetupAction == nil, currentSetupID == nil else { return }
        guard let server = library.server(id: serverID) else { return }
        let setupID = UUID()
        currentSetupID = setupID
        editServerTrustSnapshot = nil

        let identity: SSHIdentity
        let credential: SSHCredential?
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
        cancelLibrarySSHPrewarm()
        connectionSetup = ConnectionSetupState(
            draft: TmuxConnectionDraft(
                server: server,
                workspace: workspace,
                identity: identity,
                credential: credential
            ),
            mode: .editServer(serverID, reconnectWorkspaceID: reconnectWorkspaceID)
        )
    }

    func beginEditWorkspace(serverID: SavedServer.ID, workspaceID: SavedWorkspace.ID) async {
        guard activeSetupAction == nil, currentSetupID == nil else { return }
        guard
            let server = library.server(id: serverID),
            let workspace = library.workspace(id: workspaceID)
        else {
            return
        }

        currentSetupID = UUID()
        editServerTrustSnapshot = nil
        cancelLibrarySSHPrewarm()
        connectionSetup = ConnectionSetupState(
            draft: TmuxConnectionDraft(server: server, workspace: workspace),
            mode: .editWorkspace(serverID, workspaceID)
        )
    }

    func updateDraft(_ mutation: (inout TmuxConnectionDraft) -> Void) {
        guard activeSetupAction == nil else { return }
        guard var setup = connectionSetup else { return }
        mutation(&setup.draft)
        setup.submissionIssue = nil
        connectionSetup = setup
    }

    func dismissSetupSubmissionIssue(
        _ issue: ConnectionSetupState.SubmissionIssue
    ) {
        guard activeSetupAction == nil,
              var setup = connectionSetup,
              setup.submissionIssue == issue else {
            return
        }
        setup.submissionIssue = nil
        connectionSetup = setup
    }

    @discardableResult
    func trustNewServerHostKey(
        _ challenge: SSHHostKeyTrustChallenge,
        setupSessionID: UUID?
    ) -> Bool {
        guard activeSetupAction == nil,
              let setupSessionID,
              currentSetupID == setupSessionID,
              var setup = connectionSetup,
              setup.mode == .newServer,
              setup.draft.serverID == challenge.serverID,
              setup.submissionIssue == .hostKeyTrustRequired(challenge) else {
            return false
        }

        do {
            try dependencies.trustedHostStore.trustHostKey(challenge)
            setup.submissionIssue = nil
            connectionSetup = setup
            return true
        } catch {
            setup.submissionIssue = .verificationFailed(error.localizedDescription)
            connectionSetup = setup
            return false
        }
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
              connectionSetup != nil else {
            throw CancellationError()
        }
    }

    func cancelSetup() {
        guard let setup = connectionSetup else { return }
        guard let action = beginSetupAction() else { return }
        defer { finishSetupAction(action) }

        switch setup.mode {
        case .newServer:
            dependencies.closeIdleSSHConnections(forServerID: setup.draft.serverID)
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
        finishSetupSession(action.setupID)
        if state == .library {
            scheduleLibrarySSHPrewarm(snapshot: library)
        }
    }

    @discardableResult
    func saveAndConnect() async -> SavedServer.ID? {
        guard let setup = connectionSetup else { return nil }
        guard let action = beginSetupAction() else { return nil }
        defer { finishSetupAction(action) }

        switch setup.mode {
        case .editServer(let serverID, let reconnectWorkspaceID):
            await saveServer(
                setup,
                serverID: serverID,
                reconnectWorkspaceID: reconnectWorkspaceID,
                action: action
            )
            return nil

        case .editWorkspace(let serverID, let workspaceID):
            await saveWorkspace(
                setup,
                serverID: serverID,
                workspaceID: workspaceID,
                action: action
            )
            return nil

        case .newServer:
            return await saveNewServer(setup, action: action)

        case .newWorkspace(let serverID):
            await saveNewWorkspaceAndConnect(setup, serverID: serverID, action: action)
            return nil
        }
    }

    private func saveNewServer(
        _ setup: ConnectionSetupState,
        action: SetupAction
    ) async -> SavedServer.ID? {
        switch TmuxConnectionDraftValidator.validateServer(
            setup.draft,
            existingServerID: nil
        ) {
        case .invalid(let validation):
            connectionSetup = setupWithValidation(validation, from: setup)
            return nil

        case .valid(let submission):
            let identityCredential: SSHIdentityCredentialPair
            do {
                identityCredential = try makeIdentityCredentialPair(from: submission)
            } catch {
                connectionSetup = setupWithValidation(
                    privateKeyValidation(from: error),
                    from: setup
                )
                return nil
            }
            let identity = identityCredential.identity
            let server = submission.savedServer(identityID: identity.id)
            do {
                let sshAuth = try resolvedSSHAuth(
                    from: submission,
                    identityCredential: identityCredential
                )
                // Only SSH is checked: a server is valid without tmux, for
                // example one that runs only Herdr.
                try await dependencies.verifySSHAccess(
                    for: target(
                        server: server,
                        workspace: SavedWorkspace(serverID: server.id, sessionName: ""),
                        sshAuth: sshAuth
                    )
                )
                guard isCurrentSetupAction(action) else { return nil }
                return await persistVerifiedNewServer(
                    server,
                    identityCredential: identityCredential,
                    setup: setup,
                    action: action
                )
            } catch is CancellationError {
                return nil
            } catch TrustedHostStoreError.hostKeyTrustRequired(let challenge) {
                guard isCurrentSetupAction(action) else { return nil }
                connectionSetup = setupWithSubmissionIssue(
                    .hostKeyTrustRequired(challenge),
                    from: setup
                )
                return nil
            } catch {
                guard isCurrentSetupAction(action) else { return nil }
                connectionSetup = setupWithSubmissionIssue(
                    .verificationFailed(Self.newServerVerificationMessage(for: error)),
                    from: setup
                )
                return nil
            }
        }
    }

    private func persistVerifiedNewServer(
        _ server: SavedServer,
        identityCredential: SSHIdentityCredentialPair,
        setup: ConnectionSetupState,
        action: SetupAction
    ) async -> SavedServer.ID? {
        let identity = identityCredential.identity
        var savedCredential = false
        var savedIdentity = false
        var savedServer = false
        do {
            if let credential = identityCredential.credential {
                try await dependencies.credentialStore.saveCredential(
                    credential,
                    identityID: identity.id
                )
                savedCredential = true
            }
            try await dependencies.profileRepository.saveIdentity(identity)
            savedIdentity = true
            try await dependencies.profileRepository.saveServer(server)
            savedServer = true
            updateLibrary(try await dependencies.profileRepository.loadSnapshot())
            guard isCurrentSetupAction(action) else { return nil }
            finishSetupSession(action.setupID)
            refreshSessions(for: server.id)
            scheduleLibrarySSHPrewarm(snapshot: library)
            return server.id
        } catch {
            if !savedServer && savedIdentity {
                do {
                    try await dependencies.profileRepository.deleteIdentity(id: identity.id)
                } catch {
                    NSLog(
                        "Remux new-server identity cleanup failed: %@",
                        String(describing: error)
                    )
                }
            }
            if !savedServer {
                await cleanupCreatedCredential(identity, savedCredential: savedCredential)
                guard isCurrentSetupAction(action) else { return nil }
                NSLog(
                    "Remux new-server persistence failed before server save: %@",
                    String(describing: error)
                )
                connectionSetup = setupWithSubmissionIssue(.saveFailed, from: setup)
                return nil
            }
            transitionToFailed(error)
            return nil
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
            connectionSetup = setupWithValidation(validation, from: setup)

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
                connectionSetup = setupWithValidation(
                    privateKeyValidation(from: error),
                    from: setup
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

                invalidateSessionRefresh(for: serverID)
                // However this save ends, check the server's sessions again
                // against the profile it leaves saved. A check started during
                // the save would carry the old profile and be dropped as stale.
                // From saving the server until the library is reloaded, the
                // library still has the old profile, and a check would sign in
                // to the old address with the new credential. A save that ends
                // there leaves the app failed, and the next launch checks again.
                var libraryMatchesSavedServer = true
                defer {
                    invalidateSessionRefresh(for: serverID)
                    if libraryMatchesSavedServer {
                        refreshSessions(for: serverID)
                    }
                }
                let server = submission.savedServer(identityID: updatedIdentityCredential.identity.id)
                cancelLibrarySSHPrewarm()
                let previousCredential = try await dependencies.credentialStore.loadCredential(
                    identityID: updatedIdentityCredential.identity.id
                )
                guard isCurrentSetupAction(action) else { return }
                try await replaceCredential(
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
                    libraryMatchesSavedServer = false
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
                updateLibrary(library)
                libraryMatchesSavedServer = true
                let updatedSSHAuth = try await resolveSSHAuth(for: server)
                guard isCurrentSetupAction(action) else { return }
                closePreparedTransports(forServerID: server.id)
                dependencies.closeIdleSSHConnections(forServerID: server.id)
                RemuxActiveSessionCollection.refreshServer(
                    server,
                    sshAuth: updatedSSHAuth,
                    in: &activeSessions
                )
                refreshDisconnectedTerminalRuntimes(serverID: server.id)

                guard let reconnectWorkspaceID else {
                    finishSetupSession(action.setupID)
                    scheduleLibrarySSHPrewarm(snapshot: library)
                    return
                }

                guard var workspace = library.workspace(id: reconnectWorkspaceID) else {
                    finishSetupSession(action.setupID)
                    scheduleLibrarySSHPrewarm(snapshot: library)
                    return
                }

                workspace.lastOpenedAt = Date()
                try await dependencies.profileRepository.saveWorkspace(workspace)
                guard isCurrentSetupAction(action) else { return }
                let reloadedLibrary = try await dependencies.profileRepository.loadSnapshot()
                guard isCurrentSetupAction(action) else { return }
                updateLibrary(reloadedLibrary)
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
        guard connectionSetup != nil else {
            finishSetupSession(action.setupID)
            return
        }
    }

    private func isCurrentSetupAction(_ action: SetupAction) -> Bool {
        activeSetupAction == action && currentSetupID == action.setupID
    }

    private func finishSetupSession(_ setupID: UUID?) {
        guard currentSetupID == setupID else { return }
        connectionSetup = nil
        currentSetupID = nil
        if editServerTrustSnapshot?.setupID == setupID {
            editServerTrustSnapshot = nil
        }
    }

    private func saveNewWorkspaceAndConnect(
        _ setup: ConnectionSetupState,
        serverID: SavedServer.ID,
        action: SetupAction
    ) async {
        guard isCurrentSetupAction(action) else { return }
        switch TmuxConnectionDraftValidator.validateWorkspace(
            setup.draft,
            serverID: serverID,
            existingWorkspaceID: nil
        ) {
        case .invalid(let validation):
            connectionSetup = setupWithValidation(validation, from: setup)

        case .valid(let submission):
            do {
                guard let server = library.server(id: serverID) else {
                    finishSetupSession(action.setupID)
                    if state == .library {
                        scheduleLibrarySSHPrewarm(snapshot: library)
                    }
                    return
                }

                cancelLibrarySSHPrewarm()
                try await dependencies.profileRepository.saveWorkspace(submission.workspace)
                updateLibrary(try await dependencies.profileRepository.loadSnapshot())

                let sshAuth = try await resolveSSHAuth(for: server)

                finishSetupSession(action.setupID)
                activate(
                    server: server,
                    workspace: submission.workspace,
                    sshAuth: sshAuth,
                    opening: .create
                )
            } catch {
                transitionToFailed(error)
            }
        }
    }

    private func saveWorkspace(
        _ setup: ConnectionSetupState,
        serverID: SavedServer.ID,
        workspaceID: SavedWorkspace.ID,
        action: SetupAction
    ) async {
        guard isCurrentSetupAction(action) else { return }
        switch TmuxConnectionDraftValidator.validateWorkspace(
            setup.draft,
            serverID: serverID,
            existingWorkspaceID: workspaceID
        ) {
        case .invalid(let validation):
            connectionSetup = setupWithValidation(validation, from: setup)

        case .valid(let submission):
            do {
                cancelLibrarySSHPrewarm()
                var workspace = submission.workspace
                if let existing = library.workspace(id: workspaceID) {
                    workspace.lastOpenedAt = existing.lastOpenedAt
                }

                try await dependencies.profileRepository.saveWorkspace(workspace)
                updateLibrary(try await dependencies.profileRepository.loadSnapshot())
                closePreparedTransport(for: workspace.id)
                RemuxActiveSessionCollection.refreshWorkspace(
                    workspace,
                    in: &activeSessions
                )
                finishSetupSession(action.setupID)
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
        updated.submissionIssue = nil
        return updated
    }

    private func setupWithSubmissionIssue(
        _ issue: ConnectionSetupState.SubmissionIssue,
        from setup: ConnectionSetupState
    ) -> ConnectionSetupState {
        var updated = setup
        updated.submissionIssue = issue
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

    /// Opens a session that discovery found on a server, through its saved session if there is one.
    func connectToDiscoveredSession(
        _ locator: SessionLocator,
        on serverID: SavedServer.ID
    ) async {
        guard !locator.name.isEmpty,
              let server = library.server(id: serverID) else {
            return
        }
        let workspace = library.workspaces(for: serverID).first {
            $0.locator == locator
        } ?? SavedWorkspace(serverID: serverID, backend: locator.backend, sessionName: locator.name)
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
        switch workspace.backend {
        case .tmux:
            cancelSessionRefreshForInteractiveConnection(serverID: server.id)
        case .herdr:
            // The bridge shares the server's pooled SSH connection with a running discovery, so the
            // discovery keeps running.
            break
        }

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

        // Activate before the bookkeeping so the screen builds while
        // lastOpenedAt is saved and the library reloads. The awaits stay
        // sequential in this call so a later delete or edit cannot interleave
        // with a dangling save and resurrect a removed profile.
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
            updateLibrary(try await dependencies.profileRepository.loadSnapshot())
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

    func sessionDiscovery(
        for serverID: SavedServer.ID?
    ) -> ServerSessionDiscovery {
        guard let serverID else { return .idle }
        return sessionDiscoveries[serverID] ?? .idle
    }

    func discoveryNotices(for serverID: SavedServer.ID) -> ServerDiscoveryNotices {
        guard library.server(id: serverID) != nil else { return .none }
        return sessionDiscovery(for: serverID).notices
    }

    func refreshSessions() {
        for server in library.servers {
            refreshSessions(for: server.id)
        }
    }

    /// Coalesces launch and explicit refresh requests for one server. A
    /// completed result must still match the server profile it started with;
    /// editing or deleting that server makes the result stale.
    func refreshSessions(for serverID: SavedServer.ID) {
        guard sessionRefreshes[serverID] == nil,
              let server = library.server(id: serverID) else {
            return
        }

        let refreshID = UUID()
        sessionDiscoveries[serverID] = sessionDiscovery(for: serverID)
            .mapping { $0.startingRefresh() }
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performSessionRefresh(
                for: server,
                refreshID: refreshID
            )
        }
        sessionRefreshes[serverID] = SessionRefresh(id: refreshID, task: task)
    }

    func refreshSessionsAndWait(for serverID: SavedServer.ID) async {
        refreshSessions(for: serverID)
        guard let refresh = sessionRefreshes[serverID] else { return }
        await refresh.task.value
    }

    func trustSessionDiscoveryHostKey(_ challenge: SSHHostKeyTrustChallenge) {
        guard library.server(id: challenge.serverID) != nil,
              sessionDiscovery(for: challenge.serverID).hostKeyChallenge == challenge else {
            return
        }

        do {
            try dependencies.trustedHostStore.trustHostKey(challenge)
            refreshSessions(for: challenge.serverID)
        } catch {
            sessionDiscoveries[challenge.serverID] = sessionDiscovery(
                for: challenge.serverID
            ).mapping { $0.failingRefresh() }
        }
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
        // A Herdr model opens the new connection itself, and its panes keep the last frame meanwhile.
        // One made before its server was edited is replaced, as a tmux one is, to take the new profile.
        if case .herdr(let model)? = terminalRuntimes[TerminalRuntimeAttemptKey(session: currentSession)],
           Self.opensTheSameHerdrBridge(model.target, currentSession.target),
           model.reconnect() {
            var session = currentSession
            session.reconnectRuntime(source: source)
            RemuxActiveSessionCollection.replaceRuntime(with: session, in: &activeSessions)
            state = .terminal(id)
            GhosttyRuntimeTrace.flowEvent(
                sessionReconnectFlowID(id),
                event: "model.reconnect.restarted",
                fields: [
                    "instanceID": session.instanceID.uuidString,
                    "source": source.traceLabel,
                    "workspaceID": id.uuidString,
                ]
            )
            return
        }
        guard let session = RemuxActiveSessionCollection.runtimeReplacementSession(
            workspaceID: id,
            source: source,
            in: activeSessions
        ) else {
            state = .library
            return
        }
        prepareTmuxTransport(for: session.target, reason: .reconnect)
        replaceTerminalRuntime(for: session)
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

    /// A tapped notification banner opens its session, at its pane when it names one, as Herdr's client
    /// goes to a notification's pane on its machine. The banner goes either way.
    func openHerdrNotification(_ banner: HerdrNotificationPolicy.Banner) {
        herdrNotifications.dismiss(banner.id)
        openHerdrSession(banner.origin.workspaceID, atPane: banner.notification.paneID, bootID: banner.origin.bootID)
    }

    /// Shows an open Herdr session, at `paneID` when given.
    func openHerdrSession(_ workspaceID: SavedWorkspace.ID, atPane paneID: String?, bootID: String?) {
        openHerdrSession(workspaceID, to: paneID.map { .place(.pane($0)) }, bootID: bootID)
    }

    /// Shows an open Herdr session, taken to `destination` when given: the session goes there once it is on
    /// screen, if what it names is still there on the server boot `bootID` names. The session on screen goes
    /// there at once.
    private func openHerdrSession(_ workspaceID: SavedWorkspace.ID, to destination: HerdrDestination?, bootID: String?) {
        guard RemuxActiveSessionCollection.containsWorkspace(workspaceID, in: activeSessions) else { return }
        if let destination {
            herdrModel(of: workspaceID)?.ask(.go(destination), bootID: bootID)
        }
        showActiveSession(workspaceID)
    }

    /// The workspaces and tabs of an open Herdr session, for the Sessions sheet.
    func herdrPlaces(of workspaceID: SavedWorkspace.ID) -> HerdrSessionPlaces? {
        herdrModel(of: workspaceID)?.places
    }

    /// A Herdr workspace picked in the Sessions sheet, as Herdr's client opens a machine at a workspace.
    /// `bootID` is the server boot the sheet listed it from.
    func openHerdrWorkspace(_ herdrWorkspaceID: String, bootID: String, in workspaceID: SavedWorkspace.ID) {
        openHerdrSession(workspaceID, to: .place(.workspace(herdrWorkspaceID)), bootID: bootID)
    }

    /// New Workspace under a session in the Sessions sheet, beside the workspace this phone has there. A
    /// session not on screen is shown, and the workspace made as part of its show.
    func createHerdrWorkspace(in workspaceID: SavedWorkspace.ID) {
        guard let outline = herdrModel(of: workspaceID)?.places.outline else { return }
        openHerdrSession(
            workspaceID,
            to: .creation(.workspace(source: outline.focusedWorkspaceID)),
            bootID: outline.bootID
        )
    }

    /// What closing a workspace from its row in the Sessions sheet asks: always, as Herdr's client asks. Only
    /// the session on screen offers it, since Herdr refuses commands from a hidden session.
    func herdrWorkspaceCloseConfirmation(
        _ herdrWorkspaceID: String,
        in workspaceID: SavedWorkspace.ID
    ) -> HerdrCloseConfirmation? {
        herdrModelOnScreen(workspaceID)?.places.outline?.closeConfirmation(ofWorkspace: herdrWorkspaceID)
    }

    /// The close the user agreed to, checked as any close is when it goes.
    func closeHerdrWorkspace(confirmed confirmation: HerdrCloseConfirmation, in workspaceID: SavedWorkspace.ID) {
        herdrModelOnScreen(workspaceID)?.ask(confirmation.request, bootID: confirmation.bootID)
    }

    /// What renaming a workspace from its row starts with; only the session on screen offers it.
    func herdrWorkspaceRenameField(_ herdrWorkspaceID: String, in workspaceID: SavedWorkspace.ID) -> TerminalRenameField? {
        herdrModelOnScreen(workspaceID)?.renameField(for: .workspace(herdrWorkspaceID))
    }

    /// A workspace renamed from its row, which the Sessions sheet listed from server boot `bootID`.
    func renameHerdrWorkspace(
        _ herdrWorkspaceID: String,
        to name: String,
        bootID: String,
        in workspaceID: SavedWorkspace.ID
    ) {
        herdrModelOnScreen(workspaceID)?.ask(.rename(.workspace(herdrWorkspaceID), name: name), bootID: bootID)
    }

    private func herdrModelOnScreen(_ workspaceID: SavedWorkspace.ID) -> HerdrScreenModel? {
        guard state == .terminal(workspaceID) else { return nil }
        return herdrModel(of: workspaceID)
    }

    /// The current session's existing notice publisher, observed by the sheet that issues its commands.
    func herdrScreen(of workspaceID: SavedWorkspace.ID) -> HerdrTerminalScreenAdapter? {
        herdrModelOnScreen(workspaceID)?.terminalScreenAdapter
    }

    /// An open Herdr session's agents.
    func herdrAgents(of workspaceID: SavedWorkspace.ID) -> HerdrAgentPresentation? {
        herdrModel(of: workspaceID)?.agents
    }

    private func herdrModel(of workspaceID: SavedWorkspace.ID) -> HerdrScreenModel? {
        guard let session = RemuxActiveSessionCollection.session(workspaceID, in: activeSessions),
              case .herdr(let model)? = terminalRuntimes[TerminalRuntimeAttemptKey(session: session)]
        else { return nil }
        return model
    }

    private func herdrNotificationState(of workspaceID: SavedWorkspace.ID) -> HerdrNotificationSessionState? {
        herdrModel(of: workspaceID)?.notificationState
    }

    /// Only the session's current model speaks for it; a replaced one's late events are dropped.
    private func handleHerdrNotification(
        _ event: HerdrScreenModel.NotificationEvent,
        from key: TerminalRuntimeAttemptKey
    ) {
        guard terminalRuntimes[key] != nil,
              let session = RemuxActiveSessionCollection.session(key.workspaceID, in: activeSessions)
        else { return }
        switch event {
        case .received(let notification, let bootID, let place):
            herdrNotifications.receive(notification, from: HerdrNotificationPolicy.Origin(
                workspaceID: key.workspaceID,
                sessionName: session.target.workspace.sessionName,
                serverName: session.target.server.displayName,
                bootID: bootID,
                place: place
            ))
        case .serverRestarted:
            herdrNotifications.retire(key.workspaceID)
        case .bell:
            herdrNotifications.ringBell()
        }
    }

    /// Whether two targets reach the same Herdr session the same way. Terminal settings don't count:
    /// a running model takes them live.
    private static func opensTheSameHerdrBridge(_ lhs: SessionTarget, _ rhs: SessionTarget) -> Bool {
        HerdrSessionAddress(lhs) == HerdrSessionAddress(rhs)
            && lhs.workspace.backend == rhs.workspace.backend
            && lhs.sshAuth.authFingerprint == rhs.sshAuth.authFingerprint
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
                // Only a tmux session has a viewport to claim.
                if case .tmux(let model)? = terminalRuntimes[TerminalRuntimeAttemptKey(session: session)] {
                    claimActiveTmuxViewportIfSelectedAndActive(model, for: session)
                }
                let serverID = session.target.server.id
                let backend = session.target.workspace.backend
                var discovery = sessionDiscovery(for: serverID)
                let previousPhase = discovery[backend].phase
                discovery[backend] = discovery[backend]
                    .confirmingExistingSession(named: session.target.workspace.sessionName)
                sessionDiscoveries[serverID] = discovery
                if previousPhase == .failed || discovery.hasIdleBackend {
                    refreshSessions(for: serverID)
                }
            }
        case .applied(.disconnected(let reason)) where reason.kind == .sessionEnded:
            // The server's list no longer has it.
            if let session = RemuxActiveSessionCollection.session(update.workspaceID, in: activeSessions) {
                refreshSessions(for: session.target.server.id)
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
            cancelAllSessionRefreshes()
        }
        // Going to the background cancels discovery, leaving a server's first check undone; it resumes on return.
        if phase == .active {
            for server in library.servers where sessionDiscovery(for: server.id).hasIdleBackend {
                refreshSessions(for: server.id)
            }
        }
        let runtimes = Array(terminalRuntimes.values)
        for runtime in runtimes {
            runtime.handleAppLifecyclePhase(phase)
        }

        guard phase == .active,
              connectionSetup == nil,
              case .terminal(let selectedID) = state,
              let session = RemuxActiveSessionCollection.session(
                  selectedID,
                  in: activeSessions
              ),
              case .tmux(let model)? = terminalRuntimes[TerminalRuntimeAttemptKey(session: session)]
        else { return }
        model.terminalScreenAdapter.reclaimActiveTmuxViewport()
    }

    private func claimActiveTmuxViewportIfSelectedAndActive(
        _ model: TmuxScreenModel,
        for session: ActiveTerminalSession
    ) {
        guard currentAppLifecyclePhase == .active,
              connectionSetup == nil,
              state == .terminal(session.id)
        else { return }
        model.terminalScreenAdapter.claimActiveTmuxViewportIfNeeded()
    }

    func disconnectActiveSession(_ id: SavedWorkspace.ID) {
        // Fallback selection follows the order users see in the switcher
        // and library, not internal activation order.
        let displayedIndex = RemuxActiveSessionCollection.sortedForDisplay(activeSessions)
            .firstIndex { $0.id == id }
        closePreparedTransport(for: id)
        stopTerminalRuntimes(workspaceID: id)
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
            invalidateSessionRefresh(for: id)
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
            stopTerminalRuntimes(serverID: id)
            RemuxActiveSessionCollection.removeServer(id, from: &activeSessions)
            updateLibrary(snapshot)
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
            stopTerminalRuntimes(workspaceID: id)
            RemuxActiveSessionCollection.removeWorkspace(id, from: &activeSessions)
            updateLibrary(try await dependencies.profileRepository.loadSnapshot())
            state = .library
            scheduleLibrarySSHPrewarm(snapshot: library)
        } catch {
            transitionToFailed(error)
        }
    }

    func updateTerminalSettings(_ mutation: (inout TerminalSettings) -> Void) async {
        var updated = terminalSettings
        mutation(&updated)

        do {
            try await dependencies.settingsRepository.saveSettings(updated)
        } catch {
            NSLog("Remux terminal settings save failed: %@", String(describing: error))
            terminalSettingsSaveFailed = true
            return
        }

        terminalSettingsSaveFailed = false
        terminalSettings = updated
        dependencies.applyHostKeyPolicy(allowInsecureRSA: updated.allowInsecureRSAHostKeys)
        applyTerminalSettingsToActiveSessions(updated)
    }

    func dismissTerminalSettingsSaveFailure() {
        terminalSettingsSaveFailed = false
    }

    func makeTransport(for target: SessionTarget) -> any TmuxControlTransport {
        preparedTransportCoordinator.claimOrCreateTransport(for: target)
    }

    private func applyTerminalSettingsToActiveSessions(_ settings: TerminalSettings) {
        RemuxActiveSessionCollection.refreshTerminalSettings(
            settings,
            in: &activeSessions
        )

        for session in activeSessions {
            let key = TerminalRuntimeAttemptKey(session: session)
            guard let runtime = terminalRuntimes[key] else { continue }
            do {
                try runtime.applyTerminalSettings(settings)
            } catch {
                NSLog("Remux terminal settings apply failed: %@", String(describing: error))
            }
        }
    }

    /// A runtime's target is fixed when it's made, so a disconnected one is replaced to take the
    /// server's new profile.
    private func refreshDisconnectedTerminalRuntimes(serverID: SavedServer.ID) {
        for session in activeSessions where session.target.server.id == serverID {
            let key = TerminalRuntimeAttemptKey(session: session)
            guard terminalRuntimes[key]?.isDisconnected == true else { continue }
            replaceTerminalRuntime(for: session)
            applyCurrentAppLifecyclePhase(to: session)
        }
    }

    func terminalRuntime(for session: ActiveTerminalSession) -> TerminalRuntime {
        let key = TerminalRuntimeAttemptKey(session: session)
        guard let runtime = terminalRuntimes[key] else {
            preconditionFailure("Missing terminal runtime for active runtime attempt")
        }
        return runtime
    }

    func hasTerminalRuntime(for session: ActiveTerminalSession) -> Bool {
        terminalRuntimes[TerminalRuntimeAttemptKey(session: session)] != nil
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
        sshAuth: ResolvedSSHAuth,
        opening: SessionOpening = .attach
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
        var target = target(server: server, workspace: workspace, sshAuth: sshAuth)
        target.opening = opening
        let activeSession = ActiveTerminalSession(target: target)
        prepareTmuxTransport(for: target, reason: .activation)
        replaceTerminalRuntime(for: activeSession)
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

    private func resolvedSSHAuth(
        from draft: ValidatedTmuxServerDraft,
        identityCredential: SSHIdentityCredentialPair
    ) throws -> ResolvedSSHAuth {
        switch identityCredential.credential {
        case .some(.password(let password)):
            return .password(
                username: draft.username,
                password: password,
                identityID: identityCredential.identity.id,
                displayLabel: identityCredential.identity.name
            )
        case .some(.privateKey(let credential)):
            return try .privateKey(
                username: draft.username,
                credential: credential,
                identityID: identityCredential.identity.id,
                displayLabel: identityCredential.identity.name
            )
        case .none:
            return .none(
                username: draft.username,
                identityID: identityCredential.identity.id,
                displayLabel: identityCredential.identity.name
            )
        }
    }

    private static func newServerVerificationMessage(for error: any Error) -> String {
        if let tailscaleCheckError = error as? TailscaleSSHCheckError {
            return tailscaleCheckError.localizedDescription
        }

        let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure(error)
        switch reason.kind {
        case .serverUnreachable:
            return "Remux could not reach the server. Check the address, port, network, or VPN."
        case .authentication:
            return "The server rejected these credentials. Check the user and authentication details."
        case .backendUnavailable:
            return reason.message
        case .hostKey:
            return "Remux could not verify the SSH host key."
        case .verificationExpired, .sessionEnded, .transportIO, .profile, .remoteExit, .runtime, .userClosed,
             .unknown:
            return error.localizedDescription
        }
    }

    private struct SSHIdentityCredentialPair {
        let identity: SSHIdentity
        let credential: SSHCredential?
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

        case .none:
            let identity = SSHIdentity(
                name: draft.displayName,
                authenticationKind: .none
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: nil
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

        case .none:
            let identity = SSHIdentity(
                id: existingIdentity.id,
                name: draft.displayName,
                authenticationKind: .none
            )
            return SSHIdentityCredentialPair(
                identity: identity,
                credential: nil
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
    ) async throws -> (SSHIdentity, SSHCredential?) {
        guard let identity = library.identity(id: server.identityID) else {
            throw SSHAuthResolverError.missingIdentity(server.identityID)
        }
        if identity.authenticationKind == .none {
            return (identity, nil)
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

    private func replaceCredential(
        _ credential: SSHCredential?,
        identityID: SSHIdentity.ID
    ) async throws {
        if let credential {
            try await dependencies.credentialStore.saveCredential(
                credential,
                identityID: identityID
            )
        } else {
            try await dependencies.credentialStore.deleteCredential(identityID: identityID)
        }
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
    ) -> SessionTarget {
        SessionTarget(
            server: server,
            workspace: workspace,
            sshAuth: sshAuth,
            terminalSettings: terminalSettings
        )
    }

    /// Lists both backends' sessions over the server's SSH connection, each applied as it arrives, so a
    /// slow or missing backend doesn't hold back the other.
    private func performSessionRefresh(
        for server: SavedServer,
        refreshID: UUID
    ) async {
        defer { finishSessionRefresh(for: server.id, refreshID: refreshID) }

        let sshAuth: ResolvedSSHAuth
        do {
            sshAuth = try await resolveSSHAuth(for: server)
        } catch {
            guard isCurrentSessionRefresh(server, refreshID: refreshID) else { return }
            sessionDiscoveries[server.id] = sessionDiscovery(for: server.id).mapping {
                Self.applying(.failure(error), to: $0, backend: nil, configuredPath: nil)
            }
            return
        }
        guard isCurrentSessionRefresh(server, refreshID: refreshID) else { return }
        let discoveryTarget = target(
            server: server,
            workspace: SavedWorkspace(serverID: server.id, sessionName: ""),
            sshAuth: sshAuth
        )
        let dependencies = dependencies
        // Each child awaits before building its tuple: optimized Swift 6.3 and 6.4 builds return the wrong first
        // element from a tuple expression that contains the `await`.
        await withTaskGroup(of: (SessionBackend, Result<SessionListing, Error>).self) { group in
            group.addTask {
                do {
                    let listing = try await dependencies.discoverTmuxSessions(for: discoveryTarget)
                    return (.tmux, .success(listing))
                } catch {
                    return (.tmux, .failure(error))
                }
            }
            group.addTask {
                do {
                    let listing = try await dependencies.discoverHerdrSessions(for: discoveryTarget)
                    return (.herdr, .success(listing))
                } catch {
                    return (.herdr, .failure(error))
                }
            }
            for await (backend, result) in group {
                guard isCurrentSessionRefresh(server, refreshID: refreshID) else { continue }
                var discovery = sessionDiscovery(for: server.id)
                discovery[backend] = Self.applying(
                    result,
                    to: discovery[backend],
                    backend: backend,
                    configuredPath: server.executablePath(for: backend)
                )
                sessionDiscoveries[server.id] = discovery
            }
        }
    }

    /// Discovery is auxiliary: a failure stays in the server's discovery state and never replaces the app
    /// route. `backend` is nil for a failure before either backend ran; `configuredPath` is the backend's
    /// path set in Edit Server, nil for Automatic.
    private static func applying(
        _ result: Result<SessionListing, Error>,
        to state: SessionDiscoveryState,
        backend: SessionBackend?,
        configuredPath: String?
    ) -> SessionDiscoveryState {
        switch result {
        case .success(let listing):
            return state.finishingRefresh(with: SessionListing(
                executablePath: listing.executablePath,
                sessions: normalizedSessions(listing.sessions)
            ))
        case .failure(let error) where error is CancellationError:
            return state.cancellingRefresh()
        case .failure(TrustedHostStoreError.hostKeyTrustRequired(let challenge)):
            return state.failingRefresh(hostKeyChallenge: challenge)
        case .failure(let error):
            return state.failingRefresh(
                problem: backend == nil ? nil : BackendProblem(discoveryError: error, path: configuredPath)
            )
        }
    }

    private static func normalizedSessions(_ sessions: [DiscoveredSession]) -> [DiscoveredSession] {
        var seen = Set<String>()
        return sessions.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
    }

    private func isCurrentSessionRefresh(
        _ server: SavedServer,
        refreshID: UUID
    ) -> Bool {
        sessionRefreshes[server.id]?.id == refreshID
            && library.server(id: server.id) == server
    }

    private func finishSessionRefresh(
        for serverID: SavedServer.ID,
        refreshID: UUID
    ) {
        guard sessionRefreshes[serverID]?.id == refreshID else { return }
        sessionRefreshes.removeValue(forKey: serverID)
    }

    private func invalidateSessionRefresh(for serverID: SavedServer.ID) {
        sessionRefreshes.removeValue(forKey: serverID)?.task.cancel()
        sessionDiscoveries.removeValue(forKey: serverID)
    }

    private func cancelSessionRefreshForInteractiveConnection(
        serverID: SavedServer.ID
    ) {
        guard let refresh = sessionRefreshes.removeValue(forKey: serverID) else { return }
        refresh.task.cancel()
        sessionDiscoveries[serverID] = sessionDiscovery(for: serverID)
            .mapping { $0.cancellingRefresh() }
    }

    private func cancelAllSessionRefreshes() {
        let refreshes = sessionRefreshes
        sessionRefreshes.removeAll()
        for (serverID, refresh) in refreshes {
            refresh.task.cancel()
            sessionDiscoveries[serverID] = sessionDiscovery(for: serverID)
                .mapping { $0.cancellingRefresh() }
        }
    }

    private static func makeDefaultTerminalScreenModel(
        target: SessionTarget,
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

    private func replaceTerminalRuntime(for session: ActiveTerminalSession) {
        let previous = terminalRuntimes.first(where: {
            $0.key.workspaceID == session.id
        })?.value
        stopTerminalRuntimes(workspaceID: session.id, reason: .replacedByNewAttempt)
        let key = TerminalRuntimeAttemptKey(session: session)
        let onRuntimeStateChange: (TerminalRuntimeStateUpdate) -> Void = { [weak self] update in
            guard let self else { return }
            _ = self.handleTerminalRuntimeStateUpdate(update)
        }
        let runtime: TerminalRuntime
        switch session.target.workspace.backend {
        case .tmux:
            // Carry the previous attempt's viewport into the replacement so
            // it attaches already sized (captures land at this width).
            var carriedClientSize: TmuxSessionController.ClientSize?
            if case .tmux(let previousModel)? = previous {
                carriedClientSize = previousModel.carriedClientSize
            }
            let transportFactory: TmuxScreenModel.TransportFactory = { [preparedTransportCoordinator] target in
                preparedTransportCoordinator.claimOrCreateTransport(for: target)
            }
            runtime = .tmux(terminalScreenModelFactory(
                session.target,
                session.instanceID,
                transportFactory,
                onRuntimeStateChange,
                carriedClientSize
            ))
        case .herdr:
            let target = session.target
            runtime = .herdr(HerdrScreenModel(
                target: target,
                sessionInstanceID: session.instanceID,
                openBridge: { [dependencies] kind in
                    try await dependencies.openHerdrBridge(for: target, kind: kind)
                },
                onRuntimeStateChange: onRuntimeStateChange,
                onNotification: { [weak self] event in
                    self?.handleHerdrNotification(event, from: key)
                },
                zoomKeepers: dependencies.herdrZoomKeepers
            ))
        }
        terminalRuntimes[key] = runtime
        runtime.setSelected(state == .terminal(session.id))
    }

    private func applyCurrentAppLifecyclePhase(to session: ActiveTerminalSession) {
        if let currentAppLifecyclePhase {
            terminalRuntimes[TerminalRuntimeAttemptKey(session: session)]?
                .handleAppLifecyclePhase(currentAppLifecyclePhase)
        }
    }

    /// The root shows the selected session, outside Home; another session and Home hide it, and the
    /// sheets over it don't.
    private func reconcileRuntimeSelection() {
        for session in activeSessions {
            terminalRuntimes[TerminalRuntimeAttemptKey(session: session)]?
                .setSelected(state == .terminal(session.id))
        }
    }

    private func stopTerminalRuntimes(
        workspaceID: SavedWorkspace.ID,
        reason: TerminalRuntimeStopReason = .sessionEnded
    ) {
        stopTerminalRuntimes(reason: reason) { key, _ in
            key.workspaceID == workspaceID
        }
    }

    private func stopTerminalRuntimes(serverID: SavedServer.ID) {
        stopTerminalRuntimes { key, _ in
            return activeSessions.contains {
                $0.id == key.workspaceID && $0.target.server.id == serverID
            }
        }
    }

    private func stopAllTerminalRuntimes() {
        stopTerminalRuntimes { _, _ in true }
    }

    private func stopTerminalRuntimes(
        reason: TerminalRuntimeStopReason = .sessionEnded,
        where shouldStop: (TerminalRuntimeAttemptKey, TerminalRuntime) -> Bool
    ) {
        let removed = terminalRuntimes.filter(shouldStop)
        for (key, runtime) in removed {
            terminalRuntimes[key] = nil
            // As Herdr's client drops a machine's notifications when it lets the machine go.
            if case .herdr = runtime { herdrNotifications.retire(key.workspaceID) }
        }
        for runtime in removed.values {
            // Teardown ordering (surface unregister/free before terminal
            // release, link before controller) is owned by the model; the
            // task retains it until shutdown completes.
            Task { await runtime.stop(reason) }
        }
    }

    private func transitionToFailed(_ error: any Error) {
        finishSetupSession(currentSetupID)
        stopAllTerminalRuntimes()
        activeSessions.removeAll()
        state = .failed(String(describing: error))
    }

    private func automaticReconnectSource(
        for update: TerminalRuntimeStateUpdate
    ) -> TerminalReconnectSource? {
        guard connectionSetup == nil,
              case .terminal(let selectedID) = state,
              selectedID == update.workspaceID else {
            return nil
        }
        // A Herdr session reconnects by itself, on Herdr's schedule.
        let key = TerminalRuntimeAttemptKey(workspaceID: update.workspaceID, instanceID: update.instanceID)
        if case .herdr? = terminalRuntimes[key] { return nil }
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
            var fields = [
                "instanceID": update.instanceID.uuidString,
                "source": update.source.traceLabel,
                "state": state.traceLabel,
                "workspaceID": update.workspaceID.uuidString,
            ]
            // Most kinds have the same words on the session's screen each time; this is what went wrong.
            if let reason = state.disconnectedReason {
                fields["reason"] = reason.message
            }
            GhosttyRuntimeTrace.flowEventIfActive(
                sessionOpenFlowID(update.workspaceID),
                event: "model.runtimeState.applied",
                fields: fields
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

    /// Herdr's bridge claims its SSH connection when its model opens it.
    private func prepareTmuxTransport(
        for target: SessionTarget,
        reason: RemuxPreparedTransportPrepareReason
    ) {
        switch target.workspace.backend {
        case .tmux:
            preparedTransportCoordinator.prepareTransport(for: target, reason: reason)
        case .herdr:
            break
        }
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
                    isLibraryVisible: state == .library && connectionSetup == nil,
                    activeServerIDs: RemuxActiveSessionCollection.activeServerIDs(
                        in: activeSessions
                    ),
                    terminalSettings: terminalSettings
                )
            },
            onEligibleTarget: { [weak self] target in
                self?.prepareTmuxTransport(for: target, reason: .library)
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
