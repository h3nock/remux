import SwiftUI

/// Every agent of the open Herdr sessions in one list, grouped by what each needs from the user: blocked, done,
/// working, idle, in Herdr's order of urgency (`client/shell.rs` `status_priority`), the newest state change
/// first in each group. An agent whose state isn't known yet reads as idle. An agent whose session isn't
/// connected keeps the group and the place of its last known state: its session's status already says the
/// link is down, and a list that regrouped on every reconnect would move every row twice. Its row is dimmed.
struct SessionAgentsProjection: Equatable {
    struct Session: Equatable {
        let id: SavedWorkspace.ID
        let serverName: String
        /// Nil for Herdr's default session, which a row doesn't name, as the banner doesn't.
        let sessionName: String?
        let runtimeState: TerminalRuntimeState
        /// The server boot the agents' pane ids belong to.
        let bootID: String?

        /// Not connected, so its agents' states may be out of date.
        var isStale: Bool {
            runtimeState != .connected
        }
    }

    /// A group of the list: a state.
    enum Group: Hashable {
        case blocked
        case done
        case working
        case idle

        init(_ status: TerminalAgentStatus) {
            self = switch status {
            case .blocked: .blocked
            case .done: .done
            case .working: .working
            case .idle, .unknown: .idle
            }
        }

        var title: String {
            switch self {
            case .blocked: "Blocked"
            case .done: "Done"
            case .working: "Working"
            case .idle: "Idle"
            }
        }

        var status: TerminalAgentStatus {
            switch self {
            case .blocked: .blocked
            case .done: .done
            case .working: .working
            case .idle: .idle
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .blocked: 0
            case .done: 1
            case .working: 2
            case .idle: 3
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        /// A row is its agent in one group: when the agent changes group, the list takes the row out where it
        /// was and puts a new one in where it belongs, so the row fades between the two places. Sliding the
        /// same row there draws it across every row between them.
        struct ID: Hashable {
            let session: SavedWorkspace.ID
            let pane: String
            let group: Group
        }

        let session: Session
        let agent: HerdrAgentPresentation.Agent
        /// The title the agent's program sets for itself, word for word, when it sets one.
        let title: String?
        let group: Group

        var id: ID { ID(session: session.id, pane: agent.paneID, group: group) }

        /// What the row leads with: what the agent is working on, in its program's words, else its name.
        var heading: String { title ?? agent.name }

        /// The name the user gave the agent, unless the heading or the tab already says it.
        var givenName: String? { agent.givenName == heading ? nil : agent.givenName }
    }

    struct Section: Identifiable, Equatable {
        let group: Group
        let entries: [Entry]

        var id: Group { group }
    }

    /// How many agents Home shows before the row that opens the whole list.
    static let homeEntryCount = 3

    /// Every agent, in the list's order.
    let entries: [Entry]
    let sections: [Section]
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
                serverName: item.serverName,
                sessionName: isDefault ? nil : item.sessionName,
                runtimeState: item.runtimeState,
                bootID: presentation.bootID
            )
            for agent in presentation.agents {
                let group = Group(agent.state.status)
                let entry = Entry(session: session, agent: agent, title: presentation.titles[agent.paneID], group: group)
                ranked.append((entry, presentation.recency[agent.paneID]))
            }
        }
        // Agents that tie stay in the Sessions list's order, each session's in Herdr's.
        let order = ranked.indices.sorted { leftIndex, rightIndex in
            let left = ranked[leftIndex]
            let right = ranked[rightIndex]
            if left.entry.group != right.entry.group {
                return left.entry.group.rank < right.entry.group.rank
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
        var sections: [Section] = []
        for entry in entries {
            if let last = sections.last, last.group == entry.group {
                sections[sections.count - 1] = Section(group: entry.group, entries: last.entries + [entry])
            } else {
                sections.append(Section(group: entry.group, entries: [entry]))
            }
        }
        self.sections = sections
        namesSessions = Set(entries.map(\.session.id)).count > 1
    }

    /// The first agents of the list, which Home shows.
    var homeEntries: [Entry] {
        Array(entries.prefix(Self.homeEntryCount))
    }

    /// Whether the list has agents Home doesn't show, so Home ends with the row that opens it.
    var hasMoreThanHomeShows: Bool {
        entries.count > Self.homeEntryCount
    }

    /// What all the agents are doing, group by group in the list's order: "2 blocked · 5 working · 17 idle".
    /// The whole line comes first, then the same with one more group left off its end each time, for a row
    /// too narrow for the whole.
    var summaries: [String] {
        let parts = sections.map { section in
            "\(section.entries.count) \(section.group.status.word)"
        }
        return parts.indices.reversed().map { parts[...$0].joined(separator: " · ") }
    }

    /// Where an agent is, from the whole line to ever shorter ones, for a row to show the longest that fits.
    /// The order never changes, the general before the specific: the machine, the session, the workspace and
    /// the tab, then the name the user gave the agent. A line too long loses whole names, never letters: first
    /// the session, then the workspace, which leaves "…" before the tab so the tab still reads as a tab, then
    /// the given name, then the machine. The last name of the place always stays.
    static func placeLines(
        machine: String?,
        session: String?,
        workspace: String?,
        tab: String?,
        givenName: String?
    ) -> [String] {
        func line(machine: String?, session: String?, workspace: String?, givenName: String?) -> String {
            let place: String? = switch (workspace, tab) {
            case let (workspace?, tab?): "\(workspace) › \(tab)"
            case let (nil, tab?): tab
            case let (workspace, nil): workspace
            }
            return [machine, session, place, givenName].compactMap { $0 }.joined(separator: " · ")
        }
        // Without a tab the workspace is the place's last name, so it stays.
        let elided = tab == nil ? workspace : workspace.map { _ in "…" }
        var lines: [String] = []
        for next in [
            line(machine: machine, session: session, workspace: workspace, givenName: givenName),
            line(machine: machine, session: nil, workspace: workspace, givenName: givenName),
            line(machine: machine, session: nil, workspace: elided, givenName: givenName),
            line(machine: machine, session: nil, workspace: elided, givenName: nil),
            line(machine: nil, session: nil, workspace: elided, givenName: nil),
        ] where lines.last != next && !next.isEmpty {
            lines.append(next)
        }
        return lines
    }
}

extension SessionAgentsProjection.Entry {
    /// Where the agent is, the longest line first. The machine and the session are named when the list has
    /// more than one session's agents.
    func placeLines(namesSession: Bool) -> [String] {
        SessionAgentsProjection.placeLines(
            machine: namesSession ? session.serverName : nil,
            session: namesSession ? session.sessionName : nil,
            workspace: agent.workspaceName,
            tab: agent.tabName,
            givenName: givenName
        )
    }
}

/// Lets one touch open one agent. A row that fades into a new place as a finger lifts can report the tap twice,
/// once for each place (seen on iOS 26.4), and each would open a pane.
struct AgentOpenGate {
    private var last: ContinuousClock.Instant?

    /// Whether an open asked for at `now` goes ahead: not within half a second of the one before.
    mutating func admits(at now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < .milliseconds(500) { return false }
        last = now
        return true
    }
}

/// The Agents page: a section for each group that has agents, each of which folds away under its header and
/// keeps its count. A row opens the agent's pane.
///
/// The list follows the agents as they change. A row whose agent changes state leaves its section and appears
/// at the top of its new one, and the rows between make room, in the list's own animation.
struct SessionAgentsList: View {
    let projection: SessionAgentsProjection
    let onOpen: (SessionAgentsProjection.Session, HerdrAgentPresentation.Agent) -> Void

    /// The groups folded by hand, for as long as the page is open.
    @State private var folded: Set<SessionAgentsProjection.Group> = []
    @State private var gate = AgentOpenGate()

    var body: some View {
        List {
            ForEach(projection.sections) { section in
                Section {
                    if !folded.contains(section.group) {
                        ForEach(section.entries) { entry in
                            Button {
                                guard gate.admits() else { return }
                                Haptic.selection()
                                onOpen(entry.session, entry.agent)
                            } label: {
                                SessionAgentRow(entry: entry, namesSession: projection.namesSessions, showsState: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("agents.agent")
                            .libraryHomeListRowSurface()
                        }
                    }
                } header: {
                    header(section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .libraryHomeGroupedScrollBackground()
        .animation(.default, value: projection.entries.map(\.id))
        .overlay {
            if projection.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "terminal")
                } description: {
                    Text("Agents in your open Herdr sessions appear here.")
                }
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("agents.list")
    }

    private func header(_ section: SessionAgentsProjection.Section) -> some View {
        let isFolded = folded.contains(section.group)
        return HStack(spacing: 6) {
            Circle()
                .fill(section.group.status.color)
                .frame(width: 8, height: 8)
            Text(section.group.title)
            Text("\(section.entries.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isFolded ? 0 : 90))
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        .frame(maxWidth: .infinity, minHeight: 32)
        // The whole header folds its section, not only its words: a button in a list's header takes touches
        // only where its label draws something, so the header itself takes the tap.
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.selection()
            withAnimation(.snappy) {
                if isFolded { folded.remove(section.group) } else { folded.insert(section.group) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(section.group.title)
        .accessibilityValue(section.entries.count == 1 ? "1 agent" : "\(section.entries.count) agents")
        .accessibilityHint(isFolded ? "Shows its agents" : "Hides its agents")
        .accessibilityIdentifier("agents.section.\(section.group.title.lowercased())")
    }
}

/// Home's Agents section: the list's first agents, each saying its state, since Home has no header to say it,
/// and, when the list has more, a last row that says what all the agents are doing and opens the list.
struct SessionAgentsHomeRows: View {
    let projection: SessionAgentsProjection
    let onOpen: (SessionAgentsProjection.Session, HerdrAgentPresentation.Agent) -> Void
    let onShowAll: () -> Void

    @State private var gate = AgentOpenGate()

    var body: some View {
        ForEach(projection.homeEntries) { entry in
            Button {
                guard gate.admits() else { return }
                onOpen(entry.session, entry.agent)
            } label: {
                SessionAgentRow(entry: entry, namesSession: projection.namesSessions, showsState: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.agents.agent")
            .libraryHomeListRowSurface()
        }

        if projection.hasMoreThanHomeShows {
            Button(action: onShowAll) {
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        ForEach(projection.summaries, id: \.self) { summary in
                            Text(summary).lineLimit(1)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All agents")
            .accessibilityValue(projection.summaries.first ?? "")
            .accessibilityIdentifier("library.agents.all")
            .libraryHomeListRowSurface()
        }
    }
}

/// One agent: its program's mark, what it is working on in its program's words, and where it is. In the list
/// its section says its state. On Home (`showsState`) the mark carries the state's dot, as a tab's does in the
/// Tabs sheet, and the state's word comes first on the second line, in its colour when the agent is waiting
/// for the user. While the agent's session isn't connected the row says so in words and its mark is dimmed;
/// the rest stays at full strength, since the row still opens the agent.
private struct SessionAgentRow: View {
    let entry: SessionAgentsProjection.Entry
    let namesSession: Bool
    let showsState: Bool

    var body: some View {
        HStack(spacing: 12) {
            TerminalProgramStack(programs: [entry.agent.program], paneCount: 1, dot: showsState ? status : nil)
                .frame(width: TerminalProgramStack.tile.width, alignment: .leading)
                .opacity(entry.session.isStale ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.heading)
                    .font(.headline)
                    .lineLimit(showsState ? 1 : 2)

                let lines = entry.placeLines(namesSession: namesSession)
                if showsState || entry.session.isStale || !lines.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines.isEmpty ? [""] : lines, id: \.self) { line in
                            secondLine(place: line).lineLimit(1)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens its pane")
        .accessibilityAddTraits(.isButton)
    }

    private var status: TerminalAgentStatus {
        entry.agent.state.status
    }

    /// The line under the heading starts with one word, then says where the agent is. While the agent's session
    /// isn't connected the word is the session's status, in the app's word for it, so opening the agent then is
    /// no surprise. It stands in for the state's word, which Home shows otherwise: the state is the last one
    /// known, the dot still shows it, and two words would leave a tab's name about ten characters.
    private func secondLine(place: String) -> Text {
        var parts: [Text] = []
        if entry.session.isStale {
            let label = TerminalRuntimeStatusPresentation.projection(for: entry.session.runtimeState).label
            parts.append(Text(label).fontWeight(.medium))
        } else if showsState {
            let waits = status == .blocked || status == .done
            parts.append(
                Text(entry.agent.state.word)
                    .fontWeight(.medium)
                    .foregroundStyle(waits ? AnyShapeStyle(status.color) : AnyShapeStyle(.secondary))
            )
        }
        if !place.isEmpty {
            parts.append(Text(place))
        }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text(" · ") + $1 }
    }

    private var accessibilityLabel: String {
        var parts = [entry.heading, entry.agent.state.word]
        parts += entry.placeLines(namesSession: namesSession).prefix(1)
        if entry.session.isStale {
            parts.append(TerminalRuntimeStatusPresentation.projection(for: entry.session.runtimeState).label)
        }
        return parts.joined(separator: ", ")
    }
}
