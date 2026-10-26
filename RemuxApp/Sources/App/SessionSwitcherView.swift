import SwiftUI

struct ActiveSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let backend: SessionBackend
    let sessionName: String
    let serverName: String
    let runtimeState: TerminalRuntimeState
    let isSelected: Bool
    let link: URL?
}

struct RemoteSessionIdentity: Hashable {
    let serverID: SavedServer.ID
    let locator: SessionLocator
}

struct AvailableSessionSwitcherItem: Identifiable, Equatable {
    let id: RemoteSessionIdentity
    let serverName: String
    /// Herdr lists stopped sessions too; opening one starts it.
    let isRunning: Bool
    let link: URL?
}

struct RecentSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let backend: SessionBackend
    let sessionName: String
    let serverName: String
    let lastOpenedAt: Date
    let link: URL?
}

struct SessionSwitcherProjection: Equatable {
    static let maximumInlineAvailableSessionCount = 3

    let activeSessions: [ActiveSessionSwitcherItem]
    let availableSessions: [AvailableSessionSwitcherItem]
    let recentSessions: [RecentSessionSwitcherItem]
    /// Servers none of whose sessions could be listed: a host key to review, or a failed check.
    let uncheckedServerIDs: Set<SavedServer.ID>

    var inlineAvailableSessions: [AvailableSessionSwitcherItem] {
        Array(availableSessions.prefix(Self.maximumInlineAvailableSessionCount))
    }

    var hiddenAvailableSessionCount: Int {
        availableSessions.count - inlineAvailableSessions.count
    }

    func availableSessions(on serverID: SavedServer.ID) -> [AvailableSessionSwitcherItem] {
        availableSessions.filter { $0.id.serverID == serverID }
    }

    init(
        snapshot: ConnectionLibrarySnapshot,
        activeSessions: [ActiveTerminalSession],
        discoveries: [SavedServer.ID: ServerSessionDiscovery] = [:],
        selectedSessionID: SavedWorkspace.ID?
    ) {
        self.activeSessions = RemuxActiveSessionCollection
            .sortedForDisplay(activeSessions)
            .map { session in
                ActiveSessionSwitcherItem(
                    id: session.id,
                    backend: session.target.workspace.backend,
                    sessionName: session.target.workspace.sessionName,
                    serverName: session.target.server.displayName,
                    runtimeState: session.runtimeState,
                    isSelected: session.id == selectedSessionID,
                    link: RemuxDeepLink.sessionURL(
                        server: session.target.server,
                        locator: session.target.locator,
                        among: snapshot.servers
                    )
                )
            }

        let activeWorkspaceIDs = Set(activeSessions.map(\.id))
        let activeIdentities = Set(activeSessions.map {
            RemoteSessionIdentity(
                serverID: $0.target.server.id,
                locator: $0.target.locator
            )
        })

        var recentIdentities = Set<RemoteSessionIdentity>()
        self.recentSessions = snapshot
            .recentWorkspaces(excluding: activeWorkspaceIDs)
            .filter {
                SessionReconciliation.includesSavedWorkspace(
                    $0,
                    discoveries: discoveries
                )
            }
            .compactMap { workspace in
                guard let server = snapshot.server(id: workspace.serverID) else {
                    return nil
                }
                let identity = RemoteSessionIdentity(
                    serverID: workspace.serverID,
                    locator: workspace.locator
                )
                guard !activeIdentities.contains(identity),
                      recentIdentities.insert(identity).inserted else {
                    return nil
                }
                return RecentSessionSwitcherItem(
                    id: workspace.id,
                    backend: workspace.backend,
                    sessionName: workspace.sessionName,
                    serverName: server.displayName,
                    lastOpenedAt: workspace.lastOpenedAt,
                    link: RemuxDeepLink.sessionURL(
                        server: server,
                        locator: workspace.locator,
                        among: snapshot.servers
                    )
                )
            }

        self.availableSessions = snapshot.servers
            .flatMap { server in
                let discovery = discoveries[server.id] ?? .idle
                return [SessionBackend.tmux, .herdr]
                    .flatMap { backend in
                        discovery[backend].sessions.map { session in
                            let locator = SessionLocator(backend: backend, name: session.name)
                            return AvailableSessionSwitcherItem(
                                id: RemoteSessionIdentity(serverID: server.id, locator: locator),
                                serverName: server.displayName,
                                isRunning: session.isRunning,
                                link: RemuxDeepLink.sessionURL(
                                    server: server,
                                    locator: locator,
                                    among: snapshot.servers
                                )
                            )
                        }
                    }
                    .sorted { lhs, rhs in
                        let order = lhs.id.locator.name.localizedStandardCompare(rhs.id.locator.name)
                        guard order == .orderedSame else { return order == .orderedAscending }
                        return lhs.id.locator.backend == .tmux && rhs.id.locator.backend == .herdr
                    }
            }
            .filter {
                !activeIdentities.contains($0.id) && !recentIdentities.contains($0.id)
            }

        self.uncheckedServerIDs = Set(snapshot.servers.compactMap { server in
            (discoveries[server.id] ?? .idle).notices.isServerUnchecked ? server.id : nil
        })
    }

    static func orderedServers(
        _ servers: [SavedServer],
        currentServerID: SavedServer.ID?
    ) -> [SavedServer] {
        servers.filter { $0.id == currentServerID }
            + servers.filter { $0.id != currentServerID }
    }
}

struct SessionSwitcherView<NewSessionContent: View>: View {
    private static var collapsedRecentSessionCount: Int { 3 }

    private enum Route: Hashable {
        case chooseServer
        case availableSessions
        case newSession
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: SessionSwitcherProjection
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelectActiveSession: (SavedWorkspace.ID) -> Void
    let onResumeSession: (SavedWorkspace.ID) -> Void
    let onResumeAvailableSession: (SavedServer.ID, SessionLocator) -> Void
    let onDisconnectSession: (SavedWorkspace.ID) -> Void
    let isCreatingSession: Bool
    let onCreateSession: (SavedServer.ID) -> Bool
    let onCancelCreateSession: () -> Void
    let newSessionContent: () -> NewSessionContent
    let onRefresh: () -> Void
    let discoveries: [SavedServer.ID: ServerSessionDiscovery]

    @State private var path: [Route] = []
    @State private var showsAllRecentSessions = false

    var body: some View {
        NavigationStack(path: $path) {
            sessionList
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .chooseServer:
                        NewSessionServerPickerView(
                            servers: SessionSwitcherProjection.orderedServers(
                                servers,
                                currentServerID: currentServerID
                            ),
                            currentServerID: currentServerID,
                            onSelect: beginNewSession
                        )
                    case .availableSessions:
                        AvailableSessionsBrowserView(
                            sessions: projection.availableSessions,
                            isRefreshing: isRefreshing,
                            failureMessage: failedServerNames.isEmpty
                                ? nil
                                : discoveryFailureMessage,
                            onRefresh: onRefresh,
                            onSelect: resumeAvailableSession
                        )
                    case .newSession:
                        newSessionContent()
                    }
                }
        }
        .onChange(of: path) { previousPath, path in
            guard previousPath.contains(.newSession),
                  !path.contains(.newSession) else { return }
            onCancelCreateSession()
        }
        .interactiveDismissDisabled(isCreatingSession)
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("terminal.sessions.sheet")
    }

    private var sessionList: some View {
        List {
            Section {
                ForEach(projection.activeSessions) { session in
                    activeSessionRow(session)
                }
            } header: {
                SessionSwitcherSectionHeader(title: "Active")
            }

            if !projection.recentSessions.isEmpty {
                Section {
                    ForEach(visibleRecentSessions) { session in
                        recentSessionRow(session)
                    }

                    if projection.recentSessions.count > Self.collapsedRecentSessionCount {
                        Button {
                            withAnimation(.snappy) {
                                showsAllRecentSessions.toggle()
                            }
                        } label: {
                            DisclosureRowLabel(
                                title: showsAllRecentSessions
                                    ? "Show fewer"
                                    : "Show more",
                                systemImage: showsAllRecentSessions
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                        }
                        .buttonStyle(.plain)
                        .sessionSwitcherListRow(
                            accessibilityIdentifier: "terminal.sessions.recent-toggle"
                        )
                    }
                } header: {
                    SessionSwitcherSectionHeader(title: "Recent")
                }
            }

            if !servers.isEmpty {
                Section {
                    discoveryStatusRows
                    ForEach(projection.inlineAvailableSessions) { session in
                        availableSessionRow(session)
                    }
                    if projection.hiddenAvailableSessionCount > 0 {
                        availableSessionsBrowserRow
                    }
                } header: {
                    availableSessionsHeader
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy, value: projection.activeSessions.map(\.id))
        .animation(.snappy, value: projection.availableSessions.map(\.id))
        .animation(.snappy, value: projection.recentSessions.map(\.id))
        .accessibilityIdentifier("terminal.sessions.list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalSelectionSheetActionButton(
                title: "New Session…",
                systemName: "plus",
                accessibilityIdentifier: "terminal.sessions.new",
                action: newSessionAction
            )
            .frame(height: TerminalSelectionSheetLayout.actionBarHeight)
            .padding(.horizontal, 16)
            .padding(.top, TerminalSelectionSheetLayout.contentToActionsSpacing)
            .padding(.bottom, TerminalSelectionSheetLayout.actionsBottomPadding)
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    Haptic.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close Sessions")
                .accessibilityIdentifier("terminal.sessions.close")
            }
        }
    }

    private var availableSessionsHeader: some View {
        HStack(spacing: 8) {
            SessionSwitcherSectionHeader(title: "Available")

            Spacer(minLength: 0)

            Button {
                Haptic.tap()
                onRefresh()
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TerminalSelectionSheetPalette.secondary)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Refreshing Available Sessions" : "Refresh Available Sessions")
            .accessibilityIdentifier("terminal.sessions.refresh")
        }
    }

    private var visibleRecentSessions: [RecentSessionSwitcherItem] {
        guard !showsAllRecentSessions else { return projection.recentSessions }
        return Array(projection.recentSessions.prefix(Self.collapsedRecentSessionCount))
    }

    private func activeSessionRow(_ session: ActiveSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            onSelectActiveSession(session.id)
            dismiss()
        } label: {
            ActiveSessionSwitcherRow(
                session: session,
                chromeStyle: chromeStyle
            )
        }
        .buttonStyle(.plain)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.active-session")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptic.warning()
                onDisconnectSession(session.id)
            } label: {
                Label("Disconnect", systemImage: "bolt.slash")
            }
            .accessibilityIdentifier("terminal.sessions.disconnect")
        }
        .copyLinkContextMenu(session.link)
        .accessibilityAction(named: Text("Disconnect from Remux")) {
            onDisconnectSession(session.id)
        }
    }

    private func availableSessionRow(_ session: AvailableSessionSwitcherItem) -> some View {
        Button {
            resumeAvailableSession(session)
        } label: {
            AvailableSessionSwitcherRow(session: session)
        }
        .buttonStyle(.plain)
        .copyLinkContextMenu(session.link)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.available-session")
    }

    private var availableSessionsBrowserRow: some View {
        Button {
            Haptic.tap()
            path.append(.availableSessions)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                    .frame(width: 28, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Find Available Sessions…")
                        .font(.headline)
                        .foregroundStyle(TerminalSelectionSheetPalette.primary)

                    Text(availableSessionsBrowserSummary)
                        .font(.footnote)
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TerminalSelectionSheetPalette.tertiary)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sessionSwitcherListRow(
            accessibilityIdentifier: "terminal.sessions.available-browser"
        )
    }

    private var availableSessionsBrowserSummary: String {
        let sessionCount = projection.availableSessions.count
        let serverCount = Set(projection.availableSessions.map(\.id.serverID)).count
        let sessions = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
        let servers = serverCount == 1 ? "1 server" : "\(serverCount) servers"
        return "\(sessions) across \(servers)"
    }

    private func resumeAvailableSession(_ session: AvailableSessionSwitcherItem) {
        Haptic.selection()
        dismiss()
        onResumeAvailableSession(session.id.serverID, session.id.locator)
    }

    private func recentSessionRow(_ session: RecentSessionSwitcherItem) -> some View {
        Button {
            Haptic.selection()
            dismiss()
            onResumeSession(session.id)
        } label: {
            RecentSessionSwitcherRow(session: session)
        }
        .buttonStyle(.plain)
        .copyLinkContextMenu(session.link)
        .sessionSwitcherListRow(accessibilityIdentifier: "terminal.sessions.recent-session")
    }

    private var newSessionAction: (() -> Void)? {
        guard !servers.isEmpty else { return nil }
        return showNewSessionFlow
    }

    private func showNewSessionFlow() {
        if servers.count == 1, let server = servers.first {
            beginNewSession(server.id)
            return
        }

        path.append(.chooseServer)
    }

    private func beginNewSession(_ serverID: SavedServer.ID) {
        guard onCreateSession(serverID) else { return }
        path.append(.newSession)
    }

    private var isRefreshing: Bool {
        servers.contains { (discoveries[$0.id] ?? .idle).isLoading }
    }

    private var failedServerNames: [String] {
        servers.compactMap { server in
            projection.uncheckedServerIDs.contains(server.id) ? server.displayName : nil
        }
    }

    private var hasUndiscoveredServer: Bool {
        servers.contains { (discoveries[$0.id] ?? .idle).hasIdleBackend }
    }

    @ViewBuilder
    private var discoveryStatusRows: some View {
        if isRefreshing {
            discoveryStatusRow(
                "Looking for sessions…",
                systemImage: "arrow.clockwise"
            )
        } else if !failedServerNames.isEmpty {
            discoveryStatusRow(
                discoveryFailureMessage,
                systemImage: "exclamationmark.triangle"
            )
        } else if projection.availableSessions.isEmpty,
                  hasUndiscoveredServer {
            discoveryStatusRow(
                "Refresh to find sessions",
                systemImage: "arrow.clockwise"
            )
        } else if projection.availableSessions.isEmpty {
            discoveryStatusRow(
                "No available sessions",
                systemImage: "checkmark.circle"
            )
        }
    }

    private func discoveryStatusRow(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
            .listRowBackground(Color.clear)
    }

    private var discoveryFailureMessage: String {
        if failedServerNames.count == 1, let serverName = failedServerNames.first {
            return "Couldn’t check sessions on \(serverName)"
        }
        return "Couldn’t check sessions on \(failedServerNames.count) servers"
    }
}

private struct SessionSwitcherSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
            .textCase(nil)
    }
}

private struct ActiveSessionSwitcherRow: View {
    let session: ActiveSessionSwitcherItem
    let chromeStyle: GhosttyTerminalChromeStyle

    var body: some View {
        HStack(spacing: 12) {
            SessionBackendLogo(backend: session.backend, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(session.serverName)
                        .lineLimit(1)

                    Text("·")
                        .accessibilityHidden(true)

                    TerminalRuntimeStateIndicator(state: session.runtimeState)
                }
                .font(.footnote)
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if session.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(chromeStyle.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(session.isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        let status = TerminalRuntimeStatusPresentation.projection(for: session.runtimeState).label
        let current = session.isSelected ? ", current session" : ""
        return "\(session.sessionName), \(session.serverName), \(status)\(current)"
    }
}

private struct AvailableSessionSwitcherRow: View {
    let session: AvailableSessionSwitcherItem
    var showsServerName = true

    /// The logo tells tmux from Herdr; a Herdr session can be listed while stopped.
    private var detail: String? {
        var parts: [String] = []
        if !session.isRunning {
            parts.append("Stopped")
        }
        if showsServerName {
            parts.append(session.serverName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            SessionBackendLogo(backend: session.id.locator.backend, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.id.locator.name)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([session.id.locator.name, session.id.locator.backend.displayName] + [detail].compactMap { $0 })
                .joined(separator: ", ")
        )
        .accessibilityValue("Available")
        .accessibilityHint("Resume this session")
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecentSessionSwitcherRow: View {
    let session: RecentSessionSwitcherItem

    var body: some View {
        HStack(spacing: 12) {
            SessionBackendLogo(backend: session.backend, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(session.serverName)
                        .lineLimit(1)

                    Text("·")
                        .accessibilityHidden(true)

                    SessionLastOpenedText(date: session.lastOpenedAt)
                }
                .font(.footnote)
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.sessionName), \(session.serverName)")
        .accessibilityValue(SessionLastOpenedText.value(for: session.lastOpenedAt))
        .accessibilityHint("Resume this session")
        .accessibilityAddTraits(.isButton)
    }
}

struct SessionLastOpenedText: View {
    let date: Date

    var body: some View {
        Text(Self.value(for: date))
    }

    static func value(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let elapsed = referenceDate.timeIntervalSince(date)
        if elapsed >= 0, elapsed < 60 {
            return "Opened just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return "Opened \(formatter.localizedString(for: date, relativeTo: referenceDate))"
    }
}

private struct AvailableSessionsBrowserView: View {
    private struct ServerGroup: Identifiable {
        let id: SavedServer.ID
        let serverName: String
        let sessions: [AvailableSessionSwitcherItem]
    }

    let sessions: [AvailableSessionSwitcherItem]
    let isRefreshing: Bool
    let failureMessage: String?
    let onRefresh: () -> Void
    let onSelect: (AvailableSessionSwitcherItem) -> Void

    @State private var query = ""

    var body: some View {
        List {
            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                    .listRowBackground(Color.clear)
            }

            if groups.isEmpty {
                emptyResults
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            Button {
                                onSelect(session)
                            } label: {
                                AvailableSessionSwitcherRow(
                                    session: session,
                                    showsServerName: false
                                )
                            }
                            .buttonStyle(.plain)
                            .copyLinkContextMenu(session.link)
                            .sessionSwitcherListRow(
                                accessibilityIdentifier: "terminal.sessions.available-result"
                            )
                        }
                    } header: {
                        SessionSwitcherSectionHeader(title: group.serverName)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Available Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptic.tap()
                    onRefresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel(
                    isRefreshing ? "Refreshing Sessions" : "Refresh Sessions"
                )
                .accessibilityIdentifier("terminal.sessions.available-refresh")
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Sessions or servers"
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .accessibilityIdentifier("terminal.sessions.available-browser-view")
    }

    private var matchingSessions: [AvailableSessionSwitcherItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sessions }
        return sessions.filter {
            $0.id.locator.name.localizedCaseInsensitiveContains(term)
                || $0.serverName.localizedCaseInsensitiveContains(term)
        }
    }

    private var groups: [ServerGroup] {
        let sessions = matchingSessions
        let grouped = Dictionary(grouping: sessions, by: \.id.serverID)
        var seen = Set<SavedServer.ID>()
        return sessions.compactMap { session in
            let serverID = session.id.serverID
            guard seen.insert(serverID).inserted,
                  let serverSessions = grouped[serverID] else { return nil }
            return ServerGroup(
                id: serverID,
                serverName: session.serverName,
                sessions: serverSessions
            )
        }
    }

    @ViewBuilder
    private var emptyResults: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No Available Sessions",
                systemImage: "terminal"
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
}

private struct NewSessionServerPickerView: View {
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelect: (SavedServer.ID) -> Void

    var body: some View {
        List(servers) { server in
            Button {
                Haptic.selection()
                onSelect(server.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(server.displayName)
                                .font(.headline)
                                .foregroundStyle(TerminalSelectionSheetPalette.primary)
                                .lineLimit(1)

                            if server.id == currentServerID {
                                Text("Current")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                            }
                        }

                        Text(server.displayAddress)
                            .font(.footnote.monospaced())
                            .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TerminalSelectionSheetPalette.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
            .accessibilityIdentifier("terminal.sessions.server")
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Choose Server")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("terminal.sessions.server-picker")
    }
}

private extension View {
    func sessionSwitcherListRow(accessibilityIdentifier: String) -> some View {
        self
            .accessibilityIdentifier(accessibilityIdentifier)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.visible)
            .listRowSeparatorTint(TerminalSelectionSheetPalette.stroke)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// A long-press menu that copies a `remux://` link to the session, when
    /// the session has one.
    @ViewBuilder
    func copyLinkContextMenu(_ link: URL?) -> some View {
        if let link {
            contextMenu {
                Button {
                    UIPasteboard.general.url = link
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
            }
        } else {
            self
        }
    }
}
