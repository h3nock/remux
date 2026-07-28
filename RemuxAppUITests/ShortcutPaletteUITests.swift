import XCTest

final class ShortcutPaletteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment = [
            "REMUX_UI_TESTING": "1",
            "REMUX_DEBUG_SEED_CONNECTION": "1",
            "REMUX_DEBUG_SERVER_NAME": "UI Test Server",
            "REMUX_DEBUG_SERVER_HOST": "example.com",
            "REMUX_DEBUG_SERVER_USERNAME": "tester",
            "REMUX_DEBUG_SERVER_PASSWORD": "password",
            "REMUX_DEBUG_TMUX_SESSION": "ui-test",
        ]
    }

    func testLongPressControlOpensShortcutPalette() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()

        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Upload"].exists)
    }

    func testShortcutPaletteFavoritesAndSettingsEditWorkflow() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()
        tapVisiblePaletteTabs(["Favorites", "Shell", "Claude", "Codex"])

        addFavoriteShortcut(title: "/clear", text: "/clear")
        openShortcutPalette()
        XCTAssertTrue(app.buttons["/clear"].waitForExistence(timeout: 2))

        addFavoriteShortcut(title: "^C", text: "stop")
        openShortcutPalette()
        XCTAssertTrue(app.buttons["/clear"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["^C"].waitForExistence(timeout: 2))

        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))

        dragCollectionRow(named: "Shell", to: "Codex")
        XCTAssertTrue(app.navigationBars["Shortcuts"].exists)

        app.buttons["Edit"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Done").count, 1)
        XCTAssertGreaterThan(app.images.matching(identifier: "minus.circle.fill").count, 0)
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).count, 0)
        dragCollectionRow(named: "Shell", to: "Codex")
        deleteCollectionWithNativeControls(named: "Shell")
        XCTAssertFalse(collectionRow(named: "Shell").waitForExistence(timeout: 0.5))
        XCTAssertTrue(app.buttons["Restore Default Collections"].waitForExistence(timeout: 2))
        app.buttons["Restore Default Collections"].tap()
        XCTAssertTrue(collectionRow(named: "Shell").waitForExistence(timeout: 2))
    }

    func testShortcutCollectionDetailEditUsesNativeControls() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()

        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))

        let codexRow = collectionRow(named: "Codex")
        XCTAssertTrue(codexRow.waitForExistence(timeout: 2))
        codexRow.tap()
        XCTAssertTrue(app.navigationBars["Codex"].waitForExistence(timeout: 2))

        app.buttons["Edit"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "Done").count, 1)
        XCTAssertGreaterThan(app.images.matching(identifier: "minus.circle.fill").count, 0)
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).count, 0)
    }

    private func openTerminal() {
        let session = app.descendants(matching: .any)["library.session.resume"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        if !app.buttons["terminal.ctrl"].waitForExistence(timeout: 0.5) {
            terminal.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
        }

        XCTAssertTrue(app.buttons["terminal.ctrl"].waitForExistence(timeout: 5))
    }

    private func openShortcutPalette() {
        let control = app.buttons["terminal.ctrl"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)

        XCTAssertTrue(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["terminal.shortcuts.add"].waitForExistence(timeout: 2))
    }

    private func tapVisiblePaletteTabs(_ titles: [String]) {
        for title in titles {
            let tab = paletteTabButton(named: title)
            XCTAssertTrue(tab.waitForExistence(timeout: 2), "Missing palette tab \(title)")
            tab.tap()
        }
    }

    private func addFavoriteShortcut(title: String, text: String) {
        paletteTabButton(named: "Favorites").tap()
        XCTAssertTrue(app.buttons["terminal.shortcuts.add"].waitForExistence(timeout: 2))

        app.buttons["terminal.shortcuts.add"].tap()
        XCTAssertTrue(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))

        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.tap()
        titleField.typeText(title)

        let textField = app.textFields["Text"].firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.tap()
        textField.typeText(text)

        app.buttons["Save"].tap()
        XCTAssertFalse(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))
    }

    private func paletteTabButton(named title: String) -> XCUIElement {
        let query = app.buttons.matching(identifier: "terminal.shortcuts.tab.\(paletteTabID(for: title))")
        let firstMatch = query.firstMatch
        _ = firstMatch.waitForExistence(timeout: 2)
        return query.allElementsBoundByIndex.first { $0.exists && $0.isHittable } ?? firstMatch
    }

    private func paletteTabID(for title: String) -> String {
        switch title {
        case "Favorites":
            return "favorites"
        case "Shell":
            return "collection.shell"
        case "Claude":
            return "collection.claude"
        case "Codex":
            return "collection.codex"
        default:
            XCTFail("Unknown palette tab \(title)")
            return title
        }
    }

    private func dragCollectionRow(named source: String, to destination: String) {
        let sourceRow = collectionRow(named: source)
        let destinationRow = collectionRow(named: destination)
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 2), "Missing source row \(source)")
        XCTAssertTrue(destinationRow.waitForExistence(timeout: 2), "Missing destination row \(destination)")

        sourceRow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            .press(
                forDuration: 0.25,
                thenDragTo: destinationRow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            )
    }

    private func deleteCollectionWithNativeControls(named title: String) {
        let row = collectionRow(named: title)
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()

        let deleteButton = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
        deleteButton.tap()
    }

    private func collectionRow(named title: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: title).firstMatch
    }
}
