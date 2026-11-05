import SwiftUI

/// Which agents the Agents list shows, by Herdr's names for its agent filters (`client/shell/overlays.rs`).
/// An agent whose state isn't known yet reads as idle, so Idle includes it.
enum SessionAgentsFilter: CaseIterable, Hashable {
    case all
    case blocked
    case working
    case idle
    case done

    var title: String {
        switch self {
        case .all: "All"
        case .blocked: "Blocked"
        case .working: "Working"
        case .idle: "Idle"
        case .done: "Done"
        }
    }

    func includes(_ status: TerminalAgentStatus) -> Bool {
        switch self {
        case .all: true
        case .blocked: status == .blocked
        case .working: status == .working
        case .idle: status == .idle || status == .unknown
        case .done: status == .done
        }
    }
}

/// Every agent of the open Herdr sessions in one list, the most urgent first, as Herdr's client lists the
/// agents of all its machines when its agent list is sorted by priority (`client/shell/aggregate_navigation.rs`
/// `sort_aggregate_rows`): the agents of connected sessions before the others, then blocked, done, working
/// and idle (`client/shell.rs` `status_priority`), then the newest state change first.
struct SessionAgentsProjection: Equatable {
    struct Session: Equatable {
        let id: SavedWorkspace.ID
        /// The server, then the session unless it is Herdr's default one, as the banner names them.
        let title: String
        let runtimeState: TerminalRuntimeState
        /// The server boot the agents' pane ids belong to.
        let bootID: String?

        /// Not connected, so its agents' states may be out of date; Herdr's list dims them.
        var isStale: Bool {
            runtimeState != .connected
        }
    }

    struct Entry: Identifiable, Equatable {
        struct ID: Hashable {
            let session: SavedWorkspace.ID
            let pane: String
        }

        let session: Session
        let agent: HerdrAgentPresentation.Agent

        var id: ID { ID(session: session.id, pane: agent.paneID) }
    }

    let entries: [Entry]
    /// The agents are from more than one session, so each row names its session.
    let namesSessions: Bool

    /// `agents` gives an open Herdr session's agents.
    init(
        activeSessions: [ActiveSessionSwitcherItem],
        agents: (SavedWorkspace.ID) -> HerdrAgentPresentation?
    ) {
        var ranked: [(entry: Entry, recency: HerdrAgentRecency?)] = []
        for item in activeSessions {
            guard let presentation = agents(item.id) else { continue }
            let isDefault = item.sessionName == HerdrNotificationBannerContent.defaultSessionName
            let session = Session(
                id: item.id,
                title: isDefault ? item.serverName : "\(item.serverName) · \(item.sessionName)",
                runtimeState: item.runtimeState,
                bootID: presentation.bootID
            )
            for agent in presentation.agents {
                ranked.append((Entry(session: session, agent: agent), presentation.recency[agent.paneID]))
            }
        }
        // Agents that tie stay in the Sessions list's order, each session's in Herdr's.
        let order = ranked.indices.sorted { leftIndex, rightIndex in
            let left = ranked[leftIndex]
            let right = ranked[rightIndex]
            if left.entry.session.isStale != right.entry.session.isStale {
                return !left.entry.session.isStale
            }
            if left.entry.agent.state.status != right.entry.agent.state.status {
                return left.entry.agent.state.status > right.entry.agent.state.status
            }
            switch (left.recency, right.recency) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return leftIndex < rightIndex
            }
        }
        entries = order.map { ranked[$0].entry }
        namesSessions = Set(entries.map(\.session.id)).count > 1
    }

    func count(_ filter: SessionAgentsFilter) -> Int {
        entries.count { filter.includes($0.agent.state.status) }
    }

    /// The agents `filter` shows, the most urgent first.
    func entries(_ filter: SessionAgentsFilter) -> [Entry] {
        entries.filter { filter.includes($0.agent.state.status) }
    }

    /// The agents `filter` shows with those in `order` first, in that order, so rows stay where they are
    /// while the list is open; then any others, the most urgent first.
    func entries(_ filter: SessionAgentsFilter, keeping order: [Entry.ID]) -> [Entry] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        let shown = entries(filter)
        let kept = shown
            .compactMap { entry in position[entry.id].map { (entry, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return kept + shown.filter { position[$0.id] == nil }
    }
}

/// The Sessions sheet's Agents list: filters for every agent and for each state, in a row that scrolls
/// sideways when it doesn't fit, then the agents, the most urgent first. A row opens the agent's pane.
///
/// The order is taken when the list appears and when the filter changes. Meanwhile states change in place
/// and rows keep their places, so a row doesn't move under a finger. The rows shown become the order kept,
/// so an agent that appears, or comes back to the filter, is added after the rest and keeps its place from
/// then on. Herdr's client sorts again at once.
struct SessionAgentsList: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: SessionAgentsProjection
    @Binding var filter: SessionAgentsFilter
    let onOpen: (SessionAgentsProjection.Session, HerdrAgentPresentation.Agent) -> Void

    @State private var order: [SessionAgentsProjection.Entry.ID] = []

    var body: some View {
        let entries = projection.entries(filter, keeping: order)
        VStack(spacing: 0) {
            filterBar
            List {
                ForEach(entries) { entry in
                    Button {
                        onOpen(entry.session, entry.agent)
                    } label: {
                        SessionAgentRow(
                            agent: entry.agent,
                            session: entry.session,
                            namesSession: projection.namesSessions
                        )
                    }
                    .buttonStyle(.plain)
                    .sessionSwitcherListRow(accessibilityIdentifier: "terminal.agents.agent")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if entries.isEmpty {
                    emptyResults
                }
            }
            .accessibilityIdentifier("terminal.agents.list")
        }
        .onAppear {
            order = projection.entries(filter).map(\.id)
        }
        .onChange(of: filter) { _, filter in
            order = projection.entries(filter).map(\.id)
        }
        .onChange(of: entries.map(\.id)) { _, shown in
            order = shown
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            filterChips
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.vertical, 8)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(SessionAgentsFilter.allCases, id: \.self) { option in
                let isSelected = option == filter
                let count = projection.count(option)
                Button {
                    Haptic.selection()
                    filter = option
                } label: {
                    Text("\(option.title) \(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? chromeStyle.accentForeground : TerminalSelectionSheetPalette.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? chromeStyle.accent : TerminalSelectionSheetPalette.controlFill,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityValue(count == 1 ? "1 agent" : "\(count) agents")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("terminal.agents.filter.\(option.title.lowercased())")
            }
        }
    }

    private var emptyResults: some View {
        let title = switch filter {
        case .all: "No Agents"
        case .blocked: "No Agents Blocked"
        case .working: "No Agents Working"
        case .idle: "No Agents Idle"
        case .done: "No Agents Done"
        }
        return ContentUnavailableView {
            Label(title, systemImage: "terminal")
        } description: {
            if filter == .all {
                Text("Agents in your open Herdr sessions appear here.")
            }
        }
    }
}

/// One agent: its dot, its name over where it is, and its state. Where it is starts with its session
/// when the list has more than one session's agents, as Herdr's list of all its machines' agents names each
/// agent's machine.
private struct SessionAgentRow: View {
    let agent: HerdrAgentPresentation.Agent
    let session: SessionAgentsProjection.Session
    let namesSession: Bool

    var body: some View {
        HStack(spacing: 12) {
            TerminalAgentDot(status: agent.state.status, size: 10, isStale: session.isStale)

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundStyle(TerminalSelectionSheetPalette.primary)
                    .lineLimit(1)

                if !location.isEmpty {
                    Text(location)
                        .font(.footnote)
                        .foregroundStyle(TerminalSelectionSheetPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(agent.state.word)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.isStale ? TerminalAgentStatus.unknown.color : agent.state.status.color)
                .lineLimit(1)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens its pane")
        .accessibilityAddTraits(.isButton)
    }

    private var location: String {
        [namesSession ? session.title : "", agent.place].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [agent.name, namesSession ? session.title : "", agent.place, agent.state.word]
            .filter { !$0.isEmpty }
        if session.isStale {
            parts.append(TerminalRuntimeStatusPresentation.projection(for: session.runtimeState).label)
        }
        return parts.joined(separator: ", ")
    }
}
