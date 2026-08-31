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
        attachScreenshot(named: "terminal-shortcuts-shared-chrome")
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

    func testShortcutPaletteAddEditFavoriteAndDeleteWorkflow() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()
        addFavoriteShortcut(title: "A", text: "x")

        openShortcutPalette()
        let original = app.buttons["A"]
        XCTAssertTrue(original.waitForExistence(timeout: 2))
        openContextMenu(for: original)
        app.buttons["Edit"].tap()

        XCTAssertTrue(app.navigationBars["Edit Shortcut"].waitForExistence(timeout: 2))
        appendText("2", to: app.textFields["Title"].firstMatch, expecting: "A2")
        appendText("h", to: app.textFields["Hint"].firstMatch, expecting: "h")
        appendText("y", to: editorActionField(), expecting: "xy")
        app.buttons["Save"].tap()
        XCTAssertFalse(app.navigationBars["Edit Shortcut"].waitForExistence(timeout: 2))

        openShortcutPalette()
        let editedFavorite = app.buttons["A2"]
        XCTAssertTrue(editedFavorite.waitForExistence(timeout: 2))
        openContextMenu(for: editedFavorite)
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 2))
        app.buttons["Remove from Favorites"].tap()
        XCTAssertFalse(app.buttons["A2"].waitForExistence(timeout: 1))

        paletteTabButton(named: "Shell").tap()
        let editedInCollection = app.buttons["A2"]
        XCTAssertTrue(editedInCollection.waitForExistence(timeout: 2))
        openContextMenu(for: editedInCollection)
        XCTAssertTrue(app.buttons["Add to Favorites"].waitForExistence(timeout: 2))
        app.buttons["Add to Favorites"].tap()
        paletteTabButton(named: "Favorites").tap()
        XCTAssertTrue(app.buttons["A2"].waitForExistence(timeout: 2))

        let executed = app.buttons["A2"]
        XCTAssertTrue(executed.waitForExistence(timeout: 2))
        openContextMenu(for: executed)
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Delete A2"].waitForExistence(timeout: 2))
        app.buttons["Delete A2"].tap()
        XCTAssertFalse(app.buttons["A2"].waitForExistence(timeout: 2))
    }

    func testShortcutEditorModesValidationAndCancel() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()
        paletteTabButton(named: "Favorites").tap()
        app.buttons["terminal.shortcuts.add"].tap()

        XCTAssertTrue(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled)

        enterText("M", in: app.textFields["Title"].firstMatch)
        XCTAssertFalse(save.isEnabled)
        enterText("x", in: editorActionField())
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.staticTexts["x⏎"].exists)

        let autoSend = app.switches["Auto-send Enter"]
        XCTAssertTrue(autoSend.exists)
        autoSend.tap()
        XCTAssertTrue(app.staticTexts["x"].exists)

        app.buttons["Ctrl"].tap()
        let controlField = editorActionField()
        XCTAssertTrue(controlField.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForValue(controlField, expected: "c"))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(app.staticTexts["^C"].exists)
        appendText("c", to: controlField, expecting: "cc")
        XCTAssertFalse(save.isEnabled)

        app.buttons["Key"].tap()
        XCTAssertTrue(app.buttons["Key, Esc"].waitForExistence(timeout: 2))
        app.buttons["Key, Esc"].tap()
        let tabOption = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Tab",
                "terminal.toolbar-key.2"
            )
        ).firstMatch
        XCTAssertTrue(tabOption.waitForExistence(timeout: 2))
        tabOption.tap()
        app.scrollViews.firstMatch.swipeUp()
        app.switches["Ctrl"].tap()
        XCTAssertTrue(waitForValue(app.switches["Ctrl"], expected: "1"))
        app.switches["Opt"].tap()
        XCTAssertTrue(waitForValue(app.switches["Opt"], expected: "1"))
        app.switches["Shift"].tap()
        XCTAssertTrue(waitForValue(app.switches["Shift"], expected: "1"))
        XCTAssertTrue(app.staticTexts["Ctrl-Opt-Shift-Tab"].waitForExistence(timeout: 2))
        XCTAssertTrue(save.isEnabled)

        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))
        openShortcutPalette()
        XCTAssertFalse(app.buttons["M"].exists)
    }

    func testShortcutSettingsCollectionAndShortcutLifecycle() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()
        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))

        app.buttons["Add Collection"].tap()
        XCTAssertTrue(app.navigationBars["New Collection"].waitForExistence(timeout: 2))
        let collectionSave = app.buttons["Save"]
        XCTAssertFalse(collectionSave.isEnabled)
        enterText("O", in: app.textFields["Name"].firstMatch)
        XCTAssertTrue(collectionSave.isEnabled)
        app.buttons["terminal"].tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(collectionRow(named: "O").waitForExistence(timeout: 2))

        collectionRow(named: "O").tap()
        XCTAssertTrue(app.navigationBars["O"].waitForExistence(timeout: 2))
        app.buttons["Collection Actions"].tap()
        app.buttons["Rename Collection"].tap()
        XCTAssertTrue(app.navigationBars["Edit Collection"].waitForExistence(timeout: 2))
        appendText("2", to: app.textFields["Name"].firstMatch, expecting: "O2")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["O2"].waitForExistence(timeout: 2))

        app.buttons["Add Shortcut"].tap()
        XCTAssertTrue(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))
        enterText("R", in: app.textFields["Title"].firstMatch)
        enterText("h", in: app.textFields["Hint"].firstMatch)
        enterText("x", in: editorActionField())
        app.buttons["Save"].tap()
        XCTAssertTrue(shortcutRow(named: "R").waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["h"].exists)

        app.buttons["Add Shortcut"].tap()
        enterText("S", in: app.textFields["Title"].firstMatch)
        enterText("z", in: editorActionField())
        app.buttons["Save"].tap()
        XCTAssertTrue(shortcutRow(named: "S").waitForExistence(timeout: 2))

        XCTAssertLessThan(shortcutRow(named: "R").frame.midY, shortcutRow(named: "S").frame.midY)
        app.buttons["Edit"].tap()
        dragShortcutRow(named: "R", to: "S")
        app.buttons["Done"].tap()
        XCTAssertGreaterThan(shortcutRow(named: "R").frame.midY, shortcutRow(named: "S").frame.midY)

        shortcutRow(named: "R").tap()
        XCTAssertTrue(app.navigationBars["Edit Shortcut"].waitForExistence(timeout: 2))
        appendText("2", to: app.textFields["Title"].firstMatch, expecting: "R2")
        appendText("2", to: app.textFields["Hint"].firstMatch, expecting: "h2")
        appendText("y", to: editorActionField(), expecting: "xy")
        app.switches["Auto-send Enter"].tap()
        app.buttons["Save"].tap()
        XCTAssertFalse(shortcutRow(named: "R").exists)
        let reload = shortcutRow(named: "R2")
        XCTAssertTrue(reload.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["h2"].exists)

        reload.swipeRight()
        XCTAssertTrue(app.buttons["Favorite"].waitForExistence(timeout: 2))
        app.buttons["Favorite"].tap()
        XCTAssertTrue(reload.images["Favorite"].waitForExistence(timeout: 2))
        reload.swipeRight()
        XCTAssertTrue(app.buttons["Unfavorite"].waitForExistence(timeout: 2))
        app.buttons["Unfavorite"].tap()
        XCTAssertFalse(reload.images["Favorite"].exists)

        reload.swipeLeft()
        XCTAssertTrue(app.buttons["Hide"].waitForExistence(timeout: 2))
        app.buttons["Hide"].tap()
        XCTAssertTrue(reload.images["Hidden"].waitForExistence(timeout: 2))
        reload.swipeLeft()
        XCTAssertTrue(app.buttons["Show"].waitForExistence(timeout: 2))
        app.buttons["Show"].tap()
        XCTAssertFalse(reload.images["Hidden"].exists)

        reload.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertFalse(shortcutRow(named: "R2").waitForExistence(timeout: 2))
    }

    func testShortcutSettingsRestoresDeletedDefaultShortcut() throws {
        app.launch()

        openTerminal()
        openShortcutPalette()
        app.buttons["terminal.shortcuts.settings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))
        collectionRow(named: "Shell").tap()
        XCTAssertTrue(app.navigationBars["Shell"].waitForExistence(timeout: 2))
        let interrupt = shortcutRow(named: "^C")
        XCTAssertTrue(interrupt.waitForExistence(timeout: 2))
        interrupt.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(shortcutRow(named: "^C").waitForExistence(timeout: 1))
        app.buttons["Restore Missing Defaults"].tap()
        XCTAssertTrue(shortcutRow(named: "^C").waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Restore Missing Defaults"].exists)
    }

    private func openTerminal() {
        let session = app.descendants(matching: .any)["library.session.resume"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        XCTAssertTrue(app.buttons["terminal.toolbar-key.0"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openShortcutPalette() {
        let control = app.buttons["terminal.toolbar-key.0"]
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
        enterText(title, in: titleField)

        let textField = app.textFields["Text"].firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.tap()
        for character in text {
            app.typeText(String(character))
        }
        XCTAssertTrue(app.staticTexts["\(text)⏎"].waitForExistence(timeout: 2))

        app.buttons["Save"].tap()
        XCTAssertFalse(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))
    }

    private func openContextMenu(for element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
    }

    private func enterText(_ text: String, in field: XCUIElement) {
        if !field.waitForExistence(timeout: 1) {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        var entered = ""
        for character in text {
            entered.append(character)
            field.typeText(String(character))
            XCTAssertTrue(
                waitForValue(field, expected: entered),
                "Expected \(field.label) to contain \(entered)"
            )
        }
    }

    private func appendText(_ text: String, to field: XCUIElement, expecting expected: String) {
        if !field.waitForExistence(timeout: 1) {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText(text)
        XCTAssertTrue(waitForValue(field, expected: expected))
    }

    private func editorActionField() -> XCUIElement {
        app.textFields.element(boundBy: 2)
    }

    private func waitForValue(
        _ field: XCUIElement,
        expected: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let value = element.value as? String
            if expected.isEmpty {
                return value == nil || value == "" || value == element.placeholderValue
            }
            return value == expected
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: field)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

    private func dragShortcutRow(named source: String, to destination: String) {
        let sourceHandle = app.buttons["Reorder \(source)"]
        let destinationHandle = app.buttons["Reorder \(destination)"]
        XCTAssertTrue(sourceHandle.waitForExistence(timeout: 2), "Missing source shortcut \(source)")
        XCTAssertTrue(destinationHandle.waitForExistence(timeout: 2), "Missing destination shortcut \(destination)")

        sourceHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.8,
                thenDragTo: destinationHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.25))
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

    private func shortcutRow(named title: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: title).firstMatch
    }
}
