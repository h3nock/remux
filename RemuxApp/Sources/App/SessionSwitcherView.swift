import SwiftUI

struct ActiveSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let runtimeState: TerminalRuntimeState
    let isSelected: Bool
}

struct RemoteTmuxSessionIdentity: Hashable {
    let serverID: SavedServer.ID
    let sessionName: String
}

struct AvailableSessionSwitcherItem: Identifiable, Equatable {
    let id: RemoteTmuxSessionIdentity
    let serverName: String
}

struct RecentSessionSwitcherItem: Identifiable, Equatable {
    let id: SavedWorkspace.ID
    let sessionName: String
    let serverName: String
    let lastOpenedAt: Date
}

struct SessionSwitcherProjection: Equatable {
    static let maximumInlineAvailableSessionCount = 3

    let activeSessions: [ActiveSessionSwitcherItem]
    let availableSessions: [AvailableSessionSwitcherItem]
    let recentSessions: [RecentSessionSwitcherItem]

    var inlineAvailableSessions: [AvailableSessionSwitcherItem] {
        Array(availableSessions.prefix(Self.maximumInlineAvailableSessionCount))
    }

    var hiddenAvailableSessionCount: Int {
        availableSessions.count - inlineAvailableSessions.count
    }

    init(
        snapshot: ConnectionLibrarySnapshot,
        activeSessions: [ActiveTerminalSession],
        discoveryStates: [SavedServer.ID: TmuxSessionDiscoveryState] = [:],
        selectedSessionID: SavedWorkspace.ID?
    ) {
        self.activeSessions = RemuxActiveSessionCollection
            .sortedForDisplay(activeSessions)
            .map { session in
                ActiveSessionSwitcherItem(
                    id: session.id,
                    sessionName: session.target.workspace.sessionName,
                    serverName: session.target.server.displayName,
                    runtimeState: session.runtimeState,
                    isSelected: session.id == selectedSessionID
                )
            }

        let activeWorkspaceIDs = Set(activeSessions.map(\.id))
        let activeIdentities = Set(activeSessions.map {
            RemoteTmuxSessionIdentity(
                serverID: $0.target.server.id,
                sessionName: $0.target.workspace.sessionName
            )
        })

        var recentIdentities = Set<RemoteTmuxSessionIdentity>()
        self.recentSessions = snapshot
            .recentWorkspaces(excluding: activeWorkspaceIDs)
            .filter {
                TmuxSessionReconciliation.includesSavedWorkspace(
                    $0,
                    discoveryStates: discoveryStates
                )
            }
            .compactMap { workspace in
                guard let server = snapshot.server(id: workspace.serverID) else {
                    return nil
                }
                let identity = RemoteTmuxSessionIdentity(
                    serverID: workspace.serverID,
                    sessionName: workspace.sessionName
                )
                guard !activeIdentities.contains(identity),
                      recentIdentities.insert(identity).inserted else {
                    return nil
                }
                return RecentSessionSwitcherItem(
                    id: workspace.id,
                    sessionName: workspace.sessionName,
                    serverName: server.displayName,
                    lastOpenedAt: workspace.lastOpenedAt
                )
            }

        self.availableSessions = snapshot.servers
            .flatMap { server in
                discoveryStates[server.id]?.sessionNames.map { sessionName in
                    AvailableSessionSwitcherItem(
                        id: RemoteTmuxSessionIdentity(
                            serverID: server.id,
                            sessionName: sessionName
                        ),
                        serverName: server.displayName
                    )
                } ?? []
            }
            .filter {
                !activeIdentities.contains($0.id) && !recentIdentities.contains($0.id)
            }
            .sorted { lhs, rhs in
                let serverComparison = lhs.serverName.localizedStandardCompare(rhs.serverName)
                if serverComparison != .orderedSame {
                    return serverComparison == .orderedAscending
                }
                let sessionComparison = lhs.id.sessionName.localizedStandardCompare(
                    rhs.id.sessionName
                )
                if sessionComparison != .orderedSame {
                    return sessionComparison == .orderedAscending
                }
                return lhs.id.serverID.uuidString < rhs.id.serverID.uuidString
            }
    }

    static func orderedServers(
        _ servers: [SavedServer],
        currentServerID: SavedServer.ID?
    ) -> [SavedServer] {
        servers.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == currentServerID
            let rhsIsCurrent = rhs.id == currentServerID
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct SessionSwitcherView: View {
    private static let collapsedRecentSessionCount = 5

    private enum Route: Hashable {
        case chooseServer
        case availableSessions
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: SessionSwitcherProjection
    let servers: [SavedServer]
    let currentServerID: SavedServer.ID?
    let onSelectActiveSession: (SavedWorkspace.ID) -> Void
    let onResumeSession: (SavedWorkspace.ID) -> Void
    let onResumeAvailableSession: (SavedServer.ID, String) -> Void
    let onDisconnectSession: (SavedWorkspace.ID) -> Void
    let onCreateSession: (SavedServer.ID) -> Void
    let onRefresh: () -> Void
    let discoveryStates: [SavedServer.ID: TmuxSessionDiscoveryState]

    @State private var path: [Route] = []
    @State private var showsAllRecentSessions = false

    var body: some View {
        NavigationStack(path: $path) {
            sessionList
                .toolbar(.hidden, for: .navigationBar)
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
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("terminal.sessions.sheet")
    }

    private var sessionList: some View {
        TerminalSelectionSheetScaffold(
            title: "Sessions",
            context: sessionCountSummary,
            closeAccessibilityIdentifier: "terminal.sessions.close"
        ) {
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
                                        : "View all \(projection.recentSessions.count)",
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
                        SessionSwitcherSectionHeader(title: "Available")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(.snappy, value: projection.activeSessions.map(\.id))
            .animation(.snappy, value: projection.availableSessions.map(\.id))
            .animation(.snappy, value: projection.recentSessions.map(\.id))
            .accessibilityIdentifier("terminal.sessions.list")
        } actions: {
            TerminalSelectionSheetActionButton(
                title: "New Session…",
                systemName: "plus",
                accessibilityIdentifier: "terminal.sessions.new",
                action: newSessionAction
            )
        }
        .overlay(alignment: .topTrailing) {
            refreshButton
                .padding(.top, 10)
                .padding(.trailing, 16)
        }
    }

    private var refreshButton: some View {
        Button {
            Haptic.tap()
            onRefresh()
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TerminalSelectionSheetPalette.primary)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .compactCircularChromeButtonLabel()
        }
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "Refreshing Sessions" : "Refresh Sessions")
        .accessibilityIdentifier("terminal.sessions.refresh")
    }

    private var sessionCountSummary: String {
        let count = projection.activeSessions.count
            + projection.availableSessions.count
            + projection.recentSessions.count
        return count == 1 ? "1 session" : "\(count) sessions"
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
        onResumeAvailableSession(session.id.serverID, session.id.sessionName)
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
        dismiss()
        onCreateSession(serverID)
    }

    private var serverDiscoveryStates: [(SavedServer, TmuxSessionDiscoveryState)] {
        servers.map { ($0, discoveryStates[$0.id] ?? .idle) }
    }

    private var isRefreshing: Bool {
        serverDiscoveryStates.contains { $0.1.isLoading }
    }

    private var failedServerNames: [String] {
        serverDiscoveryStates.compactMap { server, state in
            guard case .failed = state.phase else { return nil }
            return server.displayName
        }
    }

    private var hasUndiscoveredServer: Bool {
        serverDiscoveryStates.contains { $0.1.phase == .idle }
    }

    @ViewBuilder
    private var discoveryStatusRows: some View {
        if isRefreshing {
            discoveryStatusRow(
                "Looking for tmux sessions…",
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
                "Refresh to find tmux sessions",
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
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    session.isSelected
                        ? chromeStyle.accent
                        : TerminalSelectionSheetPalette.secondary
                )
                .frame(width: 28, height: 32)

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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.id.sessionName)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsServerName {
                    Text(session.serverName)
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
        .accessibilityLabel("\(session.id.sessionName), \(session.serverName)")
        .accessibilityValue("Available")
        .accessibilityHint("Resume this session")
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecentSessionSwitcherRow: View {
    let session: RecentSessionSwitcherItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                .frame(width: 28, height: 32)

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
            $0.id.sessionName.localizedCaseInsensitiveContains(term)
                || $0.serverName.localizedCaseInsensitiveContains(term)
        }
    }

    private var groups: [ServerGroup] {
        Dictionary(grouping: matchingSessions, by: \.id.serverID)
            .compactMap { serverID, sessions in
                guard let serverName = sessions.first?.serverName else { return nil }
                return ServerGroup(
                    id: serverID,
                    serverName: serverName,
                    sessions: sessions.sorted {
                        $0.id.sessionName.localizedStandardCompare($1.id.sessionName)
                            == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                let comparison = lhs.serverName.localizedStandardCompare(rhs.serverName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
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
