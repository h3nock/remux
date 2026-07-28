import XCTest
import UIKit
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

    func testSelectionStartsAtFirstEnabledResult() {
        let disabled = item(id: "disabled", isEnabled: false)
        let first = item(id: "first")
        let second = item(id: "second")

        XCTAssertEqual(
            CommandPaletteSelection.initialID(in: [disabled, first, second]),
            first.id
        )
    }

    func testSelectionMovesPastDisabledResultsAndStopsAtEnds() {
        let first = item(id: "first")
        let disabled = item(id: "disabled", isEnabled: false)
        let last = item(id: "last")
        let results = [first, disabled, last]

        XCTAssertEqual(
            CommandPaletteSelection.moving(
                from: first.id,
                direction: .next,
                in: results
            ),
            last.id
        )
        XCTAssertEqual(
            CommandPaletteSelection.moving(
                from: last.id,
                direction: .next,
                in: results
            ),
            last.id
        )
        XCTAssertEqual(
            CommandPaletteSelection.moving(
                from: last.id,
                direction: .previous,
                in: results
            ),
            first.id
        )
        XCTAssertEqual(
            CommandPaletteSelection.moving(
                from: first.id,
                direction: .previous,
                in: results
            ),
            first.id
        )
    }

    func testStateStartsWithCommandsAndFirstEnabledSelection() {
        let disabled = item(id: "disabled", isEnabled: false)
        let first = item(id: "first")
        let state = CommandPaletteState(results: [disabled, first])

        XCTAssertEqual(state.results, [disabled, first])
        XCTAssertEqual(state.selectedResultID, first.id)
        XCTAssertEqual(state.selectedResult, first)
    }

    func testQueryResultReplacementResetsSelectionToFirstEnabled() {
        let first = item(id: "first")
        let second = item(id: "second")
        var state = CommandPaletteState(results: [first, second])

        state.moveSelection(.next)
        XCTAssertEqual(state.selectedResultID, second.id)

        state.replaceResults([first, second])
        XCTAssertEqual(state.selectedResultID, first.id)
    }

    func testAvailabilityRefreshResetsSelectionWhenQueryReplacementIsPending() {
        let first = CommandPaletteItem(
            id: "first",
            title: "Target First",
            subtitle: nil,
            action: .appCommand(.panes)
        )
        let second = CommandPaletteItem(
            id: "second",
            title: "Target Second",
            subtitle: nil,
            action: .appCommand(.home)
        )
        var state = CommandPaletteState(results: [first, second])
        state.moveSelection(.next)

        state.refreshAvailability(
            query: "target",
            commands: [first, second],
            snapshots: []
        )

        XCTAssertEqual(state.selectedResultID, first.id)
    }

    func testStateRefreshesReadyCommandToDisconnectedWhileKeepingQueryFiltering() {
        let available = CommandPaletteItem(
            id: "panes",
            title: "Show Panes",
            subtitle: nil,
            action: .appCommand(.panes)
        )
        let unrelated = item(id: "unrelated")
        var state = CommandPaletteState(
            results: [available],
            appliedQuery: "panes"
        )

        state.refreshAvailability(
            query: "panes",
            commands: [
                CommandPaletteItem(
                    id: available.id,
                    title: available.title,
                    subtitle: available.subtitle,
                    action: available.action,
                    isEnabled: false
                ),
                unrelated,
            ],
            snapshots: []
        )

        XCTAssertEqual(state.results.map(\.id), [available.id])
        XCTAssertFalse(state.results[0].isEnabled)
        XCTAssertNil(state.selectedResultID)
    }

    func testStateRefreshesDisconnectedCommandToReadyWithoutReplacingValidSelection() {
        let newlyAvailable = CommandPaletteItem(
            id: "first",
            title: "Target First",
            subtitle: nil,
            action: .appCommand(.panes),
            isEnabled: false
        )
        let selected = CommandPaletteItem(
            id: "second",
            title: "Target Second",
            subtitle: nil,
            action: .appCommand(.home)
        )
        var state = CommandPaletteState(
            results: [newlyAvailable, selected],
            appliedQuery: "target"
        )

        state.refreshAvailability(
            query: "target",
            commands: [
                CommandPaletteItem(
                    id: newlyAvailable.id,
                    title: newlyAvailable.title,
                    subtitle: newlyAvailable.subtitle,
                    action: newlyAvailable.action
                ),
                selected,
                item(id: "unrelated"),
            ],
            snapshots: []
        )

        XCTAssertEqual(state.results.map(\.id), ["first", "second"])
        XCTAssertTrue(state.results[0].isEnabled)
        XCTAssertEqual(state.selectedResultID, selected.id)
    }

    func testFloatingLayoutCapsAtSixRowsAndKeepsEmptyStateCompact() {
        XCTAssertEqual(CommandPaletteLayout.inputRowHeight, 44)
        XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 0), 120)
        XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 1), 56)
        XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 6), 336)
        XCTAssertEqual(CommandPaletteLayout.resultAreaHeight(for: 9), 336)
    }

    func testFloatingLayoutUsesBalancedSpacing() {
        XCTAssertEqual(CommandPaletteLayout.screenMargin, 20)
        XCTAssertEqual(CommandPaletteLayout.cardInset, 10)
        XCTAssertEqual(CommandPaletteLayout.innerCornerRadius, 12)
    }

    @MainActor
    func testSearchFieldUsesCompactDynamicTypeFont() {
        let field = CommandPaletteTextField()
        let expected = UIFont.preferredFont(forTextStyle: .footnote)

        XCTAssertEqual(field.font?.pointSize, expected.pointSize)
        XCTAssertEqual(
            field.font?.fontDescriptor.object(forKey: .textStyle) as? String,
            UIFont.TextStyle.footnote.rawValue
        )
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
    }

    @MainActor
    func testSearchFieldRoutesNavigationAndActivationKeysWithoutModifiers() {
        let field = CommandPaletteTextField()
        var actions: [String] = []
        field.onMoveSelection = {
            switch $0 {
            case .previous:
                actions.append("previous")
            case .next:
                actions.append("next")
            }
        }
        field.onActivateSelection = {
            actions.append("activate")
        }
        field.onDismiss = {
            actions.append("dismiss")
        }

        XCTAssertTrue(
            field.handleKeyPress(
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            field.handleKeyPress(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: []
            )
        )
        XCTAssertTrue(field.handleKeyPress(input: "\r", modifierFlags: []))
        XCTAssertTrue(
            field.handleKeyPress(
                input: UIKeyCommand.inputEscape,
                modifierFlags: []
            )
        )
        XCTAssertFalse(
            field.handleKeyPress(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .command
            )
        )
        XCTAssertFalse(field.handleKeyPress(input: "a", modifierFlags: []))
        XCTAssertEqual(actions, ["previous", "next", "activate", "dismiss"])
    }

    private func item(
        id: String,
        isEnabled: Bool = true
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: id,
            subtitle: nil,
            action: .addConnection,
            isEnabled: isEnabled
        )
    }
}
