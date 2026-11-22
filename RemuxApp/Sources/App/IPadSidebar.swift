import SwiftUI

/// A sidebar row a person can choose: a session, which the window then shows, or one of a Herdr session's workspaces,
/// which the session then shows. Each row is tagged with its own, so a workspace never takes its session's highlight.
enum IPadSidebarRow: Hashable {
    case session(SavedWorkspace.ID)
    case herdrWorkspace(session: SavedWorkspace.ID, workspace: String, bootID: String)
}

/// A wide iPad window's sidebar: every server with its sessions, listed beside the terminal, as Files lists its
/// locations beside the folder shown. Choosing a session shows it, and the session shown is the list's selection, so
/// the phone's pickers (Home, a server's page, the Sessions sheet) aren't needed here. A Herdr session open in the
/// window lists its workspaces under it. Agents waiting lead the list.
struct IPadSidebar<SettingsPage: View>: View {
    @ObservedObject var model: RemuxRootModel
    let selectedSessionID: SavedWorkspace.ID?
    let onShowActiveSession: (SavedWorkspace.ID) -> Void
    let onConnect: (SavedWorkspace.ID) -> Void
    let onNewSession: (SavedServer.ID) -> Void
    @ViewBuilder let settingsPage: () -> SettingsPage

    @State private var showsSettings = false
    @State private var showsAllAgents = false
    @State private var collapsedServers: Set<SavedServer.ID> = []
    @State private var serverToDelete: SavedServer?
    @State private var hostKeyToReview: SSHHostKeyTrustChallenge?

    private var projection: SessionSwitcherProjection {
        SessionSwitcherProjection(
            snapshot: model.library,
            activeSessions: model.activeSessions,
            discoveries: model.sessionDiscoveries,
            selectedSessionID: selectedSessionID
        )
    }

    var body: some View {
        let projection = projection
        let agents = SessionAgentsProjection(
            activeSessions: projection.activeSessions,
            agents: model.herdrAgents(of:)
        )
        List(selection: selection) {
            if !agents.entries.isEmpty {
                Section("Agents") {
                    SessionAgentsHomeRows(
                        projection: agents,
                        onOpen: openAgent,
                        onShowAll: { showsAllAgents = true },
                        inSidebar: true
                    )
                }
            }
            if model.library.servers.isEmpty {
                Section {
                    Button("Add Server", systemImage: "plus", action: model.beginNewServer)
                        .accessibilityIdentifier("sidebar.add-server.empty")
                }
            }
            ForEach(model.library.servers) { server in
                serverSection(server, projection: projection)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    .tint(.primary)
                    .accessibilityIdentifier("library.settings")
                Button("Add Server", systemImage: "plus", action: model.beginNewServer)
                    .tint(.primary)
                    .accessibilityIdentifier("library.server.add")
            }
        }
        .refreshable {
            for server in model.library.servers {
                await model.refreshSessionsAndWait(for: server.id)
            }
        }
        .task {
            // The sidebar is where a server's sessions are found, so it checks a server it hasn't checked yet, as
            // opening a server's page does on the phone.
            for server in model.library.servers where (model.sessionDiscoveries[server.id] ?? .idle).hasIdleBackend {
                model.refreshSessions(for: server.id)
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                settingsPage()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }
                                .accessibilityIdentifier("library.page.done")
                        }
                    }
            }
        }
        .sheet(isPresented: $showsAllAgents) {
            NavigationStack {
                SessionAgentsList(projection: agents) { session, agent in
                    showsAllAgents = false
                    openAgent(session, agent)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsAllAgents = false }
                    }
                }
            }
        }
        .confirmationDialog(
            serverToDelete.map { ServerDeletionConfirmation(server: $0, snapshot: model.library).title } ?? "",
            isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } }),
            titleVisibility: .visible,
            presenting: serverToDelete
        ) { server in
            Button("Delete Server", role: .destructive) {
                Task { await model.deleteServer(server.id) }
            }
        } message: { server in
            Text(ServerDeletionConfirmation(server: server, snapshot: model.library).message)
        }
        .alert(
            "Review Host Key",
            isPresented: Binding(get: { hostKeyToReview != nil }, set: { if !$0 { hostKeyToReview = nil } }),
            presenting: hostKeyToReview
        ) { challenge in
            Button("Trust") { model.trustSessionDiscoveryHostKey(challenge) }
            Button("Cancel", role: .cancel) {}
        } message: { challenge in
            Text("\(challenge.host) presented \(challenge.receivedKeyFingerprint ?? "a key Remux couldn't read"). Trust it only if it matches the server's key.")
        }
        .alert("Server Order Couldn’t Be Saved", isPresented: Binding(
            get: { model.serverOrderSaveFailed },
            set: { if !$0 { model.dismissServerOrderSaveFailure() } }
        )) {
            Button("Retry", action: model.retryServerOrderSave)
            Button("Cancel", role: .cancel, action: model.dismissServerOrderSaveFailure)
        } message: {
            Text("Your order is still shown, but may be lost when you close Remux. Try saving it again.")
        }
    }

    /// The list's selection is the session shown. Choosing an open session shows it; choosing a saved one opens it,
    /// and the selection follows once it is shown. Choosing a Herdr workspace shows it in its session; the session
    /// keeps the highlight, and the workspace on screen is marked in its own row.
    private var selection: Binding<IPadSidebarRow?> {
        Binding(
            get: { selectedSessionID.map(IPadSidebarRow.session) },
            set: { row in
                switch row {
                case .session(let id):
                    guard id != selectedSessionID else { return }
                    if model.activeSessions.contains(where: { $0.id == id }) {
                        onShowActiveSession(id)
                    } else {
                        onConnect(id)
                    }
                case .herdrWorkspace(let session, let workspace, let bootID):
                    model.openHerdrWorkspace(workspace, bootID: bootID, in: session)
                    if session != selectedSessionID { onShowActiveSession(session) }
                case nil:
                    return
                }
            }
        )
    }

    private func openAgent(_ session: SessionAgentsProjection.Session, _ agent: HerdrAgentPresentation.Agent) {
        model.openHerdrSession(session.id, atPane: agent.paneID, bootID: session.bootID)
    }

    // MARK: A server and its sessions

    private func serverSection(_ server: SavedServer, projection: SessionSwitcherProjection) -> some View {
        let discovery = model.sessionDiscoveries[server.id] ?? .idle
        let notices = discovery.notices
        let active = RemuxActiveSessionCollection.sortedForDisplay(
            model.activeSessions.filter { $0.target.server.id == server.id }
        )
        let activeIDs = Set(active.map(\.id))
        let saved = model.library.workspaces(for: server.id).filter { workspace in
            !activeIDs.contains(workspace.id)
                && SessionReconciliation.includesSavedWorkspace(workspace, discoveries: model.sessionDiscoveries)
        }
        let found = projection.availableSessions(on: server.id)
        return Section(isExpanded: Binding(
            get: { !collapsedServers.contains(server.id) },
            set: { expanded in
                if expanded { collapsedServers.remove(server.id) } else { collapsedServers.insert(server.id) }
            }
        )) {
            if let challenge = notices.hostKey {
                Button {
                    hostKeyToReview = challenge
                } label: {
                    Label {
                        Text("Check this server's key")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityHint("Remux won't connect until you trust the key \(server.displayName) presented.")
                .accessibilityIdentifier("sidebar.server.host-key")
            }
            ForEach(active) { session in
                activeRow(session)
            }
            ForEach(saved) { workspace in
                savedRow(workspace, server: server, discovery: discovery, notices: notices)
            }
            ForEach(found) { session in
                foundRow(session, server: server)
            }
            if notices.isNeitherBackendInstalled {
                Button("Set tmux or Herdr Path", systemImage: "wrench.and.screwdriver") {
                    Task { await model.beginEditServer(serverID: server.id) }
                }
                .accessibilityIdentifier("library.server.set-paths")
            } else if discovery.isLoading || discovery.isIdle {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(server.displayName)…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityIdentifier("library.server.available.loading")
            } else if notices.checkFailed {
                Text("Couldn't check \(server.displayName). Pull down to try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library.server.check-failed")
            }
            if active.isEmpty && saved.isEmpty && found.isEmpty && !notices.isNeitherBackendInstalled {
                Button("New Session", systemImage: "plus") { onNewSession(server.id) }
                    .accessibilityIdentifier("library.server.new-session.empty")
            }
        } header: {
            serverHeader(server)
        }
    }

    private func serverHeader(_ server: SavedServer) -> some View {
        HStack {
            Text(server.displayName)
            Spacer(minLength: 8)
            Menu {
                Button("New Session", systemImage: "plus") { onNewSession(server.id) }
                Button("Check for Sessions", systemImage: "arrow.clockwise") { model.refreshSessions(for: server.id) }
                Divider()
                Button("Edit Server", systemImage: "pencil") {
                    Task { await model.beginEditServer(serverID: server.id) }
                }
                Button("Delete Server", systemImage: "trash", role: .destructive) { serverToDelete = server }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(server.displayName) Actions")
            .accessibilityIdentifier("sidebar.server.menu")
        }
        .accessibilityIdentifier("sidebar.server.\(server.displayName)")
    }

    /// An open session: its name, and its connection's state when it isn't connected. A Herdr session lists its
    /// workspaces under it.
    @ViewBuilder
    private func activeRow(_ session: ActiveTerminalSession) -> some View {
        let isConnected = TerminalRuntimeStateProjection.isRootVisibleConnected(session.runtimeState)
        Label {
            HStack(spacing: 8) {
                Text(session.target.workspace.sessionName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !isConnected {
                    TerminalRuntimeStateIndicator(state: session.runtimeState)
                }
            }
        } icon: {
            SessionBackendLogo(backend: session.target.workspace.backend, size: 20)
        }
        .tag(IPadSidebarRow.session(session.id))
        .contextMenu {
            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                model.disconnectActiveSession(session.id)
            }
        }
        .accessibilityIdentifier("sidebar.session.active")
        if session.target.workspace.backend == .herdr, let places = model.herdrPlaces(of: session.id) {
            IPadSidebarHerdrWorkspaces(
                places: places,
                sessionID: session.id,
                isShown: session.id == selectedSessionID
            )
        }
    }

    /// A saved session that isn't open: choosing it opens it.
    private func savedRow(
        _ workspace: SavedWorkspace,
        server: SavedServer,
        discovery: ServerSessionDiscovery,
        notices: ServerDiscoveryNotices
    ) -> some View {
        let unavailableReason = discovery.unavailableReason(of: workspace.locator)
        return Label {
            Text(workspace.sessionName)
                .lineLimit(1)
                .foregroundStyle(unavailableReason == nil ? .secondary : .tertiary)
        } icon: {
            SessionBackendLogo(backend: workspace.backend, size: 20)
                .opacity(0.6)
        }
        .tag(IPadSidebarRow.session(workspace.id))
        .selectionDisabled(unavailableReason != nil)
        .contextMenu {
            Button("Edit Session", systemImage: "pencil") {
                Task { await model.beginEditWorkspace(serverID: server.id, workspaceID: workspace.id) }
            }
            Button("Delete Session", systemImage: "trash", role: .destructive) {
                Task { await model.deleteWorkspace(workspace.id) }
            }
        }
        .accessibilityIdentifier("library.session.resume")
    }

    /// A session found on the server that Remux hasn't opened: choosing it opens and saves it.
    private func foundRow(_ session: AvailableSessionSwitcherItem, server: SavedServer) -> some View {
        Button {
            Task { await model.connectToDiscoveredSession(session.id.locator, on: server.id) }
        } label: {
            Label {
                Text(session.id.locator.name)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } icon: {
                SessionBackendLogo(backend: session.id.locator.backend, size: 20)
                    .opacity(0.6)
            }
        }
        .buttonStyle(.plain)
        .disabled(session.unavailableReason != nil)
        .accessibilityIdentifier("library.server.available.session")
    }
}

/// A Herdr session's workspaces, nested under its row: each one's icon sits under the session's name, as a sidebar
/// nests a folder's items, and the workspace on screen is marked.
private struct IPadSidebarHerdrWorkspaces: View {
    @ObservedObject var places: HerdrSessionPlaces
    let sessionID: SavedWorkspace.ID
    let isShown: Bool

    /// How far a nested row's icon sits in: the session row's icon and the gap after it, so it starts under the
    /// session's name.
    private static let nestedInset: CGFloat = 22

    var body: some View {
        if let outline = places.outline {
            ForEach(outline.workspaces) { workspace in
                let isCurrent = isShown && workspace.id == outline.focusedWorkspaceID
                Label {
                    Text(workspace.label)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "square.stack")
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .font(.subheadline)
                .padding(.leading, Self.nestedInset)
                .tag(IPadSidebarRow.herdrWorkspace(session: sessionID, workspace: workspace.id, bootID: outline.bootID))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier("sidebar.herdr.workspace")
            }
        }
    }
}
