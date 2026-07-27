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
                        ].joined(separator: " · "),
                        action: .viewport(snapshot)
                    )
                }
        }
        return matchingCommands + matchingText
    }
}
