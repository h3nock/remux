import Darwin
import Foundation
import UIKit
import XCTest

final class RemuxAppUITests: XCTestCase {
    /// The connection fields of the harness's live SSH configuration. The app
    /// reads the credential from the same file itself.
    private struct LiveSSHConfiguration: Decodable {
        var displayName: String?
        let host: String
        var port: String?
        let username: String
        var sessionName: String?
        var tmuxExecutablePath: String?
        /// The Herdr the app's discovery runs on the server. Without one, discovery finds no Herdr: the server's
        /// own Herdr and its sessions belong to whoever runs it.
        var herdrExecutablePath: String?
    }

    /// The live Herdr UI test's configuration, a JSON file named by REMUX_LIVE_HERDR_UI_CONFIG (pass it
    /// to `xcodebuild test` as TEST_RUNNER_REMUX_LIVE_HERDR_UI_CONFIG). The app reads the credential
    /// from the same file. The Herdr session must already exist.
    private struct LiveHerdrConfiguration: Decodable {
        var displayName: String?
        let host: String
        var port: String?
        let username: String
        let sessionName: String
        let herdrExecutablePath: String
        /// The tmux the app's discovery runs on the server, such as a wrapper for a tmux of its own.
        var tmuxExecutablePath: String?
        /// The host key Remux shows when it first meets the server, as "<type> <SHA256 fingerprint>".
        let expectedHostKey: String
        /// Where each step's screenshot is written as well, when set.
        var captureDirectory: String?
        /// The panes of the session's tab, as the server counts them: the session test needs more than one,
        /// and checks that the pane picker shows a tile for each.
        var paneCount: Int?
        /// Where the notification test asks the harness for each change on the server, by writing
        /// `<step>.request`; that test is skipped without it.
        var stepDirectory: String?
    }

    private struct LiveSSHCleanupHarnessError: Error, CustomStringConvertible {
        let description: String
    }

    private var app: XCUIApplication!
    private var acceptedExpectedLiveHostKey = false
    private var startedLiveSession = false
    private var launchedLiveSSHApp = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        app = XCUIApplication()
        installSystemPromptMonitor()
        try waitForEarlierLiveTestCleanupThenMarkThisTest()
    }

    override func tearDown() {
        // The cleanup harness removes a live test's tmux sessions as soon as
        // the test ends. An app left running would reattach and recreate them.
        if launchedLiveSSHApp {
            app.terminate()
        }
        super.tearDown()
    }

    /// The cleanup harness checks and cleans up after a live test once XCTest
    /// reports its result, by which time the next test may have started. So
    /// each test creates `<test>.awaiting-cleanup` in setUp, before its body
    /// runs; the harness removes it when it is done with the test, and the
    /// next test waits for that in setUp. If the harness could not remove the
    /// test's sessions, it keeps the marker and writes "cleanup failed" in it.
    private func waitForEarlierLiveTestCleanupThenMarkThisTest() throws {
        guard let records = liveHarnessRunDirectory?.appendingPathComponent("tests", isDirectory: true) else {
            return
        }
        let suffix = ".awaiting-cleanup"
        let timeout: TimeInterval = 120
        let started = Date()
        while true {
            let awaiting = try FileManager.default.contentsOfDirectory(atPath: records.path)
                .filter { $0.hasSuffix(suffix) }
            if awaiting.isEmpty {
                break
            }
            for marker in awaiting {
                if let contents = FileManager.default.contents(atPath: records.appendingPathComponent(marker).path),
                   !contents.isEmpty {
                    throw LiveSSHCleanupHarnessError(
                        description: "The cleanup harness could not remove the tmux sessions of \(marker.dropLast(suffix.count)); refusing to start a test that could see them."
                    )
                }
            }
            guard Date().timeIntervalSince(started) < timeout else {
                throw LiveSSHCleanupHarnessError(
                    description: "The cleanup harness has not finished with \(awaiting.joined(separator: ", ")) after \(Int(timeout)) s; refusing to start a test that could see its tmux sessions."
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let waited = Date().timeIntervalSince(started)
        if waited >= 0.2 {
            print(String(format: "Waited %.1f s for the cleanup harness to finish the previous test.", waited))
        }
        try Data().write(to: records.appendingPathComponent(liveHarnessTestMethod + suffix))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCreatesSSHServerThenStartsFirstSessionWithSimulatorTransport() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        saveServerAndStartSession()
        _ = waitForTerminalHomeButton()
    }

    /// iOS offers to save a typed password when the form holding it closes.
    /// Remux keeps server passwords in its own Keychain, so the server form
    /// closes without that offer.
    func testServerFormClosesWithoutPasswordSaveOffer() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        app.buttons["connection.cancel"].tap()
        XCTAssertTrue(app.buttons["library.empty.add-server"].waitForExistence(timeout: 5))
        assertNoPasswordSaveOffer(after: "Cancel")

        openConnectionSetup()
        fillConnectionForm()
        app.buttons["connection.save"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.server.detail"].waitForExistence(timeout: 5)
        )
        assertNoPasswordSaveOffer(after: "Save")
    }

    /// Return on the last field shown saves the server. The tmux path is
    /// hidden in the collapsed Advanced group, so Return skips it.
    func testReturnOnPasswordSavesServer() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: app.buttons["connection.save"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)

        app.secureTextFields["connection.password"].typeText("\n")

        XCTAssertTrue(
            app.descendants(matching: .any)["library.server.detail"].waitForExistence(timeout: 5),
            "Return on the password should save the server."
        )
    }

    /// Save stays disabled while the tmux path is invalid, so the path's
    /// problem shows as it is typed and Advanced can't be collapsed over it.
    func testInvalidTmuxPathKeepsAdvancedOpen() {
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        let advanced = app.buttons["Advanced"]
        for _ in 0..<4 where !advanced.isHittable {
            app.swipeUp()
        }
        advanced.tap()
        let executable = app.textFields["connection.tmux-executable"]
        XCTAssertTrue(executable.waitForExistence(timeout: 2))
        tapFormField(executable)
        typeTextAndConfirm("~/bin/tmux", into: executable)
        let problem = app.staticTexts["Enter an absolute path beginning with /."]
        XCTAssertTrue(problem.waitForExistence(timeout: 2), "The path's problem should show as it is typed.")
        XCTAssertFalse(app.buttons["connection.save"].isEnabled)

        advanced.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(executable.exists, "Advanced should stay open while the path is invalid.")
        XCTAssertTrue(problem.exists)

        // Correcting the path keeps Advanced open, also while the field is briefly empty. The field's
        // clear button empties it back to Automatic.
        tapFormField(executable)
        let clear = app.buttons["connection.tmux-executable.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 2), "A filled, focused path should offer its clear button.")
        clear.tap()
        let emptied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '' OR value == 'Automatic'"),
            object: executable
        )
        XCTAssertEqual(XCTWaiter.wait(for: [emptied], timeout: 2), .completed, "Clear should empty the path.")
        XCTAssertFalse(clear.exists, "An empty path has nothing to clear.")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(executable.exists, "Advanced closed while the path was being corrected.")
        typeTextAndConfirm("/usr/local/bin/tmux", into: executable)
        XCTAssertFalse(problem.exists)
        XCTAssertTrue(app.buttons["connection.save"].isEnabled)
    }

    /// Terminals stay alive behind Home. Home follows the system appearance,
    /// not the theme of the terminal it covers.
    func testHomeFollowsSystemAppearanceAfterDarkTerminal() {
        XCUIDevice.shared.appearance = .light
        launchSeededSimulatorTerminal()
        XCTAssertLessThan(
            averageLuminance(app.screenshot()) ?? 1,
            0.5,
            "The terminal should show its default dark theme."
        )

        openHomeFromTerminal()

        let deadline = Date().addingTimeInterval(3)
        var luminance = averageLuminance(app.screenshot()) ?? 0
        while luminance <= 0.5, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            luminance = averageLuminance(app.screenshot()) ?? 0
        }
        XCTAssertGreaterThan(luminance, 0.5, "Home should be light, like the system.")
    }

    func testToolbarKeysUpdateRetainedSimulatorTerminalAndFirstSlotOpensShortcuts() {
        launchSeededSimulatorTerminal()

        XCTAssertEqual(app.buttons["terminal.toolbar-key.0"].label, "Control")
        openHomeFromTerminal()
        app.buttons["library.settings"].tap()
        let toolbarKeys = app.buttons["settings.toolbar-keys"]
        if !toolbarKeys.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        toolbarKeys.tap()
        app.buttons["settings.toolbar-keys.slot.0"].tap()
        selectToolbarKey("Page Down")
        app.buttons["settings.toolbar-keys.slot.1"].tap()
        selectToolbarKey("Control")
        app.buttons["settings.toolbar-keys.slot.2"].tap()
        selectToolbarKey("Home")
        app.navigationBars["Toolbar Keys"].buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons.firstMatch.tap()

        let retainedSession = app.buttons["library.active-session.show"].firstMatch
        XCTAssertTrue(retainedSession.waitForExistence(timeout: 5))
        retainedSession.tap()

        let first = app.buttons["terminal.toolbar-key.0"]
        let control = app.buttons["terminal.toolbar-key.1"]
        let third = app.buttons["terminal.toolbar-key.2"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "Page Down")
        XCTAssertEqual(control.label, "Control")
        XCTAssertEqual(third.label, "Home")

        attachScreenshot(named: "toolbar-keys-control-moved")

        waitForLiveTerminalInputReady(timeout: 10)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 2))
        attachScreenshot(named: "toolbar-keys-first-slot-shortcuts")
        app.otherElements["terminal.screen"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .tap()
        XCTAssertFalse(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 1))
    }

    func testComposerDictationStopAndCancelFlow() {
        let transcript = "Review the current changes and run the focused tests"
        app.launchEnvironment["REMUX_DEBUG_DICTATION_TRANSCRIPT"] = transcript
        launchSeededSimulatorTerminal(attachesTmux: false)

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

        stop.tap()

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
        launchSeededSimulatorTerminal(attachesTmux: false)

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
        launchSeededSimulatorTerminal(attachesTmux: false)

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

    /// On a tmux session the Tabs sheet covers the terminal, which gives up the keyboard under it and gets it
    /// back when the sheet closes. A responder left under a sheet has UIKit bring its keyboard back over the
    /// sheet for anything there that reloads input views, as a menu's list does.
    func testTheTerminalGivesUpTheKeyboardUnderTheTabsSheet() {
        launchSeededSimulatorTerminal()
        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "terminal keyboard before Tabs"))
        XCTAssertTrue(waitForTerminalFirstResponder(true), "The terminal didn't take the keyboard.")

        openWindowsSheet()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "Tabs over the terminal"))
        XCTAssertTrue(waitForTerminalFirstResponder(false), "The terminal kept the keyboard under Tabs.")

        let close = app.buttons["terminal.windows.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "terminal keyboard after Tabs"))
        XCTAssertTrue(waitForTerminalFirstResponder(true), "The terminal didn't get the keyboard back after Tabs.")
    }

    func testComposerTogglePreservesKeyboardWhileReservingComposerViewport() {
        launchSeededSimulatorTerminal()

        let terminal = app.otherElements["terminal.screen"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))

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
        app.launchArguments += ["-terminal.composer.keyboardDismissHintShown", "NO"]
        launchSeededSimulatorTerminal()

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
        launchSeededSimulatorTerminal()

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
        launchSeededSimulatorTerminal(attachesTmux: false)
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
        typeTextAndConfirm("logs", into: sessionName)
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

        let legacyRSAHostKeys = app.switches["settings.allow-insecure-rsa"]
        for _ in 0..<3 where !legacyRSAHostKeys.exists {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(legacyRSAHostKeys.waitForExistence(timeout: 2))
        XCTAssertEqual(legacyRSAHostKeys.label, "Allow older RSA host keys")
    }

    func testSettingsShowHapticsSwitchesOnByDefault() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        let bellsAndAgents = app.switches["settings.haptics.bells-and-agents"]
        let keysAndButtons = app.switches["settings.haptics.keys-and-buttons"]
        for _ in 0..<3 where !keysAndButtons.isHittable {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(bellsAndAgents.waitForExistence(timeout: 2))
        XCTAssertTrue(keysAndButtons.waitForExistence(timeout: 2))
        XCTAssertEqual(bellsAndAgents.value as? String, "1")
        XCTAssertEqual(keysAndButtons.value as? String, "1")
        attachScreenshot(named: "settings-haptics")
    }

    func testFreshPhoneInstallShowsMultipaneZoomDefaultEnabled() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        let zoom = app.switches["settings.zoom-multipane-windows-by-default"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 2))
        XCTAssertEqual(zoom.value as? String, "1")
    }

    func testSettingsOpenShortcutCollections() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        let shortcuts = app.buttons["settings.shortcuts"]
        if !shortcuts.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 2))
        shortcuts.tap()

        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Collections"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["Add Collection"].exists)
        XCTAssertFalse(app.buttons["Close Shortcuts"].exists)
        attachScreenshot(named: "settings-shortcuts-shared-chrome")
    }

    func testSettingsConfigureAndResetToolbarKeys() {
        launchSimulatorApp()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 5))
        app.buttons["library.settings"].tap()

        let toolbarKeys = app.buttons["settings.toolbar-keys"]
        if !toolbarKeys.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(toolbarKeys.waitForExistence(timeout: 2))
        XCTAssertEqual(toolbarKeys.value as? String, "Control, Escape, Tab")
        attachScreenshot(named: "settings-toolbar-keys-row-default")
        toolbarKeys.tap()

        XCTAssertTrue(app.navigationBars["Toolbar Keys"].waitForExistence(timeout: 2))
        let first = app.buttons["settings.toolbar-keys.slot.0"]
        let second = app.buttons["settings.toolbar-keys.slot.1"]
        let third = app.buttons["settings.toolbar-keys.slot.2"]
        XCTAssertEqual(first.value as? String, "Control")
        XCTAssertEqual(second.value as? String, "Escape")
        XCTAssertEqual(third.value as? String, "Tab")
        attachScreenshot(named: "settings-toolbar-keys-default")

        first.tap()
        XCTAssertTrue(app.navigationBars["First Key"].waitForExistence(timeout: 2))
        attachScreenshot(named: "settings-toolbar-keys-picker")
        selectToolbarKey("Page Down")
        XCTAssertEqual(first.value as? String, "Page Down")

        second.tap()
        XCTAssertTrue(app.navigationBars["Second Key"].waitForExistence(timeout: 2))
        selectToolbarKey("Page Down")
        XCTAssertEqual(second.value as? String, "Page Down")

        third.tap()
        XCTAssertTrue(app.navigationBars["Third Key"].waitForExistence(timeout: 2))
        selectToolbarKey("Home")
        XCTAssertEqual(third.value as? String, "Home")
        attachScreenshot(named: "settings-toolbar-keys-customized")

        let reset = app.buttons["settings.toolbar-keys.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 2))
        reset.tap()

        XCTAssertEqual(first.value as? String, "Control")
        XCTAssertEqual(second.value as? String, "Escape")
        XCTAssertEqual(third.value as? String, "Tab")
        XCTAssertFalse(reset.exists)
        attachScreenshot(named: "settings-toolbar-keys-reset")
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
        tapFormField(host)
        host.typeText(".changed")
        XCTAssertTrue(
            waitForElementToDisappear(inlineStatus, timeout: 3),
            "Editing the host should invalidate the install confirmation."
        )

        XCTAssertTrue(app.buttons["connection.private-key.change"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        XCTAssertFalse(app.staticTexts["Add the public key to your server"].exists)
    }

    func testTailscaleAuthenticationIsExplicitAndHidesPassword() {
        launchSimulatorApp()
        openConnectionSetup()

        selectAuthentication("Tailscale SSH")

        let tailscaleInfo = app.descendants(matching: .any)["connection.authentication.tailscale-info"]
        XCTAssertTrue(tailscaleInfo.waitForExistence(timeout: 2))
        XCTAssertTrue(
            waitForElementToDisappear(
                app.secureTextFields["connection.password"],
                timeout: 2
            )
        )
        attachScreenshot(named: "tailscale-authentication-explicit")
    }

    func testTailscaleCheckOffersToOpenVerificationInBrowser() {
        app.launchEnvironment["REMUX_UI_TEST_TAILSCALE_CHECK_BANNER"] =
            "# Tailscale SSH requires an additional check.\n" +
            "# To authenticate, visit: https://login.tailscale.com/a/5fb81378394f\n"
        launchSimulatorApp()
        openConnectionSetup()
        fillTailscaleConnectionForm()

        selectAuthentication("Tailscale SSH")
        app.buttons["connection.save"].tap()

        let alert = app.alerts["Verify Tailscale SSH"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let openBrowser = alert.buttons["Open Browser"]
        XCTAssertTrue(openBrowser.isHittable)
        attachScreenshot(named: "tailscale-check-verification")

        openBrowser.tap()

        let browser = app.descendants(matching: .any)["tailscale-check.browser"]
        XCTAssertTrue(
            browser.waitForExistence(timeout: 5),
            "Verification should open in an in-app browser instead of a universal-link handler."
        )
        XCTAssertTrue(browser.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(named: "tailscale-check-browser")
    }

    func testTailscaleCheckCanCancelAndReturnToSetup() {
        app.launchEnvironment["REMUX_UI_TEST_TAILSCALE_CHECK_BANNER"] =
            "# Tailscale SSH requires an additional check.\n" +
            "# To authenticate, visit: https://login.tailscale.com/a/5fb81378394f\n"
        launchSimulatorApp()
        openConnectionSetup()
        fillTailscaleConnectionForm()

        selectAuthentication("Tailscale SSH")
        app.buttons["connection.save"].tap()

        let alert = app.alerts["Verify Tailscale SSH"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel Connection"].tap()

        XCTAssertTrue(waitForElementToDisappear(alert, timeout: 2))
        XCTAssertTrue(app.textFields["connection.name"].exists)
        let save = app.buttons["connection.save"]
        let saveEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: save
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saveEnabled], timeout: 2), .completed)
        XCTAssertFalse(app.alerts["Couldn’t Add Server"].exists)
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

    func testLiveCreatedShortcutExecutesInTmuxWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("shortcut")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
        waitForLiveTerminalInputReady(timeout: 10)

        let control = app.buttons["terminal.toolbar-key.0"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2)

        XCTAssertTrue(app.buttons["terminal.shortcuts.add"].waitForExistence(timeout: 2))
        app.buttons["terminal.shortcuts.add"].tap()
        XCTAssertTrue(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))

        let titleField = app.textFields["Title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 2))
        titleField.tap()
        titleField.typeText("E2E")

        let textField = app.textFields["Text"].firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.tap()
        textField.typeText("echo REMUXS")
        app.buttons["Save"].tap()
        XCTAssertFalse(app.navigationBars["New Shortcut"].waitForExistence(timeout: 2))

        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2)
        let shortcut = app.buttons["E2E"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 2))
        shortcut.tap()
        XCTAssertFalse(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 2))

        RunLoop.current.run(until: Date().addingTimeInterval(1))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUXS"
        )
    }

    func testLiveCustomizedToolbarKeysExecuteAndRetainSessionWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("toolbar-keys")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(traceRuntime: true, sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)

        let initialFirst = app.buttons["terminal.toolbar-key.0"]
        XCTAssertTrue(initialFirst.waitForExistence(timeout: 5))
        XCTAssertEqual(initialFirst.label, "Control")

        openHomeFromTerminal()
        app.buttons["library.settings"].tap()
        let toolbarKeys = app.buttons["settings.toolbar-keys"]
        if !toolbarKeys.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        XCTAssertTrue(toolbarKeys.waitForExistence(timeout: 2))
        toolbarKeys.tap()

        let firstSetting = app.buttons["settings.toolbar-keys.slot.0"]
        let secondSetting = app.buttons["settings.toolbar-keys.slot.1"]
        let thirdSetting = app.buttons["settings.toolbar-keys.slot.2"]
        firstSetting.tap()
        selectToolbarKey("Escape")
        secondSetting.tap()
        selectToolbarKey("Control")
        thirdSetting.tap()
        selectToolbarKey("Up Arrow")

        app.navigationBars["Toolbar Keys"].buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        let retainedSession = app.buttons["library.active-session.show"].firstMatch
        XCTAssertTrue(retainedSession.waitForExistence(timeout: 5))
        retainedSession.tap()
        waitForLiveTerminalReady(timeout: 10)

        let escape = app.buttons["terminal.toolbar-key.0"]
        let control = app.buttons["terminal.toolbar-key.1"]
        let arrowUp = app.buttons["terminal.toolbar-key.2"]
        XCTAssertTrue(escape.waitForExistence(timeout: 5))
        XCTAssertEqual(escape.label, "Escape")
        XCTAssertEqual(control.label, "Control")
        XCTAssertEqual(arrowUp.label, "Up Arrow")

        // The harness checks these markers in the pane's scrollback after the
        // test, where the typed commands also remain, so each command builds
        // its marker at run time and its own text can't satisfy the check.
        sendTerminalCommand(
            "python3 -c 'import os,select,sys,termios,tty; f=sys.stdin.fileno(); o=termios.tcgetattr(f); tty.setraw(f); r=select.select([f],[],[],3)[0]; b=os.read(f,1) if r else b\"\"; termios.tcsetattr(f,termios.TCSADRAIN,o); print(\"REMUX_LONG_PRESS_\" + (\"OK\" if not b else \"BAD\"))'"
        )
        escape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 2))
        app.otherElements["terminal.screen"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .tap()
        XCTAssertFalse(app.buttons["terminal.shortcuts.settings"].waitForExistence(timeout: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_LONG_PRESS_OK",
            includingHistory: true
        )

        sendTerminalCommand(
            "python3 -c 'import os,sys,termios,tty; f=sys.stdin.fileno(); o=termios.tcgetattr(f); tty.setraw(f, termios.TCSANOW); b=os.read(f,1); termios.tcsetattr(f,termios.TCSADRAIN,o); print(\"REMUX_ESCAPE_\" + (\"OK\" if b and b[0]==27 else \"BAD\"))'"
        )
        escape.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_ESCAPE_OK",
            includingHistory: true
        )

        sendTerminalCommand("sleep 10")
        control.tap()
        waitForLiveTerminalInputReady(timeout: 10)
        app.typeText("c")
        sendTerminalCommand("echo REMUX_CTRL_MOVED_\"OK\"")
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_CTRL_MOVED_OK",
            includingHistory: true
        )

        // The command prints its own run count, so only the arrow-up re-run
        // prints RUN_2. No `clear` in between: it also erases the scrollback.
        sendTerminalCommand(
            "remux_arrow_runs=$((remux_arrow_runs + 1)); echo REMUX_ARROW_UP_RUN_$remux_arrow_runs"
        )
        sendTerminalCommand("true")
        arrowUp.tap()
        arrowUp.tap()
        waitForLiveTerminalInputReady(timeout: 10)
        app.typeText("\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_ARROW_UP_RUN_2",
            includingHistory: true
        )

        sendTerminalCommand(
            "python3 -c 'import os,sys,termios,tty; f=sys.stdin.fileno(); o=termios.tcgetattr(f); tty.setraw(f, termios.TCSANOW); b=os.read(f,1); termios.tcsetattr(f,termios.TCSADRAIN,o); print(\"REMUX_PLAIN_C_\" + (\"OK\" if b and b[0]==99 else \"BAD\"))'"
        )
        control.tap()
        openHomeFromTerminal()
        app.buttons["library.settings"].tap()
        let changedToolbarKeys = app.buttons["settings.toolbar-keys"]
        if !changedToolbarKeys.waitForExistence(timeout: 1) {
            settingsForm.swipeUp()
        }
        changedToolbarKeys.tap()
        app.buttons["settings.toolbar-keys.slot.1"].tap()
        selectToolbarKey("Tab")
        app.navigationBars["Toolbar Keys"].buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        app.buttons["library.active-session.show"].firstMatch.tap()
        waitForLiveTerminalReady(timeout: 10)
        waitForLiveTerminalInputReady(timeout: 10)
        app.typeText("c")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        recordLiveTmuxPaneCaptureExpectation(
            sessionName: sessionName,
            paneIndex: 1,
            marker: "REMUX_PLAIN_C_OK",
            includingHistory: true
        )
    }

    func testLiveNewSessionBackReturnsToPresentingSessionSheetWhenConfigured() throws {
        let sessionName = try generatedLiveLatencySessionName("new-session-navigation")
        defer {
            cleanupGeneratedLiveLatencySessionIfPossible(sessionName)
        }

        try launchLiveSSHAppIfConfigured(sessionNameOverride: sessionName)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60)
        openSessionSwitcherFromTerminal()

        let sessionSheet = app.otherElements["terminal.sessions.sheet"]
        XCTAssertTrue(sessionSheet.waitForExistence(timeout: 5))
        app.buttons["terminal.sessions.new"].tap()
        XCTAssertTrue(app.textFields["connection.session"].waitForExistence(timeout: 2))
        attachScreenshot(named: "live-new-session-in-session-sheet")

        let backButton = app.navigationBars["New Session"].buttons["Sessions"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 2))
        backButton.tap()
        XCTAssertTrue(sessionSheet.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["terminal.sessions.new"].isHittable)
        attachScreenshot(named: "live-session-sheet-after-new-session-back")

        app.buttons["terminal.sessions.close"].tap()
        XCTAssertTrue(app.otherElements["terminal.input.ready"].waitForExistence(timeout: 2))
    }

    /// The SSH server is simulated: it signs in and reports that neither tmux nor Herdr is installed, as
    /// the discovery scripts do on a host without either.
    func testAddServerWithNeitherBackendInstalled() {
        app.launchEnvironment["REMUX_UI_TEST_TMUX_MISSING"] = "1"
        launchSimulatorApp()
        openConnectionSetup()
        fillConnectionForm()

        app.buttons["connection.save"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["library.server.detail"].waitForExistence(timeout: 5),
            "A server without tmux or Herdr should be added."
        )
        XCTAssertFalse(app.alerts["Couldn’t Add Server"].exists)
        XCTAssertTrue(
            noBackendRow().waitForExistence(timeout: 5),
            "The server page should say neither tmux nor Herdr is installed."
        )
        XCTAssertEqual(noBackendRow().label, "Remux couldn't find tmux or Herdr on this server.")
        XCTAssertFalse(app.buttons["library.server.new-session.empty"].exists)

        app.buttons["library.server.set-paths"].tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 5))
        let executable = app.textFields["connection.tmux-executable"]
        for _ in 0..<4 where !executable.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(executable.isHittable, "Set Paths should lead to the paths.")
        XCTAssertEqual(
            app.staticTexts["connection.tmux-executable.note"].label,
            "Remux couldn't find tmux on this server.",
            "Each path should say the last check found nothing there."
        )
    }

    /// Most servers have no Herdr. Where none of its sessions is saved, Edit Server keeps Advanced closed; the
    /// path says Herdr wasn't found once Advanced is opened.
    func testEditServerKeepsAdvancedClosedForAnUnusedMissingHerdr() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()
        openFirstServerDetail()
        XCTAssertTrue(
            waitForElementToDisappear(
                app.descendants(matching: .any)["library.server.available.loading"],
                timeout: 5
            )
        )

        let edit = app.buttons["library.server.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 5))
        let advanced = app.buttons["Advanced"]
        for _ in 0..<6 where !(advanced.exists && advanced.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(advanced.isHittable)
        XCTAssertFalse(app.textFields["connection.herdr-executable"].exists, "Advanced should start closed.")

        advanced.tap()
        let executable = app.textFields["connection.herdr-executable"]
        for _ in 0..<4 where !(executable.exists && executable.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(executable.isHittable)
        XCTAssertEqual(
            app.staticTexts["connection.herdr-executable.note"].label,
            "Remux couldn't find Herdr on this server."
        )
        // tmux is on Automatic and the simulated server has it: its path says where.
        XCTAssertEqual(app.staticTexts["connection.tmux-executable.note"].label, "Using /usr/bin/tmux")
    }

    /// Opening a Herdr session on a server without Herdr shows Herdr's own panel, as tmux has one, and its Edit
    /// Server leads to Herdr's path.
    func testOpeningAHerdrSessionWithoutHerdrShowsHerdrUnavailable() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_HERDR_SESSION": "default",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()

        let session = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.staticTexts["Herdr Unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Remux couldn't find Herdr on this server. Install it, or set its path in Edit Server."].exists
        )
        // The panel's identifier covers its buttons, so they're found by their titles.
        XCTAssertTrue(app.buttons["Retry"].exists)

        app.buttons["Edit Server"].tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 5))
        let executable = app.textFields["connection.herdr-executable"]
        for _ in 0..<4 where !executable.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(executable.isHittable, "Edit Server should open on Herdr's path.")
    }

    /// A saved Herdr session on a server without Herdr says so in place of when it was last opened, and
    /// leads to Herdr's path. The server's tmux is fine, so nothing else on the page mentions Herdr.
    func testASavedHerdrSessionSaysHerdrIsMissing() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_HERDR_SESSION": "default",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()
        openFirstServerDetail()

        let session = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .matching(NSPredicate(format: "label CONTAINS %@", "Herdr not found · Set path"))
            .firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5), "The saved Herdr session should say Herdr is missing.")
        XCTAssertFalse(noBackendRow().exists)
        XCTAssertFalse(app.descendants(matching: .any)["library.server.check-failed"].exists)

        session.tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 5))
        let executable = app.textFields["connection.herdr-executable"]
        for _ in 0..<4 where !executable.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(executable.isHittable, "The session should lead to Herdr's path.")
        XCTAssertEqual(
            app.staticTexts["connection.herdr-executable.note"].label,
            "Remux couldn't find Herdr on this server."
        )
    }

    func testDeleteServerAsksFirst() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()

        let server = app.descendants(matching: .any).matching(identifier: "library.server.row").firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        let alert = app.alerts.firstMatch

        server.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 2), "Deleting a server should ask first.")
        XCTAssertTrue(server.exists, "The server should stay until the deletion is confirmed.")

        alert.buttons["Cancel"].tap()
        XCTAssertTrue(waitForElementToDisappear(alert, timeout: 2))
        XCTAssertTrue(server.exists, "Cancelling should keep the server.")

        server.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(
            app.buttons["library.empty.add-server"].waitForExistence(timeout: 5),
            "Confirming should delete the only server."
        )
    }

    /// New Session offers tmux and Herdr. Herdr starts on its default name and checks names by Herdr's rule;
    /// going back to tmux takes the default name out again.
    func testNewSessionOffersHerdrWithItsDefaultName() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()
        openFirstServerDetail()
        let newSession = app.buttons["library.server.new-session.toolbar"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        newSession.tap()

        let name = app.textFields["connection.session"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let kind = app.segmentedControls["connection.session.kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 2))
        kind.buttons["Herdr"].tap()
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "default"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 2), .completed, "Herdr should start on its default name.")
        // The simulated server has no Herdr.
        let herdrMissing = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Remux couldn't find Herdr on this server."))
            .firstMatch
        XCTAssertTrue(herdrMissing.waitForExistence(timeout: 2), "New Session should say Herdr is missing.")

        tapFormField(name)
        name.typeText(" two")
        XCTAssertTrue(
            app.staticTexts["Use only letters, numbers, dots, underscores and hyphens."].waitForExistence(timeout: 2),
            "A Herdr name with a space should show Herdr's rule."
        )

        kind.buttons["tmux"].tap()
        XCTAssertFalse(app.staticTexts["Use only letters, numbers, dots, underscores and hyphens."].exists)
        XCTAssertFalse(herdrMissing.exists)
        XCTAssertEqual(name.value as? String, "default two")
    }

    func testEditServerChecksSessionsAgain() {
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_UI_TEST_TMUX_MISSING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()
        openFirstServerDetail()
        XCTAssertTrue(noBackendRow().waitForExistence(timeout: 5))

        let edit = app.buttons["library.server.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 2))
        edit.tap()
        XCTAssertTrue(app.textFields["connection.name"].waitForExistence(timeout: 5))
        let executable = app.textFields["connection.tmux-executable"]
        for _ in 0..<4 where !executable.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            executable.isHittable,
            "With tmux missing, Edit Server should open Advanced on the tmux path."
        )
        let note = app.staticTexts["connection.tmux-executable.note"]
        XCTAssertEqual(note.label, "Remux couldn't find tmux on this server.")
        tapFormField(executable)
        XCTAssertTrue(waitForSoftwareKeyboardOnScreen(timeout: 3))
        XCTAssertTrue(waitForElementToSettle(executable))
        XCTAssertTrue(executable.isHittable, "The focused path should sit above the keyboard.")
        typeTextAndConfirm("/usr/local/bin/tmux", into: executable)
        XCTAssertTrue(
            waitForElementToDisappear(note, timeout: 2),
            "The check was of Automatic, not of the path typed, so its note goes."
        )
        app.buttons["connection.save"].tap()
        XCTAssertTrue(
            waitForElementToDisappear(app.textFields["connection.name"], timeout: 5),
            "Saving the edited server should close the form."
        )

        XCTAssertTrue(
            waitForElementToDisappear(
                app.descendants(matching: .any)["library.server.available.loading"],
                timeout: 5
            ),
            "The server page should check its sessions again after the edit."
        )
        XCTAssertTrue(
            noBackendRow().waitForExistence(timeout: 2),
            "The edited path still finds no tmux."
        )
    }

    private func noBackendRow() -> XCUIElement {
        app.descendants(matching: .any)["library.server.no-backend"]
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

    /// A Herdr session opened from the library on a live server. On a phone the multi-pane tab opens zoomed
    /// on its focused pane, and Panes lists all of its panes; turned off there, the tab's panes are on
    /// screen, with the keyboard opening and closing over them, and the tab stays unzoomed over Home and
    /// back. Skipped without REMUX_LIVE_HERDR_UI_CONFIG; its `paneCount` must give the tab's panes.
    func testLiveHerdrSessionWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        let paneCount = try XCTUnwrap(configuration.paneCount, "The live Herdr configuration should give paneCount.")
        guard paneCount > 1 else { return XCTFail("The session's tab needs more than one pane to open zoomed.") }

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        assertLiveTerminalScreenshotContainsRenderedContent()
        captureLiveHerdrStep("1-session", in: configuration)

        // Zoomed on open, as "Zoom multipane windows" is on by default on a phone, with every pane in the
        // pane picker; turned off from Panes, the tab's panes are on screen for the rest of the test.
        let zoom = openHerdrPanesZoomSwitch(paneCount: paneCount)
        XCTAssertEqual(zoom.value as? String, "1", "The multi-pane tab should open zoomed.")
        captureLiveHerdrStep("1a-panes-zoomed", in: configuration)
        zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(
            waitForValue("0", of: zoom, timeout: 8),
            "Zoom should turn off from Panes."
        )
        app.buttons["terminal.panes.close"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        captureLiveHerdrStep("1c-panes-unzoomed", in: configuration)

        // A long-press selects the word under the finger and offers Copy, as on a tmux pane.
        let terminal = app.otherElements["terminal.screen"].firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.03)).press(forDuration: 0.70)
        XCTAssertTrue(waitForCopyMenuItem(timeout: 5).exists, "A long-press on a Herdr pane should select a word.")
        XCTAssertEqual(app.state, .runningForeground)
        captureLiveHerdrStep("1b-selection", in: configuration)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()

        // The keyboard comes up with the composer, as on a tmux screen.
        let composerToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(composerToggle.waitForExistence(timeout: 5))
        composerToggle.tap()
        let composerField = app.textViews["terminal.composer.field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        composerField.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "herdr keyboard show", timeout: 8))
        captureLiveHerdrStep("2-keyboard-open", in: configuration)
        let handle = app.descendants(matching: .any)["terminal.composer.keyboard-dismiss"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let dragStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 14)))
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "herdr keyboard hide", timeout: 8))
        captureLiveHerdrStep("3-keyboard-closed", in: configuration)
        composerToggle.tap()

        openHomeFromTerminal()
        captureLiveHerdrStep("4-home", in: configuration)

        // The server page lists both backends' sessions once each backend has answered.
        openFirstServerDetail()
        let checking = app.descendants(matching: .any)["library.server.available.loading"]
        XCTAssertTrue(checking.waitForNonExistence(timeout: 20), "Both backends should finish checking the server.")
        // The fixture's tmux has no session of that name, so a tmux row named for it is Herdr's list under tmux.
        let herdrNameAsTmux = app.descendants(matching: .any)
            .matching(identifier: "library.server.available.session")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(configuration.sessionName), tmux"))
            .firstMatch
        XCTAssertFalse(herdrNameAsTmux.exists, "Herdr's sessions should be listed as Herdr's.")
        captureLiveHerdrStep("4b-server-page", in: configuration)
        app.navigationBars.buttons.firstMatch.tap()

        let activeSession = app.descendants(matching: .any)["library.active-session.show"].firstMatch
        XCTAssertTrue(activeSession.waitForExistence(timeout: 5))
        activeSession.tap()
        waitForLiveTerminalReady(timeout: 30, expectedHostKey: configuration.expectedHostKey)
        assertLiveTerminalScreenshotContainsRenderedContent()
        captureLiveHerdrStep("5-back", in: configuration)

        // The tab the user unzoomed isn't zoomed again on the way back, and the pane picker maps every pane
        // from Herdr's frame, however close Herdr's border settings put them.
        XCTAssertEqual(
            openHerdrPanesZoomSwitch(paneCount: paneCount).value as? String,
            "0",
            "The tab should stay unzoomed."
        )
        captureLiveHerdrStep("5a-pane-picker", in: configuration)
        app.buttons["terminal.panes.close"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // A swipe down over the first pane scrolls its history back on Herdr. The harness reads
        // Herdr's scroll position after the test, so the swipe's steps get time to go out first.
        let firstPane = app.otherElements["terminal.screen"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        firstPane.press(forDuration: 0.05, thenDragTo: firstPane.withOffset(CGVector(dx: 0, dy: 240)))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the swipe's wheel steps go out")], timeout: 2)
        XCTAssertEqual(app.state, .runningForeground)
        captureLiveHerdrStep("6-scrolled", in: configuration)
    }

    /// Uses an isolated Herdr fixture with ordinary shells, integration-reported agents and actual OSC
    /// terminal titles. Tab labels stay independent of descriptions, which are shown without parsing.
    func testLiveHerdrTabLabelsKeepSuppliedTitlesWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        app.buttons["terminal.windows"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["terminal.windows.sheet"].waitForExistence(timeout: 5))

        func row(_ number: Int) -> XCUIElement {
            app.buttons["terminal.window.tile.\(number)"].firstMatch
        }
        func description(_ number: Int) -> String {
            row(number).value as? String ?? ""
        }
        for number in 1...6 {
            XCTAssertTrue(row(number).waitForExistence(timeout: 5))
        }
        captureLiveHerdrStep("labels-initial", in: configuration)
        XCTAssertTrue(row(1).label.components(separatedBy: ", ").contains("1"), "The unnamed tab lost Herdr's label.")
        XCTAssertEqual(description(1), "api")
        XCTAssertEqual(description(2), "codex-a | 01a18929-c0a9-7f41-9044-2b8f242ba070")
        XCTAssertEqual(description(3), "Claude Code: Review")
        XCTAssertTrue(row(4).label.components(separatedBy: ", ").contains("review"))
        XCTAssertEqual(description(4), "", "The logo already identifies the agent; its name isn't a description.")
        XCTAssertEqual(description(5), "Running tests")
        XCTAssertEqual(description(6), "api")

        // The fixture updates integration metadata along with OSC titles, publishing fresh snapshots.
        // Updates while Tabs stays open must reach the same rows, including removal of a description.
        _ = try performLiveHerdrStep("change-title", in: configuration)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            description(3) == "Claude Code: Updated while open"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        XCTAssertEqual(description(5), "Integration updated")
        captureLiveHerdrStep("labels-updated", in: configuration)

        _ = try performLiveHerdrStep("clear-description", in: configuration)
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row(2).exists && description(2).isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)
        XCTAssertEqual(description(5), "Integration cleared test")
        captureLiveHerdrStep("labels-cleared", in: configuration)
    }

    /// Tabs and workspaces of a live Herdr session whose workspace `remux` has a three-pane tab and a tab
    /// `build`, beside workspaces `api` (a two-pane tab `server` and a tab `tests`), `web`, `notes` and
    /// `infra`, with a session `locked` Herdr can't reach. The Tabs sheet lists the tabs of the workspace
    /// on screen, and offers the three most recent workspaces as capsules and the rest behind More, with New
    /// Workspace at the end of More's menu; picking one only changes the tiles, a tile goes there, and the
    /// capsules follow recency. The Sessions sheet
    /// lists the workspaces under the session with New Workspace, and lists `locked` as unavailable. New
    /// Tab goes to its tab, and the Panes sheet's Split → goes to the pane it makes, zoomed by the setting.
    func testLiveHerdrTabsAndWorkspacesWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        let tabs = app.buttons.matching(identifier: "terminal.windows").firstMatch
        let panes = app.buttons.matching(identifier: "terminal.panes").firstMatch
        let tabsSheet = elementWithIdentifier("terminal.windows.sheet")
        func capsule(_ index: Int) -> XCUIElement { app.buttons["terminal.windows.group.\(index)"] }
        let more = elementWithIdentifier("terminal.windows.group.more")
        func tile(_ index: Int) -> XCUIElement { app.buttons["terminal.window.tile.\(index)"] }

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 2", timeout: 10))

        tabs.tap()
        XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))
        XCTAssertEqual(capsule(1).label, "Workspace remux")
        XCTAssertTrue(capsule(1).isSelected)
        XCTAssertEqual([capsule(2).label, capsule(3).label], ["Workspace api", "Workspace web"])
        XCTAssertTrue(tile(2).exists && !tile(3).exists, "The sheet should list remux's two tabs.")
        XCTAssertEqual(tile(2).value as? String, "remux", "The build tab's row doesn't say its shell is in remux.")
        captureLiveHerdrStep("w1-tabs-sheet", in: configuration)

        capsule(2).tap()
        XCTAssertTrue(waitForLabel(of: tile(1), "Tab 1 of 2, server, 2 panes", timeout: 5), "Picking api didn't list its tabs.")
        XCTAssertTrue(tabsSheet.exists, "Picking a workspace closed the sheet.")
        captureLiveHerdrStep("w2-other-workspace", in: configuration)

        more.tap()
        let infra = app.buttons["infra"]
        XCTAssertTrue(infra.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notes"].exists)
        XCTAssertTrue(app.buttons["New Workspace"].exists, "More's menu doesn't offer New Workspace.")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "New Workspace")).count, 1,
            "New Workspace is offered twice."
        )
        captureLiveHerdrStep("w3-more-menu", in: configuration)
        infra.tap()
        XCTAssertTrue(waitForLabel(of: more, "Workspace infra, more workspaces", timeout: 5))
        XCTAssertTrue(tile(1).exists && !tile(2).exists, "The sheet should list infra's one tab.")
        captureLiveHerdrStep("w3b-more-picked", in: configuration)
        more.tap()
        XCTAssertTrue(infra.waitForExistence(timeout: 5))
        XCTAssertTrue(infra.isSelected, "More didn't mark the workspace it shows.")
        XCTAssertFalse(app.buttons["notes"].isSelected)
        captureLiveHerdrStep("w3c-more-marks-shown", in: configuration)
        infra.tap()
        XCTAssertTrue(waitForLabel(of: more, "Workspace infra, more workspaces", timeout: 5))

        capsule(2).tap()
        XCTAssertTrue(waitForLabel(of: tile(1), "Tab 1 of 2, server, 2 panes", timeout: 5))
        tile(1).tap()
        XCTAssertTrue(tabsSheet.waitForNonExistence(timeout: 5), "The tile didn't close the sheet.")
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 2 panes", timeout: 10), "The tile didn't go to api's server tab.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 2", timeout: 10))
        captureLiveHerdrStep("w4-moved-to-api", in: configuration)

        // The setting zooms the two-pane tab reached, as a show does.
        let zoom = openHerdrPanesZoomSwitch(paneCount: 2)
        XCTAssertTrue(waitForValue("1", of: zoom, timeout: 8), "The tab reached wasn't zoomed.")
        app.buttons["terminal.panes.close"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        tabs.tap()
        XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))
        XCTAssertEqual([capsule(1).label, capsule(2).label], ["Workspace api", "Workspace remux"])
        captureLiveHerdrStep("w5-recency", in: configuration)
        app.buttons["terminal.windows.close"].tap()
        XCTAssertTrue(tabsSheet.waitForNonExistence(timeout: 5))

        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        let workspaceRows = app.descendants(matching: .any).matching(identifier: "terminal.sessions.herdr-workspace")
        XCTAssertTrue(workspaceRows.firstMatch.waitForExistence(timeout: 5), "The session on screen didn't list its workspaces.")
        let current = workspaceRows.matching(NSPredicate(format: "label == %@", "Workspace api, 2 tabs, current workspace"))
        XCTAssertEqual(current.count, 1)
        captureLiveHerdrStep("w6-sessions-sheet", in: configuration)
        // The list makes only the rows it shows, so the workspaces are read as it scrolls.
        let sessionList = app.descendants(matching: .any)["terminal.sessions.list"]
        let newWorkspace = elementWithIdentifier("terminal.sessions.herdr-workspace.new")
        var listed = Set(workspaceRows.allElementsBoundByIndex.map { $0.label })
        for _ in 0..<4 where !newWorkspace.exists || !newWorkspace.isHittable {
            sessionList.swipeUp()
            listed.formUnion(workspaceRows.allElementsBoundByIndex.map { $0.label })
        }
        XCTAssertTrue(newWorkspace.isHittable, "The session on screen didn't offer New Workspace.")
        XCTAssertEqual(listed, [
            "Workspace remux, 2 tabs", "Workspace api, 2 tabs, current workspace", "Workspace web, 1 tab",
            "Workspace notes, 1 tab", "Workspace infra, 1 tab",
        ], "The session on screen didn't list its 5 workspaces.")
        captureLiveHerdrStep("w6b-sessions-sheet-scrolled", in: configuration)

        let web = workspaceRows.matching(NSPredicate(format: "label BEGINSWITH %@", "Workspace web,")).firstMatch
        for _ in 0..<4 where !web.exists || !web.isHittable {
            sessionList.swipeDown()
        }
        web.tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 1", timeout: 10))
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 1 pane", timeout: 10), "The workspace row didn't go to web.")
        captureLiveHerdrStep("w7-moved-to-web", in: configuration)

        // Herdr lists a session it can't reach as unavailable, and it isn't offered.
        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        let locked = app.descendants(matching: .any)
            .matching(identifier: "terminal.sessions.available-session")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "locked, Herdr, Unavailable"))
            .firstMatch
        for _ in 0..<6 where !locked.exists || !locked.isHittable {
            sessionList.swipeUp()
        }
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "The session Herdr can't reach wasn't listed as unavailable.")
        XCTAssertFalse(locked.isEnabled, "The unavailable session was offered.")
        sessionList.swipeUp()
        captureLiveHerdrStep("w8-unavailable-session", in: configuration)
        for _ in 0..<6 where !newWorkspace.exists || !newWorkspace.isHittable {
            sessionList.swipeDown()
        }
        XCTAssertTrue(newWorkspace.isHittable)
        newWorkspace.tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5))
        tabs.tap()
        XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(of: more, "More workspaces", timeout: 5))
        XCTAssertFalse(["Workspace remux", "Workspace api", "Workspace web", "Workspace notes", "Workspace infra"]
            .contains(capsule(1).label), "New Workspace didn't go to the new workspace: \(capsule(1).label)")
        captureLiveHerdrStep("w9-new-workspace", in: configuration)

        app.buttons["terminal.window.new"].tap()
        XCTAssertTrue(tabsSheet.waitForNonExistence(timeout: 5), "New Tab didn't close the sheet.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 2 of 2", timeout: 10), "New Tab didn't go to the new tab.")
        sendTerminalCommand("echo REMUX_NEW_TAB_TYPED")
        XCTAssertEqual(app.state, .runningForeground)
        captureLiveHerdrStep("w10-new-tab", in: configuration)

        // Split → makes a pane beside the one on screen and goes to it; the setting zooms the new pane.
        openPanesSheet()
        tapPickerButton(identifier: "terminal.pane.split.right", fallbackLabel: "Split right")
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 2 panes", timeout: 10), "Split didn't make a pane.")
        let splitZoom = openHerdrPanesZoomSwitch(paneCount: 2)
        XCTAssertTrue(waitForValue("1", of: splitZoom, timeout: 8), "The pane the split made wasn't zoomed.")
        captureLiveHerdrStep("w11-split", in: configuration)
        app.buttons["terminal.panes.close"].tap()
        sendTerminalCommand("echo REMUX_SPLIT_TYPED")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Closing tabs from the Tabs sheet asks where Herdr's client asks, on the tabs test's server with a
    /// worktree group added: the repository `shop`'s root checkout and its linked worktree `shop-feature`. A
    /// tab beside another closes at once; a workspace's only tab asks about the workspace's close first; and
    /// the only tab of the group's root, whose close Herdr's server asks to confirm, asks about the group's
    /// close in the same dialog.
    func testLiveHerdrClosesWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        let tabs = app.buttons.matching(identifier: "terminal.windows").firstMatch
        let tabsSheet = elementWithIdentifier("terminal.windows.sheet")
        func capsule(_ index: Int) -> XCUIElement { app.buttons["terminal.windows.group.\(index)"] }
        let more = elementWithIdentifier("terminal.windows.group.more")
        func tile(_ index: Int) -> XCUIElement { app.buttons["terminal.window.tile.\(index)"] }
        func remove(tile index: Int) {
            XCTAssertTrue(tile(index).waitForExistence(timeout: 5), "Missing tab tile \(index)")
            tile(index).press(forDuration: 1.0)
            tapPickerButton(identifier: "terminal.window.remove.\(index)", fallbackLabel: "Close Tab")
        }

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 2", timeout: 10))
        tabs.tap()
        XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))

        remove(tile: 2)
        XCTAssertTrue(tile(2).waitForNonExistence(timeout: 10), "remux's second tab didn't close.")
        XCTAssertFalse(app.buttons["terminal.window.remove.confirm.2"].exists, "A tab beside another asked first.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 1", timeout: 10))

        // The row beside the tab on screen takes the touches on its own right edge and its own Close.
        func openTabs() {
            tabs.tap()
            XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))
        }
        app.buttons["terminal.window.new"].tap()
        XCTAssertTrue(tabsSheet.waitForNonExistence(timeout: 5), "New Tab didn't close the sheet.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 2 of 2", timeout: 10), "New Tab didn't go to the new tab.")
        openTabs()
        tile(1).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(tabsSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 2", timeout: 10), "A tap on tab 1's right edge didn't go to tab 1.")
        tabs.tap()
        XCTAssertTrue(tabsSheet.waitForExistence(timeout: 5))
        tile(2).tap()
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 2 of 2", timeout: 10))
        openTabs()
        // The tiles are numbered by position, so the tab left is told by its panes: remux's three-pane tab
        // and the new tab's one.
        func panes(ofTile index: Int) -> String? {
            tile(index).label.components(separatedBy: ", ").first { $0.hasSuffix(" pane") || $0.hasSuffix(" panes") }
        }
        let newTabPanes = panes(ofTile: 2)
        XCTAssertNotEqual(panes(ofTile: 1), newTabPanes, "Tabs 1 and 2 can't be told apart.")
        remove(tile: 1)
        XCTAssertTrue(tile(2).waitForNonExistence(timeout: 10), "Tab 1's Close didn't close a tab.")
        XCTAssertTrue(tabsSheet.exists, "Tab 1's Close closed the sheet.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 1", timeout: 10))
        XCTAssertEqual(panes(ofTile: 1), newTabPanes, "Tab 1's Close closed tab 2.")
        captureLiveHerdrStep("d0-remove-beside-tab-on-screen", in: configuration)

        XCTAssertEqual(capsule(3).label, "Workspace web")
        capsule(3).tap()
        XCTAssertTrue(capsule(3).isSelected)
        remove(tile: 1)
        // The action sheet nests each button in another with its identifier.
        let closeWorkspace = app.buttons.matching(identifier: "terminal.window.remove.confirm.1").firstMatch
        XCTAssertTrue(closeWorkspace.waitForExistence(timeout: 5), "web's only tab didn't ask first.")
        XCTAssertEqual(closeWorkspace.label, "Close Workspace")
        XCTAssertTrue(app.staticTexts["Close Workspace?"].exists)
        XCTAssertTrue(app.staticTexts["“web” and its 1 tab and 1 pane will close."].exists)
        captureLiveHerdrStep("d1-close-workspace", in: configuration)
        closeWorkspace.tap()
        XCTAssertTrue(waitForLabel(of: capsule(3), "Workspace notes", timeout: 10), "web didn't close.")
        XCTAssertTrue(capsule(1).isSelected, "The sheet didn't go back to the workspace on screen.")

        more.tap()
        let shop = app.buttons["shop"]
        XCTAssertTrue(shop.waitForExistence(timeout: 5), "The worktree group's root isn't listed.")
        XCTAssertTrue(app.buttons["shop-feature"].exists, "The linked worktree isn't listed.")
        shop.tap()
        XCTAssertTrue(waitForLabel(of: more, "Workspace shop, more workspaces", timeout: 5))
        remove(tile: 1)
        let closeGroup = app.buttons.matching(identifier: "terminal.close.asked.confirm").firstMatch
        XCTAssertTrue(closeGroup.waitForExistence(timeout: 10), "Herdr's question about the group didn't reach the user.")
        XCTAssertEqual(closeGroup.label, "Close Worktree Group")
        XCTAssertTrue(app.staticTexts["Close Worktree Group?"].exists)
        XCTAssertTrue(app.staticTexts["“shop” and its 1 other workspace will close, with 2 tabs and 2 panes."].exists)
        captureLiveHerdrStep("d2-close-worktree-group", in: configuration)
        closeGroup.tap()
        XCTAssertTrue(waitForLabel(of: more, "More workspaces", timeout: 10), "The sheet didn't leave the closed group.")
        more.tap()
        let infra = app.buttons["infra"]
        XCTAssertTrue(infra.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shop"].exists || app.buttons["shop-feature"].exists, "The group didn't close.")
        captureLiveHerdrStep("d3-group-closed", in: configuration)
        infra.tap()
    }

    /// The session `locked` that Herdr can't reach, on the tabs test's server, saved as the server's latest
    /// session: the server row's Resume Latest is disabled, as the session's own row is, and doesn't open it,
    /// and its swipe actions leave out Resume.
    func testLiveHerdrUnreachableLatestSessionIsNotResumedFromItsServerWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(sessionName: "locked")
        let server = app.descendants(matching: .any).matching(identifier: "library.server.row").firstMatch
        let terminal = app.otherElements["terminal.screen"]

        // The server's sessions are listed once its host key is trusted.
        openFirstServerDetail()
        let hostKey = app.buttons["library.server.host-key"]
        XCTAssertTrue(hostKey.waitForExistence(timeout: 20), "The server page didn't ask to verify the server.")
        hostKey.tap()
        let trust = app.alerts.firstMatch
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        let fingerprint = try XCTUnwrap(configuration.expectedHostKey.split(separator: " ").last.map(String.init))
        guard trust.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists else {
            XCTFail("Refusing to trust a host key other than the fixture's.")
            return
        }
        trust.buttons["Trust Server"].tap()
        let locked = app.descendants(matching: .any)
            .matching(identifier: "library.session.resume")
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "locked", "Unavailable"))
            .firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "The saved session Herdr can't reach wasn't shown unavailable.")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(server.waitForExistence(timeout: 5))

        server.press(forDuration: 1.2)
        let resumeLatest = app.buttons["Resume Latest"]
        XCTAssertTrue(resumeLatest.waitForExistence(timeout: 5), "The server row's menu didn't open.")
        XCTAssertFalse(resumeLatest.isEnabled, "Resume Latest offered the session Herdr can't reach.")
        captureLiveHerdrStep("u1-resume-latest-disabled", in: configuration)
        resumeLatest.tap()
        XCTAssertFalse(terminal.waitForExistence(timeout: 3), "Resume Latest opened the session Herdr can't reach.")
        if resumeLatest.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            XCTAssertTrue(resumeLatest.waitForNonExistence(timeout: 5))
        }

        server.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "The server row's swipe actions didn't open.")
        XCTAssertFalse(app.buttons["Resume"].exists, "The Resume swipe offered the session Herdr can't reach.")
        captureLiveHerdrStep("u2-resume-swipe-not-offered", in: configuration)
    }

    /// Copy on a Herdr pane is Herdr's text of the selection: an OSC 8 link the pane wraps onto two rows
    /// pastes as the whole link on one line, as does a plain-text one once Herdr has found the rest of it,
    /// and a word pastes as itself. A selection made over the history moves with its line when a swipe
    /// scrolls Herdr's history.
    func testLiveHerdrSelectionCopyWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        let terminal = app.otherElements["terminal.screen"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        // A row and a half down, a press lands on the text's first or second row, whether or not Herdr
        // draws a border above the pane.
        let topRows = terminal.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 26))

        let token = UUID().uuidString.prefix(8).lowercased()
        let url = "https://example.com/\(token)/" + String(repeating: "p", count: 60)
        UIPasteboard.general.string = "REMUX_HERDR_LINK_COPY_SENTINEL"
        sendTerminalCommand(#"clear; printf '\033]8;;"# + url + #"\033\\"# + url + #"\033]8;;\033\\\n'"#)
        hideKeyboardIfPresent()
        guard waitForStableLiveTerminalScreenshot(attachmentName: "herdr-wrapped-link-ready") != nil else { return }
        topRows.press(forDuration: 0.70)
        let linkCopy = waitForCopyMenuItem(timeout: 5)
        captureLiveHerdrStep("c1-wrapped-link-selected", in: configuration)
        linkCopy.tap()
        XCTAssertEqual(pasteIntoEmptyComposer(), url, "A link the pane wraps should copy whole, on one line.")
        captureLiveHerdrStep("c2-link-pasted", in: configuration)
        clearAndCloseComposer()

        let plainURL = "https://example.org/\(token)/" + String(repeating: "q", count: 60)
        UIPasteboard.general.string = "REMUX_HERDR_PLAIN_LINK_COPY_SENTINEL"
        sendTerminalCommand("clear; printf '%s\\n' \(plainURL)")
        hideKeyboardIfPresent()
        guard waitForStableLiveTerminalScreenshot(attachmentName: "herdr-plain-link-ready") != nil else { return }
        topRows.press(forDuration: 0.70)
        let plainCopy = waitForCopyMenuItem(timeout: 5)
        captureLiveHerdrStep("c2b-plain-link-grown", in: configuration)
        plainCopy.tap()
        XCTAssertEqual(
            pasteIntoEmptyComposer(),
            plainURL,
            "A plain-text link the pane wraps should grow to the whole link and copy on one line."
        )
        clearAndCloseComposer()

        let word = "herdrword-\(token)"
        UIPasteboard.general.string = "REMUX_HERDR_WORD_COPY_SENTINEL"
        sendTerminalCommand("clear; printf '%s\\n%s\\n' \(word) \(word)")
        hideKeyboardIfPresent()
        guard waitForStableLiveTerminalScreenshot(attachmentName: "herdr-word-ready") != nil else { return }
        topRows.press(forDuration: 0.70)
        waitForCopyMenuItem(timeout: 5).tap()
        XCTAssertEqual(pasteIntoEmptyComposer(), word, "A word should copy as itself.")
        clearAndCloseComposer()

        sendTerminalCommand("clear; seq -f 'scrolled line %g' 1 120")
        hideKeyboardIfPresent()
        guard waitForStableLiveTerminalScreenshot(attachmentName: "herdr-history-ready") != nil else { return }
        topRows.press(forDuration: 0.70)
        XCTAssertTrue(waitForCopyMenuItem(timeout: 5).exists)
        captureLiveHerdrStep("c3-history-word-selected", in: configuration)
        let swipe = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        swipe.press(forDuration: 0.05, thenDragTo: swipe.withOffset(CGVector(dx: 0, dy: 70)))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Herdr scrolls and the highlight follows")], timeout: 2)
        captureLiveHerdrStep("c4-selection-followed-scroll", in: configuration)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A program's OSC 52 copy in a Herdr pane lands on the clipboard, and the screen says so.
    func testLiveHerdrProgramCopyWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)

        let copied = "herdr-copy-\(UUID().uuidString.prefix(8).lowercased())"
        sendTerminalCommand(#"clear; printf '\033]52;c;%s\a' "$(printf %s "# + copied + #" | base64)""#)
        let notice = app.descendants(matching: .any)["terminal.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "A program's copy should say so.")
        XCTAssertEqual(notice.label, "Copied to clipboard")
        captureLiveHerdrStep("d1-copied", in: configuration)
        hideKeyboardIfPresent()
        XCTAssertEqual(pasteIntoEmptyComposer(), copied, "A program's copy should be on the clipboard.")
        captureLiveHerdrStep("d2-copy-pasted", in: configuration)
        clearAndCloseComposer()
    }

    /// A tap on a Herdr pane that isn't focused, whose program reads the mouse, focuses the pane and is a
    /// click where the finger is. The session's tab has two panes, and the right one, not focused, runs
    /// `cat -v` with SGR mouse reports on, which shows the reports it reads; the harness reads its text and
    /// the focus after the test.
    func testLiveHerdrMouseClickWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp()
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)

        // A phone opens a multi-pane tab zoomed; turned off from Panes, both panes are on screen.
        let zoom = openHerdrPanesZoomSwitch(paneCount: 2)
        zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue("0", of: zoom, timeout: 8), "Zoom should turn off from Panes.")
        app.buttons["terminal.panes.close"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        captureLiveHerdrStep("d3-two-panes", in: configuration)

        let terminal = app.otherElements["terminal.screen"].firstMatch
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)).tap()
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the click shows")], timeout: 1.5)
        captureLiveHerdrStep("d3-click", in: configuration)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Opens Panes over a Herdr session whose tab has `paneCount` panes, checks that the pane picker maps
    /// every one, also while the tab is zoomed, and returns its Zoom switch.
    private func openHerdrPanesZoomSwitch(paneCount: Int) -> XCUIElement {
        openPanesSheet()
        XCTAssertTrue(
            waitForPanePickerTileCount(paneCount, timeout: 10),
            "The pane picker should map every pane of the tab, also while it is zoomed."
        )
        let zoom = app.switches["terminal.pane.zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 8))
        return zoom
    }

    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// The keyboard and what covers the terminal, on a live Herdr session whose tab 1 and tab 3 run Claude Code
    /// and whose workspaces overflow the Tabs sheet's capsules. The harness answers `reset` (tab 1 on screen,
    /// its agents idle) and `prompt-1` and `prompt-3` (a one-line prompt to that tab's Claude Code, which a
    /// banner reports done). With the keyboard up, Tabs covers the terminal, which gives up the keyboard: More's
    /// menu opens over the sheet with no keyboard and answers, and closing Tabs brings the keyboard back.
    func testLiveHerdrMenuOverTabsLeavesTheKeyboardDownWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let keyboardButton = app.buttons["terminal.keyboard"].firstMatch
        let close = app.buttons["terminal.windows.close"].firstMatch
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        _ = try performLiveHerdrStep("reset", in: configuration)
        keyboardButton.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard before Tabs"))

        app.buttons["terminal.windows"].firstMatch.tap()
        let more = app.buttons["terminal.windows.group.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Tabs has no More.")
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "Tabs over the terminal"))
        more.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 5), "More's menu didn't open.")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The keyboard came up over the Tabs sheet.")
        captureLiveHerdrStep("k1-more-over-tabs", in: configuration)

        // A tap away from the menu puts it away and leaves Tabs open.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(newWorkspace.waitForNonExistence(timeout: 5), "More's menu didn't go.")
        XCTAssertTrue(close.isHittable, "Tabs closed with the menu.")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard after Tabs"))
        XCTAssertEqual(keyboardButton.label, "Hide keyboard controls")
    }

    /// With the keyboard up, Home, then a banner for the agent in tab 3: the tap opens its tab with the keyboard
    /// up, and the keyboard button, which says so, puts it away with one tap.
    func testLiveHerdrBannerFromHomeBringsTheKeyboardBackWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let keyboardButton = app.buttons["terminal.keyboard"].firstMatch
        let banner = app.descendants(matching: .any)["herdr.notification.banner"].firstMatch
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        _ = try performLiveHerdrStep("reset", in: configuration)
        keyboardButton.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard before Home"))

        openHomeFromTerminal()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "Home"))
        _ = try performLiveHerdrStep("prompt-3", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "No banner over Home for the agent in tab 3.")
        XCTAssertEqual(banner.label, "claude done, Herdr live · remux-ui · agents › 3")
        banner.tap()
        XCTAssertTrue(
            waitForLabel(of: app.buttons["terminal.windows"].firstMatch, "Tab 3 of 3", timeout: 15),
            "The banner didn't open tab 3."
        )
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard back with the banner's tab"))
        XCTAssertEqual(keyboardButton.label, "Hide keyboard controls")
        captureLiveHerdrStep("k2-banner-from-home", in: configuration)

        keyboardButton.tap()
        XCTAssertNotNil(waitForKeyboardPresence(false, label: "the keyboard button's first tap"))
        XCTAssertEqual(keyboardButton.label, "Show keyboard controls")
    }

    /// With the keyboard up in tab 1, a swipe to tab 2 and the Sessions sheet's Agents, then a banner for the
    /// agent in tab 1: the tap closes the sheet and opens tab 1 with the keyboard up, and the first tap on Tabs
    /// opens Tabs.
    func testLiveHerdrBannerOverAgentsBringsTheKeyboardBackWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let keyboardButton = app.buttons["terminal.keyboard"].firstMatch
        let tabs = app.buttons["terminal.windows"].firstMatch
        let banner = app.descendants(matching: .any)["herdr.notification.banner"].firstMatch
        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        _ = try performLiveHerdrStep("reset", in: configuration)
        keyboardButton.tap()
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard in tab 1"))
        app.otherElements["terminal.screen"].firstMatch.swipeLeft()
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 2 of 3", timeout: 10), "The swipe didn't reach tab 2.")

        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        app.buttons["Agents"].firstMatch.tap()
        _ = try performLiveHerdrStep("prompt-1", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "No banner over Agents for the agent in tab 1.")
        banner.tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5), "The tap didn't close the Sessions sheet.")
        XCTAssertTrue(waitForLabel(of: tabs, "Tab 1 of 3", timeout: 15), "The banner didn't open tab 1.")
        XCTAssertNotNil(waitForKeyboardPresence(true, label: "keyboard back with the banner's tab"))
        captureLiveHerdrStep("k3-banner-over-agents", in: configuration)

        tabs.tap()
        let close = app.buttons["terminal.windows.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The first tap on Tabs didn't open Tabs.")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    /// Herdr's notifications on a live server whose session has a three-pane tab (workspace `remux`) and a
    /// second tab, `build`, with one agent pane. An agent waiting in the other tab shows a banner above the
    /// open Sessions sheet; tapping it closes the sheet and takes the phone to that tab. An agent finishing
    /// while Home is on screen shows a banner naming the server and session over Home; tapping it opens
    /// the session at that agent's pane. A banner above the Panes sheet closes it too, and both sheets open
    /// again afterwards. A bell in the session on screen vibrates and draws nothing. A banner over a server
    /// form being filled in only goes away when tapped, keeping the typing. The harness makes each change on
    /// the server when the test asks: `attention`, `finished`, `attention-again`, `bell`, `attention-form`.
    func testLiveHerdrNotificationsWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let banner = app.descendants(matching: .any)["herdr.notification.banner"].firstMatch
        let panes = app.buttons.matching(identifier: "terminal.panes").firstMatch
        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        let panesSheet = elementWithIdentifier("terminal.panes.sheet")

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 3 panes", timeout: 10))
        captureLiveHerdrStep("n1-session", in: configuration)

        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        try requestLiveHerdrStep("attention", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner for the agent waiting in the other tab.")
        XCTAssertEqual(banner.label, "claude waiting, remux › build")
        captureLiveHerdrStep("n2-banner-over-sessions-sheet", in: configuration)
        banner.tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5), "The tap didn't close the Sessions sheet.")
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 1 pane", timeout: 10), "The tap didn't go to the other tab.")
        XCTAssertFalse(banner.exists)
        captureLiveHerdrStep("n3-tapped-other-tab", in: configuration)
        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5), "The Sessions sheet didn't open again.")
        app.buttons["terminal.sessions.close"].tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5))

        openHomeFromTerminal()
        try requestLiveHerdrStep("finished", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner over Home for the agent that finished.")
        XCTAssertEqual(banner.label, "claude done, Herdr live · remux-ui · remux › 1")
        captureLiveHerdrStep("n4-banner-over-home", in: configuration)
        banner.tap()
        waitForLiveTerminalReady(timeout: 30, expectedHostKey: configuration.expectedHostKey)
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 3 panes", timeout: 10), "The tap didn't open the agent's tab.")
        captureLiveHerdrStep("n5-tapped-from-home", in: configuration)

        panes.tap()
        XCTAssertTrue(panesSheet.waitForExistence(timeout: 5))
        try requestLiveHerdrStep("attention-again", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner above the Panes sheet.")
        captureLiveHerdrStep("n5b-banner-over-panes-sheet", in: configuration)
        banner.tap()
        XCTAssertTrue(panesSheet.waitForNonExistence(timeout: 5), "The tap didn't close the Panes sheet.")
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 1 pane", timeout: 10), "The tap didn't go to the other tab.")
        panes.tap()
        XCTAssertTrue(panesSheet.waitForExistence(timeout: 5), "The Panes sheet didn't open again.")
        app.buttons["terminal.panes.close"].tap()
        XCTAssertTrue(panesSheet.waitForNonExistence(timeout: 5))

        try requestLiveHerdrStep("bell", in: configuration)
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the bell arrives")], timeout: 3)
        captureLiveHerdrStep("n6-bell", in: configuration)

        openHomeFromTerminal()
        let addServer = app.buttons["library.add-server"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()
        let serverName = app.textFields["connection.name"]
        XCTAssertTrue(serverName.waitForExistence(timeout: 5))
        serverName.tap()
        serverName.typeText("Draft server")
        try requestLiveHerdrStep("attention-form", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner over the server form.")
        XCTAssertEqual(banner.label, "claude waiting, Herdr live · remux-ui · remux › build")
        captureLiveHerdrStep("n7-banner-over-server-form", in: configuration)
        banner.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "The tap didn't put the banner away.")
        XCTAssertTrue(serverName.exists, "The tap closed the server form.")
        XCTAssertEqual(serverName.value as? String, "Draft server", "The typing in the server form was lost.")
        captureLiveHerdrStep("n8-form-kept", in: configuration)
        app.buttons["connection.cancel"].tap()
        XCTAssertTrue(serverName.waitForNonExistence(timeout: 5))
    }

    /// Herdr's agents on a live server whose session has the fixture's three-pane tab (workspace `remux`),
    /// with agent `claude` working in it, and a second tab, `build`, whose two panes each have an agent: one
    /// blocked, and one working that finishes when the test asks (`finish`). Panes adds the agent's state to
    /// its tile, Tabs shows the tab's agent, and Sessions the session's most urgent one. The Agents list has
    /// every agent, with Blocked and Done filters; the finished agent's row opens its pane, where it counts as
    /// seen.
    func testLiveHerdrAgentsWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let banner = app.descendants(matching: .any)["herdr.notification.banner"].firstMatch
        let panes = app.buttons.matching(identifier: "terminal.panes").firstMatch
        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        let agentRows = app.descendants(matching: .any).matching(identifier: "terminal.agents.agent")
        func element(_ identifierPrefix: String, labelContaining text: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", identifierPrefix, text))
                .firstMatch
        }
        func agentRow(_ label: String) -> XCUIElement {
            agentRows.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        func waitForAgentRows(_ labels: [String]) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if agentRows.allElementsBoundByIndex.map({ $0.label }).sorted() == labels.sorted() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return false
        }
        func showAgents() {
            openSessionSwitcherFromTerminal()
            XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
            let agents = app.segmentedControls["terminal.sessions.mode"].buttons["Agents"]
            XCTAssertTrue(agents.waitForExistence(timeout: 5), "No Agents switch while a Herdr session is open.")
            agents.tap()
        }
        let working = "claude, remux › 1, working"
        let blocked = "claude, remux › build, blocked"
        let done = "claude, remux › build, done"

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 3 panes", timeout: 10))

        openPanesSheet()
        XCTAssertTrue(
            element("terminal.pane.tile.", labelContaining: "Fixing tests · 2, working").waitForExistence(timeout: 10),
            "The agent's pane tile didn't name its state."
        )
        captureLiveHerdrStep("a1-panes", in: configuration)
        app.buttons["terminal.panes.close"].tap()

        openWindowsSheet()
        XCTAssertTrue(
            element("terminal.window.tile.", labelContaining: "agent working").waitForExistence(timeout: 10),
            "The tab's tile didn't show its agent."
        )
        XCTAssertEqual(app.buttons["terminal.windows.group.1"].label, "Workspace remux, agent blocked")
        XCTAssertFalse(app.buttons["terminal.windows.group.more"].exists, "One workspace offered More.")
        let newWorkspace = app.buttons["terminal.windows.group.new"]
        XCTAssertTrue(newWorkspace.isHittable, "New Workspace doesn't follow the workspace's capsule.")
        XCTAssertEqual(newWorkspace.frame.midY, app.buttons["terminal.windows.group.1"].frame.midY, accuracy: 1)
        captureLiveHerdrStep("a2-tabs", in: configuration)
        app.buttons["terminal.windows.close"].tap()

        try requestLiveHerdrStep("finish", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner for the agent that finished in the other tab.")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 20))

        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element("terminal.sessions.active-session", labelContaining: "agent blocked").waitForExistence(timeout: 5),
            "The session's row didn't show its most urgent agent."
        )
        captureLiveHerdrStep("a3-sessions", in: configuration)
        app.buttons["terminal.sessions.close"].tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5))

        showAgents()
        XCTAssertTrue(waitForAgentRows([working, blocked, done]), "Agents didn't list every agent.")
        captureLiveHerdrStep("a4-agents", in: configuration)
        app.buttons["terminal.agents.filter.blocked"].tap()
        XCTAssertTrue(waitForAgentRows([blocked]), "Blocked didn't show only the blocked agent.")
        captureLiveHerdrStep("a5-agents-blocked", in: configuration)
        app.buttons["terminal.agents.filter.done"].tap()
        XCTAssertTrue(waitForAgentRows([done]), "Done didn't show only the finished agent.")
        captureLiveHerdrStep("a6-agents-done", in: configuration)
        app.buttons["terminal.agents.filter.working"].tap()
        XCTAssertTrue(waitForAgentRows([working]), "Working didn't show only the working agent.")
        captureLiveHerdrStep("a6b-agents-working", in: configuration)
        app.buttons["terminal.agents.filter.idle"].tap()
        XCTAssertTrue(waitForAgentRows([]), "Idle showed an agent while none is idle.")
        XCTAssertTrue(app.staticTexts["No Agents Idle"].waitForExistence(timeout: 5))
        captureLiveHerdrStep("a6c-agents-idle", in: configuration)
        app.buttons["terminal.agents.filter.all"].tap()
        XCTAssertTrue(waitForAgentRows([working, blocked, done]))

        agentRow(done).tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5), "The row didn't close the Sessions sheet.")
        XCTAssertTrue(waitForLabel(of: panes, "Panes, 2 panes", timeout: 10), "The row didn't go to the agent's tab.")
        captureLiveHerdrStep("a7-opened-agent", in: configuration)
        openPanesSheet()
        XCTAssertTrue(
            element("terminal.pane.tile.", labelContaining: "blocked").waitForExistence(timeout: 10),
            "The blocked agent's pane tile didn't name its state."
        )
        XCTAssertTrue(
            element("terminal.pane.tile.", labelContaining: "idle").waitForExistence(timeout: 10),
            "The agent whose pane is on screen didn't count as seen."
        )
        captureLiveHerdrStep("a8-panes-agent-tab", in: configuration)
        app.buttons["terminal.panes.close"].tap()

        showAgents()
        XCTAssertTrue(
            waitForAgentRows([working, blocked, "claude, remux › build, idle"]),
            "The agent that finished wasn't seen once its pane was on screen."
        )
        captureLiveHerdrStep("a9-agents-after-seen", in: configuration)
        app.buttons["terminal.agents.filter.idle"].tap()
        XCTAssertTrue(waitForAgentRows(["claude, remux › build, idle"]), "Idle didn't show only the idle agent.")
        captureLiveHerdrStep("a9b-agents-idle", in: configuration)
        app.buttons["terminal.sessions.close"].tap()
    }

    /// Herdr's workspaces on a live server, each showing its most urgent agent: the fixture's `remux`, with
    /// agent `claude` working, then `api`, whose agent works and finishes when the test asks (`finish`),
    /// `web`, with none, `notes`, whose agent is idle, and `infra`, whose agent is blocked. Sessions shows
    /// each workspace's agent on its row, and collapses the session to one row that says it's current; Tabs
    /// shows each workspace's agent on its capsule; the workspaces behind More show theirs in
    /// its menu, top to bottom in Herdr's order then New Workspace, and on More once picked. Once `notes` and
    /// `infra` close (`trim`), the three left fit as capsules, so there's no More and New Workspace ends the
    /// capsules.
    func testLiveHerdrWorkspaceAgentsWhenConfigured() throws {
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        let banner = app.descendants(matching: .any)["herdr.notification.banner"].firstMatch
        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        let workspaceRows = app.buttons.matching(identifier: "terminal.sessions.herdr-workspace")
        let more = app.buttons["terminal.windows.group.more"]
        // The list makes only the rows it shows, so the workspaces are read as it scrolls, in order.
        func listedWorkspaceRows() -> [String] {
            let sessionList = app.descendants(matching: .any)["terminal.sessions.list"]
            let newWorkspace = app.buttons["terminal.sessions.herdr-workspace.new"]
            var listed: [String] = []
            func read() {
                for label in workspaceRows.allElementsBoundByIndex.map({ $0.label }) where !listed.contains(label) {
                    listed.append(label)
                }
            }
            read()
            for _ in 0..<4 where !newWorkspace.exists || !newWorkspace.isHittable {
                sessionList.swipeUp()
                read()
            }
            return listed
        }

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        try requestLiveHerdrStep("finish", in: configuration)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "No banner for the agent that finished in api.")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 20))

        openSessionSwitcherFromTerminal()
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(workspaceRows.firstMatch.waitForExistence(timeout: 5), "The session didn't list its workspaces.")
        captureLiveHerdrStep("w1-sessions", in: configuration)
        XCTAssertEqual(listedWorkspaceRows(), [
            "Workspace remux, 1 tab, agent working, current workspace",
            "Workspace api, 1 tab, agent done",
            "Workspace web, 1 tab",
            "Workspace notes, 1 tab, agent idle",
            "Workspace infra, 1 tab, agent blocked",
        ], "The workspace rows didn't show their agents.")
        captureLiveHerdrStep("w1b-sessions-scrolled", in: configuration)
        // Collapsed, the session the user is in is marked on its own row; VoiceOver reads it as before.
        let sessionRow = app.descendants(matching: .any).matching(identifier: "terminal.sessions.active-session").firstMatch
        let sessionList = app.descendants(matching: .any)["terminal.sessions.list"]
        for _ in 0..<4 where !sessionRow.isHittable {
            sessionList.swipeDown()
        }
        XCTAssertEqual(sessionRow.value as? String, "Expanded")
        sessionRow.tap()
        XCTAssertTrue(waitForValue("Collapsed", of: sessionRow, timeout: 5), "The session didn't collapse.")
        XCTAssertTrue(workspaceRows.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sessionRow.label.hasSuffix(", current session"), sessionRow.label)
        captureLiveHerdrStep("w1c-sessions-collapsed", in: configuration)
        sessionRow.tap()
        XCTAssertTrue(waitForValue("Expanded", of: sessionRow, timeout: 5), "The session didn't expand again.")
        app.buttons["terminal.sessions.close"].tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 5))

        openWindowsSheet()
        XCTAssertTrue(
            waitForLabel(of: app.buttons["terminal.windows.group.1"], "Workspace remux, agent working", timeout: 10),
            "The capsule of the workspace on screen didn't show its agent."
        )
        XCTAssertEqual(app.buttons["terminal.windows.group.2"].label, "Workspace api, agent done")
        XCTAssertEqual(app.buttons["terminal.windows.group.3"].label, "Workspace web")
        XCTAssertEqual(more.label, "More workspaces")
        XCTAssertTrue(app.buttons["terminal.window.new"].isHittable, "New Tab isn't offered.")
        XCTAssertFalse(app.buttons["New Workspace"].exists, "New Workspace is offered outside More's menu.")
        captureLiveHerdrStep("w2-tabs", in: configuration)

        more.tap()
        let infra = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "infra")).firstMatch
        XCTAssertTrue(infra.waitForExistence(timeout: 5), "More didn't list infra.")
        let notes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "notes")).firstMatch
        XCTAssertTrue(notes.exists)
        XCTAssertLessThan(notes.frame.minY, infra.frame.minY, "More didn't list its workspaces top to bottom in Herdr's order.")
        let menuNewWorkspace = app.buttons["New Workspace"]
        XCTAssertTrue(menuNewWorkspace.exists, "More's menu doesn't offer New Workspace.")
        XCTAssertLessThan(infra.frame.minY, menuNewWorkspace.frame.minY, "New Workspace doesn't end More's menu.")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "New Workspace")).count, 1,
            "New Workspace is offered twice."
        )
        captureLiveHerdrStep("w3-more-menu", in: configuration)
        infra.tap()
        XCTAssertTrue(
            waitForLabel(of: more, "Workspace infra, agent blocked, more workspaces", timeout: 10),
            "More didn't show the picked workspace's agent."
        )
        captureLiveHerdrStep("w4-more-picked", in: configuration)
        app.buttons["terminal.windows.close"].tap()
        XCTAssertTrue(app.buttons["terminal.windows.close"].waitForNonExistence(timeout: 5))

        try requestLiveHerdrStep("trim", in: configuration)
        openWindowsSheet()
        XCTAssertTrue(more.waitForNonExistence(timeout: 15), "Three workspaces still offered More.")
        XCTAssertEqual(
            (1...3).map { app.buttons["terminal.windows.group.\($0)"].label },
            ["Workspace remux, agent working", "Workspace api, agent done", "Workspace web"]
        )
        let newWorkspace = app.buttons["terminal.windows.group.new"]
        XCTAssertTrue(newWorkspace.isHittable, "New Workspace doesn't end the capsules.")
        XCTAssertEqual(newWorkspace.label, "New Workspace")
        XCTAssertEqual(newWorkspace.frame.midY, app.buttons["terminal.windows.group.3"].frame.midY, accuracy: 1)
        XCTAssertGreaterThan(newWorkspace.frame.minX, app.buttons["terminal.windows.group.3"].frame.maxX)
        captureLiveHerdrStep("w5-tabs-three-workspaces", in: configuration)
        app.buttons["terminal.windows.close"].tap()
    }

    /// Herdr's popup on a live server, opened by a second Herdr client on the tab the phone shows, as from a
    /// Mac. The phone attaches to the popup's terminal and shows it in a frame filling the terminal area at
    /// the panes' font, with its title and the tab it is over; Tabs and Panes are held, Sessions isn't. The
    /// popup's terminal takes the phone's grid, which the keyboard and a rotation change by rows and columns,
    /// not text size, and keeps it while the other client types, and through a quiet minute; Home gives it
    /// back. Typing, the composer and swipes go into it: an arrow reaches a program asking for application
    /// cursor keys as one, a shell's history scrolls, and a program reporting the mouse gets wheel steps and a
    /// tap as a click. A long press on a word selects it, and Copy copies it.
    /// btop says the grid it has is too small, with its size; Claude Code takes the phone's keys. Each
    /// popup closes when its program exits. Screens in dark, then Latte.
    /// The harness answers each `<step>.request` with `<step>.done`, and `<step>.out` for what it read:
    /// `open-shell`, `open-probe`, `open-btop` and `open-claude` open the popups from the other client,
    /// `mac-claims` and `mac-types` type there, `read` captures its screen, `winsize` reads the popup's
    /// terminal size as "rows columns", and `end-claude` ends Claude Code (its first-run screens don't quit on
    /// Control-C). The other client draws the popup's terminal in its own popup box, which shows only its top
    /// rows while the phone's grid is taller, so what the test reads there is written after a `clear`. The
    /// harness puts `key_probe.py` in the server's home, which shows the bytes of each key it gets.
    func testLiveHerdrPopupFrameWhenConfigured() throws {
        app.launchEnvironment["REMUX_TRACE_GHOSTTY_DIAGNOSTICS"] = "1"
        let configuration = try launchLiveHerdrApp(requiringSteps: true)
        // A failure in a landscape phase ends the test there; the tests after it start in portrait.
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let popup = app.descendants(matching: .any)["terminal.popup"].firstMatch
        let content = app.descendants(matching: .any)["terminal.popup.content"].firstMatch
        let title = app.staticTexts["terminal.popup.title"].firstMatch
        let tab = app.staticTexts["terminal.popup.tab"].firstMatch
        let tabs = app.buttons["terminal.windows"].firstMatch
        let panes = app.buttons["terminal.panes"].firstMatch
        let sessions = app.buttons["terminal.sessions"].firstMatch
        typealias Grid = (rows: Int, columns: Int)
        func step(_ name: String) throws -> String {
            try performLiveHerdrStep(name, in: configuration)
        }
        func capture(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            captureLiveHerdrStep(name, in: configuration)
        }
        func showKeyboard() {
            guard !app.keyboards.firstMatch.exists else { return }
            content.tap()
            XCTAssertNotNil(waitForKeyboardPresence(true, label: "popup keyboard", timeout: 8))
        }
        func hideKeyboard() {
            guard app.keyboards.firstMatch.exists else { return }
            app.buttons["terminal.keyboard"].tap()
            XCTAssertNotNil(waitForKeyboardPresence(false, label: "popup keyboard hide", timeout: 8))
        }
        func typeIntoPopup(_ text: String) {
            showKeyboard()
            app.typeText(text)
        }
        func screen(containing text: String, timeout: TimeInterval = 10) throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try step("read").contains(text) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            return false
        }
        /// The popup's terminal size once `condition` holds for it, as its program sees it.
        func popupGrid(_ context: String, where condition: (Grid) -> Bool = { _ in true }) throws -> Grid? {
            let deadline = Date().addingTimeInterval(10)
            var last: Grid?
            while Date() < deadline {
                let parts = try step("winsize").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                if parts.count == 2 {
                    last = (parts[0], parts[1])
                    if let last, condition(last) { return last }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            XCTFail("The popup's terminal was \(last.map { "\($0.rows)x\($0.columns)" } ?? "unread") \(context).")
            return nil
        }
        /// Asks the popup's shell for its size, typing with the keyboard up, and checks it says `grid`.
        func assertSttySays(_ grid: Grid, _ context: String) throws {
            typeIntoPopup("clear; stty size\n")
            XCTAssertTrue(try screen(containing: "\(grid.rows) \(grid.columns)"), "stty didn't say \(grid.rows) \(grid.columns) \(context).")
        }
        /// The numbers on the other client's screen, which shows the popup's terminal.
        func numbersOnScreen() throws -> [Int] {
            let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃║|"))
            return try step("read").split(whereSeparator: \.isNewline).compactMap {
                Int($0.trimmingCharacters(in: edges))
            }
        }
        func assertNavigationHeld(_ held: Bool, _ context: String) {
            XCTAssertEqual(tabs.isEnabled, !held, "Tabs \(held ? "worked" : "stayed held") \(context).")
            XCTAssertEqual(panes.isEnabled, !held, "Panes \(held ? "worked" : "stayed held") \(context).")
            XCTAssertTrue(sessions.isEnabled, "Sessions was held \(context).")
        }
        func backToSession() {
            let activeSession = app.descendants(matching: .any)["library.active-session.show"].firstMatch
            XCTAssertTrue(activeSession.waitForExistence(timeout: 5))
            activeSession.tap()
        }

        openFirstSavedSession()
        waitForLiveTerminalReady(timeout: 60, expectedHostKey: configuration.expectedHostKey)
        assertNavigationHeld(false, "before any popup")
        capture("f0-panes-dark")

        // The other client holds the tab's size, then opens a shell popup over it.
        _ = try step("mac-claims")
        _ = try step("open-shell")
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "The popup opened on the tab on screen didn't show.")
        XCTAssertFalse(title.label.isEmpty, "The popup's frame has no title.")
        XCTAssertTrue(tab.label.hasPrefix("over "), "The popup's frame doesn't say which tab it is over: \(tab.label)")
        XCTAssertFalse(app.buttons["terminal.popup.close"].exists, "The popup has a close button.")
        XCTAssertFalse(app.buttons["terminal.popup.expand"].exists, "The popup has an Expand button.")
        assertNavigationHeld(true, "under the popup")

        // The popup's terminal has the phone's grid, narrower than the other client's popup.
        let full = try XCTUnwrap(try popupGrid("at the phone's size") { $0.columns < 80 })
        capture("f1-popup-dark")

        // The keyboard takes rows, not text size; hiding it gives them back.
        showKeyboard()
        let withKeyboard = try XCTUnwrap(try popupGrid("with the keyboard up") {
            $0.rows < full.rows && $0.columns == full.columns
        })
        try assertSttySays(withKeyboard, "with the keyboard up")
        capture("f2-popup-dark-keyboard")
        hideKeyboard()
        XCTAssertNotNil(try popupGrid("with the keyboard down again") { $0 == full })

        // Landscape in dark, with the keyboard down and up.
        XCUIDevice.shared.orientation = .landscapeLeft
        let darkLandscape = try XCTUnwrap(try popupGrid("in landscape") { $0.columns > full.columns })
        capture("f2l-popup-dark-landscape")
        showKeyboard()
        XCTAssertNotNil(try popupGrid("in landscape with the keyboard up") { $0.rows < darkLandscape.rows })
        capture("f2lk-popup-dark-landscape-keyboard")
        hideKeyboard()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertNotNil(try popupGrid("back in portrait") { $0 == full })

        // A quiet popup keeps its attach past Herdr's minute for an idle background bridge.
        RunLoop.current.run(until: Date().addingTimeInterval(65))
        XCTAssertNotNil(try popupGrid("after a quiet minute") { $0 == full })
        typeIntoPopup("clear; echo still-$((6*7))\n")
        XCTAssertTrue(try screen(containing: "still-42"), "Typing after a quiet minute didn't reach the popup.")
        hideKeyboard()

        // A long press selects a word of the popup's terminal, as on a pane, and Copy copies it.
        UIPasteboard.general.string = "REMUX_HERDR_POPUP_COPY_SENTINEL"
        typeIntoPopup("clear; echo popupword-$((6*7))\n")
        XCTAssertTrue(try screen(containing: "popupword-42"), "echo didn't run in the popup.")
        hideKeyboard()
        content.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 8)).press(forDuration: 0.7)
        let popupCopy = waitForCopyMenuItem(timeout: 5)
        capture("f2c-popup-dark-selected")
        popupCopy.tap()
        XCTAssertEqual(pasteIntoEmptyComposer(), "popupword-42", "A word of the popup didn't copy as itself.")
        clearAndCloseComposer()
        hideKeyboard()
        // A tap ends the selection, as on a pane; the next brings up the keyboard.
        content.tap()

        // Herdr encodes the phone's keys for the program's modes: an arrow reaches a program asking for
        // application cursor keys as one.
        typeIntoPopup("clear; python3 -I ~/key_probe.py decckm ~/decckm.log\n")
        XCTAssertTrue(try screen(containing: "probe decckm ready"), "The key probe didn't start.")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(try screen(containing: #"b'\x1bOA'"#), "An arrow didn't reach the program as an application cursor key.")
        app.typeText("QQ")
        hideKeyboard()

        // A swipe scrolls the shell's history, and back.
        typeIntoPopup("clear; seq 1 200\n")
        XCTAssertTrue(try screen(containing: "199"), "seq didn't run in the popup.")
        hideKeyboard()
        let bottom = try XCTUnwrap(try numbersOnScreen().min())
        content.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let scrolled = try XCTUnwrap(try numbersOnScreen().min())
        XCTAssertLessThan(scrolled, bottom, "A swipe didn't scroll the popup's history.")
        capture("f3-popup-dark-scrolled")
        content.swipeUp()
        content.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try numbersOnScreen().min(), bottom, "Swiping back didn't return to the popup's newest lines.")

        // The composer's message goes into the popup.
        app.buttons["terminal.composer.toggle"].tap()
        let composerField = app.textViews["terminal.composer.field"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 3))
        composerField.tap()
        composerField.typeText("clear; echo from-the-$((6*7))-composer")
        app.buttons["terminal.composer.send"].tap()
        XCTAssertTrue(try screen(containing: "from-the-42-composer"), "The composer's message didn't reach the popup.")
        if composerField.exists { app.buttons["terminal.composer.toggle"].tap() }
        hideKeyboard()

        // The other client's typing goes into the popup, which keeps the phone's size.
        let held = try XCTUnwrap(try popupGrid("before the other client typed"))
        _ = try step("mac-types")
        XCTAssertTrue(try screen(containing: "typed-on-mac"), "The other client's typing didn't reach the popup.")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let afterMac = try XCTUnwrap(try popupGrid("after the other client typed"))
        XCTAssertTrue(afterMac == held, "The other client's typing took the popup's size.")

        // Home gives the popup's size back to the other client; coming back takes it again.
        openHomeFromTerminal()
        let given = try XCTUnwrap(try popupGrid("with the phone on Home") { $0.columns > held.columns })
        XCTAssertGreaterThan(given.columns, held.columns)
        backToSession()
        XCTAssertTrue(popup.waitForExistence(timeout: 20), "Coming back didn't land on the popup.")
        XCTAssertNotNil(try popupGrid("back on the popup") { $0 == held })
        assertNavigationHeld(true, "back on the popup")

        // Latte, the light theme, while the popup is open.
        openHomeFromTerminal()
        app.buttons["library.settings"].tap()
        XCTAssertTrue(app.buttons["Latte"].waitForExistence(timeout: 5))
        app.buttons["Latte"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        backToSession()
        XCTAssertTrue(popup.waitForExistence(timeout: 20))
        typeIntoPopup("clear; ls /\n")
        capture("f4k-popup-light-keyboard")
        hideKeyboard()
        capture("f4-popup-light")

        // Landscape gives the popup the wider grid, at the same font; portrait takes it back.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = try XCTUnwrap(try popupGrid("in landscape") { $0.columns > full.columns })
        XCTAssertLessThan(landscape.rows, full.rows)
        capture("f5-popup-light-landscape")
        showKeyboard()
        let landscapeWithKeyboard = try XCTUnwrap(try popupGrid("in landscape with the keyboard up") {
            $0.rows < landscape.rows && $0.columns == landscape.columns
        })
        try assertSttySays(landscapeWithKeyboard, "in landscape with the keyboard up")
        capture("f5k-popup-light-landscape-keyboard")
        hideKeyboard()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertNotNil(try popupGrid("back in portrait") { $0 == full })

        // The shell exits, the popup closes, and the panes come back with Tabs and Panes.
        typeIntoPopup("exit\n")
        XCTAssertTrue(popup.waitForNonExistence(timeout: 15), "The popup stayed after its program exited.")
        hideKeyboard()
        assertNavigationHeld(false, "once the popup closed")
        capture("f6-popup-closed")

        // A program reporting the mouse gets a swipe as wheel steps, in its own grid.
        _ = try step("open-probe")
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "The wheel probe's popup didn't show.")
        XCTAssertTrue(try screen(containing: "probe ready"), "The wheel probe didn't start.")
        content.swipeDown()
        XCTAssertTrue(try screen(containing: "wheel up at"), "A swipe didn't reach the program as the wheel.")
        content.swipeUp()
        XCTAssertTrue(try screen(containing: "wheel down at"), "A swipe didn't reach the program as the wheel.")
        // A tap is a click there, as on a pane: a press and its release.
        content.tap()
        XCTAssertTrue(try screen(containing: "press at"), "A tap didn't reach the program as a click.")
        XCTAssertTrue(try screen(containing: "release at"), "A tap's release didn't reach the program.")
        capture("f7-popup-light-wheel")
        typeIntoPopup("q")
        XCTAssertTrue(popup.waitForNonExistence(timeout: 15), "The wheel probe's popup stayed after it quit.")
        hideKeyboard()

        // btop draws at 80x24 or more; at the phone's grid it says so, with the size it has.
        _ = try step("open-btop")
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "btop's popup didn't show.")
        let btopGrid = try XCTUnwrap(try popupGrid("under btop"))
        XCTAssertTrue(
            try screen(containing: "Width = \(btopGrid.columns) Height = \(btopGrid.rows)"),
            "btop didn't say the popup's grid, \(btopGrid.columns)x\(btopGrid.rows)."
        )
        capture("f8-popup-light-btop")
        typeIntoPopup("q")
        XCTAssertTrue(popup.waitForNonExistence(timeout: 15), "btop's popup stayed after it quit.")
        hideKeyboard()

        // Claude Code in a popup takes the phone's keys, and its popup closes when it exits.
        _ = try step("open-claude")
        XCTAssertTrue(popup.waitForExistence(timeout: 15), "The Claude Code popup didn't show.")
        // Its first-run screen, or its name once past it.
        let claudeDrew = try screen(containing: "Let's get started", timeout: 20) || screen(containing: "Claude", timeout: 1)
        XCTAssertTrue(claudeDrew, "Claude Code didn't draw in the popup.")
        capture("f9-popup-light-claude")
        let before = try step("read")
        typeIntoPopup("\n")
        hideKeyboard()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertNotEqual(try step("read"), before, "The phone's key didn't reach Claude Code.")
        capture("f10-popup-light-claude-key")
        _ = try step("end-claude")
        XCTAssertTrue(popup.waitForNonExistence(timeout: 15), "The Claude Code popup stayed after it exited.")
        assertNavigationHeld(false, "once Claude Code's popup closed")
    }

    /// Asks the harness for `step` and waits for it to answer; returns what it wrote for the step.
    private func performLiveHerdrStep(_ step: String, in configuration: LiveHerdrConfiguration) throws -> String {
        let directory = URL(fileURLWithPath: try XCTUnwrap(configuration.stepDirectory))
        let done = directory.appendingPathComponent("\(step).done")
        try? FileManager.default.removeItem(at: done)
        try requestLiveHerdrStep(step, in: configuration)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: done.path) {
            guard Date() < deadline else {
                XCTFail("The harness didn't answer step \(step).")
                return ""
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let output = (try? String(contentsOf: directory.appendingPathComponent("\(step).out"), encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: done)
        return output
    }

    private func waitForLabel(of element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func requestLiveHerdrStep(_ step: String, in configuration: LiveHerdrConfiguration) throws {
        let directory = try XCTUnwrap(configuration.stepDirectory)
        try Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(step).request"))
    }

    /// Launches the app with the live Herdr configuration's server saved, with its session or `sessionName`.
    private func launchLiveHerdrApp(
        sessionName: String? = nil,
        requiringSteps: Bool = false
    ) throws -> LiveHerdrConfiguration {
        guard let path = ProcessInfo.processInfo.environment["REMUX_LIVE_HERDR_UI_CONFIG"], !path.isEmpty else {
            throw XCTSkip("Set REMUX_LIVE_HERDR_UI_CONFIG to run the live Herdr UI test.")
        }
        let configuration = try JSONDecoder().decode(
            LiveHerdrConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        if requiringSteps, configuration.stepDirectory == nil {
            throw XCTSkip("Set stepDirectory in the live Herdr configuration to run the notification test.")
        }
        app.launchEnvironment["REMUX_DEBUG_SEED_CONNECTION"] = "1"
        app.launchEnvironment["REMUX_DEBUG_SERVER_NAME"] = configuration.displayName ?? "Live Herdr"
        app.launchEnvironment["REMUX_DEBUG_SERVER_HOST"] = configuration.host
        app.launchEnvironment["REMUX_DEBUG_SERVER_PORT"] = configuration.port ?? "22"
        app.launchEnvironment["REMUX_DEBUG_SERVER_USERNAME"] = configuration.username
        app.launchEnvironment["REMUX_DEBUG_CREDENTIALS_FILE"] = path
        app.launchEnvironment["REMUX_DEBUG_HERDR_SESSION"] = sessionName ?? configuration.sessionName
        app.launchEnvironment["REMUX_DEBUG_HERDR_EXECUTABLE_PATH"] = configuration.herdrExecutablePath
        if let tmuxExecutablePath = configuration.tmuxExecutablePath {
            app.launchEnvironment["REMUX_DEBUG_TMUX_EXECUTABLE_PATH"] = tmuxExecutablePath
        }
        app.launchEnvironment["REMUX_DEBUG_EPHEMERAL_STORAGE"] = "1"
        launchedLiveSSHApp = true
        app.launch()
        return configuration
    }

    private func captureLiveHerdrStep(_ name: String, in configuration: LiveHerdrConfiguration) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "herdr-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = configuration.captureDirectory else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("herdr-\(name).png")
        XCTAssertNoThrow(try screenshot.pngRepresentation.write(to: url))
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
            "seq -f 'REMUX_MOUSE_LINE_%g' 300 > /tmp/remux-scroll.txt; vim --clean -n -c 'set mouse=a' /tmp/remux-scroll.txt"
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
        // Five fast flicks in a row. XCUITest waits for each deceleration
        // to end before the next swipe.
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

        // A preview fills its tile and is drawn past its sides; the tile beside the window on screen still
        // takes the touches on its own right edge.
        let windows = app.buttons.matching(identifier: "terminal.windows").firstMatch
        openWindowsSheet()
        XCTAssertTrue(waitForValue("Preview ready", of: app.buttons["terminal.window.tile.2"], timeout: 10))
        app.buttons["terminal.window.tile.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForLabel(of: windows, "Window 1 of 2", timeout: 10), "A tap on tile 1's right edge didn't go to window 1.")
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

        // The marker lives in the composer bar, which re-renders on every
        // keystroke even when the screen body does not.
        let probe = app.otherElements["terminal.composer.perf"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        // Dictation hypothesis path: the debug backend emits one audio level
        // per meter bar, then one hypothesis that writes the draft. Screen body
        // evals in this window show how much of dictation invalidates the whole
        // screen.
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
        // Tapping the field places the caret where the tap lands (a center
        // tap put it before the transcript), so tap past the transcript's end
        // to append to it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
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
        let sessionName = try generatedLiveLatencySessionName("window-names")
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
        XCTAssertEqual(
            pasteIntoEmptyComposer(),
            marker,
            "Stationary terminal word selection should copy exactly the selected marker."
        )
        clearAndCloseComposer()

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
        XCTAssertEqual(
            pasteIntoEmptyComposer(),
            link,
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

        let ctrl = app.buttons["terminal.toolbar-key.0"]
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

        if let assigned = liveHarnessTestValue("session") {
            XCTAssertTrue(
                assigned.range(
                    of: #"^remux-latency-[A-Za-z0-9._-]+$"#,
                    options: .regularExpression
                ) != nil,
                "Refusing to use non-allowlisted harness-assigned live tmux session \(assigned)."
            )
            recordGeneratedLiveLatencySession(assigned, manifestPath: manifestPath)
            return assigned
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
        guard liveCleanupHarnessEnabled(), let path = liveHarnessTestRecordPath("sessions") else {
            throw LiveSSHCleanupHarnessError(
                description: "Live SSH UI tests that create remux-latency-* tmux sessions must run through scripts/remux_live_ui_test_with_cleanup.sh; refusing to create a remote tmux session without remote kill-session cleanup."
            )
        }

        return path
    }

    private func liveCleanupHarnessEnabled() -> Bool {
        liveCleanupHarnessFieldsIfEnabled() != nil
    }

    /// The cleanup harness gives each run its own directory, which reaches the
    /// test runner as TEST_RUNNER_REMUX_LIVE_RUN_DIR. It holds the harness
    /// marker and each test's records.
    private var liveHarnessRunDirectory: URL? {
        guard
            let path = ProcessInfo.processInfo.environment["REMUX_LIVE_RUN_DIR"],
            !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func liveCleanupHarnessFieldsIfEnabled() -> [String: String]? {
        guard
            let url = liveHarnessRunDirectory?.appendingPathComponent("harness.txt"),
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

    /// The live SSH configuration file the cleanup harness was given.
    private func liveSSHConfigurationPath() throws -> String {
        guard liveHarnessRunDirectory != nil else {
            throw XCTSkip("Run live SSH UI tests through scripts/remux_live_ui_test_with_cleanup.sh.")
        }
        guard let path = liveCleanupHarnessFieldsIfEnabled()?["config"] else {
            throw LiveSSHCleanupHarnessError(
                description: "The live UI test cleanup harness marker is missing, stale or has no config."
            )
        }
        return path
    }

    private func requireLiveSSHConfigurationExists() throws {
        _ = try liveSSHConfigurationPath()
    }

    private func liveAgentTUISessionName() throws -> String {
        try requireLiveSSHConfigurationExists()
        guard let sessionName = liveCleanupHarnessOverride("REMUX_LIVE_AGENT_TUI_SESSION") else {
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
        guard liveHarnessTestValue("fixture") == fixtureName else {
            throw XCTSkip("Run this live SSH UI test through scripts/remux_live_ui_test_with_cleanup.sh so it can prepare the \(fixtureName) tmux fixture.")
        }
    }

    /// XCTest names a test "-[RemuxUITests.RemuxAppUITests testLiveExample]".
    private var liveHarnessTestMethod: String {
        String(name.split(separator: " ").last?.dropLast() ?? "")
    }

    /// The cleanup harness assigns values to individual tests, such as a
    /// prepared fixture's tmux session, as `<field>.<test method>=<value>`
    /// marker lines, so tests sharing one xcodebuild run never share them.
    private func liveHarnessTestValue(_ field: String) -> String? {
        liveCleanupHarnessFieldsIfEnabled()?["\(field).\(liveHarnessTestMethod)"]
    }

    /// Each test records its generated tmux sessions and tmux expectations in
    /// its own files, which the cleanup harness checks and cleans up as soon
    /// as the test ends.
    private func liveHarnessTestRecordPath(_ kind: String) -> String? {
        liveHarnessRunDirectory?
            .appendingPathComponent("tests/\(liveHarnessTestMethod).\(kind)")
            .path
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

    /// The harness checks the marker after the test ends. By default it must
    /// still be on screen; `includingHistory` also accepts the pane's
    /// scrollback, for markers that later output may scroll away.
    private func recordLiveTmuxPaneCaptureExpectation(
        sessionName: String,
        paneIndex: Int,
        marker: String,
        includingHistory: Bool = false
    ) {
        XCTAssertGreaterThan(paneIndex, 0)
        XCTAssertTrue(
            marker.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
            "Refusing to record unsafe tmux capture marker \(marker)."
        )
        let kind = includingHistory ? "pane-index-history-contains" : "pane-index-contains"
        recordLiveTmuxExpectation(fields: [kind, sessionName, "\(paneIndex)", marker])
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
        guard let manifestPath = liveHarnessTestRecordPath("expectations") else {
            XCTFail("Live tmux expectations need the cleanup harness's run directory.")
            return
        }

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

    /// Whether the terminal holds first responder, as the screen's keyboard marker reports it.
    private func waitForTerminalFirstResponder(_ expected: Bool, timeout: TimeInterval = 5) -> Bool {
        let marker = app.otherElements["terminal.keyboard.continuity"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = marker.value as? String, value.contains("firstResponder=\(expected);") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
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

    /// Opens the seeded server's session. Without `attachesTmux`, the
    /// simulated server never answers tmux, so the terminal stays connecting.
    private func launchSeededSimulatorTerminal(attachesTmux: Bool = true) {
        if attachesTmux {
            app.launchEnvironment["REMUX_UI_TEST_INPUT_READY"] = "1"
        }
        app.launchEnvironment.merge(
            [
                "REMUX_UI_TESTING": "1",
                "REMUX_DEBUG_SEED_CONNECTION": "1",
                "REMUX_DEBUG_SERVER_NAME": "UI Test Server",
                "REMUX_DEBUG_SERVER_HOST": "example.com",
                "REMUX_DEBUG_SERVER_USERNAME": "tester",
                "REMUX_DEBUG_SERVER_PASSWORD": "password",
                "REMUX_DEBUG_TMUX_SESSION": "ui-test",
            ],
            uniquingKeysWith: { _, new in new }
        )
        app.launch()

        let session = app.descendants(matching: .any)["library.session.resume"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.buttons["terminal.toolbar-key.0"].waitForExistence(timeout: 5))
        if attachesTmux {
            waitForLiveTerminalInputReady(timeout: 10)
        }
    }

    private func selectToolbarKey(_ title: String) {
        let option = app.collectionViews.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.tap()
    }

    private func launchLiveSSHAppIfConfigured(
        traceRuntime: Bool = false,
        sessionNameOverride: String? = nil
    ) throws {
        let configurationPath = try liveSSHConfigurationPath()
        let configuration = try JSONDecoder().decode(
            LiveSSHConfiguration.self,
            from: Data(contentsOf: URL(fileURLWithPath: configurationPath))
        )
        let displayName = configuration.displayName ?? "Live SSH"
        let sessionName = sessionNameOverride ?? configuration.sessionName ?? "remux-live-e2e"

        app.launchEnvironment["REMUX_DEBUG_SEED_CONNECTION"] = "1"
        app.launchEnvironment["REMUX_DEBUG_SERVER_NAME"] = displayName
        app.launchEnvironment["REMUX_DEBUG_SERVER_HOST"] = configuration.host
        app.launchEnvironment["REMUX_DEBUG_SERVER_PORT"] = configuration.port ?? "22"
        app.launchEnvironment["REMUX_DEBUG_SERVER_USERNAME"] = configuration.username
        if let tmuxExecutablePath = configuration.tmuxExecutablePath {
            app.launchEnvironment["REMUX_DEBUG_TMUX_EXECUTABLE_PATH"] = tmuxExecutablePath
        }
        app.launchEnvironment["REMUX_DEBUG_HERDR_EXECUTABLE_PATH"] =
            configuration.herdrExecutablePath ?? "/nonexistent/herdr"
        // XCTest records the launch environment in the result bundle, so the
        // app reads the password or private key from the file itself.
        app.launchEnvironment["REMUX_DEBUG_CREDENTIALS_FILE"] = configurationPath
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
        launchedLiveSSHApp = true
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

    /// `expectedHostKey` stands in for the cleanup harness's when the test runs without it.
    private func waitForLiveTerminalReady(timeout: TimeInterval, expectedHostKey: String? = nil) {
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

            if failedStatuses.firstMatch.exists {
                // The host-key panel is a failed status, so it's checked once one is seen: a check made
                // before can miss a panel that appears just after it.
                if trustExpectedUnknownLiveHostKeyIfNeeded(expectedHostKey: expectedHostKey)
                    || startLiveSessionIfNeeded() {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    continue
                }
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

    /// A test's own session doesn't exist until the test starts it: its saved session opens as ended, and Restart
    /// starts it, once.
    private func startLiveSessionIfNeeded() -> Bool {
        guard !startedLiveSession, app.staticTexts["Session Ended"].exists else { return false }
        // The panel's identifier covers its buttons, so the button is found by its title.
        let restart = app.buttons["Restart"]
        guard restart.exists else { return false }
        restart.tap()
        startedLiveSession = true
        return true
    }

    private func trustExpectedUnknownLiveHostKeyIfNeeded(expectedHostKey: String? = nil) -> Bool {
        let verifyTitle = app.staticTexts["Verify Server"]
        guard verifyTitle.exists else { return false }
        guard let expectedHostKey = expectedHostKey ?? liveCleanupHarnessFieldsIfEnabled()?["expectedHostKey"] else {
            XCTFail("Live SSH host-key verification requires the cleanup harness's expected host key.")
            return false
        }

        let failureLabels = app.staticTexts
            .matching(identifier: "terminal.status.failed")
            .allElementsBoundByIndex
            .map { $0.label }
        guard failureLabels.contains(expectedHostKey) else {
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

    /// Mean luminance of a screenshot, from 0 (black) to 1 (white).
    private func averageLuminance(_ screenshot: XCUIScreenshot) -> Double? {
        guard let cgImage = screenshot.image.cgImage,
              let snapshot = renderedPixels(
                  cgImage: cgImage,
                  crop: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
              )
        else {
            return nil
        }
        var total = 0.0
        for offset in stride(from: 0, to: snapshot.pixels.count, by: 4) {
            total += 0.2126 * Double(snapshot.pixels[offset])
                + 0.7152 * Double(snapshot.pixels[offset + 1])
                + 0.0722 * Double(snapshot.pixels[offset + 2])
        }
        return total / Double(snapshot.width * snapshot.height) / 255
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

        tapFormField(app.textFields["connection.username"])
        typeTextThenReturn("demo", into: app.textFields["connection.username"])

        let password = app.secureTextFields["connection.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 2))
        password.typeText("demo-password")

        XCTAssertTrue(app.buttons["connection.save"].waitForExistence(timeout: 2))
    }

    private func fillTailscaleConnectionForm() {
        app.textFields["connection.name"].tap()
        app.textFields["connection.name"].typeText("Tailscale Server")

        app.textFields["connection.host"].tap()
        app.textFields["connection.host"].typeText("100.64.0.10")

        tapFormField(app.textFields["connection.username"])
        typeTextThenReturn("demo", into: app.textFields["connection.username"])
    }

    /// Taps a server form field once a tap can reach it. A field scrolled out of
    /// view is scrolled back by the tap itself, which then arrives while the form
    /// is still moving and only stops the scroll, so the form is scrolled toward
    /// the field first and the field left to settle.
    private func tapFormField(_ field: XCUIElement) {
        if !field.isHittable {
            if field.frame.maxY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(waitForElementToSettle(field), "\(field) kept moving.")
        field.tap()
    }

    private func waitForElementToSettle(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame = element.frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let frame = element.frame
            if frame == previousFrame, element.isHittable {
                return true
            }
            previousFrame = frame
        }
        return false
    }

    /// Types the text, waits until the field shows it, then presses Return.
    /// Typed as one burst, the Return can reach the server form before the
    /// field has applied the text: the field then reverts to an earlier value
    /// or ignores the Return, leaving focus on it.
    private func typeTextThenReturn(_ text: String, into field: XCUIElement) {
        typeTextAndConfirm(text, into: field)
        field.typeText("\n")
    }

    private func typeTextAndConfirm(_ text: String, into field: XCUIElement) {
        field.typeText(text)
        let applied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", text),
            object: field
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [applied], timeout: 5),
            .completed,
            "\(field) does not show \"\(text)\"."
        )
    }

    private func selectAuthentication(_ name: String) {
        let button = app.buttons[name]
        if !button.isHittable {
            app.swipeUp()
        }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: button
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 2) == .completed else {
            return XCTFail("Authentication option \(name) is not hittable.")
        }
        button.tap()
    }

    private func fillPublicKeyInstallationServerFields() {
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1")

        let port = app.textFields["connection.port"]
        XCTAssertEqual(port.value as? String, "22")

        let username = app.textFields["connection.username"]
        tapFormField(username)
        typeTextThenReturn("demo", into: username)
    }

    private func saveConnectionAndWaitForTerminal() {
        app.buttons["connection.save"].tap()
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 10))
    }

    private func saveServerAndStartSession() {
        app.buttons["connection.save"].tap()

        let serverDetail = app.descendants(matching: .any)["library.server.detail"]
        XCTAssertTrue(serverDetail.waitForExistence(timeout: 5))
        let newSessionButton = app.buttons["library.server.new-session.empty"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 2))
        newSessionButton.tap()

        let sessionName = app.textFields["connection.session"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 2))
        sessionName.tap()
        typeTextAndConfirm("base", into: sessionName)
        saveConnectionAndWaitForTerminal()
    }

    /// iOS shows its Save Password offer a second or more after the form
    /// closes, and several seconds later on a freshly booted simulator, so
    /// watch for it for a while.
    private func assertNoPasswordSaveOffer(after action: String) {
        XCTAssertFalse(
            app.buttons["Not Now"].waitForExistence(timeout: 10),
            "iOS offered to save the server password after \(action)."
        )
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
        let detailButton = app.buttons["library.server.new-session.toolbar"]
        if detailButton.waitForExistence(timeout: 1) {
            detailButton.tap()
            return
        }

        openFirstServerDetail()

        let serverButton = app.buttons["library.server.new-session.toolbar"]
        XCTAssertTrue(serverButton.waitForExistence(timeout: 2))
        if serverButton.isHittable {
            serverButton.tap()
        } else {
            serverButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
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

    /// Pastes into the empty composer through the app's own Paste action and
    /// returns the draft. The test runner can't check a copy by reading the
    /// pasteboard: iOS denies its read of an item Remux wrote (PBErrorDomain
    /// 13) without offering an Allow Paste prompt.
    private func pasteIntoEmptyComposer(timeout: TimeInterval = 5) -> String? {
        let field = app.textViews["terminal.composer.field"]
        if !field.exists {
            let composerToggle = app.buttons["terminal.composer.toggle"]
            XCTAssertTrue(composerToggle.waitForExistence(timeout: 10))
            composerToggle.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        field.press(forDuration: 0.8)
        waitForSelectionMenuItem("Paste", timeout: timeout).tap()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, ((field.value as? String) ?? "").isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return field.value as? String
    }

    private func clearAndCloseComposer() {
        let field = app.textViews["terminal.composer.field"]
        if let draft = field.value as? String, !draft.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count))
        }
        app.buttons["terminal.composer.toggle"].tap()
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
