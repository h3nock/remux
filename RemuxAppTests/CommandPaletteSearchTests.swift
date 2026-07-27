import XCTest
@testable import Remux

final class CommandPaletteSearchTests: XCTestCase {
    func testMatchesCommandsAndVisibleLinesCaseInsensitively() {
        let snapshot = TerminalViewportSnapshot(
            workspaceID: UUID(),
            serverName: "Build Host",
            sessionName: "deploy",
            windowID: UUID(),
            windowName: "logs",
            paneID: UUID(),
            paneIndex: 2,
            text: "ready\nFATAL: disk full\nretrying"
        )
        let commands = [
            CommandPaletteItem(
                id: "add",
                title: "Add Connection",
                subtitle: nil,
                action: .addConnection
            ),
        ]

        XCTAssertEqual(
            CommandPaletteSearch.results(
                query: "connection",
                commands: commands,
                snapshots: [snapshot]
            ).map(\.title),
            ["Add Connection"]
        )
        let textResult = CommandPaletteSearch.results(
            query: "fatal",
            commands: commands,
            snapshots: [snapshot]
        )
        XCTAssertEqual(textResult.map(\.title), ["FATAL: disk full"])
        XCTAssertEqual(textResult.first?.subtitle, "Build Host · deploy · logs · Pane 2")
    }

    func testEmptyQueryReturnsOnlyCommands() {
        let command = CommandPaletteItem(
            id: "home",
            title: "Home",
            subtitle: nil,
            action: .appCommand(.home)
        )

        XCTAssertEqual(
            CommandPaletteSearch.results(query: "", commands: [command], snapshots: []),
            [command]
        )
    }

    func testEmptyQueryKeepsUnavailableCommandDisabled() {
        let command = CommandPaletteItem(
            id: "panes",
            title: "Show Panes",
            subtitle: nil,
            action: .appCommand(.panes),
            isEnabled: false
        )

        XCTAssertEqual(
            CommandPaletteSearch.results(query: "", commands: [command], snapshots: [])
                .first?
                .isEnabled,
            false
        )
    }
}
