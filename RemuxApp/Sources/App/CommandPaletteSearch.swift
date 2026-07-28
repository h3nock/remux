import Foundation

enum CommandPaletteAction: Equatable {
    case addConnection
    case newSession(SavedServer.ID)
    case appCommand(AppKeyboardCommand)
    case viewport(TerminalViewportSnapshot)
}

struct CommandPaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let action: CommandPaletteAction
    let isEnabled: Bool

    init(
        id: String,
        title: String,
        subtitle: String?,
        action: CommandPaletteAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.isEnabled = isEnabled
    }
}

enum CommandPaletteSelectionDirection {
    case previous
    case next
}

enum CommandPaletteSelection {
    static func initialID(in results: [CommandPaletteItem]) -> CommandPaletteItem.ID? {
        results.first(where: \.isEnabled)?.id
    }

    static func moving(
        from selectedID: CommandPaletteItem.ID?,
        direction: CommandPaletteSelectionDirection,
        in results: [CommandPaletteItem]
    ) -> CommandPaletteItem.ID? {
        let enabledResults = results.filter(\.isEnabled)
        guard !enabledResults.isEmpty else { return nil }
        guard
            let selectedID,
            let selectedIndex = enabledResults.firstIndex(where: { $0.id == selectedID })
        else {
            return direction == .previous ? enabledResults.last?.id : enabledResults.first?.id
        }

        let offset = direction == .previous ? -1 : 1
        let nextIndex = min(max(selectedIndex + offset, 0), enabledResults.count - 1)
        return enabledResults[nextIndex].id
    }
}

struct CommandPaletteState: Equatable {
    private(set) var results: [CommandPaletteItem]
    private(set) var selectedResultID: CommandPaletteItem.ID?
    private(set) var appliedQuery: String

    init(
        results: [CommandPaletteItem],
        appliedQuery: String = ""
    ) {
        self.results = results
        selectedResultID = CommandPaletteSelection.initialID(in: results)
        self.appliedQuery = appliedQuery
    }

    var selectedResult: CommandPaletteItem? {
        guard let selectedResultID else { return nil }
        return results.first {
            $0.id == selectedResultID && $0.isEnabled
        }
    }

    mutating func replaceResults(_ newResults: [CommandPaletteItem]) {
        results = newResults
        selectedResultID = CommandPaletteSelection.initialID(in: newResults)
    }

    mutating func replaceResults(
        _ newResults: [CommandPaletteItem],
        for query: String
    ) {
        appliedQuery = query
        replaceResults(newResults)
    }

    mutating func refreshAvailability(
        query: String,
        commands: [CommandPaletteItem],
        snapshots: [TerminalViewportSnapshot]
    ) {
        let currentSelection = query == appliedQuery ? selectedResultID : nil
        replaceResults(
            CommandPaletteSearch.results(
                query: query,
                commands: commands,
                snapshots: snapshots
            ),
            for: query
        )
        if let currentSelection,
           results.contains(where: {
               $0.id == currentSelection && $0.isEnabled
           }) {
            selectedResultID = currentSelection
        }
    }

    mutating func moveSelection(
        _ direction: CommandPaletteSelectionDirection
    ) {
        selectedResultID = CommandPaletteSelection.moving(
            from: selectedResultID,
            direction: direction,
            in: results
        )
    }
}

enum CommandPaletteSearch {
    static func results(
        query: String,
        commands: [CommandPaletteItem],
        snapshots: [TerminalViewportSnapshot]
    ) -> [CommandPaletteItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }

        let matchingCommands = commands.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle?.localizedCaseInsensitiveContains(query) == true
        }
        let matchingText = snapshots.flatMap { snapshot in
            snapshot.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { lineNumber, line -> CommandPaletteItem? in
                    let snippet = String(line).trimmingCharacters(in: .whitespaces)
                    guard snippet.localizedCaseInsensitiveContains(query) else { return nil }
                    return CommandPaletteItem(
                        id: "viewport:\(snapshot.workspaceID):\(snapshot.paneID):\(lineNumber)",
                        title: snippet.isEmpty ? "Matching blank line" : snippet,
                        subtitle: [
                            snapshot.serverName,
                            snapshot.sessionName,
                            snapshot.windowName,
                            "Pane \(snapshot.paneIndex)",
                        ].joined(separator: " · "),
                        action: .viewport(snapshot)
                    )
                }
        }
        return matchingCommands + matchingText
    }
}
