import SafariServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    private let dependencies: Result<RemuxAppDependencies, Error>

    init(dependencies: Result<RemuxAppDependencies, Error> = RemuxAppDependencies.launch()) {
        self.dependencies = dependencies
    }

    var body: some View {
        liveBody
    }

    @ViewBuilder
    private var liveBody: some View {
        switch dependencies {
        case .success(let dependencies):
            RemuxRootContentView(dependencies: dependencies)
        case .failure(let error):
            FailureView(message: String(describing: error))
        }
    }
}

private struct RemuxRootContentView: View {
    @StateObject private var model: RemuxRootModel
    @State private var composer: GhosttyComposerModel
    @State private var shortcutStore: ShortcutStore
    @State private var tailscaleSSHCheckRequests: [TailscaleSSHCheckRequest]
    private let tailscaleSSHCheckEvents: AsyncStream<TailscaleSSHCheckEvent>

    init(dependencies: RemuxAppDependencies) {
        _model = StateObject(wrappedValue: RemuxRootModel(dependencies: dependencies))
        _composer = State(initialValue: GhosttyComposerModel())
        _shortcutStore = State(
            initialValue: ShortcutStore(repository: dependencies.shortcutRepository)
        )
        _tailscaleSSHCheckRequests = State(initialValue: [])
        tailscaleSSHCheckEvents = dependencies.tailscaleSSHCheckEvents
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading Remux")
                    .task {
                        async let modelLoad: Void = model.load()
                        async let shortcutLoad: Void = shortcutStore.load()
                        _ = await (modelLoad, shortcutLoad)
                    }

            case .library, .terminal:
                RemuxWorkspaceShell(
                    model: model,
                    composer: composer,
                    shortcutStore: shortcutStore,
                    tailscaleSSHCheckRequest: currentTailscaleSSHCheckRequest
                )

            case .failed(let message):
                FailureView(message: message)
            }
        }
        .task {
            for await event in tailscaleSSHCheckEvents {
                handleTailscaleSSHCheckEvent(event)
            }
        }
    }

    private var currentTailscaleSSHCheckRequest: Binding<TailscaleSSHCheckRequest?> {
        Binding(
            get: { tailscaleSSHCheckRequests.first },
            set: { _ in }
        )
    }

    private func handleTailscaleSSHCheckEvent(_ event: TailscaleSSHCheckEvent) {
        switch event {
        case .presented(let request):
            if let index = tailscaleSSHCheckRequests.firstIndex(where: { $0.id == request.id }) {
                tailscaleSSHCheckRequests[index] = request
            } else {
                tailscaleSSHCheckRequests.append(request)
            }
        case .finished(let requestID):
            tailscaleSSHCheckRequests.removeAll { $0.id == requestID }
        }
    }
}

private struct RemuxWorkspaceShell: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: RemuxRootModel
    let composer: GhosttyComposerModel
    let shortcutStore: ShortcutStore
    @Binding var tailscaleSSHCheckRequest: TailscaleSSHCheckRequest?
    @State private var retainedTerminalID: SavedWorkspace.ID?
    @State private var isSessionSwitcherPresented = false
    @State private var presentedServerID: SavedServer.ID?
    @State private var connectionSetupSheetShowsServerSummary = true

    var body: some View {
        ZStack {
            activeTerminalLayer
            routeLayer
        }
        .onAppear {
            model.handleAppLifecyclePhase(
                RemuxAppLifecycleProjection(scenePhase: scenePhase).appLifecyclePhase
            )
            if scenePhase == .background {
                composer.stopDictationImmediately()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.handleAppLifecyclePhase(
                RemuxAppLifecycleProjection(scenePhase: newPhase).appLifecyclePhase
            )
            if newPhase == .background {
                composer.stopDictationImmediately()
            }
        }
        .onChange(of: selectedTerminalID) { _, newValue in
            guard let newValue else { return }
            retainedTerminalID = newValue
        }
        .onChange(of: model.activeTerminalScreenEntries.map(\.id)) { _, ids in
            guard !ids.isEmpty else {
                retainedTerminalID = nil
                return
            }

            if let retainedTerminalID, ids.contains(retainedTerminalID) {
                return
            }

            retainedTerminalID = ids[0]
        }
        .onChange(of: model.state) { _, state in
            switch state {
            case .library:
                isSessionSwitcherPresented = false
            case .terminal:
                presentedServerID = nil
            case .loading, .failed:
                isSessionSwitcherPresented = false
                presentedServerID = nil
            }
        }
        .tailscaleSSHCheckAlert(
            request: $tailscaleSSHCheckRequest,
            isActive: !isSessionSwitcherPresented && model.connectionSetup == nil
        )
        .sheet(
            isPresented: $isSessionSwitcherPresented,
            onDismiss: cancelSessionSetupIfNeeded
        ) {
            SessionSwitcherView(
                projection: SessionSwitcherProjection(
                    snapshot: model.library,
                    activeSessions: model.activeSessions,
                    discoveryStates: model.tmuxSessionDiscoveryStates,
                    selectedSessionID: selectedTerminalID
                ),
                servers: model.library.servers,
                currentServerID: selectedActiveSession?.target.server.id,
                onSelectActiveSession: model.showActiveSession,
                onResumeSession: { workspaceID in
                    traceSessionOpenTap(workspaceID)
                    Task { await model.connect(to: workspaceID) }
                },
                onResumeAvailableSession: { serverID, sessionName in
                    Task {
                        await model.connectToDiscoveredSession(
                            named: sessionName,
                            on: serverID
                        )
                    }
                },
                onDisconnectSession: model.disconnectActiveSession,
                isCreatingSession: terminalNewSessionSetup != nil,
                onCreateSession: model.beginNewWorkspace,
                onCancelCreateSession: model.cancelSetup,
                newSessionContent: {
                    Group {
                        if let setup = terminalNewSessionSetup {
                            connectionSetupView(
                                setup,
                                showsServerSummaryForNewSession: true,
                                onSave: saveSessionFromTerminal
                            )
                        }
                    }
                },
                onRefresh: model.refreshTmuxSessions,
                discoveryStates: model.tmuxSessionDiscoveryStates
            )
            .remuxSheetPresentationBackground()
            .ghosttyTerminalChromePresentation(
                model.terminalSettings.theme.terminalChromeColorScheme,
                chromeStyle: model.terminalSettings.theme.terminalChromeStyle
            )
            .tailscaleSSHCheckAlert(
                request: $tailscaleSSHCheckRequest,
                isActive: true
            )
        }
        .sheet(isPresented: connectionSetupSheetIsPresented) {
            connectionSetupSheet
                .interactiveDismissDisabled()
                .tailscaleSSHCheckAlert(
                    request: $tailscaleSSHCheckRequest,
                    isActive: true
                )
        }
        .alert(
            terminalSettingsUpdateIssueTitle,
            isPresented: terminalSettingsUpdateIssueIsPresented,
            presenting: model.terminalSettingsUpdateIssue
        ) { issue in
            Button("OK", role: .cancel) {
                model.dismissTerminalSettingsUpdateIssue(issue)
            }
        } message: { issue in
            Text(terminalSettingsUpdateIssueMessage(issue))
        }
    }

    private var terminalSettingsUpdateIssueIsPresented: Binding<Bool> {
        Binding(
            get: { model.terminalSettingsUpdateIssue != nil },
            set: { isPresented in
                guard !isPresented, let issue = model.terminalSettingsUpdateIssue else { return }
                model.dismissTerminalSettingsUpdateIssue(issue)
            }
        )
    }

    private var terminalSettingsUpdateIssueTitle: String {
        switch model.terminalSettingsUpdateIssue {
        case .saveFailed:
            "Settings Couldn’t Be Saved"
        case .applyFailed:
            "Settings Couldn’t Be Applied"
        case nil:
            "Settings"
        }
    }

    private func terminalSettingsUpdateIssueMessage(
        _ issue: RemuxRootModel.TerminalSettingsUpdateIssue
    ) -> String {
        switch issue {
        case .saveFailed:
            "Your previous settings are still in use. Try again."
        case .applyFailed:
            "The settings were saved, but couldn’t be applied to every active terminal. "
                + "Reconnect affected sessions to apply them."
        }
    }

    private var connectionSetupSheetIsPresented: Binding<Bool> {
        Binding(
            get: { model.connectionSetup != nil && !isSessionSwitcherPresented },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var connectionSetupSheet: some View {
        if let setup = model.connectionSetup {
            NavigationStack {
                connectionSetupView(
                    setup,
                    showsServerSummaryForNewSession: connectionSetupSheetShowsServerSummary,
                    onSave: saveConnectionSetupSheet
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismissKeyboard()
                            model.cancelSetup()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Cancel")
                        .accessibilityIdentifier("connection.cancel")
                        .disabled(model.isSetupActionInProgress)
                    }
                }
            }
            .presentationDetents(presentationDetents(for: setup.mode))
            .presentationDragIndicator(.visible)
            .remuxSheetPresentationBackground()
            .ghosttyTerminalChromePresentation(
                model.terminalSettings.theme.terminalChromeColorScheme,
                chromeStyle: model.terminalSettings.theme.terminalChromeStyle
            )
            .alert(
                setupSubmissionIssueTitle(setup.submissionIssue),
                isPresented: setupSubmissionIssueIsPresented(setup.submissionIssue),
                presenting: setup.submissionIssue
            ) { issue in
                setupSubmissionIssueActions(
                    issue,
                    setupSessionID: model.setupSessionID
                )
            } message: { issue in
                Text(setupSubmissionIssueMessage(issue))
            }
        }
    }

    private func setupSubmissionIssueIsPresented(
        _ issue: RemuxRootModel.ConnectionSetupState.SubmissionIssue?
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let issue else { return false }
                return model.connectionSetup?.submissionIssue == issue
            },
            set: { isPresented in
                guard !isPresented, let issue else { return }
                model.dismissSetupSubmissionIssue(issue)
            }
        )
    }

    private func setupSubmissionIssueTitle(
        _ issue: RemuxRootModel.ConnectionSetupState.SubmissionIssue?
    ) -> String {
        switch issue {
        case .hostKeyTrustRequired:
            "Trust This Server?"
        case .verificationFailed, nil:
            "Couldn’t Add Server"
        case .saveFailed:
            "Server Wasn’t Saved"
        }
    }

    @ViewBuilder
    private func setupSubmissionIssueActions(
        _ issue: RemuxRootModel.ConnectionSetupState.SubmissionIssue,
        setupSessionID: UUID?
    ) -> some View {
        switch issue {
        case .hostKeyTrustRequired(let challenge):
            Button("Cancel", role: .cancel) {
                model.dismissSetupSubmissionIssue(issue)
            }
            if challenge.receivedKeyFingerprint != nil {
                Button(challenge.kind == .changed ? "Update Trust" : "Trust Server") {
                    if model.trustNewServerHostKey(
                        challenge,
                        setupSessionID: setupSessionID
                    ) {
                        saveConnectionSetupSheet()
                    }
                }
            }
        case .verificationFailed, .saveFailed:
            Button("OK", role: .cancel) {
                model.dismissSetupSubmissionIssue(issue)
            }
        }
    }

    private func setupSubmissionIssueMessage(
        _ issue: RemuxRootModel.ConnectionSetupState.SubmissionIssue
    ) -> String {
        switch issue {
        case .hostKeyTrustRequired(let challenge):
            sshHostKeyTrustMessage(for: challenge)
        case .verificationFailed(let message):
            message
        case .saveFailed:
            "Your details are still here. Try again."
        }
    }

    private var terminalNewSessionSetup: RemuxRootModel.ConnectionSetupState? {
        guard isSessionSwitcherPresented,
              let setup = model.connectionSetup,
              case .newWorkspace = setup.mode else {
            return nil
        }
        return setup
    }

    private func presentationDetents(
        for mode: RemuxRootModel.SetupMode
    ) -> Set<PresentationDetent> {
        switch mode {
        case .newServer, .editServer:
            [.large]
        case .newWorkspace, .editWorkspace:
            [.medium, .large]
        }
    }

    private func connectionSetupView(
        _ setup: RemuxRootModel.ConnectionSetupState,
        showsServerSummaryForNewSession: Bool,
        onSave: @escaping @MainActor () -> Void
    ) -> some View {
        let setupSessionID = model.setupSessionID
        return ConnectionSetupView(
            draft: setup.draft,
            validation: setup.validation,
            mode: setup.mode,
            setupSessionID: setupSessionID,
            terminalTheme: model.terminalSettings.theme,
            isActionInProgress: model.isSetupActionInProgress,
            showsServerSummaryForNewSession: showsServerSummaryForNewSession,
            onChange: model.updateDraft,
            onConnect: onSave,
            publicKeyInstallTarget: { draft in
                try model.publicKeyInstallTarget(for: draft)
            },
            preflightPublicKeyInstallation: { draft in
                try await model.preflightPublicKeyInstallation(
                    draft,
                    setupSessionID: setupSessionID
                )
            },
            appendPublicKey: { draft, password in
                try await model.appendPublicKey(
                    draft,
                    password: password,
                    setupSessionID: setupSessionID
                )
            },
            verifyPublicKeyInstallation: { draft in
                try await model.verifyPublicKeyInstallation(
                    draft,
                    setupSessionID: setupSessionID
                )
            },
            trustSetupHostKey: { challenge in
                try model.trustSetupHostKey(
                    challenge,
                    setupSessionID: setupSessionID
                )
            }
        )
    }

    private func saveConnectionSetupSheet() {
        Task {
            if let serverID = await model.saveAndConnect() {
                presentedServerID = serverID
            }
        }
    }

    private func saveSessionFromTerminal() {
        Task {
            _ = await model.saveAndConnect()
            if model.connectionSetup == nil {
                isSessionSwitcherPresented = false
            }
        }
    }

    private func cancelSessionSetupIfNeeded() {
        guard let mode = model.connectionSetup?.mode,
              case .newWorkspace = mode else { return }
        model.cancelSetup()
    }

    private var selectedTerminalID: SavedWorkspace.ID? {
        guard case .terminal(let id) = model.state else {
            return nil
        }

        return id
    }

    private var visibleTerminalID: SavedWorkspace.ID? {
        selectedTerminalID ?? retainedTerminalID ?? model.activeTerminalScreenEntries.first?.id
    }

    private var selectedActiveSession: ActiveTerminalSession? {
        guard let selectedTerminalID else { return nil }
        return model.activeSessions.first { $0.id == selectedTerminalID }
    }

    private var activeTerminalLayer: some View {
        ZStack {
            ForEach(model.activeTerminalScreenEntries) { entry in
                let isSelected = selectedTerminalID == entry.id
                let isVisible = visibleTerminalID == entry.id
                ActiveTerminalSessionView(
                    entry: entry,
                    isSelected: isSelected,
                    isAppSheetPresented: (isSessionSwitcherPresented || model.connectionSetup != nil)
                        && isSelected,
                    composer: composer,
                    shortcutStore: shortcutStore,
                    onReconnect: {
                        model.reconnectActiveSession(entry.id, source: .manualButton)
                    },
                    onUpdateCredentials: {
                        Task {
                            await model.beginCredentialRepair(for: entry.id)
                        }
                    },
                    onEditServer: {
                        Task {
                            await model.beginServerRepair(for: entry.id)
                        }
                    },
                    onTrustHostKey: {
                        model.trustHostKeyAndReconnect(entry.id)
                    },
                    onShowSessions: {
                        isSessionSwitcherPresented = true
                    },
                    onShowLibrary: {
                        dismissKeyboard()
                        Task { await model.showLibrary() }
                    }
                )
                .id(entry.instanceID)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
                .zIndex(isVisible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var routeLayer: some View {
        switch model.state {
        case .library:
            libraryStack

        case .terminal(let id):
            if !model.activeSessions.contains(where: { $0.id == id }) {
                libraryStack
            }

        case .loading, .failed:
            EmptyView()
        }
    }

    private var libraryStack: some View {
        NavigationStack {
            ConnectionLibraryView(
                snapshot: model.library,
                activeSessions: model.activeSessions,
                discoveryStates: model.tmuxSessionDiscoveryStates,
                terminalSettings: terminalSettingsBinding,
                shortcutStore: shortcutStore,
                presentedServerID: $presentedServerID,
                onAddServer: model.beginNewServer,
                onAddWorkspace: { serverID, showsServerSummary in
                    connectionSetupSheetShowsServerSummary = showsServerSummary
                    _ = model.beginNewWorkspace(for: serverID)
                },
                onEditServer: { serverID in
                    Task { await model.beginEditServer(serverID: serverID) }
                },
                onEditWorkspace: { serverID, workspaceID in
                    Task { await model.beginEditWorkspace(serverID: serverID, workspaceID: workspaceID) }
                },
                onConnect: { workspaceID in
                    traceSessionOpenTap(workspaceID)
                    Task { await model.connect(to: workspaceID) }
                },
                onConnectAvailableSession: { serverID, sessionName in
                    Task {
                        await model.connectToDiscoveredSession(
                            named: sessionName,
                            on: serverID
                        )
                    }
                },
                onRefreshServerSessions: { serverID in
                    await model.refreshTmuxSessionsAndWait(for: serverID)
                },
                onTrustDiscoveryHostKey: model.trustTmuxSessionDiscoveryHostKey,
                onShowActiveSession: { workspaceID in
                    GhosttyRuntimeTrace.flowBegin(
                        sessionShowFlowID(workspaceID),
                        event: "ui.tap.activeSession",
                        fields: ["workspaceID": workspaceID.uuidString]
                    )
                    model.showActiveSession(workspaceID)
                },
                onDisconnectActiveSession: model.disconnectActiveSession,
                onDeleteServer: { serverID in
                    Task { await model.deleteServer(serverID) }
                },
                onDeleteWorkspace: { workspaceID in
                    Task { await model.deleteWorkspace(workspaceID) }
                }
            )
        }
        .zIndex(2)
    }

    private var terminalSettingsBinding: Binding<TerminalSettings> {
        Binding(
            get: { model.terminalSettings },
            set: { settings in
                Task {
                    await model.updateTerminalSettings { current in
                        current = settings
                    }
                }
            }
        )
    }

    private func traceSessionOpenTap(_ workspaceID: SavedWorkspace.ID) {
        var fields = ["workspaceID": workspaceID.uuidString]
        if let workspace = model.library.workspace(id: workspaceID) {
            fields["session"] = workspace.sessionName
            if let server = model.library.server(id: workspace.serverID) {
                fields["server"] = server.displayName
                fields["host"] = server.host
            }
        }

        GhosttyRuntimeTrace.flowBegin(
            sessionOpenFlowID(workspaceID),
            event: "ui.tap.session",
            fields: fields
        )
    }

    private func sessionOpenFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.open.\(workspaceID.uuidString)"
    }

    private func sessionShowFlowID(_ workspaceID: SavedWorkspace.ID) -> String {
        "session.show.\(workspaceID.uuidString)"
    }

}

private extension View {
    func tailscaleSSHCheckAlert(
        request: Binding<TailscaleSSHCheckRequest?>,
        isActive: Bool
    ) -> some View {
        modifier(
            TailscaleSSHCheckAlertModifier(
                request: request,
                isActive: isActive
            )
        )
    }
}

private struct TailscaleSSHCheckAlertModifier: ViewModifier {
    @Binding var request: TailscaleSSHCheckRequest?
    @State private var browserRequest: TailscaleSSHCheckRequest?
    let isActive: Bool

    func body(content: Content) -> some View {
        content.alert(
            "Verify Tailscale SSH",
            isPresented: isPresented,
            presenting: request
        ) { request in
            Button("Open Browser") {
                browserRequest = request
            }
            Button("Cancel Connection", role: .cancel) {
                request.cancel()
            }
        } message: { _ in
            Text(
                "Tailscale requires verification for this SSH connection. " +
                "Complete it in your browser, then return to Remux."
            )
        }
        .sheet(item: $browserRequest) { request in
            TailscaleSSHVerificationBrowser(
                verificationURL: request.challenge.verificationURL
            )
            .ignoresSafeArea()
            .accessibilityIdentifier("tailscale-check.browser")
        }
        .onChange(of: request) { _, currentRequest in
            guard let browserRequest, browserRequest != currentRequest else { return }
            self.browserRequest = nil
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { isActive && request != nil && browserRequest == nil },
            set: { _ in }
        )
    }
}

private struct TailscaleSSHVerificationBrowser: UIViewControllerRepresentable {
    let verificationURL: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: verificationURL)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(
        _ uiViewController: SFSafariViewController,
        context: Context
    ) {
    }
}

struct RemuxAppLifecycleProjection: Equatable {
    let scenePhase: ScenePhase
    let appLifecyclePhase: GhosttyAppLifecyclePhase

    init(scenePhase: ScenePhase) {
        self.scenePhase = scenePhase
        switch scenePhase {
        case .active:
            self.appLifecyclePhase = .active
        case .inactive:
            self.appLifecyclePhase = .inactive
        case .background:
            self.appLifecyclePhase = .background
        @unknown default:
            self.appLifecyclePhase = .inactive
        }
    }
}

private struct ActiveTerminalSessionView: View {
    let entry: ActiveTerminalScreenEntry
    let isSelected: Bool
    let isAppSheetPresented: Bool
    let composer: GhosttyComposerModel
    let shortcutStore: ShortcutStore
    let onReconnect: () -> Void
    let onUpdateCredentials: () -> Void
    let onEditServer: () -> Void
    let onTrustHostKey: () -> Void
    let onShowSessions: () -> Void
    let onShowLibrary: () -> Void

    @StateObject private var previewSession: TerminalPreviewSession

    init(
        entry: ActiveTerminalScreenEntry,
        isSelected: Bool,
        isAppSheetPresented: Bool,
        composer: GhosttyComposerModel,
        shortcutStore: ShortcutStore,
        onReconnect: @escaping () -> Void,
        onUpdateCredentials: @escaping () -> Void,
        onEditServer: @escaping () -> Void,
        onTrustHostKey: @escaping () -> Void,
        onShowSessions: @escaping () -> Void,
        onShowLibrary: @escaping () -> Void
    ) {
        self.entry = entry
        self.isSelected = isSelected
        self.isAppSheetPresented = isAppSheetPresented
        self.composer = composer
        self.shortcutStore = shortcutStore
        self.onReconnect = onReconnect
        self.onUpdateCredentials = onUpdateCredentials
        self.onEditServer = onEditServer
        self.onTrustHostKey = onTrustHostKey
        self.onShowSessions = onShowSessions
        self.onShowLibrary = onShowLibrary
        _previewSession = StateObject(
            wrappedValue: TerminalPreviewSession(
                client: entry.model.terminalPreviewClient,
                serverDisplayName: entry.model.target.server.displayName
            )
        )
    }

    var body: some View {
        ZStack {
            GhosttySurfaceScreen(
                model: entry.model.terminalScreenAdapter,
                presentation: entry.presentation,
                isSelected: isSelected,
                composer: composer,
                isTerminalCovered: isAppSheetPresented || previewSession.isPresented,
                shortcutStore: shortcutStore,
                attachmentTransferServiceFactory: entry.attachmentTransferServiceFactory,
                onPreviewSelection: previewSelectionHandler,
                onReconnect: onReconnect,
                onShowSessions: onShowSessions,
                onShowLibrary: onShowLibrary,
                onUpdateCredentials: onUpdateCredentials,
                onEditServer: onEditServer,
                onTrustHostKey: onTrustHostKey
            )

            if previewSession.isPresented {
                TerminalPreviewView(
                    session: previewSession,
                    terminalTheme: entry.presentation.terminalTheme
                )
                .zIndex(1)
            }
        }
    }

    private func openPreview(
        _ candidate: TerminalPreviewCandidate,
        from surfaceID: UUID
    ) {
        previewSession.open(
            candidate,
            resolvingPathWith: entry.model.terminalPreviewPathResolver(
                for: candidate,
                from: surfaceID
            )
        )
    }

    private var previewSelectionHandler: ((UUID, TerminalPreviewCandidate) -> Void)? {
        guard previewSession.canOpenPreview else { return nil }
        return { surfaceID, candidate in
            openPreview(candidate, from: surfaceID)
        }
    }
}

private struct ConnectionLibraryView: View {
    private static let collapsedConnectedSessionCount = 3
    private static let collapsedRecentSessionCount = 5

    let snapshot: ConnectionLibrarySnapshot
    let activeSessions: [ActiveTerminalSession]
    let discoveryStates: [SavedServer.ID: TmuxSessionDiscoveryState]
    @Binding var terminalSettings: TerminalSettings
    let shortcutStore: ShortcutStore
    @Binding var presentedServerID: SavedServer.ID?
    let onAddServer: () -> Void
    let onAddWorkspace: (SavedServer.ID, Bool) -> Void
    let onEditServer: (SavedServer.ID) -> Void
    let onEditWorkspace: (SavedServer.ID, SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onConnectAvailableSession: (SavedServer.ID, String) -> Void
    let onRefreshServerSessions: (SavedServer.ID) async -> Void
    let onTrustDiscoveryHostKey: (SSHHostKeyTrustChallenge) -> Void
    let onShowActiveSession: (SavedWorkspace.ID) -> Void
    let onDisconnectActiveSession: (SavedWorkspace.ID) -> Void
    let onDeleteServer: (SavedServer.ID) -> Void
    let onDeleteWorkspace: (SavedWorkspace.ID) -> Void

    @State private var showsAllConnectedSessions = false
    @State private var showsAllRecentSessions = false

    var body: some View {
        let sessionProjection = SessionSwitcherProjection(
            snapshot: snapshot,
            activeSessions: activeSessions,
            discoveryStates: discoveryStates,
            selectedSessionID: nil
        )

        Group {
            if snapshot.servers.isEmpty {
                LibraryEmptyState(onAddServer: onAddServer)
            } else {
                List {
                    activeSessionsSection
                    serversSection(sessionProjection: sessionProjection)
                    recentSessionsSection
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("library.list")
            }
        }
        .libraryHomeGroupedScrollBackground()
        .libraryHomeChrome(theme: terminalSettings.theme)
        .task(id: terminalRendererWarmupID) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            GhosttyKitRuntime.prewarmTerminalRenderer(terminalSettings: terminalSettings)
        }
        .navigationTitle("Remux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    TerminalSettingsView(
                        settings: $terminalSettings,
                        shortcutStore: shortcutStore
                    )
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("library.settings")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onAddServer) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Server")
                .accessibilityIdentifier("library.add-server")
            }
        }
        .navigationDestination(isPresented: presentedServerIsActive) {
            if let presentedServerID,
               let server = snapshot.server(id: presentedServerID) {
                serverDetail(
                    for: server,
                    availableSessionNames: sessionProjection.availableSessionNames(on: server.id)
                )
            }
        }
    }

    private var presentedServerIsActive: Binding<Bool> {
        Binding(
            get: { presentedServerID != nil },
            set: { isActive in
                if !isActive {
                    presentedServerID = nil
                }
            }
        )
    }

    private var terminalRendererWarmupID: String {
        [
            terminalSettings.theme.rawValue,
            terminalSettings.fontSize.map(String.init(describing:)) ?? "default",
        ].joined(separator: ":")
    }

    @ViewBuilder
    private var activeSessionsSection: some View {
        if !sortedActiveSessions.isEmpty {
            Section {
                ForEach(visibleConnectedSessions) { session in
                    Button {
                        onShowActiveSession(session.id)
                    } label: {
                        ActiveSessionLibraryRow(session: session)
                            .accessibilityIdentifier("library.active-session.show")
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Disconnect") {
                            disconnectActiveSession(session.id)
                        }
                        .tint(.red)
                    }
                    .libraryHomeListRowSurface()
                }

                if sortedActiveSessions.count > Self.collapsedConnectedSessionCount {
                    Button {
                        withAnimation(.snappy) {
                            showsAllConnectedSessions.toggle()
                        }
                    } label: {
                        DisclosureRowLabel(
                            title: showsAllConnectedSessions ? "Show fewer" : "View all \(sortedActiveSessions.count)",
                            systemImage: showsAllConnectedSessions ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("library.connected-sessions.toggle")
                    .libraryHomeListRowSurface()
                }
            } header: {
                LibraryHomeSectionHeader("Active Sessions")
            }
        }
    }

    @ViewBuilder
    private var recentSessionsSection: some View {
        if !recentWorkspaces.isEmpty {
            Section {
                ForEach(visibleRecentWorkspaces) { workspace in
                    if let server = snapshot.server(id: workspace.serverID) {
                        Button {
                            onConnect(workspace.id)
                        } label: {
                            SessionLibraryRow(
                                server: server,
                                workspace: workspace,
                                runtimeState: nil,
                                subtitleMode: .serverAndLastOpened
                            )
                            .accessibilityIdentifier("library.session.resume")
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Edit") {
                                onEditWorkspace(server.id, workspace.id)
                            }
                            .tint(LibraryHomePalette.controlAccent)

                            Button("Delete", role: .destructive) {
                                onDeleteWorkspace(workspace.id)
                            }
                            .tint(.red)
                        }
                        .libraryHomeListRowSurface()
                    }
                }

                if recentWorkspaces.count > Self.collapsedRecentSessionCount {
                    Button {
                        withAnimation(.snappy) {
                            showsAllRecentSessions.toggle()
                        }
                    } label: {
                        DisclosureRowLabel(
                            title: showsAllRecentSessions ? "Show fewer" : "View all \(recentWorkspaces.count)",
                            systemImage: showsAllRecentSessions ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("library.recent-sessions.toggle")
                    .libraryHomeListRowSurface()
                }
            } header: {
                LibraryHomeSectionHeader("Recent Sessions")
            }
        }
    }

    private func serversSection(
        sessionProjection: SessionSwitcherProjection
    ) -> some View {
        Section {
            ForEach(snapshot.servers) { server in
                let workspaces = visibleWorkspaces(for: server.id)
                let latest = workspaces.first

                NavigationLink {
                    serverDetail(
                        for: server,
                        availableSessionNames: sessionProjection.availableSessionNames(on: server.id)
                    )
                } label: {
                    ServerLibraryRow(
                        server: server,
                        sessionCount: workspaces.count,
                        connectedSessionCount: connectedSessionCount(for: server.id),
                        latestWorkspace: latest
                    )
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("library.server.row")
                .contextMenu {
                    Button {
                        beginNewWorkspace(
                            for: server.id,
                            showsServerSummary: true
                        )
                    } label: {
                        Label("New Session", systemImage: "plus.square.on.square")
                    }

                    if let latest {
                        Button {
                            onConnect(latest.id)
                        } label: {
                            Label("Resume Latest", systemImage: "play.fill")
                        }
                    }

                    Button {
                        onEditServer(server.id)
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        onDeleteServer(server.id)
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        onDeleteServer(server.id)
                    }
                    .tint(.red)

                    if let latest {
                        Button("Resume") {
                            onConnect(latest.id)
                        }
                        .tint(LibraryHomePalette.controlAccent)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("New Session") {
                        beginNewWorkspace(
                            for: server.id,
                            showsServerSummary: true
                        )
                    }
                    .tint(LibraryHomePalette.controlAccent)
                }
                .libraryHomeListRowSurface()
            }
        } header: {
            LibraryHomeSectionHeader("Servers")
        }
    }

    private var sortedActiveSessions: [ActiveTerminalSession] {
        RemuxActiveSessionCollection.sortedForDisplay(activeSessions)
    }

    private var visibleConnectedSessions: [ActiveTerminalSession] {
        guard !showsAllConnectedSessions else { return sortedActiveSessions }
        return Array(sortedActiveSessions.prefix(Self.collapsedConnectedSessionCount))
    }

    private var activeWorkspaceIDs: Set<SavedWorkspace.ID> {
        Set(activeSessions.map(\.id))
    }

    private var recentWorkspaces: [SavedWorkspace] {
        snapshot.recentWorkspaces(excluding: activeWorkspaceIDs).filter {
            TmuxSessionReconciliation.includesSavedWorkspace(
                $0,
                discoveryStates: discoveryStates
            )
        }
    }

    private var visibleRecentWorkspaces: [SavedWorkspace] {
        guard !showsAllRecentSessions else { return recentWorkspaces }
        return Array(recentWorkspaces.prefix(Self.collapsedRecentSessionCount))
    }

    private func connectedSessionCount(for serverID: SavedServer.ID) -> Int {
        activeSessions.filter {
            $0.target.server.id == serverID
                && TerminalRuntimeStateProjection.isRootVisibleConnected($0.runtimeState)
        }.count
    }

    private func visibleWorkspaces(for serverID: SavedServer.ID) -> [SavedWorkspace] {
        snapshot.workspaces(for: serverID).filter { workspace in
            activeWorkspaceIDs.contains(workspace.id)
                || TmuxSessionReconciliation.includesSavedWorkspace(
                    workspace,
                    discoveryStates: discoveryStates
                )
        }
    }

    private func serverDetail(
        for server: SavedServer,
        availableSessionNames: [String]
    ) -> some View {
        ServerDetailView(
            server: server,
            workspaces: visibleWorkspaces(for: server.id),
            activeSessions: activeSessions.filter { $0.target.server.id == server.id },
            discoveryState: discoveryStates[server.id] ?? .idle,
            availableSessionNames: availableSessionNames,
            onAddWorkspace: { serverID in
                beginNewWorkspace(
                    for: serverID,
                    showsServerSummary: false
                )
            },
            onEditServer: onEditServer,
            onEditWorkspace: onEditWorkspace,
            onConnect: onConnect,
            onConnectAvailableSession: onConnectAvailableSession,
            onRefreshSessions: onRefreshServerSessions,
            onTrustHostKey: onTrustDiscoveryHostKey,
            onDeleteWorkspace: onDeleteWorkspace,
            terminalTheme: terminalSettings.theme
        )
    }

    private func beginNewWorkspace(
        for serverID: SavedServer.ID,
        showsServerSummary: Bool
    ) {
        onAddWorkspace(serverID, showsServerSummary)
    }

    private func disconnectActiveSession(_ sessionID: SavedWorkspace.ID) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            onDisconnectActiveSession(sessionID)
        }
    }
}

private extension View {
    @ViewBuilder
    func connectionSetupListRowSurface(usesLibraryChrome: Bool) -> some View {
        if usesLibraryChrome {
            remuxAppListRowSurface()
        } else {
            listRowBackground(Color.clear)
                .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
        }
    }

    @ViewBuilder
    func connectionSetupChrome(
        usesLibraryChrome: Bool,
        theme: TerminalTheme
    ) -> some View {
        if usesLibraryChrome {
            remuxAppGroupedScrollBackground()
                .remuxAppChrome(theme: theme)
        } else {
            scrollContentBackground(.hidden)
        }
    }
}

private struct LibraryHomeSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LibraryHomePalette.sectionHeader)
            .textCase(nil)
    }
}

private struct ServerDetailView: View {
    private static let collapsedWorkspaceCount = 3
    private static let maximumInlineAvailableSessionCount = 3

    let server: SavedServer
    let workspaces: [SavedWorkspace]
    let activeSessions: [ActiveTerminalSession]
    let discoveryState: TmuxSessionDiscoveryState
    let availableSessionNames: [String]
    let onAddWorkspace: (SavedServer.ID) -> Void
    let onEditServer: (SavedServer.ID) -> Void
    let onEditWorkspace: (SavedServer.ID, SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onConnectAvailableSession: (SavedServer.ID, String) -> Void
    let onRefreshSessions: (SavedServer.ID) async -> Void
    let onTrustHostKey: (SSHHostKeyTrustChallenge) -> Void
    let onDeleteWorkspace: (SavedWorkspace.ID) -> Void
    let terminalTheme: TerminalTheme

    @State private var isReviewingHostKey = false
    @State private var showsAllWorkspaces = false

    var body: some View {
        List {
            Section("Connection") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Address")

                    Text(server.displayAddress)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                LabeledContent("Sessions") {
                    Text(
                        serverSummary(
                            sessionCount: workspaces.count,
                            connectedSessionCount: activeSessions.filter {
                                TerminalRuntimeStateProjection.isRootVisibleConnected($0.runtimeState)
                            }.count,
                            latestWorkspace: nil
                        )
                    )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .libraryHomeListRowSurface()

            Section("Sessions") {
                if workspaces.isEmpty {
                    Text("No Sessions Added to Remux")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onAddWorkspace(server.id)
                    } label: {
                        Label("New Session", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("library.server.new-session.empty")
                } else {
                    ForEach(visibleWorkspaces) { workspace in
                        Button {
                            onConnect(workspace.id)
                        } label: {
                            SessionLibraryRow(
                                server: server,
                                workspace: workspace,
                                runtimeState: activeSession(for: workspace.id)?.runtimeState,
                                subtitleMode: .lastOpenedOnly
                            )
                            .accessibilityIdentifier("library.session.resume")
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Edit") {
                                onEditWorkspace(server.id, workspace.id)
                            }
                            .tint(LibraryHomePalette.controlAccent)

                            Button("Delete", role: .destructive) {
                                onDeleteWorkspace(workspace.id)
                            }
                            .tint(.red)
                        }
                    }

                    if workspaces.count > Self.collapsedWorkspaceCount {
                        Button {
                            withAnimation(.snappy) {
                                showsAllWorkspaces.toggle()
                            }
                        } label: {
                            DisclosureRowLabel(
                                title: showsAllWorkspaces ? "Show fewer" : "Show more",
                                systemImage: showsAllWorkspaces ? "chevron.up" : "chevron.down"
                            )
                        }
                        .accessibilityIdentifier("library.server.sessions.toggle")
                    }
                }
            }
            .libraryHomeListRowSurface()

            availableSessionsSection
        }
        .listStyle(.insetGrouped)
        .libraryHomeGroupedScrollBackground()
        .libraryHomeChrome(theme: terminalTheme)
        .refreshable {
            await onRefreshSessions(server.id)
        }
        .task(id: server.id) {
            guard discoveryState.phase == .idle else { return }
            await onRefreshSessions(server.id)
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("library.server.detail")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    onEditServer(server.id)
                } label: {
                    Text("Edit")
                }
                .accessibilityLabel("Edit Server")
                .accessibilityIdentifier("library.server.edit")

                Button {
                    onAddWorkspace(server.id)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("library.server.new-session.toolbar")
            }
        }
        .alert(
            "Trust This Server?",
            isPresented: $isReviewingHostKey,
            presenting: discoveryState.hostKeyChallenge
        ) { challenge in
            Button("Cancel", role: .cancel) {}
            if challenge.receivedKeyFingerprint != nil {
                Button(challenge.kind == .changed ? "Update Trust" : "Trust Server") {
                    onTrustHostKey(challenge)
                }
            }
        } message: { challenge in
            Text(sshHostKeyTrustMessage(for: challenge))
        }
    }

    private var activeWorkspaceIDs: Set<SavedWorkspace.ID> {
        Set(activeSessions.map(\.id))
    }

    private func activeSession(for workspaceID: SavedWorkspace.ID) -> ActiveTerminalSession? {
        activeSessions.first { $0.id == workspaceID }
    }

    private var visibleWorkspaces: [SavedWorkspace] {
        guard !showsAllWorkspaces else { return workspaces }
        return Array(workspaces.prefix(Self.collapsedWorkspaceCount))
    }

    private var inlineAvailableSessionNames: [String] {
        Array(availableSessionNames.prefix(Self.maximumInlineAvailableSessionCount))
    }

    @ViewBuilder
    private var availableSessionsSection: some View {
        Section {
            if discoveryState.isLoading || discoveryState.phase == .idle {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking sessions…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("library.server.available.loading")
            }

            if discoveryState.phase == .failed {
                discoveryFailureRow
            }

            ForEach(inlineAvailableSessionNames, id: \.self) { sessionName in
                Button {
                    onConnectAvailableSession(server.id, sessionName)
                } label: {
                    AvailableServerSessionRow(sessionName: sessionName)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.server.available.session")
            }

            if availableSessionNames.count > Self.maximumInlineAvailableSessionCount {
                NavigationLink {
                    ServerAvailableSessionsView(
                        sessionNames: availableSessionNames,
                        terminalTheme: terminalTheme,
                        onSelect: { sessionName in
                            onConnectAvailableSession(server.id, sessionName)
                        }
                    )
                } label: {
                    DisclosureRowLabel(
                        title: "View all \(availableSessionNames.count)",
                        systemImage: "magnifyingglass"
                    )
                }
                .accessibilityIdentifier("library.server.available.view-all")
            } else if discoveryState.phase == .loaded,
                      availableSessionNames.isEmpty {
                Text("No other sessions found")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.server.available.empty")
            }
        } header: {
            LibraryHomeSectionHeader("Available on Server")
        } footer: {
            if !availableSessionNames.isEmpty {
                Text("Select a session to add it to Remux.")
            }
        }
        .libraryHomeListRowSurface()
    }

    @ViewBuilder
    private var discoveryFailureRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                discoveryState.hostKeyChallenge == nil
                    ? "Couldn’t check sessions"
                    : "Trust the SSH host key to check sessions",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)

            if discoveryState.hostKeyChallenge != nil {
                Button("Review SSH Host Key") {
                    isReviewingHostKey = true
                }
                .accessibilityIdentifier("library.server.available.review-host-key")
            } else {
                Button("Retry") {
                    Task { await onRefreshSessions(server.id) }
                }
                .accessibilityIdentifier("library.server.available.retry")
            }
        }
        .padding(.vertical, 2)
    }

}

private func sshHostKeyTrustMessage(for challenge: SSHHostKeyTrustChallenge) -> String {
    guard let fingerprint = challenge.receivedKeyFingerprint else {
        return "Remux couldn’t verify the SSH host key for \(challenge.host), so trust is unavailable."
    }
    if challenge.kind == .changed {
        return "The SSH host key for \(challenge.host) changed. Update trust only if this fingerprint is correct:\n\n\(fingerprint)"
    }
    return "Trust only if this fingerprint matches \(challenge.host):\n\n\(fingerprint)"
}

private struct AvailableServerSessionRow: View {
    let sessionName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LibraryHomePalette.rowIconForeground)
                .frame(width: 30, height: 30)
                .background(
                    LibraryHomePalette.rowIconSurface,
                    in: RoundedRectangle(cornerRadius: 7)
                )

            Text(sessionName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sessionName)
        .accessibilityHint("Add this session to Remux")
        .accessibilityAddTraits(.isButton)
    }
}

private struct ServerAvailableSessionsView: View {
    let sessionNames: [String]
    let terminalTheme: TerminalTheme
    let onSelect: (String) -> Void

    @State private var query = ""

    var body: some View {
        List {
            Section {
                ForEach(filteredSessionNames, id: \.self) { sessionName in
                    Button {
                        onSelect(sessionName)
                    } label: {
                        AvailableServerSessionRow(sessionName: sessionName)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.server.available.result")
                }

                if filteredSessionNames.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                }
            }
            .libraryHomeListRowSurface()
        }
        .listStyle(.insetGrouped)
        .libraryHomeGroupedScrollBackground()
        .libraryHomeChrome(theme: terminalTheme)
        .navigationTitle("Available Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search sessions")
    }

    private var filteredSessionNames: [String] {
        guard !query.isEmpty else { return sessionNames }
        return sessionNames.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }
}

struct DisclosureRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryEmptyState: View {
    let onAddServer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("No servers")
            } icon: {
                Image(systemName: "server.rack")
            }
        } description: {
            Text("Add an SSH server to start using tmux sessions from this phone.")
        } actions: {
            LibraryEmptyAddServerButton(action: onAddServer)
        }
        .tint(LibraryHomePalette.controlAccent)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -48)
    }
}

private struct LibraryEmptyAddServerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add Server", systemImage: "plus")
        }
        .fontWeight(.semibold)
        .controlSize(.large)
        .libraryEmptyPrimaryAction()
        .accessibilityIdentifier("library.empty.add-server")
    }
}

private extension View {
    @ViewBuilder
    func libraryEmptyPrimaryAction() -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .tint(LibraryHomePalette.controlAccent)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(LibraryHomePalette.controlAccent)
        }
    }
}

private struct ActiveSessionLibraryRow: View {
    let session: ActiveTerminalSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LibraryHomePalette.rowIconForeground)
                .frame(width: 30, height: 30)
                .background(LibraryHomePalette.rowIconSurface, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.target.workspace.sessionName)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.target.server.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TerminalRuntimeStateIndicator(state: session.runtimeState)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SessionLibraryRow: View {
    enum SubtitleMode: Equatable {
        case serverAndLastOpened
        case lastOpenedOnly
    }

    let server: SavedServer
    let workspace: SavedWorkspace
    let runtimeState: TerminalRuntimeState?
    let subtitleMode: SubtitleMode
    var iconForeground: Color = LibraryHomePalette.rowIconForeground
    var iconBackground: Color = LibraryHomePalette.rowIconSurface

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(iconForeground)
                .frame(width: 30, height: 30)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.sessionName)
                    .font(.headline)
                    .lineLimit(1)

                subtitle
            }

            Spacer()

            if let runtimeState {
                TerminalRuntimeStateIndicator(state: runtimeState)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch subtitleMode {
        case .serverAndLastOpened:
            HStack(spacing: 6) {
                Text(server.displayName)
                SessionLastOpenedText(date: workspace.lastOpenedAt)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        case .lastOpenedOnly:
            SessionLastOpenedText(date: workspace.lastOpenedAt)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ServerLibraryRow: View {
    let server: SavedServer
    let sessionCount: Int
    let connectedSessionCount: Int
    let latestWorkspace: SavedWorkspace?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LibraryHomePalette.rowIconForeground)
                .frame(width: 30, height: 30)
                .background(LibraryHomePalette.rowIconSurface, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(server.displayAddress)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Text(
                    serverSummary(
                        sessionCount: sessionCount,
                        connectedSessionCount: connectedSessionCount,
                        latestWorkspace: latestWorkspace
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private func serverSummary(
    sessionCount: Int,
    connectedSessionCount: Int,
    latestWorkspace: SavedWorkspace?
) -> String {
    var parts = [
        "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"
    ]

    if connectedSessionCount > 0 {
        parts.append("\(connectedSessionCount) connected")
    }

    if let latestWorkspace {
        parts.append("latest \(latestWorkspace.sessionName)")
    }

    return parts.joined(separator: " · ")
}

private struct TerminalSettingsView: View {
    @Binding private var sourceSettings: TerminalSettings
    private let shortcutStore: ShortcutStore
    @State private var settings: TerminalSettings

    init(
        settings: Binding<TerminalSettings>,
        shortcutStore: ShortcutStore
    ) {
        _sourceSettings = settings
        self.shortcutStore = shortcutStore
        _settings = State(initialValue: settings.wrappedValue)
    }

    var body: some View {
        Form {
            Section("Font") {
                Toggle("Use default size", isOn: useDefaultFontBinding)
                    .tint(LibraryHomePalette.controlAccent)
                    .accessibilityIdentifier("settings.use-default-font")

                Stepper(
                    value: explicitFontSizeBinding,
                    in: Double(TerminalSettings.minimumFontSize)...Double(TerminalSettings.maximumFontSize),
                    step: 1
                ) {
                    LabeledContent("Font size") {
                        Text(Int(settings.fontSize ?? TerminalSettings.defaultExplicitFontSize), format: .number)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(settings.fontSize == nil ? .secondary : .primary)
                    }
                    .accessibilityIdentifier("settings.font-size")
                }
                .disabled(settings.fontSize == nil)
                .accessibilityIdentifier("settings.font-size.stepper")
            }
            .libraryHomeListRowSurface()

            Section("Theme") {
                Picker("Terminal theme", selection: themeBinding) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.pickerTitle).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.theme")

                TerminalThemePreviewPanel(settings: settings)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
            }
            .libraryHomeListRowSurface()

            Section {
                Toggle(
                    "Zoom multipane windows",
                    isOn: zoomMultipaneWindowsByDefaultBinding
                )
                .tint(LibraryHomePalette.controlAccent)
                .accessibilityIdentifier("settings.zoom-multipane-windows-by-default")
            } header: {
                Text("Windows & Panes")
            } footer: {
                Text(
                    "You can override this per window from Panes. Remux normally clears zooms "
                        + "it applied when closing. If one remains on the server, use prefix + z."
                )
            }
            .libraryHomeListRowSurface()

            Section("Keyboard") {
                NavigationLink {
                    TerminalToolbarKeysSettingsView(
                        toolbarKeys: toolbarKeysBinding,
                        theme: settings.theme
                    )
                } label: {
                    Label {
                        LabeledContent("Toolbar Keys") {
                            Text(settings.toolbarKeys.compactSummary)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "keyboard.badge.ellipsis")
                    }
                }
                .accessibilityIdentifier("settings.toolbar-keys")
                .accessibilityValue(settings.toolbarKeys.summary)

                NavigationLink {
                    ShortcutsSettingsView(
                        store: shortcutStore,
                        theme: settings.theme
                    )
                } label: {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .accessibilityIdentifier("settings.shortcuts")
            }
            .libraryHomeListRowSurface()

            Section {
                Toggle("Allow older RSA host keys", isOn: allowInsecureRSAHostKeysBinding)
                    .tint(LibraryHomePalette.controlAccent)
                    .accessibilityIdentifier("settings.allow-insecure-rsa")
                    .accessibilityHint(
                        "Allows legacy RSA host-key signatures using SHA-1; "
                            + "host identity is still verified."
                    )
            } header: {
                Text("Security")
            } footer: {
                Text(
                    "For servers that only support ssh-rsa (SHA-1). Enabling takes effect "
                        + "immediately; disabling takes effect after restarting Remux."
                )
            }
            .libraryHomeListRowSurface()
        }
        .libraryHomeGroupedScrollBackground()
        .libraryHomeChrome(theme: settings.theme)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.form")
        .onAppear {
            settings = sourceSettings
        }
        .onChange(of: sourceSettings) { previousSettings, updatedSettings in
            guard settings == previousSettings else { return }
            settings = updatedSettings
        }
    }

    private var useDefaultFontBinding: Binding<Bool> {
        Binding(
            get: { settings.fontSize == nil },
            set: { useDefault in
                settings.fontSize = useDefault ? nil : TerminalSettings.defaultExplicitFontSize
                sourceSettings = settings
            }
        )
    }

    private var explicitFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.fontSize ?? TerminalSettings.defaultExplicitFontSize) },
            set: { value in
                settings.fontSize = Float32(value)
                sourceSettings = settings
            }
        )
    }

    private var themeBinding: Binding<TerminalTheme> {
        Binding(
            get: { settings.theme },
            set: { value in
                settings.theme = value
                sourceSettings = settings
            }
        )
    }

    private var allowInsecureRSAHostKeysBinding: Binding<Bool> {
        Binding(
            get: { settings.allowInsecureRSAHostKeys },
            set: { value in
                settings.allowInsecureRSAHostKeys = value
                sourceSettings = settings
            }
        )
    }

    private var zoomMultipaneWindowsByDefaultBinding: Binding<Bool> {
        Binding(
            get: { settings.zoomMultipaneWindowsByDefault },
            set: { value in
                settings.zoomMultipaneWindowsByDefault = value
                sourceSettings = settings
            }
        )
    }

    private var toolbarKeysBinding: Binding<TerminalToolbarKeys> {
        Binding(
            get: { settings.toolbarKeys },
            set: { value in
                settings.toolbarKeys = value
                sourceSettings = settings
            }
        )
    }
}

private struct TerminalToolbarKeysSettingsView: View {
    @Binding var toolbarKeys: TerminalToolbarKeys
    let theme: TerminalTheme

    var body: some View {
        Form {
            Section {
                toolbarKeyPicker(
                    "First Key",
                    selection: binding(for: \.first),
                    identifier: "settings.toolbar-keys.slot.0"
                )
                toolbarKeyPicker(
                    "Second Key",
                    selection: binding(for: \.second),
                    identifier: "settings.toolbar-keys.slot.1"
                )
                toolbarKeyPicker(
                    "Third Key",
                    selection: binding(for: \.third),
                    identifier: "settings.toolbar-keys.slot.2"
                )
            } header: {
                Text("Key Layout")
            } footer: {
                Text(
                    "These keys appear on the left side of the terminal toolbar. "
                        + "Touch and hold the first key to open Shortcuts."
                )
            }
            .libraryHomeListRowSurface()

            if toolbarKeys != .default {
                Section {
                    Button("Reset to Defaults") {
                        toolbarKeys = .default
                    }
                    .accessibilityIdentifier("settings.toolbar-keys.reset")
                }
                .libraryHomeListRowSurface()
            }
        }
        .libraryHomeGroupedScrollBackground()
        .libraryHomeChrome(theme: theme)
        .navigationTitle("Toolbar Keys")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.toolbar-keys.form")
    }

    private func toolbarKeyPicker(
        _ title: String,
        selection: Binding<TerminalToolbarKey>,
        identifier: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(TerminalToolbarKey.allCases, id: \.self) { key in
                Text(key.settingsTitle).tag(key)
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier(identifier)
    }

    private func binding(
        for keyPath: WritableKeyPath<TerminalToolbarKeys, TerminalToolbarKey>
    ) -> Binding<TerminalToolbarKey> {
        Binding(
            get: { toolbarKeys[keyPath: keyPath] },
            set: { value in
                toolbarKeys[keyPath: keyPath] = value
            }
        )
    }
}

private struct TerminalThemePreviewPanel: View {
    @StateObject private var renderer = TerminalThemePreviewRenderer()
    @Environment(\.displayScale) private var displayScale

    let settings: TerminalSettings

    private let previewHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview")
                    .font(.headline)

                Spacer()

                Text(settings.theme.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let pointSize = CGSize(
                    width: max(proxy.size.width, 1),
                    height: previewHeight
                )

                TerminalThemePreviewSurface(
                    state: renderer.state,
                    settings: settings
                )
                .task(id: renderTaskID(pointSize: pointSize)) {
                    renderer.render(
                        settings: settings,
                        pointSize: pointSize,
                        scale: displayScale
                    )
                }
            }
            .frame(height: previewHeight)
        }
        .accessibilityIdentifier("settings.theme.preview")
    }

    private func renderTaskID(pointSize: CGSize) -> String {
        [
            settings.theme.id,
            settings.fontSize.map { String($0) } ?? "default",
            String(Int(pointSize.width.rounded(.down))),
            String(Int(pointSize.height.rounded(.down))),
            String(Int(displayScale.rounded(.toNearestOrAwayFromZero))),
        ].joined(separator: ":")
    }
}

private struct TerminalThemePreviewSurface: View {
    let state: TerminalThemePreviewRenderer.State
    let settings: TerminalSettings

    var body: some View {
        ZStack {
            Color(uiColor: settings.theme.terminalBackgroundUIColor)

            switch state {
            case .idle:
                ProgressView()
                    .controlSize(.small)

            case .ready(let content):
                TerminalThemePreviewContentView(content: content)
                    .id(ObjectIdentifier(content))

            case .failed:
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SSHPublicKeyInstallRequest: Identifiable {
    let id = UUID()
    let draft: TmuxConnectionDraft
    let target: SSHPublicKeyInstallTarget
    let setupSessionID: UUID
}

struct ConnectionSetupView: View {
    let draft: TmuxConnectionDraft
    let validation: TmuxConnectionDraftValidation
    let mode: RemuxRootModel.SetupMode
    let setupSessionID: UUID?
    let terminalTheme: TerminalTheme
    let isActionInProgress: Bool
    let showsServerSummaryForNewSession: Bool
    let onChange: ((inout TmuxConnectionDraft) -> Void) -> Void
    let onConnect: () -> Void
    let publicKeyInstallTarget: (
        TmuxConnectionDraft
    ) throws -> SSHPublicKeyInstallTarget
    let preflightPublicKeyInstallation: @MainActor (
        TmuxConnectionDraft
    ) async throws -> SSHPublicKeyPreflightOutcome
    let appendPublicKey: @MainActor (TmuxConnectionDraft, String) async throws -> Void
    let verifyPublicKeyInstallation: @MainActor (TmuxConnectionDraft) async throws -> Void
    let trustSetupHostKey: @MainActor (SSHHostKeyTrustChallenge) throws -> Void

    enum Field: Hashable {
        case displayName
        case host
        case port
        case username
        case tmuxExecutablePath
        case password
        case privateKeyPassphrase
        case sessionName
    }

    @State private var privateKeyImportError: String?
    @State private var publicKeyCopyMessage: String?
    @State private var publicKeyInstallRequest: SSHPublicKeyInstallRequest?
    @State private var publicKeyInstallConfirmation: SSHPublicKeyInstallConfirmation?
    @FocusState private var focusedField: Field?

    var body: some View {
        Form(content: {
            if showsEditableServerFields {
                Section {
                    textInputRow(
                        title: "Name",
                        placeholder: "Mac mini",
                        keyPath: \.displayName,
                        field: .displayName,
                        validationMessage: validation.displayName,
                        textInputAutocapitalization: .never,
                        autocorrectionDisabled: false,
                        accessibilityIdentifier: "connection.name"
                    )

                    textInputRow(
                        title: "IP or Hostname",
                        placeholder: "server.local or 100.64.0.10",
                        keyPath: \.host,
                        field: .host,
                        validationMessage: validation.host,
                        textStyle: .monospaced,
                        keyboardType: .URL,
                        accessibilityIdentifier: "connection.host"
                    )

                    textInputRow(
                        title: "Port",
                        placeholder: "22",
                        keyPath: \.port,
                        field: .port,
                        validationMessage: validation.port,
                        textStyle: .monospaced,
                        keyboardType: .numberPad,
                        accessibilityIdentifier: "connection.port"
                    )

                    textInputRow(
                        title: "User",
                        placeholder: "macbook",
                        keyPath: \.username,
                        field: .username,
                        validationMessage: validation.username,
                        textStyle: .monospaced,
                        accessibilityIdentifier: "connection.username"
                    )

                } header: {
                    Text("Server")
                } footer: {
                    if let serverSectionFooter {
                        Text(serverSectionFooter)
                    }
                }
                .connectionSetupListRowSurface(usesLibraryChrome: showsEditableServerFields)
            }

            if showsServerSummary {
                Section("Server") {
                    ConnectionServerSummaryRow(draft: draft)
                }
                .connectionSetupListRowSurface(usesLibraryChrome: showsEditableServerFields)
            }

            if showsAuthenticationFields {
                Section {
                    Picker("Method", selection: authenticationKindBinding) {
                        Text("Password").tag(SSHAuthenticationKind.password)
                        Text("Private Key").tag(SSHAuthenticationKind.privateKey)
                        Text("Tailscale SSH").tag(SSHAuthenticationKind.none)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("connection.authentication.method")

                    switch draft.authenticationKind {
                    case .password:
                        passwordInputRow(validationMessage: validation.password)
                    case .privateKey:
                        privateKeyInputRows()
                    case .none:
                        tailscaleAuthenticationRow()
                    }
                } header: {
                    Text("Authentication")
                }
                .connectionSetupListRowSurface(usesLibraryChrome: showsEditableServerFields)
            }

            if showsEditableServerFields {
                Section {
                    tmuxExecutableInputRow()
                } header: {
                    Text("tmux")
                }
                .connectionSetupListRowSurface(usesLibraryChrome: showsEditableServerFields)
            } else if showsSessionFields {
                Section {
                    sessionNameInputRow(title: "Name")
                } header: {
                    Text("Session")
                } footer: {
                    Text(sessionSectionFooter)
                }
                .connectionSetupListRowSurface(usesLibraryChrome: showsEditableServerFields)
            }
        })
        .disabled(isActionInProgress)
        .connectionSetupChrome(
            usesLibraryChrome: showsEditableServerFields,
            theme: terminalTheme
        )
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    submitIfPossible()
                } label: {
                    if isActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(primaryActionTitle)
                    }
                }
                .fontWeight(.semibold)
                .disabled(!canSubmit || isActionInProgress)
                .accessibilityIdentifier("connection.save")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    dismissKeyboard()
                } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                }
            }
        }
        .fileImporter(
            isPresented: $isPrivateKeyImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: handlePrivateKeyImport
        )
        .navigationDestination(isPresented: publicKeyInstallIsPresented) {
            if let request = publicKeyInstallRequest {
                SSHPublicKeyInstallSheet(
                    draft: request.draft,
                    target: request.target,
                    setupSessionID: request.setupSessionID,
                    onPreflight: preflightPublicKeyInstallation,
                    onAppend: appendPublicKey,
                    onVerify: verifyPublicKeyInstallation,
                    onTrustHostKey: trustSetupHostKey,
                    onSuccess: { completion in
                        acceptPublicKeyInstallCompletion(completion)
                        publicKeyInstallRequest = nil
                    }
                )
            }
        }
    }

    @State private var isPrivateKeyImporterPresented = false

    private var publicKeyInstallIsPresented: Binding<Bool> {
        Binding(
            get: { publicKeyInstallRequest != nil },
            set: { isPresented in
                if !isPresented {
                    publicKeyInstallRequest = nil
                }
            }
        )
    }

    private func advance(from field: Field) {
        if let next = nextField(after: field) {
            focusedField = next
        } else {
            focusedField = nil
            submitIfPossible()
        }
    }

    private func nextField(after field: Field) -> Field? {
        switch field {
        case .displayName:
            return .host
        case .host:
            return .port
        case .port:
            return .username
        case .username:
            if showsAuthenticationFields {
                switch draft.authenticationKind {
                case .password:
                    return .password
                case .privateKey:
                    return .privateKeyPassphrase
                case .none:
                    break
                }
            }
            if showsEditableServerFields { return .tmuxExecutablePath }
            if showsSessionFields { return .sessionName }
            return nil
        case .password, .privateKeyPassphrase:
            if showsEditableServerFields { return .tmuxExecutablePath }
            return showsSessionFields ? .sessionName : nil
        case .tmuxExecutablePath:
            return showsSessionFields ? .sessionName : nil
        case .sessionName:
            return nil
        }
    }

    private func submitIfPossible() {
        guard canSubmit else {
            Haptic.error()
            return
        }
        Haptic.tap()
        dismissKeyboard()
        onConnect()
    }

    private var canSubmit: Bool {
        switch mode {
        case .newServer:
            if case .valid = TmuxConnectionDraftValidator.validateServer(
                draft,
                existingServerID: nil
            ) {
                return true
            }
            return false

        case .newWorkspace(let serverID):
            if case .valid = TmuxConnectionDraftValidator.validateWorkspace(
                draft,
                serverID: serverID,
                existingWorkspaceID: nil
            ) {
                return true
            }
            return false

        case .editServer(let serverID, _):
            if case .valid = TmuxConnectionDraftValidator.validateServer(
                draft,
                existingServerID: serverID
            ) {
                return true
            }
            return false

        case .editWorkspace(let serverID, let workspaceID):
            if case .valid = TmuxConnectionDraftValidator.validateWorkspace(
                draft,
                serverID: serverID,
                existingWorkspaceID: workspaceID
            ) {
                return true
            }
            return false
        }
    }

    private var existingServerID: SavedServer.ID? {
        switch mode {
        case .newServer:
            return nil
        case .newWorkspace(let id):
            return id
        case .editServer(let id, _):
            return id
        case .editWorkspace(let id, _):
            return id
        }
    }

    private var existingWorkspaceID: SavedWorkspace.ID? {
        switch mode {
        case .newServer, .newWorkspace:
            return nil
        case .editServer(_, let reconnectWorkspaceID):
            return reconnectWorkspaceID
        case .editWorkspace(_, let id):
            return id
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .newServer:
            "New Server"
        case .newWorkspace:
            "New Session"
        case .editServer:
            "Edit Server"
        case .editWorkspace:
            "Edit Session"
        }
    }

    private var showsEditableServerFields: Bool {
        switch mode {
        case .newServer, .editServer:
            true
        case .newWorkspace, .editWorkspace:
            false
        }
    }

    private var showsServerSummary: Bool {
        switch mode {
        case .newServer, .editServer:
            false
        case .newWorkspace:
            showsServerSummaryForNewSession
        case .editWorkspace:
            true
        }
    }

    private var showsAuthenticationFields: Bool {
        switch mode {
        case .newServer, .editServer:
            true
        case .newWorkspace, .editWorkspace:
            false
        }
    }

    private var showsSessionFields: Bool {
        switch mode {
        case .newWorkspace, .editWorkspace:
            true
        case .newServer, .editServer:
            false
        }
    }

    private var serverSectionFooter: String? {
        switch mode {
        case .newServer:
            nil
        case .editServer:
            "Updates the saved endpoint for future connections."
        case .newWorkspace, .editWorkspace:
            nil
        }
    }

    private var sessionSectionFooter: String {
        switch mode {
        case .newWorkspace:
            "Names a tmux session on this server. Reuse a name to attach to an existing session."
        case .editWorkspace:
            "Renaming applies the next time you connect."
        case .newServer, .editServer:
            ""
        }
    }

    private enum ConnectionFieldTextStyle {
        case standard
        case monospaced

        var font: Font {
            switch self {
            case .standard:
                .body
            case .monospaced:
                .body.monospaced()
            }
        }
    }

    private func textInputRow(
        title: String,
        placeholder: String,
        keyPath: WritableKeyPath<TmuxConnectionDraft, String>,
        field: Field,
        validationMessage: String?,
        textStyle: ConnectionFieldTextStyle = .standard,
        textInputAutocapitalization: TextInputAutocapitalization = .never,
        autocorrectionDisabled: Bool = true,
        keyboardType: UIKeyboardType = .default,
        submitLabel: SubmitLabel = .next,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: binding(for: keyPath))
                .textInputAutocapitalization(textInputAutocapitalization)
                .autocorrectionDisabled(autocorrectionDisabled)
                .keyboardType(keyboardType)
                .font(textStyle.font)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: field)
                .submitLabel(submitLabel)
                .onSubmit { advance(from: field) }
                .accessibilityIdentifier(accessibilityIdentifier)

            fieldValidationMessage(validationMessage)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = field
        }
    }

    private func tmuxExecutableInputRow() -> some View {
        textInputRow(
            title: "Executable Path (Optional)",
            placeholder: "/absolute/path/to/tmux",
            keyPath: \.tmuxExecutablePath,
            field: .tmuxExecutablePath,
            validationMessage: validation.tmuxExecutablePath,
            textStyle: .monospaced,
            keyboardType: .URL,
            submitLabel: .go,
            accessibilityIdentifier: "connection.tmux-executable"
        )
    }

    private func sessionNameInputRow(title: String) -> some View {
        textInputRow(
            title: title,
            placeholder: "e.g. main, work",
            keyPath: \.sessionName,
            field: .sessionName,
            validationMessage: validation.sessionName,
            textStyle: .monospaced,
            submitLabel: .go,
            accessibilityIdentifier: "connection.session"
        )
    }

    private func passwordInputRow(validationMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            SecureField("Required", text: binding(for: \.password))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: .password)
                .submitLabel(nextField(after: .password) == nil ? .go : .next)
                .onSubmit { advance(from: .password) }
                .frame(minHeight: 28)
                .accessibilityIdentifier("connection.password")

            fieldValidationMessage(validationMessage)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .password
        }
    }

    private func tailscaleAuthenticationRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tailscale SSH", systemImage: "network")
                .font(.footnote.weight(.semibold))

            Text(
                "Uses your tailnet identity without a password or key. " +
                "If your SSH rule requires a check, Remux will offer to open " +
                "the verification link in your browser."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("connection.authentication.tailscale-info")
    }

    @ViewBuilder
    private func privateKeyInputRows() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let inspection = privateKeyInspection {
                privateKeySelectedRows(inspection)
            } else {
                privateKeyEmptyRows()
            }

            fieldValidationMessage(privateKeyImportError ?? validation.privateKey)
        }
        .padding(.vertical, 6)

        if shouldShowPrivateKeyPassphrase {
            privateKeyPassphraseRow()
        }
    }

    private func binding(for keyPath: WritableKeyPath<TmuxConnectionDraft, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                onChange { draft in
                    draft[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var authenticationKindBinding: Binding<SSHAuthenticationKind> {
        Binding(
            get: { draft.authenticationKind },
            set: { newValue in
                privateKeyImportError = nil
                publicKeyCopyMessage = nil
                onChange { draft in
                    draft.authenticationKind = newValue
                }
            }
        )
    }

    private var importedPrivateKeyTitle: String {
        if !draft.privateKeyFileName.isEmpty {
            return draft.privateKeyFileName
        }
        return privateKeyInspection?.keyType.displayName ?? "Private key"
    }

    private var importedPrivateKeySubtitle: String {
        if let inspection = privateKeyInspection {
            return "\(inspection.keyType.displayName) \(inspection.publicFingerprint)"
        }
        return "Private key"
    }

    private var privateKeyInspection: SSHPrivateKeyInspection? {
        try? SSHPrivateKeyInspector.inspect(draft.privateKeyPEM)
    }

    private var shouldShowPrivateKeyPassphrase: Bool {
        guard draft.authenticationKind == .privateKey else {
            return false
        }
        return privateKeyInspection?.isEncrypted == true || !draft.privateKeyPassphrase.isEmpty
    }

    private func privateKeyEmptyRows() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            privateKeyActionButton(
                title: "Import private key",
                subtitle: "Choose a private key file",
                systemImage: "square.and.arrow.down",
                accessibilityIdentifier: "connection.private-key.import"
            ) {
                presentPrivateKeyImporter()
            }

            privateKeyActionDivider()

            privateKeyActionButton(
                title: "Paste private key",
                subtitle: "Paste a private key block",
                systemImage: "doc.on.clipboard",
                accessibilityIdentifier: "connection.private-key.paste"
            ) {
                pastePrivateKeyFromClipboard()
            }

            privateKeyActionDivider()

            privateKeyActionButton(
                title: "Generate ED25519 key",
                subtitle: "Create a key pair on this device",
                systemImage: "key.horizontal",
                accessibilityIdentifier: "connection.private-key.generate"
            ) {
                generatePrivateKey()
            }
        }
    }

    private func privateKeySelectedRows(_ inspection: SSHPrivateKeyInspection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            privateKeySelectedSummary()

            privateKeySectionDivider()

            privateKeyCopyPublicKeyButton(inspection)

            privateKeySectionDivider()

            privateKeyInstallButton()

            privateKeySectionDivider()

            privateKeyChangeMenu()
        }
    }

    private func privateKeySelectedSummary() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(importedPrivateKeyTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(importedPrivateKeySubtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func privateKeyCopyPublicKeyButton(_ inspection: SSHPrivateKeyInspection) -> some View {
        Button {
            copyPublicKey(inspection.publicKeyLine)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: publicKeyCopyMessage == nil ? "doc.on.doc" : "checkmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Copy public key")
                        .foregroundStyle(.primary)

                    Text("Add to ~/.ssh/authorized_keys on the server")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if publicKeyCopyMessage != nil {
                    Text("Copied")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.private-key.copy-public")
    }

    private func privateKeyInstallButton() -> some View {
        let target: SSHPublicKeyInstallTarget?
        do {
            target = try publicKeyInstallTarget(draft)
        } catch {
            target = nil
        }

        return Button {
            dismissKeyboard()
            guard let target, let setupSessionID else { return }
            publicKeyInstallRequest = SSHPublicKeyInstallRequest(
                draft: draft,
                target: target,
                setupSessionID: setupSessionID
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.body.weight(.semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Install on Host")
                        .foregroundStyle(.primary)

                    Text("Add this public key using a one-time password")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let confirmation = publicKeyInstallConfirmation,
                   let target,
                   confirmation.matches(target) {
                    Label(confirmation.success.message, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("connection.private-key.install-status")
                }
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActionInProgress || target == nil || setupSessionID == nil)
        .accessibilityIdentifier("connection.private-key.install")
    }

    private func acceptPublicKeyInstallCompletion(
        _ completion: SSHPublicKeyInstallCompletion
    ) {
        let activeTarget: SSHPublicKeyInstallTarget
        do {
            activeTarget = try publicKeyInstallTarget(draft)
        } catch {
            return
        }
        guard completion.matchesActiveSetup(
            target: activeTarget,
            setupSessionID: setupSessionID
        ) else {
            return
        }
        publicKeyInstallConfirmation = SSHPublicKeyInstallConfirmation(
            success: completion.success,
            target: completion.target
        )
    }

    private func privateKeyChangeMenu() -> some View {
        Menu {
            Button {
                presentPrivateKeyImporter()
            } label: {
                Label("Import Different Key", systemImage: "square.and.arrow.down")
            }

            Button {
                pastePrivateKeyFromClipboard()
            } label: {
                Label("Paste Different Key", systemImage: "doc.on.clipboard")
            }

            Button {
                generatePrivateKey()
            } label: {
                Label("Generate New ED25519 Key", systemImage: "key.horizontal")
            }

            Button(role: .destructive) {
                removePrivateKey()
            } label: {
                Label("Remove Private Key", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Change Key")
                        .foregroundStyle(.primary)

                    Text("Import, paste, generate, remove")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.private-key.change")
    }

    private func privateKeyPassphraseRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Key Passphrase")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            SecureField("Required for encrypted keys", text: binding(for: \.privateKeyPassphrase))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.leading)
                .focused($focusedField, equals: .privateKeyPassphrase)
                .submitLabel(nextField(after: .privateKeyPassphrase) == nil ? .go : .next)
                .onSubmit { advance(from: .privateKeyPassphrase) }
                .frame(minHeight: 28)
                .accessibilityIdentifier("connection.private-key.passphrase")

            fieldValidationMessage(validation.privateKeyPassphrase)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .privateKeyPassphrase
        }
    }

    private func privateKeyActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isDestructive ? Color.red : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(isDestructive ? Color.red : Color.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .padding(.vertical, 6)
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func privateKeyActionDivider() -> some View {
        Rectangle()
            .fill(LibraryHomePalette.separator)
            .frame(height: 1)
            .padding(.leading, 34)
    }

    private func privateKeySectionDivider() -> some View {
        Rectangle()
            .fill(LibraryHomePalette.separator)
            .frame(height: 1)
    }

    private func presentPrivateKeyImporter() {
        privateKeyImportError = nil
        dismissKeyboard()
        isPrivateKeyImporterPresented = true
    }

    private func handlePrivateKeyImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= SSHPrivateKeyInspector.maxByteCount else {
                throw SSHPrivateKeyInspectionError.tooLarge
            }
            guard let pem = String(data: data, encoding: .utf8) else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }

            let inspection = try SSHPrivateKeyInspector.inspect(pem)
            privateKeyImportError = nil
            publicKeyCopyMessage = nil
            onChange { draft in
                draft.authenticationKind = .privateKey
                draft.privateKeyPEM = inspection.normalizedPEM
                draft.privateKeyFileName = url.lastPathComponent
                draft.privateKeyPassphrase = ""
            }
        } catch {
            if let error = error as? SSHPrivateKeyInspectionError {
                privateKeyImportError = error.localizedDescription
            } else {
                privateKeyImportError = "Private key could not be imported."
            }
        }
    }

    private func removePrivateKey() {
        privateKeyImportError = nil
        publicKeyCopyMessage = nil
        Haptic.tap()
        onChange { draft in
            draft.privateKeyPEM = ""
            draft.privateKeyFileName = ""
            draft.privateKeyPassphrase = ""
        }
    }

    private func pastePrivateKeyFromClipboard() {
        guard let pem = UIPasteboard.general.string else {
            privateKeyImportError = "Clipboard does not contain a private key."
            Haptic.error()
            return
        }

        do {
            let inspection = try SSHPrivateKeyInspector.inspect(pem)
            privateKeyImportError = nil
            publicKeyCopyMessage = nil
            Haptic.tap()
            onChange { draft in
                draft.authenticationKind = .privateKey
                draft.privateKeyPEM = inspection.normalizedPEM
                draft.privateKeyFileName = "Pasted private key"
                draft.privateKeyPassphrase = ""
            }
        } catch {
            if let error = error as? SSHPrivateKeyInspectionError {
                privateKeyImportError = error.localizedDescription
            } else {
                privateKeyImportError = "Clipboard private key could not be read."
            }
            Haptic.error()
        }
    }

    private func generatePrivateKey() {
        let generated = SSHPrivateKeyInspector.generateEd25519()
        privateKeyImportError = nil
        publicKeyCopyMessage = nil
        Haptic.tap()
        onChange { draft in
            draft.authenticationKind = .privateKey
            draft.privateKeyPEM = generated.privateKeyPEM
            draft.privateKeyFileName = "Generated ED25519 key"
            draft.privateKeyPassphrase = ""
        }
    }

    private func copyPublicKey(_ publicKeyLine: String) {
        UIPasteboard.general.string = publicKeyLine
        publicKeyCopyMessage = "Public key copied"
        Haptic.tap()
    }

    @ViewBuilder
    private func fieldValidationMessage(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

private extension ConnectionSetupView {
    var primaryActionTitle: String {
        switch mode {
        case .newServer:
            "Add"
        case .newWorkspace:
            "Start"
        case .editServer(_, let reconnectWorkspaceID):
            reconnectWorkspaceID == nil ? "Save" : "Connect"
        case .editWorkspace:
            "Save"
        }
    }
}

private struct ConnectionServerSummaryRow: View {
    let draft: TmuxConnectionDraft

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LibraryHomePalette.rowIconForeground)
                .frame(width: 30, height: 30)
                .background(LibraryHomePalette.rowIconSurface, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(draft.username)@\(draft.host)\(draft.port == "22" ? "" : ":\(draft.port)")")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Remux failed")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
