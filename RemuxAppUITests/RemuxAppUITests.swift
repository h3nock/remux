import Darwin
import Foundation
import UIKit
import XCTest

final class RemuxAppUITests: XCTestCase {
    private struct LiveSSHConfiguration: Decodable {
        var displayName: String?
        let host: String
        var port: String?
        let username: String
        var password: String?
        var privateKeyPEM: String?
        var privateKeyPassphrase: String?
        var sessionName: String?
    }

    private struct LiveSSHCleanupHarnessError: Error, CustomStringConvertible {
        let description: String
    }

    private var app: XCUIApplication!
    private var acceptedExpectedLiveHostKey = false

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        installSystemPromptMonitor()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCreatesSSHServerAndOpensTerminalWithSimulatorTransport() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()
    }

    func testComposerDictationStopAndCancelFlow() {
        let transcript = "Review the current changes and run the focused tests"
        app.launchEnvironment["REMUX_DEBUG_DICTATION_TRANSCRIPT"] = transcript
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()

        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "composer opened without keyboard"))
        let composer = app.otherElements["terminal.composer.bounds"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        let editingComposerFrame = composer.frame
        let editingTerminalFrame = app.otherElements["terminal.screen"].frame
        guard let editingContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        XCTAssertGreaterThan(
            editingComposerFrame.height,
            60,
            "The editor and controls must use distinct rows even for an empty draft."
        )
        XCTAssertGreaterThan(
            editingComposerFrame.width,
            app.otherElements["terminal.screen"].frame.width * 0.9,
            "The composer must use the full bottom-chrome width."
        )
        let placeholder = app.staticTexts["terminal.composer.placeholder"]
        XCTAssertTrue(placeholder.exists)

        let mic = app.buttons["terminal.composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        mic.tap()

        let cancel = app.buttons["terminal.composer.dictation.cancel"]
        let stop = app.buttons["terminal.composer.dictation.stop"]
        let meter = app.descendants(matching: .any)["terminal.composer.dictation.meter"]
        let keyboardDismiss = app.descendants(matching: .any)["terminal.composer.keyboard-dismiss"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertTrue(meter.waitForExistence(timeout: 3))
        XCTAssertFalse(placeholder.exists)
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "dictation started with keyboard hidden"))
        XCTAssertFalse(keyboardDismiss.exists)
        attachScreenshot(named: "composer-dictation-recording")
        XCTAssertLessThan(
            composer.frame.height,
            editingComposerFrame.height,
            "Active dictation must collapse the same composer surface into a compact row."
        )
        XCTAssertEqual(
            composer.frame.width,
            editingComposerFrame.width,
            accuracy: 1,
            "Dictation must not shrink the composer."
        )
        XCTAssertEqual(
            app.otherElements["terminal.screen"].frame,
            editingTerminalFrame,
            "Transient dictation must not resize the terminal surface."
        )
        guard let recordingContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        XCTAssertEqual(recordingContinuity.effectiveViewport, editingContinuity.effectiveViewport)
        XCTAssertEqual(recordingContinuity.bottomChrome, editingContinuity.bottomChrome)

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        stop.tap()

        let status = app.staticTexts["terminal.composer.dictation.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 1))
        XCTAssertEqual(status.label, "Transcribing…")
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "transcribing kept keyboard hidden"))
        XCTAssertFalse(keyboardDismiss.exists)
        attachScreenshot(named: "composer-dictation-transcribing")

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, transcript)
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "dictation stopped with keyboard hidden"))
        attachScreenshot(named: "composer-dictation-result")

        field.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer field focused"))
        let visibleKeyboardFrame = app.keyboards.firstMatch.frame
        field.typeText(" Keep this draft")
        guard let originalDraft = field.value as? String else {
            XCTFail("Composer field did not expose its edited draft")
            return
        }
        mic.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertFalse(placeholder.exists)
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "dictation kept keyboard visible"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, visibleKeyboardFrame)
        XCTAssertFalse(keyboardDismiss.exists, "Transient dictation states must not show the keyboard drag affordance.")
        attachScreenshot(named: "composer-dictation-recording-keyboard-visible")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        cancel.tap()

        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, originalDraft)
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "dictation cancelled with keyboard visible"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, visibleKeyboardFrame)
        XCTAssertTrue(keyboardDismiss.waitForExistence(timeout: 3))
        attachScreenshot(named: "composer-dictation-cancelled")

        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "second dictation kept keyboard visible"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, visibleKeyboardFrame)
        XCTAssertFalse(keyboardDismiss.exists)
        stop.tap()

        XCTAssertTrue(status.waitForExistence(timeout: 1))
        XCTAssertEqual(status.label, "Transcribing…")
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "transcribing kept keyboard visible"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, visibleKeyboardFrame)
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "dictation stopped with keyboard visible"))
        XCTAssertEqual(app.keyboards.firstMatch.frame, visibleKeyboardFrame)
        XCTAssertTrue(keyboardDismiss.waitForExistence(timeout: 3))

        composerToggle.tap()
        XCTAssertFalse(
            composer.waitForExistence(timeout: 1),
            "Close must dismiss the composer when terminal keyboard handoff is unavailable."
        )
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "composer close fallback"))
    }

    func testComposerDictationKeepsFullChromeWidth() {
        app.launchEnvironment["REMUX_DEBUG_DICTATION_TRANSCRIPT"] = "Width stability"
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()

        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))

        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        // Exercise the allocated button cell outside the inscribed circular
        // feedback. The full cell must remain interactive even though only
        // the circle is rendered when the control is pressed.
        composerToggle
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 2, dy: 2))
            .tap()

        let composer = app.otherElements["terminal.composer.bounds"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        let keyboardToggle = app.buttons["terminal.keyboard"]
        XCTAssertFalse(keyboardToggle.exists, "Composer mode must not expose a keyboard button.")
        let composerWidth = composer.frame.width
        XCTAssertGreaterThan(
            composerWidth,
            terminal.frame.width * 0.9,
            "The composer must use the full bottom-chrome width."
        )

        let mic = app.buttons["terminal.composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        mic.tap()

        let cancel = app.buttons["terminal.composer.dictation.cancel"]
        let meter = app.descendants(matching: .any)["terminal.composer.dictation.meter"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(meter.waitForExistence(timeout: 3))
        XCTAssertEqual(
            composer.frame.width,
            composerWidth,
            accuracy: 1,
            "Dictation must not shrink the composer."
        )
        attachScreenshot(named: "composer-dictation-width-stable")

        cancel.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.frame.width, composerWidth, accuracy: 1)
    }

    func testComposerDictationCanRestartAfterNoSpeech() {
        app.launchEnvironment["REMUX_DEBUG_DICTATION_NO_SPEECH"] = "1"
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()

        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()

        let mic = app.buttons["terminal.composer.mic"]
        let stop = app.buttons["terminal.composer.dictation.stop"]
        XCTAssertTrue(mic.waitForExistence(timeout: 3))

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Can you check my Gmail?")
        attachScreenshot(named: "composer-compact-polished")

        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()

        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No speech detected. Try again."].exists)

        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["No speech detected. Try again."].exists)
    }

    func testComposerTogglePreservesKeyboardWhileReservingComposerViewport() {
        app.launchEnvironment["REMUX_UI_TEST_INPUT_READY"] = "1"
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()
        waitForLiveTerminalInputReady(timeout: 10)

        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))

        // The optional password-manager prompt probe may need to tap the app
        // after the terminal appears. Normalize the hidden-keyboard phase so
        // this test measures composer behavior rather than that probe's tap.
        hideKeyboardIfPresent()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "terminal keyboard hidden before composer toggle"))

        guard let hiddenContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()
        let composerField = app.textViews["terminal.composer.field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "composer opened with keyboard hidden"))
        guard let hiddenOpenContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        XCTAssertNotEqual(hiddenOpenContinuity.effectiveViewport, hiddenContinuity.effectiveViewport)
        XCTAssertNotEqual(hiddenOpenContinuity.bottomChrome, hiddenContinuity.bottomChrome)

        composerToggle.tap()
        XCTAssertFalse(composerField.waitForExistence(timeout: 1))
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "composer closed with keyboard hidden"))
        guard let hiddenClosedContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        XCTAssertEqual(hiddenClosedContinuity.effectiveViewport, hiddenContinuity.effectiveViewport)

        terminal.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "terminal keyboard before composer toggle"))
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 3),
            "Composer continuity must be exercised with the software keyboard visibly on screen."
        )

        let keyboard = app.keyboards.firstMatch
        let initialKeyboardFrame = keyboard.frame
        guard let initialContinuity = waitForKeyboardContinuity(owner: "terminal") else {
            return
        }

        composerToggle.tap()
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer keyboard after terminal handoff"))
        guard let composerContinuity = waitForKeyboardContinuity(owner: "composer") else {
            return
        }
        XCTAssertEqual(composerContinuity.willHideCount, initialContinuity.willHideCount)
        XCTAssertEqual(keyboard.frame, initialKeyboardFrame)
        XCTAssertNotEqual(
            composerContinuity.effectiveViewport,
            initialContinuity.effectiveViewport,
            "Opening the composer must reserve its full height from the terminal viewport "
                + "from live=\(initialContinuity.liveViewport), effective=\(initialContinuity.effectiveViewport) "
                + "to live=\(composerContinuity.liveViewport), effective=\(composerContinuity.effectiveViewport); "
                + "bottomChrome \(initialContinuity.bottomChrome) → \(composerContinuity.bottomChrome), "
                + "safeAreaBottom \(initialContinuity.safeAreaBottom) → \(composerContinuity.safeAreaBottom)."
        )
        composerField.typeText("Keep this draft")
        XCTAssertEqual(composerField.value as? String, "Keep this draft")
        attachScreenshot(named: "composer-toggle-dock-open")

        composerToggle.tap()
        XCTAssertFalse(composerField.waitForExistence(timeout: 1))
        XCTAssertNotNil(
            waitForKeyboardPresence(
                true,
                label: "terminal keyboard after composer close",
                stableFor: 0.75
            )
        )
        guard let terminalContinuity = waitForKeyboardContinuity(owner: "terminal") else {
            return
        }
        XCTAssertEqual(terminalContinuity.willHideCount, initialContinuity.willHideCount)
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(keyboard.frame, initialKeyboardFrame)
        XCTAssertEqual(terminalContinuity.effectiveViewport, initialContinuity.effectiveViewport)
        attachScreenshot(named: "composer-toggle-dock-closed")

        composerToggle.tap()
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer keyboard after reopen"))
        guard let reopenedContinuity = waitForKeyboardContinuity(owner: "composer") else {
            return
        }
        XCTAssertEqual(reopenedContinuity.willHideCount, initialContinuity.willHideCount)
        XCTAssertEqual(composerField.value as? String, "Keep this draft")
        XCTAssertEqual(keyboard.frame, initialKeyboardFrame)
        XCTAssertEqual(reopenedContinuity.effectiveViewport, composerContinuity.effectiveViewport)

        composerToggle.tap()
        XCTAssertFalse(composerField.waitForExistence(timeout: 1))
        XCTAssertNotNil(
            waitForKeyboardPresence(
                true,
                label: "terminal keyboard after second composer close",
                stableFor: 0.75
            )
        )
        guard let reclosedContinuity = waitForKeyboardContinuity(owner: "terminal") else {
            return
        }
        XCTAssertEqual(reclosedContinuity.willHideCount, initialContinuity.willHideCount)
        XCTAssertEqual(keyboard.frame, initialKeyboardFrame)
        XCTAssertEqual(reclosedContinuity.effectiveViewport, initialContinuity.effectiveViewport)
    }

    func testComposerHandleDismissesAndEditorRestoresKeyboard() {
        app.launchEnvironment["REMUX_UI_TEST_INPUT_READY"] = "1"
        app.launchArguments += ["-terminal.composer.keyboardDismissHintShown", "NO"]
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()
        waitForLiveTerminalInputReady(timeout: 10)

        hideKeyboardIfPresent()
        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer keyboard before handle drag"))
        guard let visibleContinuity = waitForKeyboardContinuity(owner: "composer") else {
            return
        }

        let handle = app.descendants(matching: .any)["terminal.composer.keyboard-dismiss"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        attachScreenshot(named: "composer-keyboard-dismiss-hint")
        let dragStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = dragStart.withOffset(CGVector(dx: 0, dy: 14))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        XCTAssertNotNil(waitForKeyboardPresence(false, label: "composer keyboard after handle drag"))
        XCTAssertTrue(field.exists, "Dismissing the keyboard must keep the composer open.")
        guard let hiddenContinuity = waitForKeyboardContinuity(owner: "none") else {
            return
        }
        XCTAssertGreaterThan(hiddenContinuity.willHideCount, visibleContinuity.willHideCount)
        attachScreenshot(named: "composer-keyboard-dismissed")

        field.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer keyboard after editor retap"))
        XCTAssertNotNil(waitForKeyboardContinuity(owner: "composer"))
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
    }

    func testComposerMultilineKeepsWidthAndKeyboardStable() {
        app.launchEnvironment["REMUX_UI_TEST_INPUT_READY"] = "1"
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        saveConnectionAndWaitForTerminal()
        _ = waitForTerminalHomeButton()
        waitForLiveTerminalInputReady(timeout: 10)

        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        hideKeyboardIfPresent()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "keyboard hidden before composer send"))

        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()

        let composerField = app.textViews["terminal.composer.field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        composerField.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "composer keyboard before send"))
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 3),
            "Composer Send continuity must be exercised with the software keyboard visibly on screen."
        )
        let initialTextWidth = composerField.frame.width

        let initialText = "Explain why this composer keeps its width"
        composerField.typeText(initialText)
        XCTAssertEqual(composerField.value as? String, initialText)

        let composerBounds = app.otherElements["terminal.composer.bounds"]
        XCTAssertTrue(composerBounds.waitForExistence(timeout: 3))
        let composerWidthBeforeWrapping = composerBounds.frame.width
        XCTAssertGreaterThan(
            composerWidthBeforeWrapping,
            terminal.frame.width * 0.55,
            "The composer must fill the bottom chrome rather than shrink-wrap its content."
        )
        composerField.typeText(
            " and explain why the composer keeps the same width while its text wraps across multiple lines"
        )
        XCTAssertEqual(
            composerBounds.frame.width,
            composerWidthBeforeWrapping,
            accuracy: 1,
            "Multiline text must grow the composer upward without changing its width."
        )
        XCTAssertGreaterThan(
            composerField.frame.width,
            composerBounds.frame.width * 0.88,
            "The editor must use the composer width instead of sitting between controls."
        )
        XCTAssertEqual(
            composerField.frame.width,
            initialTextWidth,
            accuracy: 1,
            "The editor must keep its full width as text wraps."
        )

        let attachmentButton = app.buttons["terminal.composer.attachments"]
        let closeButton = app.buttons["terminal.composer.toggle"]
        let micButton = app.buttons["terminal.composer.mic"]
        let sendButton = app.buttons["terminal.composer.send"]
        XCTAssertLessThanOrEqual(composerField.frame.maxY, attachmentButton.frame.minY)
        XCTAssertEqual(attachmentButton.frame.midY, closeButton.frame.midY, accuracy: 1)
        XCTAssertEqual(attachmentButton.frame.midY, micButton.frame.midY, accuracy: 1)
        XCTAssertEqual(micButton.frame.midY, sendButton.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(attachmentButton.frame.maxX, closeButton.frame.minX)
        XCTAssertLessThan(closeButton.frame.maxX, micButton.frame.minX)
        attachScreenshot(named: "composer-multiline-width-stable")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertTrue(waitForSoftwareKeyboardOnScreen(timeout: 1))
        attachScreenshot(named: "composer-multiline-keyboard-stable")
    }

    func testCanKeepMultipleSimulatorSessionsActive() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        saveConnectionAndWaitForTerminal()
        openHomeFromTerminal()

        let firstOpenSession = activeSessionRows.firstMatch
        XCTAssertTrue(firstOpenSession.waitForExistence(timeout: 5))
        if firstOpenSession.isHittable {
            firstOpenSession.tap()
        } else {
            firstOpenSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 5))
        openHomeFromTerminal()

        openNewSessionFromLibrary()

        let sessionName = app.textFields["connection.session"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["connection.name"].waitForExistence(timeout: 0.5))
        XCTAssertFalse(app.secureTextFields["connection.password"].exists)
        sessionName.tap()
        sessionName.typeText("logs")
        app.swipeUp()
        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
        saveConnectionAndWaitForTerminal()
        openHomeFromTerminal()

        let runningSessions = activeSessionRows
        XCTAssertTrue(runningSessions.element(boundBy: 1).waitForExistence(timeout: 5))
    }

    func testSettingsExposeFontAndThemeControls() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        XCTAssertTrue(settingsForm.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        let legacyRSAHostKeys = app.switches["settings.allow-insecure-rsa"]
        XCTAssertTrue(legacyRSAHostKeys.waitForExistence(timeout: 2))
        XCTAssertEqual(legacyRSAHostKeys.label, "Allow older RSA host keys")
        tapFontDefaultToggle()
        let fontSize = app.descendants(matching: .any)["settings.font-size"]
        XCTAssertTrue(fontSize.waitForExistence(timeout: 2))
        XCTAssertEqual(fontSize.label, "Font size, 10")

        let themeButton = app.descendants(matching: .any)["settings.theme"]
        XCTAssertTrue(themeButton.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Mocha"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Latte"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["settings.theme.preview"].waitForExistence(timeout: 2))
        app.buttons["Mocha"].tap()
        XCTAssertTrue(app.staticTexts["Catppuccin Mocha"].waitForExistence(timeout: 2))
    }

    func testFreshPhoneInstallShowsMultipaneZoomDefaultEnabled() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        let zoom = app.switches["settings.zoom-multipane-windows-by-default"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 2))
        XCTAssertEqual(zoom.value as? String, "1")
    }

    func testPrivateKeyAuthenticationFlowShowsActionsUntilKeySelected() {
        app.launchEnvironment["REMUX_UI_TEST_PUBLIC_KEY_INSTALL_OUTCOME"] = "passwordRequired"
        launchSimulatorApp()
        openConnectionSetup()
        fillPublicKeyInstallationServerFields()

        if !app.buttons["Private Key"].waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Private Key"].waitForExistence(timeout: 2))
        app.buttons["Private Key"].tap()

        XCTAssertTrue(app.buttons["connection.private-key.import"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["connection.private-key.paste"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["connection.private-key.generate"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Use a private key to sign in"].exists)

        app.buttons["connection.private-key.generate"].tap()

        XCTAssertTrue(app.staticTexts["Generated ED25519 key"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["connection.private-key.copy-public"].waitForExistence(timeout: 2))
        let install = app.buttons["connection.private-key.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 2))
        install.tap()

        let password = app.secureTextFields["connection.private-key.install-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 2))
        password.tap()
        password.typeText("one-time-password")
        app.buttons["connection.private-key.install-confirm"].tap()

        let inlineStatus = app.staticTexts["connection.private-key.install-status"]
        XCTAssertTrue(inlineStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(inlineStatus.label, "Installed on host")
        XCTAssertFalse(app.navigationBars["Install on Host"].exists)
        XCTAssertFalse(app.buttons["connection.private-key.install-cancel"].exists)
        XCTAssertTrue(app.buttons["connection.private-key.install"].exists)
        XCTAssertTrue(app.buttons["connection.private-key.install"].isEnabled)

        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText(".changed")
        XCTAssertTrue(
            waitForElementToDisappear(inlineStatus, timeout: 3),
            "Editing the host should invalidate the install confirmation."
        )

        XCTAssertTrue(app.buttons["connection.private-key.change"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        XCTAssertFalse(app.staticTexts["Add the public key to your server"].exists)
    }

    func testAlreadyInstalledPublicKeySkipsPasswordPrompt() {
        app.launchEnvironment["REMUX_UI_TEST_PUBLIC_KEY_INSTALL_OUTCOME"] = "alreadyInstalled"
        launchSimulatorApp()
        openConnectionSetup()
        fillPublicKeyInstallationServerFields()

        if !app.buttons["Private Key"].waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Private Key"].waitForExistence(timeout: 2))
        app.buttons["Private Key"].tap()
        app.buttons["connection.private-key.generate"].tap()

        let install = app.buttons["connection.private-key.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 2))
        install.tap()

        let inlineStatus = app.staticTexts["connection.private-key.install-status"]
        XCTAssertTrue(inlineStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(inlineStatus.label, "Already installed")
        XCTAssertFalse(app.navigationBars["Install on Host"].exists)
        XCTAssertFalse(app.buttons["connection.private-key.install-cancel"].exists)
        XCTAssertTrue(app.buttons["connection.private-key.install"].exists)
        XCTAssertTrue(app.buttons["connection.private-key.install"].isEnabled)
        XCTAssertFalse(app.secureTextFields["connection.private-key.install-password"].exists)
    }

    func testLiveSSHSeededServerOpensReadyTerminalWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("render")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()

        waitForLiveTerminalReady(timeout: 60)
        sendTerminalCommand(
            "yes 'REMUX_RENDER_CHECK ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' | head -120"
        )
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 30_000)
    }

    func testLiveSessionSwitcherDiscoversAndResumesSessionsWhenConfigured() throws {
        let primarySessionName = try generatedLiveLatencySessionName("switcher-primary")
        let availableSessionName = try generatedLiveLatencySessionName("switcher-available")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(availableSessionName)
            cleanupGeneratedLiveLatencySessionIfPossible(primarySessionName)
        }

        try launchLiveSSHAppIfConfigured(
            traceRuntime: true,
            sessionNameOverride: primarySessionName
        )
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)

        sendTerminalCommand("tmux new-session -d -s \(availableSessionName)")
        hideKeyboardIfPresent()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        openSessionSwitcherFromTerminal()

        let sessionSheet = app.otherElements["terminal.sessions.sheet"]
        XCTAssertTrue(sessionSheet.waitForExistence(timeout: 5))
        let closeButton = app.buttons["terminal.sessions.close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        let mediumTop = closeButton.frame.minY
        attachScreenshot(named: "live-session-switcher-medium")

        let refreshButton = app.buttons["terminal.sessions.refresh"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5))
        for _ in 0..<20 where !refreshButton.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(refreshButton.isEnabled)
        refreshButton.tap()

        let inlineAvailableRow = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.available-session")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", availableSessionName))
            .firstMatch
        let availableBrowser = app.buttons["terminal.sessions.available-browser"]
        let sessionList = app.descendants(matching: .any)["terminal.sessions.list"]
        let discoveryDeadline = Date().addingTimeInterval(15)
        while !inlineAvailableRow.exists,
              !availableBrowser.exists,
              Date() < discoveryDeadline {
            if sessionList.exists {
                sessionList.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(
            inlineAvailableRow.exists || availableBrowser.exists,
            "Discovered remote tmux sessions should be reachable under Available."
        )
        XCTAssertTrue(app.staticTexts["Available"].exists)
        XCTAssertTrue(app.buttons["terminal.sessions.new"].isHittable)

        if closeButton.frame.minY >= mediumTop - 100 {
            sessionSheet.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertLessThan(
            closeButton.frame.minY,
            mediumTop - 100,
            "Dragging upward should expand the session sheet before scrolling its list."
        )
        attachScreenshot(named: "live-session-switcher-active-and-available-large")

        let availableRow: XCUIElement
        if availableBrowser.exists {
            for _ in 0..<8 where !availableBrowser.isHittable {
                sessionList.swipeUp()
            }
            XCTAssertTrue(availableBrowser.isHittable)
            availableBrowser.tap()

            let browserView = app.descendants(matching: .any)[
                "terminal.sessions.available-browser-view"
            ]
            XCTAssertTrue(browserView.waitForExistence(timeout: 5))
            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            XCTAssertLessThan(
                searchField.frame.minY,
                mediumTop - 100,
                "The Available browser should present at the large detent."
            )
            searchField.tap()
            searchField.typeText(availableSessionName)
            availableRow = app.descendants(matching: .any)
                .matching(identifier: "terminal.sessions.available-result")
                .matching(NSPredicate(format: "label CONTAINS[c] %@", availableSessionName))
                .firstMatch
            attachScreenshot(named: "live-session-switcher-available-search")
        } else {
            availableRow = inlineAvailableRow
            for _ in 0..<8 where !availableRow.exists || !availableRow.isHittable {
                sessionList.swipeUp()
            }
        }
        XCTAssertTrue(
            availableRow.waitForExistence(timeout: 10) && availableRow.isHittable,
            "The specifically generated tmux session should be reachable under Available."
        )
        availableRow.tap()
        XCTAssertFalse(
            app.otherElements["terminal.sessions.sheet"].waitForExistence(timeout: 1)
        )
        waitForLiveTerminalReady(timeout: 60)

        openSessionSwitcherFromTerminal()
        let availableActiveRow = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.active-session")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", availableSessionName))
            .firstMatch
        XCTAssertTrue(
            availableActiveRow.waitForExistence(timeout: 10),
            "The discovered session should move to Active after resuming."
        )

        let primaryRecentRow = disconnectActiveSessionFromSwitcher(named: primarySessionName)
        primaryRecentRow.tap()
        XCTAssertFalse(
            app.otherElements["terminal.sessions.sheet"].waitForExistence(timeout: 1)
        )
        waitForLiveTerminalReady(timeout: 60)

        openSessionSwitcherFromTerminal()
        let resumedActiveRow = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.active-session")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", primarySessionName))
            .firstMatch
        XCTAssertTrue(resumedActiveRow.waitForExistence(timeout: 10))
        XCTAssertFalse(primaryRecentRow.exists)
        attachScreenshot(named: "live-session-switcher-discovered-and-recent-resumed")
        app.buttons["terminal.sessions.close"].tap()
    }

    func testLiveSSHKeyboardResizeTraceWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("keyboard")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()

        waitForLiveTerminalReady(timeout: 60)

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        terminal.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(true, label: "terminal tap show")
        )

        waitForLiveTerminalInputReady(timeout: 10)
        app.typeText(
            "for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do echo REMUX_KEYBOARD_RESIZE_RENDER_$n ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789; done\r"
        )
        assertLiveTerminalScreenshotContainsRenderedContent()

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(false, label: "system hide")
        )

        keyboard.tap()
        XCTAssertNotNil(
            waitForKeyboardPresence(true, label: "second system show")
        )
    }

    func testLiveLatencyProfileRealRuntimeWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("profile")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let marker = "__REMUX_LATENCY_UIKEY\(UUID().uuidString.prefix(8).uppercased())__"
        sendTerminalCommand("echo \(marker)")
        assertLiveTerminalScreenshotContainsRenderedContent()

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.waitForExistence(timeout: 10))
        windows.tap()
        let newWindow = app.buttons["New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 8))
        newWindow.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let panes = app.buttons["terminal.panes"]
        XCTAssertTrue(panes.waitForExistence(timeout: 10))
        panes.tap()
        let split = app.buttons["terminal.pane.split.right"]
        XCTAssertTrue(split.waitForExistence(timeout: 8))
        split.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))
    }

    func testLiveAgentTUIPaneSwitchProfileWhenConfigured() throws {
        let sessionName = try liveAgentTUISessionName()
        let switchCountValue = liveCleanupHarnessOverride("REMUX_PROFILE_PANE_SWITCH_COUNT") ?? "24"
        guard let switchCount = Int(switchCountValue), (1...1_000).contains(switchCount) else {
            throw LiveSSHCleanupHarnessError(
                description: "REMUX_PROFILE_PANE_SWITCH_COUNT must be an integer from 1 through 1000; got \(switchCountValue)."
            )
        }
        print("Remux profile switch_count=\(switchCount)")
        app.launchEnvironment["GHOSTTY_TRACE_FRAME_COMPLETION"] = "1"
        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        let paneTiles = panePickerTiles()
        let firstPaneTile = paneTiles[0]
        let secondPaneTile = paneTiles[1]
        assertPaneTopology(paneCount: 2)
        let selectedPaneTiles = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane.tile."))
            .matching(NSPredicate(format: "selected == true"))
        XCTAssertEqual(
            selectedPaneTiles.count,
            1,
            "Exactly one profiling pane must be active."
        )
        let selectedPaneIdentifier = selectedPaneTiles.element(boundBy: 0).identifier
        var targetIndex = firstPaneTile.identifier == selectedPaneIdentifier ? 1 : 0
        dismissTopSheetIfPresent()

        for _ in 0..<switchCount {
            openPanesSheet()
            XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
            panePickerTiles()[targetIndex].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            targetIndex = targetIndex == 0 ? 1 : 0
        }

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        assertPaneTopology(paneCount: 2)
        dismissTopSheetIfPresent()

        XCTAssertFalse(app.staticTexts["terminal.status.failed"].exists)
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 30_000)
    }

    /// Deliberately synthetic scrollback/throughput stress. This proves lossless
    /// high-volume output handling; it is not a representative agent-TUI
    /// rendering or pane-switch benchmark. Use the gated agent-TUI profile for
    /// Codex/Claude performance conclusions.
    func testLiveHighOutputRuntimeWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("flow")
        let doneMarker = "REMUX_FLOW_DONE_\(UUID().uuidString.prefix(8).uppercased())"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))

        let payload = String(repeating: "x", count: 80)
        sendTerminalCommand(
            "clear; i=0; while [ $i -lt 5000 ]; do printf 'REMUX_FLOW_%05d \(payload)\\n' $i; i=$((i+1)); done; echo \(doneMarker)"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(10))
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 30_000)

        XCTAssertFalse(app.staticTexts["terminal.status.failed"].exists)
        XCTAssertTrue(app.otherElements["terminal.screen"].exists || app.staticTexts["terminal.screen"].exists)
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: doneMarker
        )

        let panes = app.buttons["terminal.panes"]
        XCTAssertTrue(panes.waitForExistence(timeout: 10))
        panes.tap()
        XCTAssertTrue(app.buttons["terminal.pane.split.right"].waitForExistence(timeout: 8))
        dismissTopSheetIfPresent()

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.waitForExistence(timeout: 10))
        windows.tap()
        XCTAssertTrue(app.buttons["New Window"].waitForExistence(timeout: 8))
        dismissTopSheetIfPresent()

        openHomeFromTerminal()
        XCTAssertTrue(activeSessionRows.firstMatch.waitForExistence(timeout: 5))
    }

    func testLiveSSHSelectionSheetsRenderPaneTopologyAndWindowPreviewsWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("preview")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand(
            "i=0; while [ $i -lt 80 ]; do printf 'REMUX_PREVIEW_WINDOW1_%03d alpha beta gamma delta\\n' $i; i=$((i+1)); done"
        )

        openPanesSheet()
        tapPickerButton(identifier: "terminal.pane.split.right", fallbackLabel: "Split right")
        waitForLiveTerminalReady(timeout: 30)

        sendTerminalCommand(
            "i=0; while [ $i -lt 80 ]; do printf 'REMUX_PREVIEW_PANE2_%03d one two three four\\n' $i; i=$((i+1)); done"
        )

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        assertPaneTopology(paneCount: 2, attachmentName: "pane-topology")
        dismissTopSheetIfPresent()

        openWindowsSheet()
        tapPickerButton(identifier: "terminal.window.new", fallbackLabel: "New Window")
        waitForLiveTerminalReady(timeout: 30)

        sendTerminalCommand(
            "i=0; while [ $i -lt 80 ]; do printf 'REMUX_PREVIEW_WINDOW2_%03d red green blue yellow\\n' $i; i=$((i+1)); done"
        )

        openWindowsSheet()
        XCTAssertTrue(app.buttons["terminal.window.tile.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["terminal.window.tile.2"].waitForExistence(timeout: 10))
        assertPreviewTilesContainRenderedImages(
            tiles: [
                app.buttons["terminal.window.tile.1"],
                app.buttons["terminal.window.tile.2"],
            ],
            attachmentName: "window-previews"
        )
    }

    func testLiveTerminalScrollbackGestureWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("scroll")
        let doneMarker = "REMUX_SCROLLBACK_DONE_\(UUID().uuidString.prefix(8).uppercased())"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand(
            "clear; i=0; while [ $i -lt 220 ]; do echo REMUX_SCROLLBACK_${i}_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789; i=$((i+1)); done; echo \(doneMarker)"
        )
        hideKeyboardIfPresent()
        guard let before = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-scrollback-before"
        ) else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.swipeDown(velocity: .slow)
        terminal.swipeDown(velocity: .slow)
        guard let after = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-scrollback-after"
        ) else {
            return
        }

        let changedPixels = liveTerminalPixelDifference(before: before, after: after)
        XCTAssertNotNil(changedPixels)
        XCTAssertGreaterThan(
            changedPixels ?? 0,
            8_000,
            "Scrollback swipe should visibly move terminal content."
        )
        let bottomContentRatio = liveTerminalBottomContentRatio(screenshot: after)
        XCTAssertNotNil(bottomContentRatio)
        XCTAssertGreaterThan(
            bottomContentRatio ?? 0,
            0.005,
            "Fractional scroll rendering should not clip the terminal to a shorter, stale grid."
        )
    }

    func testLiveMouseReportScrollTraceWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("mousescroll")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        // A full-screen app with mouse reporting enabled (the opencode
        // scroll case): wheel gestures forward to the app instead of
        // scrolling local scrollback.
        sendTerminalCommand(
            "seq -f 'REMUX_MOUSE_LINE_%g' 300 > /tmp/remux-scroll.txt; vim --clean -c 'set mouse=a' /tmp/remux-scroll.txt"
        )
        hideKeyboardIfPresent()
        guard let before = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-mousescroll-before"
        ) else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.swipeUp(velocity: .slow)
        terminal.swipeUp(velocity: .fast)
        terminal.swipeDown(velocity: .slow)
        guard let after = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-mousescroll-after"
        ) else {
            return
        }

        let changedPixels = liveTerminalPixelDifference(before: before, after: after)
        XCTAssertNotNil(changedPixels)
        XCTAssertGreaterThan(
            changedPixels ?? 0,
            8_000,
            "Mouse-report swipe should move content inside the full-screen app."
        )
    }

    func testLiveMouseReportFlingCatchWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("flingcatch")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand(
            "seq -f 'REMUX_CATCH_LINE_%g' 300 > /tmp/remux-catch.txt; vim --clean -c 'set mouse=a' -c 'normal G' /tmp/remux-catch.txt"
        )
        hideKeyboardIfPresent()
        guard waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-catch-before"
        ) != nil else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        // Fling, then immediately touch down: the catch must stop the
        // deceleration AND swallow the touch (a leaked tap would emit
        // an SGR button press into vim — asserted on the wire by the
        // harness trace analysis).
        terminal.swipeUp(velocity: .fast)
        terminal.tap()

        // Catch proof: motion has stopped — two screenshots a second
        // apart must be identical while the (cancelled) deceleration
        // window would still have been running.
        let first = app.screenshot()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let second = app.screenshot()
        let residualMotion = liveTerminalPixelDifference(before: first, after: second)
        XCTAssertNotNil(residualMotion)
        XCTAssertLessThan(
            residualMotion ?? .max,
            2_000,
            "Touching mid-fling should catch the scroll dead; content must not keep moving."
        )

        // Control: a deliberate tap after everything settles must still
        // reach the app as a click (the swallow is catch-scoped). The
        // harness wire analysis asserts exactly this tap's press and
        // release reach vim, and nothing from the catch tap.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        terminal.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    func testLiveAltScreenCursorScrollWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("altscroll")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        // A full-screen app WITHOUT mouse reporting (less): scrolling
        // takes the alt-screen-cursor route, where the engine converts
        // wheel deltas to cursor keys. Physics momentum applies there
        // exactly as on the mouse-report route.
        sendTerminalCommand(
            "seq -f 'REMUX_ALT_LINE_%g' 400 > /tmp/remux-altscroll.txt; less /tmp/remux-altscroll.txt"
        )
        hideKeyboardIfPresent()
        guard let before = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-altscroll-before"
        ) else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        // Chained same-direction flicks with no settle between them:
        // the physics view never goes idle, so this exercises virtual
        // offset drift across consecutive gestures.
        terminal.swipeUp(velocity: .fast)
        terminal.swipeUp(velocity: .fast)
        terminal.swipeUp(velocity: .fast)
        terminal.swipeUp(velocity: .fast)
        terminal.swipeUp(velocity: .fast)
        guard let after = waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 30_000,
            attachmentName: "live-terminal-altscroll-after"
        ) else {
            return
        }

        let changedPixels = liveTerminalPixelDifference(before: before, after: after)
        XCTAssertNotNil(changedPixels)
        XCTAssertGreaterThan(
            changedPixels ?? 0,
            8_000,
            "Alt-screen-cursor swipe should scroll the pager via cursor keys."
        )
    }

    func testLiveSSHTmuxActionCycleWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("action")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        openWindowsSheet()
        tapPickerButton(identifier: "terminal.window.new", fallbackLabel: "New Window")
        waitForLiveTerminalReady(timeout: 30)

        openWindowsSheet()
        XCTAssertTrue(app.buttons["terminal.window.tile.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["terminal.window.tile.2"].waitForExistence(timeout: 10))
        tapPickerButton(identifier: "terminal.window.tile.1", fallbackLabel: "Window 1 of 2")
        waitForLiveTerminalReady(timeout: 30)

        openWindowsSheet()
        tapPickerButton(identifier: "terminal.window.tile.2", fallbackLabel: "Window 2 of 2")
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        tapPickerButton(identifier: "terminal.pane.split.right", fallbackLabel: "Split right")
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        panePickerTiles()[0].tap()
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        panePickerTiles()[1].tap()
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        let removedPaneIdentifier = panePickerTiles()[1].identifier
        removePanePickerItem(app.buttons[removedPaneIdentifier])
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons[removedPaneIdentifier], timeout: 10),
            "The requested pane should disappear from the picker."
        )
        XCTAssertTrue(
            waitForPanePickerTileCount(1, timeout: 10),
            "The removed pane should disappear from the picker."
        )
        dismissTopSheetIfPresent()
        waitForLiveTerminalReady(timeout: 30)

        openWindowsSheet()
        removePickerItem(
            tileIdentifier: "terminal.window.tile.2",
            actionIdentifier: "terminal.window.remove.2",
            actionLabel: "Remove Window 2",
            confirmIdentifier: "terminal.window.remove.confirm.2",
            confirmLabel: "Remove Window 2"
        )
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons["terminal.window.tile.2"], timeout: 10),
            "Window 2 should disappear after removal."
        )
        dismissTopSheetIfPresent()
        waitForLiveTerminalReady(timeout: 30)

        let marker = "REMUX_ACTION_CYCLE_RENDER_\(UUID().uuidString.prefix(8).uppercased())"
        sendTerminalCommand("printf '\(marker)\\n'")
        hideKeyboardIfPresent()
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 2_500)

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))

        openHomeFromTerminal()
        XCTAssertTrue(activeSessionRows.firstMatch.waitForExistence(timeout: 5))
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
    }

    func testLiveComposerTypingPerfWhenConfigured() throws {
        let transcript = "Profile the composer hypothesis path"
        // Enables the body-eval probe and its accessibility marker without
        // REMUX_UI_TESTING, which would swap in the fake UI-testing
        // transport and break the live SSH connection.
        app.launchEnvironment["REMUX_TRACE_COMPOSER_PERF"] = "1"
        app.launchEnvironment["REMUX_DEBUG_DICTATION_TRANSCRIPT"] = transcript
        let sessionName = try generatedLiveLatencySessionName("composer")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 10))
        composerToggle.tap()
        XCTAssertTrue(app.otherElements["terminal.composer.bounds"].waitForExistence(timeout: 5))

        // The bar-hosted marker refreshes on every bar re-render, so it
        // stays current even when the screen body no longer re-evaluates
        // per keystroke.
        let probe = app.otherElements["terminal.composer.perf"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        // Dictation hypothesis path: the debug backend emits 28 audio-level
        // events plus one hypothesis that writes the draft. Screen body
        // evals in this window quantify how much of dictation leaks into
        // whole-screen invalidation.
        let mic = app.buttons["terminal.composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        settleComposerPerfProbe()
        guard let beforeDictation = bodyEvalProbeMetrics(probe) else {
            XCTFail("Body eval probe unreadable before dictation")
            return
        }
        mic.tap()
        let stop = app.buttons["terminal.composer.dictation.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        stop.tap()

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let transcriptDeadline = Date().addingTimeInterval(6)
        while Date() < transcriptDeadline, (field.value as? String) != transcript {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(field.value as? String, transcript)
        settleComposerPerfProbe()
        guard let afterDictation = bodyEvalProbeMetrics(probe) else {
            XCTFail("Body eval probe unreadable after dictation")
            return
        }

        // Typing path: every keystroke goes through the composer draft
        // binding. The typed tail also builds the command submitted below.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        settleComposerPerfProbe()
        guard let beforeTyping = bodyEvalProbeMetrics(probe) else {
            XCTFail("Body eval probe unreadable before typing")
            return
        }
        let token = "REMUX-CPERF-\(UUID().uuidString.prefix(8).uppercased())"
        let typed = " ; printf %s \(token) | rev"
        field.typeText(typed)
        settleComposerPerfProbe()
        guard let afterTyping = bodyEvalProbeMetrics(probe) else {
            XCTFail("Body eval probe unreadable after typing")
            return
        }

        // Submit to the real tmux session; success clears the draft and
        // restores the placeholder. The reversed token only appears in the
        // pane when the pasted command actually executed remotely.
        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let placeholder = app.staticTexts["terminal.composer.placeholder"]
        let submitStart = Date()
        send.tap()
        let submitDeadline = Date().addingTimeInterval(20)
        while Date() < submitDeadline, !placeholder.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            placeholder.exists,
            "Composer draft should clear after a successful live submit."
        )
        let submitMs = Date().timeIntervalSince(submitStart) * 1000

        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: String(token.reversed())
        )

        let typedCount = typed.count
        let dictationEvals = probeDelta(afterDictation.evals, beforeDictation.evals, "dictation evals")
        let dictationBarEvals = probeDelta(afterDictation.barEvals, beforeDictation.barEvals, "dictation bar evals")
        let dictationPasses = probeDelta(afterDictation.passes, beforeDictation.passes, "dictation passes")
        let dictationPassMs = afterDictation.passMs - beforeDictation.passMs
        let typingEvals = probeDelta(afterTyping.evals, beforeTyping.evals, "typing evals")
        let typingBarEvals = probeDelta(afterTyping.barEvals, beforeTyping.barEvals, "typing bar evals")
        let typingPasses = probeDelta(afterTyping.passes, beforeTyping.passes, "typing passes")
        let typingPassMs = afterTyping.passMs - beforeTyping.passMs
        let summary = """
        REMUX_COMPOSER_PERF typing chars=\(typedCount) screenEvals=\(typingEvals) \
        screenEvalsPerKey=\(String(format: "%.2f", Double(typingEvals) / Double(typedCount))) \
        barEvals=\(typingBarEvals) \
        barEvalsPerKey=\(String(format: "%.2f", Double(typingBarEvals) / Double(typedCount))) \
        passes=\(typingPasses) passMs=\(String(format: "%.3f", typingPassMs)) \
        passMsPerKey=\(String(format: "%.3f", typingPassMs / Double(typedCount)))
        REMUX_COMPOSER_PERF dictation screenEvals=\(dictationEvals) \
        barEvals=\(dictationBarEvals) passes=\(dictationPasses) \
        passMs=\(String(format: "%.3f", dictationPassMs))
        REMUX_COMPOSER_PERF submit elapsedMs=\(String(format: "%.0f", submitMs))
        """
        NSLog("%@", summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "composer-perf-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func probeDelta(_ after: UInt64, _ before: UInt64, _ label: String) -> UInt64 {
        guard after >= before else {
            XCTFail("Probe counter \(label) went backwards (\(before) → \(after))")
            return 0
        }
        return after - before
    }

    private struct ComposerBodyEvalProbeMetrics {
        let evals: UInt64
        let barEvals: UInt64
        let passes: UInt64
        let passMs: Double
    }

    private func bodyEvalProbeMetrics(_ marker: XCUIElement) -> ComposerBodyEvalProbeMetrics? {
        guard marker.exists, let raw = marker.value as? String else { return nil }
        var fields: [String: String] = [:]
        for field in raw.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let evals = fields["evals"].flatMap({ UInt64($0) }),
              let passes = fields["passes"].flatMap({ UInt64($0) }),
              let passMs = fields["passMs"].flatMap({ Double($0) }) else {
            return nil
        }
        return ComposerBodyEvalProbeMetrics(
            evals: evals,
            barEvals: fields["barEvals"].flatMap({ UInt64($0) }) ?? 0,
            passes: passes,
            passMs: passMs
        )
    }

    private func settleComposerPerfProbe() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    func testLiveSSHStackPaneCreatesExactlyOneRemotePaneWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("stack")
        let marker = "REMUX_STACK_PANE2_\(UUID().uuidString.prefix(8).uppercased())"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(1, timeout: 10))

        tapPickerButton(identifier: "terminal.pane.split.down", fallbackLabel: "Split down")
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))

        panePickerTiles()[1].tap()
        waitForLiveTerminalReady(timeout: 30)
        sendTerminalCommand("printf '\(marker)\\n'")
        hideKeyboardIfPresent()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        recordLiveTmuxPaneCountExpectation(sessionName: sessionName, expectedCount: 2)
        recordLiveTmuxPaneCaptureExpectation(sessionName: sessionName, paneIndex: 2, marker: marker)
    }

    func testLiveDenseWindowPickerReachabilityWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("dense-windows")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand(
            "i=2; while [ $i -le 10 ]; do tmux new-window -d -n remuxw$i; i=$((i+1)); done; printf 'REMUX_DENSE_WINDOWS_READY\\n'"
        )
        hideKeyboardIfPresent()

        openWindowsSheet()
        let window10 = waitForHittablePickerButton(
            identifier: "terminal.window.tile.10",
            fallbackLabel: "Window 10 of 10",
            timeout: 30
        )
        XCTAssertNotNil(window10, "Window 10 should be reachable in the iPhone window picker.")

        let newWindow = waitForHittablePickerButton(
            identifier: "terminal.window.new",
            fallbackLabel: "New Window",
            timeout: 10
        )
        XCTAssertNotNil(newWindow, "New Window should remain reachable after scrolling dense windows.")

        window10?.tap()
        waitForLiveTerminalReady(timeout: 30)
        let marker = "REMUX_DENSE_WINDOW_10_SELECTED_\(UUID().uuidString.prefix(8).uppercased())"
        sendTerminalCommand("printf '\(marker)\\n'")
        hideKeyboardIfPresent()
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 2_500)

        recordLiveTmuxWindowCountExpectation(sessionName: sessionName, expectedCount: 10)
        recordLiveTmuxWindowCaptureExpectation(sessionName: sessionName, windowIndex: 10, marker: marker)
    }

    func testLiveWindowNamesAndRenameWhenConfigured() throws {
        let sessionName: String
        if let override = liveSessionNameOverride() {
            guard override.range(
                of: #"^remux-latency-[A-Za-z0-9._-]+$"#,
                options: .regularExpression
            ) != nil else {
                throw LiveSSHCleanupHarnessError(
                    description: "Refusing unsafe window-name fixture session \(override)."
                )
            }
            sessionName = override
        } else {
            sessionName = try generatedLiveLatencySessionName("window-names")
        }
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand(
            "tmux rename-window 'editor workspace'; tmux new-window -d -n 'build logs'"
        )
        hideKeyboardIfPresent()

        openWindowsSheet()
        let firstWindow = app.buttons["terminal.window.tile.1"]
        let secondWindow = app.buttons["terminal.window.tile.2"]
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 10))
        wait(
            for: [
                expectation(
                    for: NSPredicate(format: "label CONTAINS %@", "editor workspace"),
                    evaluatedWith: firstWindow
                ),
                expectation(
                    for: NSPredicate(format: "label CONTAINS %@", "build logs"),
                    evaluatedWith: secondWindow
                ),
            ],
            timeout: 20
        )
        attach(name: "live-window-names-initial")

        dismissTopSheetIfPresent()
        waitForLiveTerminalReady(timeout: 30)
        sendTerminalCommand("tmux rename-window 'déploy-漢字'")
        hideKeyboardIfPresent()

        openWindowsSheet()
        let renamedWindow = app.buttons["terminal.window.tile.1"]
        XCTAssertTrue(renamedWindow.waitForExistence(timeout: 10))
        wait(
            for: [
                expectation(
                    for: NSPredicate(format: "label CONTAINS %@", "déploy-漢字"),
                    evaluatedWith: renamedWindow
                ),
            ],
            timeout: 20
        )
        XCTAssertTrue(
            app.buttons["terminal.window.tile.2"].label.contains("build logs"),
            "Renaming one window should preserve the other window's name."
        )
        attach(name: "live-window-name-unicode-renamed")

        recordLiveTmuxWindowCountExpectation(sessionName: sessionName, expectedCount: 2)
    }

    func testLiveDenseMixedTopologySelectsDeepPaneWhenConfigured() throws {
        try requireLivePreparedFixture("dense-mixed")

        let sessionName = try generatedLiveLatencySessionName("dense-mixed")
        let marker = "RDX10P4OK"
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        openWindowsSheet()
        let window10 = waitForHittablePickerButton(
            identifier: "terminal.window.tile.10",
            fallbackLabel: "Window 10 of 10",
            timeout: 30
        )
        XCTAssertNotNil(window10, "Window 10 should be reachable in the mixed dense topology.")

        window10?.tap()
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(4, timeout: 20))
        assertPaneTopology(paneCount: 4, attachmentName: "dense-pane-topology")
        let pane4 = panePickerTiles()[3]

        pane4.tap()
        waitForLiveTerminalReady(timeout: 30)
        sendTerminalCommand("printf '\(marker)\\n'")
        hideKeyboardIfPresent()
        assertLiveTerminalScreenshotContainsRenderedContent(minNonBackgroundPixels: 2_500)

        recordLiveTmuxWindowCountExpectation(sessionName: sessionName, expectedCount: 10)
        recordLiveTmuxPaneCountExpectation(sessionName: sessionName, expectedCount: 15)
        recordLiveTmuxWindowPaneCountExpectation(sessionName: sessionName, windowIndex: 10, expectedCount: 4)
        recordLiveTmuxWindowPaneCaptureExpectation(
            sessionName: sessionName,
            windowIndex: 10,
            paneIndex: 4,
            marker: marker
        )
    }

    func testLiveSSHBackgroundForegroundRetainsTerminalWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("foreground")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        openPanesSheet()
        tapPickerButton(identifier: "terminal.pane.split.right", fallbackLabel: "Split right")
        waitForLiveTerminalReady(timeout: 30)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        panePickerTiles()[0].tap()
        waitForLiveTerminalReady(timeout: 30)

        sendTerminalCommand("echo REMUX_FOREGROUND_BEFORE")
        backgroundAndReactivateApp(backgroundDuration: 4)
        waitForLiveTerminalReady(timeout: 60)
        XCTAssertFalse(app.staticTexts["terminal.status.failed"].exists)

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        panePickerTiles()[1].tap()
        waitForLiveTerminalReady(timeout: 30)
        sendTerminalCommand("echo REMUX_FOREGROUND_AFTER")

        openPanesSheet()
        XCTAssertTrue(waitForPanePickerTileCount(2, timeout: 10))
        let removedPaneIdentifier = panePickerTiles()[1].identifier
        removePanePickerItem(app.buttons[removedPaneIdentifier])
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons[removedPaneIdentifier], timeout: 10),
            "The requested pane should disappear after foreground restoration."
        )
        XCTAssertTrue(
            waitForPanePickerTileCount(1, timeout: 10),
            "The removed pane should disappear after foreground restoration."
        )
        dismissTopSheetIfPresent()
        waitForLiveTerminalReady(timeout: 30)

        openHomeFromTerminal()
        XCTAssertTrue(activeSessionRows.firstMatch.waitForExistence(timeout: 5))
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
    }

    func testLiveTerminalSelectionCopyWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("copy")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let marker = "REMUX_COPY_TOKEN_\(UUID().uuidString.prefix(8).uppercased())"
        UIPasteboard.general.string = "REMUX_COPY_SENTINEL"
        sendTerminalCommand("clear; printf '\(marker) alpha beta gamma\\n'")
        hideKeyboardIfPresent()

        guard waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 1_000,
            attachmentName: "live-terminal-stationary-selection-ready"
        ) != nil else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.02))
            .press(forDuration: 0.70)

        let copy = waitForCopyMenuItem(timeout: 5)
        copy.tap()
        XCTAssertTrue(
            waitForPasteboard(equalTo: marker, timeout: 5),
            "Stationary terminal word selection should copy exactly the selected marker."
        )

        let link = "http://localhost:3000/dashboard"
        UIPasteboard.general.string = "REMUX_LINK_COPY_SENTINEL"
        sendTerminalCommand("clear; printf '\(link)\\n'")
        hideKeyboardIfPresent()

        guard waitForStableLiveTerminalScreenshot(
            minNonBackgroundPixels: 1_000,
            attachmentName: "live-terminal-exact-link-selection-ready"
        ) != nil else {
            return
        }

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.02))
            .press(forDuration: 0.70)

        let linkCopy = waitForCopyMenuItem(timeout: 5)
        attach(name: "live-terminal-exact-link-selected")
        linkCopy.tap()
        XCTAssertTrue(
            waitForPasteboard(equalTo: link, timeout: 5),
            "Stationary terminal link selection should copy the entire URL exactly."
        )
    }

    func testLiveTerminalRelativeFilePreviewWhenConfigured() throws {
        try requireLivePreparedFixture("relative-file-preview")
        let sessionName = try generatedLiveLatencySessionName("relative-preview")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        XCTAssertFalse(app.keyboards.firstMatch.exists)
        guard waitForStableLiveTerminalScreenshot(
            minDistinctColors: 1,
            minNonBackgroundPixels: 350,
            attachmentName: "live-terminal-relative-preview-ready"
        ) != nil else {
            return
        }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let relativeFileCoordinate = terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.12, dy: 0.02)
        )
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.60)).tap()
        let softwareKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 5),
            "The Preview regression run must begin from a visible software keyboard."
        )
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 10),
            "The Preview regression run must use an on-screen keyboard, not only an off-screen accessibility keyboard element."
        )
        relativeFileCoordinate.press(forDuration: 0.70)

        let preview = waitForSelectionMenuItem("Preview", timeout: 5)
        let copy = waitForCopyMenuItem(timeout: 5)
        let itemsShareRow = abs(preview.frame.midY - copy.frame.midY)
            <= min(preview.frame.height, copy.frame.height) * 0.25
        if itemsShareRow {
            XCTAssertLessThan(
                preview.frame.minX,
                copy.frame.minX,
                "Preview should precede Copy in the terminal selection menu."
            )
        } else {
            XCTAssertLessThan(
                preview.frame.minY,
                copy.frame.minY,
                "Preview should precede Copy in the terminal selection menu."
            )
        }

        print("REMUX_PREVIEW_E2E_BEGIN")
        fflush(stdout)
        defer {
            print("REMUX_PREVIEW_E2E_END")
            fflush(stdout)
        }
        let previewOpenStarted = ProcessInfo.processInfo.systemUptime
        preview.tap()

        let previewContent = elementWithIdentifier("terminal.preview.content")
        let previewFailure = elementWithIdentifier("terminal.preview.failure")

        let previewDeadline = Date().addingTimeInterval(20)
        while Date() < previewDeadline,
              !previewContent.exists,
              !previewFailure.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(
            previewFailure.exists,
            "The relative text fixture should not enter the preview failure state."
        )
        XCTAssertTrue(
            previewContent.exists,
            "The relative text fixture should become previewable."
        )
        XCTAssertGreaterThan(previewContent.frame.width, 100)
        XCTAssertGreaterThan(previewContent.frame.height, 100)
        guard waitForRenderedPreviewContent(
            previewContent,
            attachmentName: "live-terminal-relative-file-preview"
        ) != nil else {
            return
        }
        print(String(
            format: "REMUX_PREVIEW_OPEN_MS %.1f",
            (ProcessInfo.processInfo.systemUptime - previewOpenStarted) * 1_000
        ))
        fflush(stdout)

        let close = app.buttons["terminal.preview.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Close Preview")
        let previewCloseStarted = ProcessInfo.processInfo.systemUptime
        close.tap()
        XCTAssertTrue(
            waitForElementToDisappear(close, timeout: 5),
            "Close should return directly to the retained terminal."
        )
        print(String(
            format: "REMUX_PREVIEW_CLOSE_MS %.1f",
            (ProcessInfo.processInfo.systemUptime - previewCloseStarted) * 1_000
        ))
        fflush(stdout)
        waitForLiveTerminalInputReady(timeout: 10)
        XCTAssertTrue(terminal.exists)
        XCTAssertTrue(
            softwareKeyboard.waitForExistence(timeout: 5),
            "Returning from Preview should restore the visible software keyboard."
        )
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 10),
            "Returning from Preview should restore the on-screen keyboard geometry."
        )
        attach(name: "live-terminal-absolute-preview-returned")

        relativeFileCoordinate.press(forDuration: 0.70)
        let copyAfterReturn = waitForCopyMenuItem(timeout: 5)
        XCTAssertTrue(
            waitForSelectionMenuItem("Preview", timeout: 5).exists,
            "Returning from Preview must preserve terminal long-press selection."
        )
        copyAfterReturn.tap()

        relativeFileCoordinate.press(forDuration: 0.70)
        let rapidPreview = waitForSelectionMenuItem("Preview", timeout: 5)
        print("REMUX_PREVIEW_RAPID_DISMISS_BEGIN")
        fflush(stdout)
        rapidPreview.tap()
        let rapidClose = app.buttons["terminal.preview.close"].firstMatch
        XCTAssertTrue(
            rapidClose.waitForExistence(timeout: 2),
            "Preview chrome should appear immediately while the file is loading."
        )
        rapidClose.tap()
        XCTAssertTrue(
            waitForElementToDisappear(rapidClose, timeout: 5),
            "Immediate Close should return to the retained terminal."
        )
        waitForLiveTerminalInputReady(timeout: 10)
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 10),
            "Immediate Preview dismissal must leave the keyboard and terminal geometry usable."
        )
        print("REMUX_PREVIEW_RAPID_DISMISS_END")
        fflush(stdout)

        relativeFileCoordinate.press(forDuration: 0.70)
        let copyAfterRapidDismiss = waitForCopyMenuItem(timeout: 5)
        XCTAssertTrue(
            copyAfterRapidDismiss.exists,
            "Immediate Preview dismissal must not wedge terminal interaction."
        )
        copyAfterRapidDismiss.tap()

        let pathScenarios = [
            (token: "./README.md", name: "dot-relative", shouldPreview: true),
            (token: "index.html", name: "static-html-relative-assets", shouldPreview: true),
            (token: "http://127.0.0.1:18923/", name: "live-localhost", shouldPreview: true),
            (token: "/etc/hosts", name: "absolute-extensionless", shouldPreview: true),
            (token: "does-not-exist.md", name: "missing", shouldPreview: false),
        ]
        for scenario in pathScenarios {
            sendTerminalCommand(scenario.token)
            guard waitForStableLiveTerminalScreenshot(
                minDistinctColors: 1,
                minNonBackgroundPixels: 350,
                attachmentName: "live-terminal-preview-candidate-\(scenario.name)"
            ) != nil else {
                return
            }

            relativeFileCoordinate.press(forDuration: 0.70)
            let scenarioPreview = waitForSelectionMenuItem("Preview", timeout: 5)
            scenarioPreview.tap()

            let scenarioContent = elementWithIdentifier("terminal.preview.content")
            let scenarioFailure = elementWithIdentifier("terminal.preview.failure")
            let scenarioDeadline = Date().addingTimeInterval(20)
            while Date() < scenarioDeadline,
                  !scenarioContent.exists,
                  !scenarioFailure.exists {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }

            if scenario.shouldPreview {
                XCTAssertTrue(
                    scenarioContent.exists,
                    "\(scenario.token) should render through Preview."
                )
                XCTAssertFalse(scenarioFailure.exists)
                guard waitForRenderedPreviewContent(
                    scenarioContent,
                    attachmentName: "live-terminal-preview-content-\(scenario.name)"
                ) != nil else {
                    return
                }
                if scenario.name == "static-html-relative-assets"
                    || scenario.name == "live-localhost" {
                    let firstLoad = app.staticTexts["Reload count 1"].firstMatch
                    XCTAssertTrue(
                        firstLoad.waitForExistence(timeout: 10),
                        "\(scenario.token) should execute its first page load."
                    )
                    let refresh = app.buttons["terminal.preview.refresh"].firstMatch
                    XCTAssertTrue(refresh.waitForExistence(timeout: 5))
                    refresh.tap()
                    XCTAssertTrue(
                        app.staticTexts["Reload count 2"].firstMatch
                            .waitForExistence(timeout: 10),
                        "Refresh should reload \(scenario.token) in the existing web view."
                    )
                }
            } else {
                XCTAssertTrue(
                    scenarioFailure.exists,
                    "A missing relative file should expose Preview's failure state."
                )
                XCTAssertFalse(scenarioContent.exists)
            }

            let scenarioClose = app.buttons["terminal.preview.close"].firstMatch
            XCTAssertTrue(scenarioClose.waitForExistence(timeout: 5))
            scenarioClose.tap()
            XCTAssertTrue(waitForElementToDisappear(scenarioClose, timeout: 5))
            waitForLiveTerminalInputReady(timeout: 10)
            XCTAssertTrue(waitForSoftwareKeyboardOnScreen(timeout: 10))
        }

        sendTerminalCommand("ordinaryword")
        guard waitForStableLiveTerminalScreenshot(
            minDistinctColors: 1,
            minNonBackgroundPixels: 350,
            attachmentName: "live-terminal-non-preview-word"
        ) != nil else {
            return
        }
        relativeFileCoordinate.press(forDuration: 0.70)
        let ordinaryCopy = waitForCopyMenuItem(timeout: 5)
        let anyPreviewAction = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Preview"))
            .firstMatch
        XCTAssertFalse(
            anyPreviewAction.waitForExistence(timeout: 0.5),
            "An ordinary word must remain Copy-only."
        )
        ordinaryCopy.tap()

        openWindowsSheet()
        tapPickerButton(identifier: "terminal.window.new", fallbackLabel: "New Window")
        waitForLiveTerminalReady(timeout: 30)

        openWindowsSheet()
        XCTAssertTrue(app.buttons["terminal.window.tile.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["terminal.window.tile.2"].waitForExistence(timeout: 10))
        tapPickerButton(identifier: "terminal.window.tile.1", fallbackLabel: "Window 1 of 2")
        waitForLiveTerminalReady(timeout: 30)

        terminal.swipeLeft(velocity: .slow)
        waitForLiveTerminalReady(timeout: 30)
        terminal.swipeRight(velocity: .slow)
        waitForLiveTerminalReady(timeout: 30)

        if !softwareKeyboard.exists {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.60)).tap()
        }
        XCTAssertTrue(
            waitForSoftwareKeyboardOnScreen(timeout: 10),
            "Window navigation after Preview should leave terminal input available."
        )
        relativeFileCoordinate.press(forDuration: 0.70)
        let copyAfterWindowNavigation = waitForCopyMenuItem(timeout: 5)
        XCTAssertTrue(
            copyAfterWindowNavigation.exists,
            "Window navigation after Preview must not disable terminal long-press selection."
        )
        copyAfterWindowNavigation.tap()

        hideKeyboardIfPresent()
        relativeFileCoordinate.press(forDuration: 0.70)
        XCTAssertTrue(
            waitForCopyMenuItem(timeout: 5).exists,
            "Window navigation after Preview must preserve selection after hiding the keyboard."
        )

        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "ordinaryword"
        )
    }

    func testLiveTerminalLongPressSteeringWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("steering")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        let collector = [
            #"tty=/dev/tty"#,
            #"saved=$(stty -g <$tty) || exit"#,
            #"trap "stty $saved <$tty" EXIT"#,
            #"stty raw -echo <$tty"#,
            #"data= chunk="#,
            #"IFS= read -r -k 3 -t 8 chunk <$tty; status=$?; [[ -n $chunk ]] && data+=$chunk"#,
            #"while (( status == 0 )); do chunk=; IFS= read -r -k 3 -t 0.6 chunk <$tty; status=$?; [[ -n $chunk ]] && data+=$chunk; done"#,
            #"stty $saved <$tty || exit; trap - EXIT"#,
            #"esc=$(printf "\033"); csi="${esc}[D"; ss3="${esc}OD"; rest=$data; count=0; valid=1"#,
            #"while [[ -n $rest ]]; do if [[ $rest == ${csi}* ]]; then rest=${rest[4,-1]}; elif [[ $rest == ${ss3}* ]]; then rest=${rest[4,-1]}; else valid=0; break; fi; (( count++ )); done"#,
            #"if (( valid && count >= 3 )); then print -r -- REMUX_STEER_REPEAT_OK; else hex=$(print -rn -- "$data" | od -An -tx1 | tr -d " \n"); print -r -- "REMUX_STEER_REPEAT_FAIL_$hex"; fi"#,
        ].joined(separator: "; ")
        sendTerminalCommand("zsh -fc '\(collector)'")
        hideKeyboardIfPresent()

        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.50))
            .press(
                forDuration: 0.55,
                thenDragTo: terminal.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.52, dy: 0.50)
                ),
                withVelocity: .slow,
                thenHoldForDuration: 0.90
            )

        RunLoop.current.run(until: Date().addingTimeInterval(4.5))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_STEER_REPEAT_OK"
        )
    }

    func testLiveTmuxPrefixEntersCopyModeWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("copy-mode")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)

        sendTerminalCommand("clear; printf 'REMUX_COPY_MODE_READY\\n'")
        hideKeyboardIfPresent()

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))

        let ctrl = app.buttons["terminal.ctrl"]
        XCTAssertTrue(ctrl.waitForExistence(timeout: 5))
        ctrl.tap()
        waitForLiveTerminalInputReady(timeout: 10)
        app.typeText("b")
        app.typeText("[")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        recordLiveTmuxPaneModeExpectation(sessionName: sessionName, paneIndex: 1, expectedInMode: true)
    }

    func testLiveWarmSSHRootReuseWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("warm")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)
        closeActiveSessionFromLibraryIfPossible()

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    func testLiveLibraryPrewarmedSSHRootWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("prewarm")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)

        let savedSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        savedSession.tap()
        waitForLiveTerminalReady(timeout: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    private func cleanupGeneratedLiveLatencySessionIfPossible(_ sessionName: String) {
        guard sessionName.hasPrefix("remux-latency-") else { return }

        closeActiveSessionFromLibraryIfPossible()
    }

    private func generatedLiveLatencySessionName(_ purpose: String) throws -> String {
        try requireLiveSSHConfigurationExists()
        let manifestPath = try liveGeneratedSessionManifestPath()

        if let override = liveSessionNameOverride() {
            XCTAssertTrue(
                override.range(
                    of: #"^remux-latency-[A-Za-z0-9._-]+$"#,
                    options: .regularExpression
                ) != nil,
                "Refusing to use non-allowlisted live tmux session override \(override)."
            )
            recordGeneratedLiveLatencySession(override, manifestPath: manifestPath)
            return override
        }

        let safePurpose = purpose.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        let sessionName = "remux-latency-\(safePurpose)-\(UUID().uuidString.prefix(8))"
        recordGeneratedLiveLatencySession(sessionName, manifestPath: manifestPath)
        return sessionName
    }

    private func liveGeneratedSessionManifestPath() throws -> String {
        guard liveCleanupHarnessEnabled() else {
            throw LiveSSHCleanupHarnessError(
                description: "Live SSH UI tests that create remux-latency-* tmux sessions must run through scripts/remux_live_ui_test_with_cleanup.sh; refusing to create a remote tmux session without remote kill-session cleanup."
            )
        }

        if let manifestPath = ProcessInfo.processInfo.environment["REMUX_LIVE_GENERATED_SESSION_MANIFEST"],
           !manifestPath.isEmpty {
            return manifestPath
        }

        return "/tmp/remux-live-generated-sessions.txt"
    }

    private func liveCleanupHarnessEnabled() -> Bool {
        liveCleanupHarnessFieldsIfEnabled() != nil
    }

    private func liveCleanupHarnessFieldsIfEnabled() -> [String: String]? {
        let url = URL(fileURLWithPath: "/tmp/remux-live-cleanup-harness.txt")
        guard
            let data = try? Data(contentsOf: url),
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let fields = value
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }

        guard
            let pidString = fields["pid"],
            let pid = Int32(pidString),
            let startedAtString = fields["startedAt"],
            let startedAt = TimeInterval(startedAtString)
        else {
            return nil
        }

        let markerAge = Date().timeIntervalSince1970 - startedAt
        guard markerAge >= 0, markerAge <= 30 * 60 else { return nil }

        return liveCleanupHarnessProcessExists(pid) ? fields : nil
    }

    private func liveCleanupHarnessOverride(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }
        return liveCleanupHarnessFieldsIfEnabled()?[key]
    }

    private func liveCleanupHarnessProcessExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }

        let result = Darwin.kill(pid_t(pid), 0)
        if result == 0 {
            return true
        }

        return errno == EPERM
    }

    private func requireLiveSSHConfigurationExists() throws {
        if liveSSHConfigurationDataFromEnvironment() != nil {
            return
        }
        let configurationPath = "/tmp/remux-live-ssh.json"
        guard FileManager.default.fileExists(atPath: configurationPath) else {
            throw XCTSkip("Create \(configurationPath) inside the simulator to run live SSH UI testing.")
        }
    }

    private func liveAgentTUISessionName() throws -> String {
        try requireLiveSSHConfigurationExists()
        guard let sessionName = liveCleanupHarnessOverride("REMUX_LIVE_AGENT_TUI_SESSION") ??
            liveHarnessValue(
                environmentKey: "REMUX_LIVE_AGENT_TUI_SESSION",
                fallbackPath: "/tmp/remux-live-agent-tui-session.txt"
            )
        else {
            let description = "Set REMUX_LIVE_AGENT_TUI_SESSION to an existing two-pane tmux session running real agent TUIs."
            if liveCleanupHarnessEnabled() {
                throw LiveSSHCleanupHarnessError(description: description)
            }
            throw XCTSkip(description)
        }
        guard sessionName.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil else {
            throw LiveSSHCleanupHarnessError(
                description: "Refusing unsafe agent TUI tmux session name \(sessionName)."
            )
        }
        return sessionName
    }

    private func requireLivePreparedFixture(_ fixtureName: String) throws {
        let preparedFixture = livePreparedFixtureName()
        guard preparedFixture == fixtureName else {
            throw XCTSkip("Run this live SSH UI test through scripts/remux_live_ui_test_with_cleanup.sh so it can prepare the \(fixtureName) tmux fixture.")
        }
    }

    private func liveSessionNameOverride() -> String? {
        liveHarnessValue(
            environmentKey: "REMUX_LIVE_SESSION_NAME_OVERRIDE",
            fallbackPath: "/tmp/remux-live-session-name-override.txt"
        )
    }

    private func livePreparedFixtureName() -> String? {
        liveHarnessValue(
            environmentKey: "REMUX_LIVE_PREPARED_FIXTURE",
            fallbackPath: "/tmp/remux-live-prepared-fixture.txt"
        )
    }

    private func liveHarnessValue(environmentKey: String, fallbackPath: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[environmentKey],
           !environmentValue.isEmpty {
            return environmentValue
        }

        let url = URL(fileURLWithPath: fallbackPath)
        guard
            let data = try? Data(contentsOf: url),
            let rawValue = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func recordGeneratedLiveLatencySession(_ sessionName: String, manifestPath: String) {
        XCTAssertTrue(
            sessionName.range(
                of: #"^remux-latency-[A-Za-z0-9._-]+$"#,
                options: .regularExpression
            ) != nil,
            "Refusing to record non-allowlisted generated live tmux session \(sessionName)."
        )

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let data = Data("\(sessionName)\n".utf8)

        do {
            if FileManager.default.fileExists(atPath: manifestPath) {
                let handle = try FileHandle(forWritingTo: manifestURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: manifestURL, options: .atomic)
            }
        } catch {
            XCTFail("Failed to record generated live tmux session \(sessionName): \(error)")
        }
    }

    private func recordLiveTmuxPaneCountExpectation(sessionName: String, expectedCount: Int) {
        XCTAssertGreaterThanOrEqual(expectedCount, 0)
        recordLiveTmuxExpectation(fields: ["pane-count", sessionName, "\(expectedCount)"])
    }

    private func recordLiveTmuxPaneModeExpectation(
        sessionName: String,
        paneIndex: Int,
        expectedInMode: Bool
    ) {
        XCTAssertGreaterThan(paneIndex, 0)
        recordLiveTmuxExpectation(fields: [
            "pane-mode",
            sessionName,
            "\(paneIndex)",
            expectedInMode ? "1" : "0",
        ])
    }

    private func recordLiveTmuxWindowCountExpectation(sessionName: String, expectedCount: Int) {
        XCTAssertGreaterThanOrEqual(expectedCount, 0)
        recordLiveTmuxExpectation(fields: ["window-count", sessionName, "\(expectedCount)"])
    }

    private func recordLiveTmuxWindowPaneCountExpectation(
        sessionName: String,
        windowIndex: Int,
        expectedCount: Int
    ) {
        XCTAssertGreaterThan(windowIndex, 0)
        XCTAssertGreaterThanOrEqual(expectedCount, 0)
        recordLiveTmuxExpectation(fields: ["window-pane-count", sessionName, "\(windowIndex)", "\(expectedCount)"])
    }

    private func recordLiveTmuxPaneCaptureExpectation(
        sessionName: String,
        paneIndex: Int,
        marker: String
    ) {
        XCTAssertGreaterThan(paneIndex, 0)
        XCTAssertTrue(
            marker.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
            "Refusing to record unsafe tmux capture marker \(marker)."
        )
        recordLiveTmuxExpectation(fields: ["pane-index-contains", sessionName, "\(paneIndex)", marker])
    }

    private func recordLiveTmuxWindowCaptureExpectation(
        sessionName: String,
        windowIndex: Int,
        marker: String
    ) {
        XCTAssertGreaterThan(windowIndex, 0)
        XCTAssertTrue(
            marker.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
            "Refusing to record unsafe tmux capture marker \(marker)."
        )
        recordLiveTmuxExpectation(fields: ["window-index-contains", sessionName, "\(windowIndex)", marker])
    }

    private func recordLiveTmuxWindowPaneCaptureExpectation(
        sessionName: String,
        windowIndex: Int,
        paneIndex: Int,
        marker: String
    ) {
        XCTAssertGreaterThan(windowIndex, 0)
        XCTAssertGreaterThan(paneIndex, 0)
        XCTAssertTrue(
            marker.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
            "Refusing to record unsafe tmux capture marker \(marker)."
        )
        recordLiveTmuxExpectation(fields: [
            "window-pane-index-contains",
            sessionName,
            "\(windowIndex).\(paneIndex)",
            marker,
        ])
    }

    private func recordLiveTmuxExpectation(fields: [String]) {
        let manifestPath = ProcessInfo.processInfo.environment["REMUX_LIVE_TMUX_EXPECTATION_MANIFEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp/remux-live-tmux-expectations.txt"

        for field in fields {
            XCTAssertFalse(field.contains("\t"), "Live tmux expectation fields cannot contain tabs.")
            XCTAssertFalse(field.contains("\n"), "Live tmux expectation fields cannot contain newlines.")
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let data = Data("\(fields.joined(separator: "\t"))\n".utf8)

        do {
            if FileManager.default.fileExists(atPath: manifestPath) {
                let handle = try FileHandle(forWritingTo: manifestURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: manifestURL, options: .atomic)
            }
        } catch {
            XCTFail("Failed to record live tmux expectation \(fields): \(error)")
        }
    }

    private func closeActiveSessionFromLibraryIfPossible() {
        if let homeButton = optionalTerminalHomeButton(timeout: 2) {
            tapTerminalHomeButton(homeButton)
        }

        let activeSession = app.buttons["library.active-session.show"].firstMatch
        guard activeSession.waitForExistence(timeout: 5) else { return }

        activeSession.swipeLeft()
        let disconnect = app.buttons["Disconnect"].firstMatch
        guard disconnect.waitForExistence(timeout: 3) else { return }

        disconnect.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    @discardableResult
    private func waitForKeyboardPresence(
        _ expected: Bool,
        label: String,
        timeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.01,
        stableFor minimumStableDuration: TimeInterval = 0
    ) -> TimeInterval? {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let keyboard = app.keyboards.firstMatch
        var matchingSince: Date?

        repeat {
            if isSoftwareKeyboardOnScreen(keyboard) == expected {
                let now = Date()
                matchingSince = matchingSince ?? now
                if let matchingSince,
                   now.timeIntervalSince(matchingSince) >= minimumStableDuration {
                    let elapsed = now.timeIntervalSince(start)
                    print("Remux UI perf keyboard.\(expected ? "visible" : "hidden") label=\"\(label)\" elapsed_ms=\(String(format: "%.3f", elapsed * 1000))")
                    return elapsed
                }
            } else {
                matchingSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline

        XCTFail("Timed out waiting for keyboard \(expected ? "visible" : "hidden") during \(label)")
        return nil
    }

    private func waitForKeyboardContinuity(
        owner expectedOwner: String,
        timeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.01
    ) -> (
        owner: String,
        willHideCount: Int,
        liveViewport: String,
        effectiveViewport: String,
        bottomChrome: String,
        safeAreaBottom: String,
        transitionActive: Bool,
        awaitingSystemKeyboard: Bool
    )? {
        let marker = app.otherElements["terminal.keyboard.continuity"]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if marker.exists,
               let value = marker.value as? String,
               let state = keyboardContinuityState(from: value),
               state.owner == expectedOwner,
               !state.transitionActive,
               !state.awaitingSystemKeyboard {
                return state
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline

        XCTFail("Timed out waiting for keyboard owner \(expectedOwner)")
        return nil
    }

    private func keyboardContinuityState(
        from value: String
    ) -> (
        owner: String,
        willHideCount: Int,
        liveViewport: String,
        effectiveViewport: String,
        bottomChrome: String,
        safeAreaBottom: String,
        transitionActive: Bool,
        awaitingSystemKeyboard: Bool
    )? {
        var fields: [String: String] = [:]
        for field in value.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let owner = fields["owner"],
              let willHide = fields["willHide"],
              let willHideCount = Int(willHide),
              let liveViewport = fields["liveViewport"],
              let effectiveViewport = fields["effectiveViewport"],
              let bottomChrome = fields["bottomChrome"],
              let safeAreaBottom = fields["safeAreaBottom"],
              let transitionActive = fields["transitionActive"].flatMap(Bool.init),
              let awaitingSystemKeyboard = fields["awaitingSystemKeyboard"].flatMap(Bool.init)
        else { return nil }
        return (
            owner,
            willHideCount,
            liveViewport,
            effectiveViewport,
            bottomChrome,
            safeAreaBottom,
            transitionActive,
            awaitingSystemKeyboard
        )
    }

    private func launchSimulatorApp() {
        app.launchEnvironment["REMUX_UI_TESTING"] = "1"
        app.launch()
    }

    private func launchLiveSSHAppIfConfigured(
        traceRuntime: Bool = false,
        sessionNameOverride: String? = nil
    ) throws {
        let configuration = try liveSSHConfiguration()
        let displayName = configuration.displayName ?? "Live SSH"
        let sessionName = sessionNameOverride ?? configuration.sessionName ?? "remux-live-e2e"

        app.launchEnvironment["REMUX_DEBUG_SEED_CONNECTION"] = "1"
        app.launchEnvironment["REMUX_DEBUG_SERVER_NAME"] = displayName
        app.launchEnvironment["REMUX_DEBUG_SERVER_HOST"] = configuration.host
        app.launchEnvironment["REMUX_DEBUG_SERVER_PORT"] = configuration.port ?? "22"
        app.launchEnvironment["REMUX_DEBUG_SERVER_USERNAME"] = configuration.username
        if let privateKeyPEM = configuration.privateKeyPEM, !privateKeyPEM.isEmpty {
            app.launchEnvironment["REMUX_DEBUG_PRIVATE_KEY"] = privateKeyPEM
            if let passphrase = configuration.privateKeyPassphrase {
                app.launchEnvironment["REMUX_DEBUG_PRIVATE_KEY_PASSPHRASE"] = passphrase
            }
        } else if let password = configuration.password, !password.isEmpty {
            app.launchEnvironment["REMUX_DEBUG_SERVER_PASSWORD"] = password
        } else {
            throw LiveSSHCleanupHarnessError(
                description: "/tmp/remux-live-ssh.json must include password or privateKeyPEM."
            )
        }
        app.launchEnvironment["REMUX_DEBUG_TMUX_SESSION"] = sessionName
        app.launchEnvironment["REMUX_DEBUG_EPHEMERAL_STORAGE"] = "1"
        if traceRuntime {
            app.launchEnvironment["REMUX_TRACE_FLOWS"] = "1"
            app.launchEnvironment["REMUX_TRACE_LATENCY"] = "1"
            app.launchEnvironment["REMUX_TRACE_PERF"] = "1"
            app.launchEnvironment["REMUX_TRACE_TMUX_VIEWPORT"] = "1"
            app.launchEnvironment["GHOSTTY_TRACE_SURFACE_INIT"] = "1"
        }
        forwardTraceEnvironment()
        app.launch()
    }

    private func forwardTraceEnvironment() {
        let processEnvironment = ProcessInfo.processInfo.environment
        let harnessFields = liveCleanupHarnessFieldsIfEnabled()
        for key in [
            "REMUX_TRACE_FLOWS",
            "REMUX_TRACE_PERF",
            "REMUX_TRACE_LATENCY",
            "REMUX_TRACE_GHOSTTY_IO",
            "REMUX_TRACE_GHOSTTY_DIAGNOSTICS",
            "REMUX_TRACE_TMUX_VIEWPORT",
            "REMUX_TRACE_TMUX_VIEWPORT_FULL",
            "GHOSTTY_TRACE_SURFACE_INIT",
            "GHOSTTY_TRACE_FRAME_COMPLETION",
            "REMUX_DEBUG_LATENCY_PROBE",
            "REMUX_DEBUG_LATENCY_PROBE_DELAY_MS",
            "REMUX_SCROLL_PRECISE_GAIN",
        ] {
            guard let value = processEnvironment[key] ?? harnessFields?[key] else {
                continue
            }
            app.launchEnvironment[key] = value
        }
    }

    private func liveSSHConfiguration() throws -> LiveSSHConfiguration {
        if let data = liveSSHConfigurationDataFromEnvironment() {
            return try JSONDecoder().decode(LiveSSHConfiguration.self, from: data)
        }
        let configurationURL = URL(fileURLWithPath: "/tmp/remux-live-ssh.json")
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw XCTSkip("Create /tmp/remux-live-ssh.json inside the simulator to run live SSH UI testing.")
        }

        let data = try Data(contentsOf: configurationURL)
        return try JSONDecoder().decode(LiveSSHConfiguration.self, from: data)
    }

    private func liveSSHConfigurationDataFromEnvironment() -> Data? {
        guard let encoded = ProcessInfo.processInfo.environment[
            "REMUX_LIVE_SSH_CONFIGURATION_BASE64"
        ], !encoded.isEmpty else {
            return nil
        }
        return Data(base64Encoded: encoded)
    }

    private func waitForLiveTerminalReady(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let readyStatus = app.staticTexts["terminal.status.ready"]
        let inheritedReadyStatus = app.staticTexts
            .matching(identifier: "terminal.screen")
            .matching(NSPredicate(format: "label == %@", "terminal ready"))
            .firstMatch
        let failedStatuses = app.staticTexts.matching(identifier: "terminal.status.failed")

        while Date() < deadline {
            if readyStatus.exists || inheritedReadyStatus.exists {
                return
            }

            if trustExpectedUnknownLiveHostKeyIfNeeded() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }

            if failedStatuses.firstMatch.exists {
                let messages = failedStatuses.allElementsBoundByIndex
                    .map { $0.label }
                    .filter { !$0.isEmpty }
                XCTFail(
                    messages.isEmpty
                        ? "Live SSH terminal failed before becoming ready."
                        : messages.joined(separator: " / ")
                )
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail("Timed out waiting for a live SSH terminal to become ready.")
    }

    private func trustExpectedUnknownLiveHostKeyIfNeeded() -> Bool {
        let verifyTitle = app.staticTexts["Verify Server"]
        guard verifyTitle.exists else { return false }
        guard let expectedHostKey = liveHarnessValue(
            environmentKey: "REMUX_LIVE_EXPECTED_HOST_KEY",
            fallbackPath: "/tmp/remux-live-expected-host-key.txt"
        )
        else {
            XCTFail("Live SSH host-key verification requires REMUX_LIVE_EXPECTED_HOST_KEY.")
            return false
        }

        let failureLabels = app.staticTexts
            .matching(identifier: "terminal.status.failed")
            .allElementsBoundByIndex
            .map { $0.label }
        let expectedVerification = "Received \(expectedHostKey)"
        guard failureLabels.contains(expectedVerification) else {
            XCTFail(
                "Refusing live SSH host trust because Remux did not display the expected fingerprint."
            )
            return false
        }
        if acceptedExpectedLiveHostKey {
            return true
        }

        let identifiedTrustButton = app.buttons["terminal.status.hostKey.updateTrust"]
        let trustButton = identifiedTrustButton.exists
            ? identifiedTrustButton
            : app.buttons["Trust Server"]
        guard trustButton.waitForExistence(timeout: 2) else {
            XCTFail("Expected the Trust Server action for a verified unknown host key.")
            return false
        }
        trustButton.tap()
        acceptedExpectedLiveHostKey = true
        return true
    }

    private func waitForLiveTerminalInputReady(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let inputReady = app.descendants(matching: .any)["terminal.input.ready"]
        let statusReady = app.staticTexts["terminal.status.ready"]
        let failedStatuses = app.staticTexts.matching(identifier: "terminal.status.failed")

        while Date() < deadline {
            if inputReady.exists {
                return
            }

            if failedStatuses.firstMatch.exists {
                let messages = failedStatuses.allElementsBoundByIndex
                    .map { $0.label }
                    .filter { !$0.isEmpty }
                XCTFail(
                    messages.isEmpty
                        ? "Live SSH terminal failed before input became ready."
                        : messages.joined(separator: " / ")
                )
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let statusContext = statusReady.exists ? "terminal.status.ready existed" : "terminal.status.ready missing"
        XCTFail("Timed out waiting for live SSH terminal input readiness (\(statusContext)).")
    }

    private func assertLiveTerminalScreenshotContainsRenderedContent(
        minDistinctColors: Int = 8,
        minNonBackgroundPixels: Int = 2_500,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(8)
        var lastScreenshot: XCUIScreenshot?
        var lastStats: (distinctColors: Int, nonBackgroundPixels: Int)?

        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot

            guard let stats = liveTerminalRenderedPixelStats(screenshot: screenshot) else {
                XCTFail("Unable to inspect live terminal screenshot.", file: file, line: line)
                return
            }
            lastStats = stats

            if stats.distinctColors > minDistinctColors && stats.nonBackgroundPixels > minNonBackgroundPixels {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "live-terminal-render-check"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = "live-terminal-render-check"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let statsSummary = lastStats.map {
            " distinctColors=\($0.distinctColors) nonBackgroundPixels=\($0.nonBackgroundPixels)"
        } ?? ""

        XCTFail(
            "Live terminal screenshot is visually flat; expected rendered terminal text or glyph variation with at least \(minDistinctColors) distinct colors and \(minNonBackgroundPixels) non-background pixels.\(statsSummary)",
            file: file,
            line: line
        )
    }

    private func waitForStableLiveTerminalScreenshot(
        minDistinctColors: Int = 8,
        minNonBackgroundPixels: Int = 2_500,
        stablePixelDifferenceLimit: Int = 1_500,
        timeout: TimeInterval = 8,
        attachmentName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIScreenshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: XCUIScreenshot?
        var lastScreenshot: XCUIScreenshot?
        var lastStats: (distinctColors: Int, nonBackgroundPixels: Int)?
        var lastDifference: Int?

        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot

            guard let stats = liveTerminalRenderedPixelStats(screenshot: screenshot) else {
                XCTFail("Unable to inspect live terminal screenshot.", file: file, line: line)
                return nil
            }
            lastStats = stats

            if let previous {
                lastDifference = liveTerminalPixelDifference(before: previous, after: screenshot)
            }

            if
                stats.distinctColors > minDistinctColors,
                stats.nonBackgroundPixels > minNonBackgroundPixels,
                let difference = lastDifference,
                difference <= stablePixelDifferenceLimit
            {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = attachmentName
                attachment.lifetime = .keepAlways
                add(attachment)
                return screenshot
            }

            previous = screenshot
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let statsSummary = lastStats.map {
            " distinctColors=\($0.distinctColors) nonBackgroundPixels=\($0.nonBackgroundPixels)"
        } ?? ""
        let differenceSummary = lastDifference.map { " pixelDifference=\($0)" } ?? ""

        XCTFail(
            "Live terminal screenshot did not settle before timeout.\(statsSummary)\(differenceSummary)",
            file: file,
            line: line
        )
        return nil
    }

    private func liveTerminalRenderedPixelStats(
        screenshot: XCUIScreenshot
    ) -> (distinctColors: Int, nonBackgroundPixels: Int)? {
        guard let snapshot = liveTerminalContentPixels(screenshot: screenshot) else { return nil }
        return pixelStats(snapshot)
    }

    private func waitForRenderedPreviewContent(
        _ element: XCUIElement,
        timeout: TimeInterval = 8,
        attachmentName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIScreenshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastScreenshot: XCUIScreenshot?
        var lastStats: (distinctColors: Int, nonBackgroundPixels: Int)?

        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot
            lastStats = renderedPixelStats(screenshot: screenshot, element: element)
            if let lastStats,
               lastStats.distinctColors > 2,
               lastStats.nonBackgroundPixels > 500 {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = attachmentName
                attachment.lifetime = .keepAlways
                add(attachment)
                return screenshot
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let stats = lastStats.map {
            " distinctColors=\($0.distinctColors) nonBackgroundPixels=\($0.nonBackgroundPixels)"
        } ?? ""
        XCTFail("Preview content did not render before timeout.\(stats)", file: file, line: line)
        return nil
    }

    private func renderedPixelStats(
        screenshot: XCUIScreenshot,
        element: XCUIElement
    ) -> (distinctColors: Int, nonBackgroundPixels: Int)? {
        guard let cgImage = screenshot.image.cgImage,
              app.frame.width > 0,
              app.frame.height > 0
        else {
            return nil
        }
        let frame = element.frame.intersection(app.frame)
        guard !frame.isNull, frame.width > 1, frame.height > 1 else { return nil }
        let scaleX = CGFloat(cgImage.width) / app.frame.width
        let scaleY = CGFloat(cgImage.height) / app.frame.height
        let crop = CGRect(
            x: frame.minX * scaleX,
            y: frame.minY * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        )
        guard let snapshot = renderedPixels(cgImage: cgImage, crop: crop) else { return nil }
        return pixelStats(snapshot)
    }

    private func liveTerminalPixelDifference(
        before: XCUIScreenshot,
        after: XCUIScreenshot
    ) -> Int? {
        guard
            let beforeSnapshot = liveTerminalContentPixels(screenshot: before),
            let afterSnapshot = liveTerminalContentPixels(screenshot: after),
            beforeSnapshot.width == afterSnapshot.width,
            beforeSnapshot.height == afterSnapshot.height
        else {
            return nil
        }

        var changedPixels = 0
        var index = 0
        let pixelCount = beforeSnapshot.width * beforeSnapshot.height
        while index < pixelCount {
            let offset = index * 4
            let redDelta = abs(Int(beforeSnapshot.pixels[offset] / 4) - Int(afterSnapshot.pixels[offset] / 4))
            let greenDelta = abs(Int(beforeSnapshot.pixels[offset + 1] / 4) - Int(afterSnapshot.pixels[offset + 1] / 4))
            let blueDelta = abs(Int(beforeSnapshot.pixels[offset + 2] / 4) - Int(afterSnapshot.pixels[offset + 2] / 4))
            if redDelta + greenDelta + blueDelta > 3 {
                changedPixels += 1
            }
            index += 1
        }

        return changedPixels
    }

    private func liveTerminalBottomContentRatio(
        screenshot: XCUIScreenshot
    ) -> Double? {
        guard let snapshot = liveTerminalContentPixels(screenshot: screenshot) else { return nil }

        var colorCounts: [UInt32: Int] = [:]
        colorCounts.reserveCapacity(128)
        let pixelCount = snapshot.width * snapshot.height
        for index in 0..<pixelCount {
            let offset = index * 4
            colorCounts[quantizedColor(snapshot.pixels, offset: offset), default: 0] += 1
        }
        guard let background = colorCounts.max(by: { $0.value < $1.value })?.key else { return nil }

        let firstRow = snapshot.height * 3 / 4
        let regionPixelCount = snapshot.width * (snapshot.height - firstRow)
        guard regionPixelCount > 0 else { return nil }

        var contentPixels = 0
        for y in firstRow..<snapshot.height {
            for x in 0..<snapshot.width {
                let offset = (y * snapshot.width + x) * 4
                if quantizedColor(snapshot.pixels, offset: offset) != background {
                    contentPixels += 1
                }
            }
        }
        return Double(contentPixels) / Double(regionPixelCount)
    }

    private func liveTerminalContentPixels(
        screenshot: XCUIScreenshot
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cgImage = screenshot.image.cgImage else { return nil }
        guard app.frame.width > 0, app.frame.height > 0 else { return nil }

        let terminal = app.otherElements["terminal.screen"].firstMatch
        guard terminal.exists else { return nil }

        let scaleX = CGFloat(cgImage.width) / app.frame.width
        let scaleY = CGFloat(cgImage.height) / app.frame.height
        let appFrame = app.frame
        var contentFrame = terminal.frame.intersection(appFrame)
        guard !contentFrame.isNull,
              contentFrame.width > 1,
              contentFrame.height > 1
        else {
            return nil
        }

        let topSystemChromeInset = min(64, appFrame.height * 0.08)
        let clippedMinY = max(contentFrame.minY, appFrame.minY + topSystemChromeInset)
        var clippedMaxY = contentFrame.maxY

        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            clippedMaxY = min(clippedMaxY, keyboard.frame.minY)
        }

        let keyboardChromeButton = app.buttons["terminal.keyboard"]
        if keyboardChromeButton.exists {
            clippedMaxY = min(clippedMaxY, keyboardChromeButton.frame.minY)
        }

        contentFrame = CGRect(
            x: contentFrame.minX,
            y: clippedMinY,
            width: contentFrame.width,
            height: clippedMaxY - clippedMinY
        )
        guard contentFrame.height > 1 else { return nil }

        let crop = CGRect(
            x: contentFrame.minX * scaleX,
            y: contentFrame.minY * scaleY,
            width: contentFrame.width * scaleX,
            height: contentFrame.height * scaleY
        )
        return renderedPixels(cgImage: cgImage, crop: crop)
    }

    private func assertPreviewTilesContainRenderedImages(
        tiles: [XCUIElement],
        attachmentName: String,
        minDistinctColors: Int = 8,
        minNonBackgroundPixels: Int = 2_500,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tileIdentifiers = tiles.map { $0.identifier }
        for (identifier, tile) in zip(tileIdentifiers, tiles) {
            XCTAssertTrue(
                tile.waitForExistence(timeout: 5),
                "Missing preview tile \(identifier)",
                file: file,
                line: line
            )
        }

        let deadline = Date().addingTimeInterval(15)
        var lastScreenshot: XCUIScreenshot?
        var lastStats: [String: (distinctColors: Int, nonBackgroundPixels: Int)] = [:]

        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            lastScreenshot = screenshot

            lastStats = Dictionary(
                uniqueKeysWithValues: zip(tileIdentifiers, tiles).compactMap { identifier, tile in
                    previewTileRenderedPixelStats(screenshot: screenshot, tile: tile).map {
                        (identifier, $0)
                    }
                }
            )
            let allTilesRendered = tileIdentifiers.allSatisfy { identifier in
                guard let stats = lastStats[identifier] else { return false }
                return stats.distinctColors > minDistinctColors &&
                    stats.nonBackgroundPixels > minNonBackgroundPixels
            }
            if allTilesRendered {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "preview-render-check-\(attachmentName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = "preview-render-check-\(attachmentName)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let diagnostics = tileIdentifiers.map { identifier in
            guard let stats = lastStats[identifier] else {
                return "\(identifier): no pixel sample"
            }
            return "\(identifier): distinctColors=\(stats.distinctColors), " +
                "nonBackgroundPixels=\(stats.nonBackgroundPixels)"
        }.joined(separator: "; ")

        XCTFail(
            "Preview tiles did not expose rendered terminal previews; \(diagnostics)",
            file: file,
            line: line
        )
    }

    private func assertPaneTopology(
        paneCount: Int,
        attachmentName: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let paneSheet = elementWithIdentifier("terminal.panes.sheet")
        XCTAssertTrue(paneSheet.waitForExistence(timeout: 5), file: file, line: line)

        let tiles = panePickerTiles()
        XCTAssertEqual(tiles.count, paneCount, file: file, line: line)
        var selectedPaneCount = 0
        for tile in tiles where tile.isSelected {
            selectedPaneCount += 1
        }
        XCTAssertEqual(
            selectedPaneCount,
            1,
            "Exactly one topology pane must be selected.",
            file: file,
            line: line
        )

        if let attachmentName {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func previewTileRenderedPixelStats(
        screenshot: XCUIScreenshot,
        tile: XCUIElement
    ) -> (distinctColors: Int, nonBackgroundPixels: Int)? {
        guard let snapshot = previewTileRenderedPixels(
            screenshot: screenshot,
            tile: tile
        ) else { return nil }
        return pixelStats(snapshot)
    }

    private func previewTileRenderedPixels(
        screenshot: XCUIScreenshot,
        tile: XCUIElement
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let cgImage = screenshot.image.cgImage else { return nil }
        guard app.frame.width > 0, app.frame.height > 0 else { return nil }

        let scaleX = CGFloat(cgImage.width) / app.frame.width
        let scaleY = CGFloat(cgImage.height) / app.frame.height
        let tileFrame = tile.frame
        guard tileFrame.width > 0, tileFrame.height > 0 else { return nil }

        let previewFrame = CGRect(
            x: tileFrame.minX + tileFrame.width * 0.08,
            y: tileFrame.minY + tileFrame.height * 0.08,
            width: tileFrame.width * 0.84,
            height: tileFrame.height * 0.68
        )
        let pixelCrop = CGRect(
            x: previewFrame.minX * scaleX,
            y: previewFrame.minY * scaleY,
            width: previewFrame.width * scaleX,
            height: previewFrame.height * scaleY
        )

        return renderedPixels(cgImage: cgImage, crop: pixelCrop)
    }

    private func quantizedColor(_ pixels: [UInt8], offset: Int) -> UInt32 {
        UInt32(pixels[offset] / 4) << 16 |
            UInt32(pixels[offset + 1] / 4) << 8 |
            UInt32(pixels[offset + 2] / 4)
    }

    private func pixelStats(
        _ snapshot: (pixels: [UInt8], width: Int, height: Int)
    ) -> (distinctColors: Int, nonBackgroundPixels: Int) {
        let pixels = snapshot.pixels

        var colorCounts: [UInt32: Int] = [:]
        colorCounts.reserveCapacity(128)

        var index = 0
        let pixelCount = snapshot.width * snapshot.height
        while index < pixelCount {
            let offset = index * 4
            let red = UInt32(pixels[offset] / 4)
            let green = UInt32(pixels[offset + 1] / 4)
            let blue = UInt32(pixels[offset + 2] / 4)
            let color = red << 16 | green << 8 | blue
            colorCounts[color, default: 0] += 1
            index += 1
        }

        let dominantCount = colorCounts.values.max() ?? pixelCount
        return (
            distinctColors: colorCounts.count,
            nonBackgroundPixels: pixelCount - dominantCount
        )
    }

    private func renderedPixels(
        cgImage: CGImage,
        crop: CGRect
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let boundedCrop = crop.integral.intersection(imageBounds)
        guard !boundedCrop.isNull,
              boundedCrop.width >= 1,
              boundedCrop.height >= 1,
              let cropped = cgImage.cropping(to: boundedCrop)
        else {
            return nil
        }

        let cropWidth = cropped.width
        let cropHeight = cropped.height
        var pixels = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: cropWidth,
            height: cropHeight,
            bitsPerComponent: 8,
            bytesPerRow: cropWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)
        )
        return (pixels: pixels, width: cropWidth, height: cropHeight)
    }

    private func openConnectionSetup() {
        XCTAssertTrue(app.buttons["library.empty.add-server"].waitForExistence(timeout: 5))
        app.buttons["library.empty.add-server"].tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 2))
    }

    private func fillConnectionForm() {
        app.textFields["connection.name"].tap()
        app.textFields["connection.name"].typeText("Example Server")

        app.textFields["connection.host"].tap()
        app.textFields["connection.host"].typeText("127.0.0.1")

        app.textFields["connection.username"].tap()
        app.textFields["connection.username"].typeText("demo\n")

        let password = app.secureTextFields["connection.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 2))
        password.typeText("demo-password")

        app.swipeUp()
        let sessionName = app.textFields["connection.session"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 2))
        sessionName.tap()
        sessionName.typeText("base")

        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
    }

    private func fillPublicKeyInstallationServerFields() {
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1")

        let port = app.textFields["connection.port"]
        XCTAssertEqual(port.value as? String, "22")

        let username = app.textFields["connection.username"]
        username.tap()
        username.typeText("demo\n")
    }

    private func saveConnectionAndWaitForTerminal() {
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 10))
        dismissPasswordManagerPromptIfPresent()
    }

    private func openHomeFromTerminal() {
        let homeButton = waitForTerminalHomeButton()
        tapTerminalHomeButton(homeButton)

        XCTAssertTrue(app.descendants(matching: .any)["library.list"].waitForExistence(timeout: 5))
    }

    private func openSessionSwitcherFromTerminal() {
        let buttons = app.buttons.matching(identifier: "terminal.sessions")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 5))
        guard let button = uniqueHittableElement(
            in: buttons,
            description: "terminal.sessions"
        ) else {
            XCTFail("Missing hittable terminal Sessions button.")
            return
        }
        button.tap()
    }

    private func disconnectActiveSessionFromSwitcher(named sessionName: String) -> XCUIElement {
        let activeRow = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.active-session")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", sessionName))
            .firstMatch
        XCTAssertTrue(activeRow.waitForExistence(timeout: 5))
        activeRow.swipeLeft()

        let disconnectButton = app.buttons["terminal.sessions.disconnect"]
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 5))
        disconnectButton.tap()

        let recentRow = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.recent-session")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", sessionName))
            .firstMatch
        let deadline = Date().addingTimeInterval(5)
        while !recentRow.isHittable, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            recentRow.isHittable,
            "Disconnecting from Remux should retain the session under Recent."
        )
        return recentRow
    }

    private func waitForTerminalHomeButton(timeout: TimeInterval = 2) -> XCUIElement {
        if let button = terminalHomeButton(timeout: timeout, allowMissing: false) {
            return button
        }
        XCTFail("Missing terminal Home button.")
        return app.buttons["terminal.home"].firstMatch
    }

    private func optionalTerminalHomeButton(timeout: TimeInterval = 2) -> XCUIElement? {
        terminalHomeButton(timeout: timeout, allowMissing: true)
    }

    private func terminalHomeButton(
        timeout: TimeInterval,
        allowMissing: Bool
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let identifiedButtons = app.buttons.matching(identifier: "terminal.home")
        let labeledButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Home"))
        var firstExisting: XCUIElement?

        while Date() < deadline {
            if let button = uniqueHittableElement(in: identifiedButtons, description: "terminal.home") {
                return button
            }

            if let button = uniqueHittableElement(in: labeledButtons, description: "Home") {
                return button
            }

            firstExisting = firstExisting ?? firstExistingElement(in: identifiedButtons)
            firstExisting = firstExisting ?? firstExistingElement(in: labeledButtons)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        if let firstExisting, !allowMissing {
            return firstExisting
        }

        if !allowMissing {
            XCTFail("Missing terminal Home button.")
        }
        return nil
    }

    private func uniqueHittableElement(
        in query: XCUIElementQuery,
        description: String
    ) -> XCUIElement? {
        let elements = hittableElements(in: query)
        if elements.count > 1 {
            XCTFail("Expected at most one hittable \(description) button, found \(elements.count).")
        }
        return elements.first
    }

    private func hittableElements(in query: XCUIElementQuery) -> [XCUIElement] {
        var elements: [XCUIElement] = []
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            if element.exists && element.isHittable {
                elements.append(element)
            }
        }

        return elements
    }

    private func tapTerminalHomeButton(_ button: XCUIElement) {
        if button.isHittable {
            button.tap()
        } else {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func firstExistingElement(in query: XCUIElementQuery) -> XCUIElement? {
        let element = query.firstMatch
        return element.exists ? element : nil
    }

    private func openNewSessionFromLibrary() {
        let detailButton = app.buttons["library.server.new-session"]
        if detailButton.waitForExistence(timeout: 1) {
            detailButton.tap()
            return
        }

        openFirstServerDetail()

        let serverButton = app.buttons["library.server.new-session"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 2))
        if serverButton.isHittable {
            serverButton.tap()
        } else {
            serverButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func dismissPasswordManagerPromptIfPresent() {
        let appNotNowButton = app.buttons["Not Now"]
        if appNotNowButton.waitForExistence(timeout: 1) {
            appNotNowButton.tap()
            return
        }

        app.tap()
        if appNotNowButton.waitForExistence(timeout: 1) {
            appNotNowButton.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.63)).tap()
    }

    private func installSystemPromptMonitor() {
        addUIInterruptionMonitor(withDescription: "Dismiss optional system prompt") { alert in
            let notNow = alert.buttons["Not Now"]
            if notNow.exists {
                notNow.tap()
                return true
            }

            let cancel = alert.buttons["Cancel"]
            if cancel.exists {
                cancel.tap()
                return true
            }

            let allowPaste = alert.buttons["Allow Paste"]
            if allowPaste.exists {
                allowPaste.tap()
                return true
            }

            return false
        }
    }

    private func openFirstSavedSession() {
        let savedSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        if savedSession.waitForExistence(timeout: 2) {
            savedSession.tap()
            return
        }

        openFirstServerDetail()

        let serverSession = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        XCTAssertTrue(serverSession.waitForExistence(timeout: 3))
        serverSession.tap()
    }

    private func openWindowsSheet() {
        if panePickerIsOpen {
            dismissTopSheetIfPresent()
        }

        if !windowPickerIsOpen {
            let windows = app.buttons["terminal.windows"]
            XCTAssertTrue(windows.waitForExistence(timeout: 10))
            windows.tap()
        }

        XCTAssertTrue(
            waitForAnyPickerElement(
                [
                    elementWithIdentifier("terminal.windows.sheet"),
                    app.buttons["terminal.window.new"],
                    app.buttons["New Window"],
                ],
                timeout: 8
            ),
            "Window picker should present."
        )
    }

    private func openPanesSheet() {
        if windowPickerIsOpen {
            dismissTopSheetIfPresent()
        }

        if !panePickerIsOpen {
            let panes = app.buttons["terminal.panes"]
            XCTAssertTrue(panes.waitForExistence(timeout: 10))
            panes.tap()
        }

        XCTAssertTrue(
            waitForAnyPickerElement(
                [
                    elementWithIdentifier("terminal.panes.sheet"),
                    app.buttons["terminal.pane.split.right"],
                    app.buttons["Split right"],
                ],
                timeout: 8
            ),
            "Pane picker should present."
        )
    }

    private var windowPickerIsOpen: Bool {
        elementWithIdentifier("terminal.windows.sheet").exists
            || app.buttons["terminal.window.new"].exists
            || app.buttons["New Window"].exists
    }

    private var panePickerIsOpen: Bool {
        elementWithIdentifier("terminal.panes.sheet").exists
            || app.buttons["terminal.pane.split.right"].exists
            || app.buttons["Split right"].exists
    }

    private func tapPickerButton(identifier: String, fallbackLabel: String) {
        let identified = app.buttons.matching(identifier: identifier).firstMatch
        let labeled = app.buttons.matching(NSPredicate(format: "label == %@", fallbackLabel)).firstMatch
        guard let button = firstExistingPickerElement([identified, labeled], timeout: 5) else {
            XCTFail("Missing picker button \(identifier) / \(fallbackLabel)")
            return
        }
        button.tap()
    }

    private func waitForHittablePickerButton(
        identifier: String,
        fallbackLabel: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let identified = app.buttons.matching(identifier: identifier).firstMatch
        let labeled = app.buttons.matching(NSPredicate(format: "label == %@", fallbackLabel)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            for button in [identified, labeled] where button.exists && button.isHittable {
                return button
            }

            scrollOpenPickerUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        return [identified, labeled].first { $0.exists && $0.isHittable }
    }

    private func scrollOpenPickerUp() {
        if swipeFirstHittablePickerTile(identifierPrefix: "terminal.window.tile.") {
            return
        }

        if swipeFirstHittablePickerTile(identifierPrefix: "terminal.pane.tile.") {
            return
        }

        if elementWithIdentifier("terminal.windows.scroll").exists {
            elementWithIdentifier("terminal.windows.scroll").swipeUp(velocity: .slow)
            return
        }

        if elementWithIdentifier("terminal.windows.sheet").exists {
            elementWithIdentifier("terminal.windows.sheet").swipeUp(velocity: .slow)
            return
        }

        if elementWithIdentifier("terminal.panes.sheet").exists {
            elementWithIdentifier("terminal.panes.sheet").swipeUp(velocity: .slow)
            return
        }

        app.swipeUp(velocity: .slow)
    }

    private func swipeFirstHittablePickerTile(identifierPrefix: String) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        for tile in app.buttons.matching(predicate).allElementsBoundByIndex where tile.exists && tile.isHittable {
            tile.swipeUp(velocity: .slow)
            return true
        }

        return false
    }

    private func waitForAnyPickerElement(
        _ elements: [XCUIElement],
        timeout: TimeInterval
    ) -> Bool {
        firstExistingPickerElement(elements, timeout: timeout) != nil
    }

    private func firstExistingPickerElement(
        _ elements: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for element in elements where element.exists {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        return elements.first { $0.exists }
    }

    private func elementWithIdentifier(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func panePickerTiles() -> [XCUIElement] {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.pane.tile."))
            .allElementsBoundByIndex
    }

    private func waitForPanePickerTileCount(
        _ expectedCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if panePickerTiles().count == expectedCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return panePickerTiles().count == expectedCount
    }

    private func removePanePickerItem(_ tile: XCUIElement) {
        let tilePrefix = "terminal.pane.tile."
        XCTAssertTrue(tile.identifier.hasPrefix(tilePrefix))
        let paneIdentifier = String(tile.identifier.dropFirst(tilePrefix.count))
        XCTAssertFalse(paneIdentifier.isEmpty)

        tile.press(forDuration: 1.0)
        tapPickerButton(
            identifier: "terminal.pane.remove.\(paneIdentifier)",
            fallbackLabel: "Remove Pane"
        )
    }

    private func removePickerItem(
        tileIdentifier: String,
        actionIdentifier: String,
        actionLabel: String,
        confirmIdentifier: String,
        confirmLabel: String
    ) {
        let tile = app.buttons[tileIdentifier]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Missing picker tile \(tileIdentifier)")
        tile.press(forDuration: 1.0)

        tapPickerButton(identifier: actionIdentifier, fallbackLabel: actionLabel)
        tapPickerButton(identifier: confirmIdentifier, fallbackLabel: confirmLabel)
    }

    private func sendTerminalCommand(_ command: String) {
        waitForLiveTerminalInputReady(timeout: 10)

        if !app.keyboards.firstMatch.exists {
            let keyboard = app.buttons["terminal.keyboard"]
            XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
            keyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        }

        app.typeText("\(command)\n")
    }

    private func hideKeyboardIfPresent() {
        guard app.keyboards.firstMatch.exists else { return }

        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        _ = waitForKeyboardPresence(false, label: "selection copy hide", timeout: 5)
    }

    private func waitForSoftwareKeyboardOnScreen(timeout: TimeInterval) -> Bool {
        let keyboard = app.keyboards.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSoftwareKeyboardOnScreen(keyboard) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        return isSoftwareKeyboardOnScreen(keyboard)
    }

    private func isSoftwareKeyboardOnScreen(_ keyboard: XCUIElement) -> Bool {
        guard keyboard.exists else { return false }
        let frame = keyboard.frame
        return frame.height > 100 && frame.intersects(app.frame)
    }

    private func waitForCopyMenuItem(timeout: TimeInterval) -> XCUIElement {
        waitForSelectionMenuItem("Copy", timeout: timeout)
    }

    private func waitForSelectionMenuItem(
        _ title: String,
        timeout: TimeInterval
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        let menuItem = app.menuItems[title].firstMatch
        let button = app.buttons[title].firstMatch
        let labeledElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch

        repeat {
            for element in [menuItem, button, labeledElement] where element.exists {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Terminal selection should expose the \(title) menu item.")
        return menuItem
    }

    private func waitForPasteboard(
        equalTo expected: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if readPasteboardStringAllowingPermission(timeout: 1) == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline

        return readPasteboardStringAllowingPermission(timeout: 1) == expected
    }

    private func readPasteboardStringAllowingPermission(timeout: TimeInterval) -> String? {
        let group = DispatchGroup()
        let lock = NSLock()
        var result: String?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let pasteboardString = UIPasteboard.general.string
            lock.lock()
            result = pasteboardString
            lock.unlock()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while group.wait(timeout: .now()) == .timedOut, Date() < deadline {
            allowPastePermissionIfPresent(timeout: 0.05)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        allowPastePermissionIfPresent(timeout: 0.05)

        guard group.wait(timeout: .now()) == .success else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func allowPastePermissionIfPresent(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [
            app.buttons["Allow Paste"].firstMatch,
            springboard.buttons["Allow Paste"].firstMatch,
        ]

        for candidate in candidates where candidate.exists {
            candidate.tap()
            return
        }

        if timeout > 0 {
            for candidate in candidates where candidate.waitForExistence(timeout: timeout) {
                candidate.tap()
                return
            }
        }
    }

    private func backgroundAndReactivateApp(backgroundDuration: TimeInterval) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForAppState(
                [.runningBackground, .runningBackgroundSuspended],
                timeout: 10
            ),
            "App should leave the foreground after pressing Home."
        )

        RunLoop.current.run(until: Date().addingTimeInterval(backgroundDuration))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    private func waitForAppState(
        _ states: [XCUIApplication.State],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if states.contains(app.state) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return states.contains(app.state)
    }

    private func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func openFirstServerDetail() {
        let server = app.descendants(matching: .any)
            .matching(identifier: "library.server.row")
            .firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        if !server.isHittable {
            app.swipeUp()
            XCTAssertTrue(server.waitForExistence(timeout: 2))
        }

        server.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5)).tap()
    }

    private var activeSessionRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library.active-session.show")
    }

    private func tapFontDefaultToggle() {
        if app.switches["settings.use-default-font"].exists {
            app.switches["settings.use-default-font"].tap()
            return
        }

        app.buttons["settings.use-default-font"].tap()
    }

    private var settingsForm: XCUIElement {
        let collectionView = app.collectionViews["settings.form"]
        if collectionView.exists {
            return collectionView
        }

        let table = app.tables["settings.form"]
        if table.exists {
            return table
        }

        return app.otherElements["settings.form"]
    }

    func testCaptureDesignReviewScreens() throws {
        try launchLiveSSHAppIfConfigured(traceRuntime: true)

        XCTAssertTrue(app.buttons["library.add-server"].waitForExistence(timeout: 12))
        sleep(1)
        attach(name: "10-library")

        let settings = app.buttons["library.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 3))
        sleep(1)
        attach(name: "11-settings")

        // Open the theme picker so we capture its expanded menu.
        let theme = app.descendants(matching: .any)["settings.theme"]
        if theme.waitForExistence(timeout: 2), theme.isHittable {
            theme.tap()
            sleep(1)
            attach(name: "11b-theme-menu")
            // Dismiss menu without picking a different theme by tapping the
            // currently selected item (label varies; fall back to back swipe).
            if !app.buttons["Ghostty Default"].waitForExistence(timeout: 1) {
                app.swipeDown()
            } else {
                app.buttons["Ghostty Default"].tap()
            }
        }

        app.navigationBars.buttons.firstMatch.tap()

        let addServer = app.buttons["library.add-server"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 3))
        sleep(1)
        attach(name: "12-connection-setup-empty")

        // Fill the form so we can capture the populated state.
        let name = app.textFields["connection.name"]
        name.tap()
        name.typeText("Example SSH Server")

        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("server.example.com")

        let user = app.textFields["connection.username"]
        user.tap()
        user.typeText("demo\n")

        let pwd = app.secureTextFields["connection.password"]
        XCTAssertTrue(pwd.waitForExistence(timeout: 2))
        pwd.typeText("demo-password")
        sleep(1)
        attach(name: "13-connection-setup-filled")

        app.buttons["connection.cancel"].tap()
        XCTAssertTrue(app.buttons["library.add-server"].waitForExistence(timeout: 3))
        // The cancelled connection-setup form may have left the keyboard up
        // and/or surfaced a password-manager prompt that overlays the list.
        sleep(1)
        dismissPasswordManagerPromptIfPresent()
        if app.keyboards.firstMatch.exists {
            app.tap()
        }
        sleep(1)

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
        sleep(3)
        attach(name: "20-terminal-ready")

        let panes = app.buttons["terminal.panes"]
        XCTAssertTrue(panes.waitForExistence(timeout: 5))
        if panes.isHittable { panes.tap() }
        sleep(2)
        attach(name: "21-panes-sheet")
        dismissTopSheetIfPresent()

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.waitForExistence(timeout: 5))
        if windows.isHittable { windows.tap() }
        sleep(2)
        attach(name: "22-windows-sheet")
        dismissTopSheetIfPresent()

        // Toggle the keyboard mode in the grouped terminal dock, then capture.
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        if keyboard.isHittable { keyboard.tap() }
        sleep(3)
        attach(name: "23-grouped-terminal-dock-keyboard")

        // Capture the grouped dock with ctrl armed (modifier feedback).
        let ctrlButton = app.buttons["terminal.ctrl"]
        if ctrlButton.exists, ctrlButton.isHittable {
            ctrlButton.tap()
            sleep(1)
            attach(name: "24-grouped-terminal-dock-ctrl-armed")
        }

        tapTerminalHomeButton(waitForTerminalHomeButton(timeout: 5))
        sleep(2)
        attach(name: "30-library-with-connected-session")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissTopSheetIfPresent() {
        for identifier in [
            "terminal.panes.close",
            "terminal.windows.close",
            "terminal.sessions.close",
        ] {
            let closeButton = app.buttons[identifier]
            if closeButton.exists, closeButton.isHittable {
                closeButton.tap()
                return
            }
        }

        let sheet = app.otherElements.matching(identifier: "PopoverDismissRegion").firstMatch
        if sheet.exists, sheet.isHittable {
            sheet.tap()
            return
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        sleep(1)
        if optionalTerminalHomeButton(timeout: 0.2) != nil { return }

        app.swipeDown()
    }
}
