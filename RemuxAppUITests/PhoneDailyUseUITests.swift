import UIKit
import XCTest

@MainActor
final class PhoneDailyUseUITests: XCTestCase {
    private var app: XCUIApplication!
    private let device = XCUIDevice.shared

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        device.orientation = .portrait
        app = XCUIApplication()
        setPreferredContentSizeCategory("UICTContentSizeCategoryL")
        app.launchEnvironment = [
            "REMUX_UI_TESTING": "1",
            "REMUX_UI_TEST_INPUT_READY": "1",
            "REMUX_DEBUG_SEED_CONNECTION": "1",
            "REMUX_DEBUG_SERVER_NAME": "UI Test Server",
            "REMUX_DEBUG_SERVER_HOST": "example.com",
            "REMUX_DEBUG_SERVER_USERNAME": "tester",
            "REMUX_DEBUG_SERVER_PASSWORD": "password",
            "REMUX_DEBUG_TMUX_SESSION": "ui-test",
        ]
    }

    override func tearDown() async throws {
        device.orientation = .portrait
        try await super.tearDown()
    }

    func testNineBottomControlsRemainTouchableInPortraitAndLandscapeWithKeyboardHidden() {
        launchSeededTerminal()
        let screen = app.otherElements["terminal.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))

        let controls = dockControlElements()

        assertControls(controls, in: "portrait-keyboard-hidden")
        attachScreenshot(named: "phone-controls-portrait-keyboard-hidden")

        device.orientation = .landscapeLeft
        waitForOrientation(.landscapeLeft)
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        assertControls(controls, in: "landscape-keyboard-hidden")
        attachScreenshot(named: "phone-controls-landscape-keyboard-hidden")
    }

    func testNineBottomControlsRemainTouchableInPortraitAndLandscapeWithKeyboardShown() {
        launchSeededTerminal()
        let screen = app.otherElements["terminal.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let controls = dockControlElements()

        showTerminalKeyboard(using: screen)
        assertControls(controls, in: "portrait-keyboard-shown")
        assertKeyboardClearance(controls, state: "portrait-keyboard-shown")
        attachScreenshot(named: "phone-controls-portrait-keyboard-shown")

        device.orientation = .landscapeLeft
        waitForOrientation(.landscapeLeft)
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        assertControls(controls, in: "landscape-keyboard-shown")
        assertKeyboardClearance(controls, state: "landscape-keyboard-shown")
        attachScreenshot(named: "phone-controls-landscape-keyboard-shown")
    }

    func testLiteralMultilineDraftSurvivesRotationComposerCloseAndAppBackgrounding() {
        launchSeededTerminal()
        let screen = app.otherElements["terminal.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let toggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = (1...9).map { "line \($0)" }.joined(separator: "\n")
        field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft, "Each typed newline must remain literal draft text.")
        let composerControls = composerControlElements()
        XCTAssertTrue(app.buttons["terminal.composer.send"].isHittable)
        assertKeyboardClearance(composerControls, state: "portrait-composer-keyboard-shown")
        attachScreenshot(named: "phone-composer-nine-line-draft")

        device.orientation = .landscapeLeft
        waitForOrientation(.landscapeLeft)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, draft)
        let landscapeLineHeight = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).lineHeight
        XCTAssertTrue(waitForStableHeight(of: field), "Composer editor height should settle after rotation.")
        let landscapeTwoLineCap = ceil(landscapeLineHeight * 2 + 10)
        XCTAssertLessThanOrEqual(
            field.frame.height,
            landscapeTwoLineCap + 1,
            "The landscape editor should cap at two body-text lines plus its text-container insets."
        )
        assertComposerControls(field: field)
        assertKeyboardClearance(composerControls, state: "landscape-composer-keyboard-shown")
        field.swipeUp()
        XCTAssertEqual(field.value as? String, draft, "Scrolling the landscape editor must preserve all nine literal lines.")
        attachScreenshot(named: "phone-composer-landscape-keyboard-draft")

        toggle.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 2), "Closing the composer should hide its editor.")
        toggle.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, draft, "Reopening the composer must restore the exact draft.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        device.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, draft, "Foregrounding the app must preserve the draft.")
        XCTAssertTrue(app.buttons["terminal.composer.send"].isHittable)
        assertKeyboardClearance(composerControlElements(), state: "foreground-composer-keyboard-shown")
        XCTAssertEqual(field.value as? String, draft, "No action in this flow should submit the draft.")
        attachScreenshot(named: "phone-composer-foreground-draft-preserved")
    }

    func testAccessibilityTextSizeKeepsComposerLabeledCappedAndControlsReachable() {
        app.launchArguments += ["-terminal.composer.keyboardDismissHintShown", "NO"]
        launchSeededTerminal()
        let screen = app.otherElements["terminal.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))

        let toggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
        let standardField = app.textViews["terminal.composer.field"]
        XCTAssertTrue(standardField.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForStableHeight(of: standardField), "Standard-size empty editor height should settle.")
        let standardEmptyHeight = standardField.frame.height
        XCTAssertEqual(standardField.label, "Message", "The editor needs a stable explicit accessibility label.")

        app.terminate()
        setPreferredContentSizeCategory("UICTContentSizeCategoryAccessibilityXXXL")
        launchSeededTerminal()
        XCTAssertTrue(app.otherElements["terminal.screen"].waitForExistence(timeout: 5))
        let largeToggle = app.buttons["terminal.composer.toggle"]
        XCTAssertTrue(largeToggle.isHittable)
        largeToggle.tap()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForStableHeight(of: field), "Accessibility-size empty editor height should settle.")
        XCTAssertGreaterThan(
            field.frame.height,
            standardEmptyHeight + 1,
            "Accessibility XXXL must increase the empty editor's line height on the same simulator."
        )
        XCTAssertEqual(field.label, "Message", "The editor needs a stable explicit accessibility label.")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertKeyboardClearance(composerControlElements(), state: "accessibility-xxxl-keyboard-shown")
        field.typeText((1...12).map { "large text line \($0)" }.joined(separator: "\n"))
        let expectedDraft = (1...12).map { "large text line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(field.value as? String, expectedDraft, "The full draft should remain exposed when the editor is capped.")

        let composer = app.otherElements["terminal.composer.bounds"]
        let attachments = app.buttons["terminal.composer.attachments"]
        let mic = app.buttons["terminal.composer.mic"]
        let send = app.buttons["terminal.composer.send"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            field.frame.height,
            app.frame.height * 0.35 + 12,
            "The editor should stay within 35% of the phone viewport plus text-view insets."
        )
        XCTAssertGreaterThanOrEqual(field.frame.height, 44, "At least one editor line must remain visible.")
        XCTAssertLessThanOrEqual(field.frame.maxY, attachments.frame.minY)
        for control in [toggle, attachments, mic, send] {
            XCTAssertTrue(control.isHittable, "\(control.identifier) must remain reachable at accessibility XXXL.")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        field.swipeUp()
        XCTAssertEqual(field.value as? String, expectedDraft, "Scrolling the capped editor must preserve the entire draft.")
        XCTAssertTrue(send.isHittable)
        attachScreenshot(named: "phone-composer-accessibility-xxxl")


        let handle = app.descendants(matching: .any)["terminal.composer.keyboard-dismiss"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        XCTAssertTrue(handle.isHittable, "The dismiss handle must remain reachable at accessibility XXXL.")
        XCTAssertEqual(handle.label, "Keyboard")
        let dragStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 14)))
        let hiddenKeyboard = XCTNSPredicateExpectation(
            predicate: NSPredicate { [app] _, _ in
                guard let app else { return false }
                let keyboard = app.keyboards.firstMatch
                return !keyboard.exists || !keyboard.frame.intersects(app.frame)
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenKeyboard], timeout: 5), .completed)
        XCTAssertTrue(field.exists, "Hiding the keyboard must keep the large-text editor open.")
        XCTAssertEqual(field.value as? String, expectedDraft)
        field.tap()
        assertKeyboardClearance(composerControlElements(), state: "accessibility-xxxl-keyboard-restored")
        XCTAssertEqual(field.value as? String, expectedDraft, "Restoring the keyboard must preserve the full large-text draft.")
        attachScreenshot(named: "phone-composer-accessibility-xxxl-keyboard-restored")
    }

    func testSessionWindowAndPaneSheetsOpenAndCloseWithoutChangingTopology() {
        launchSeededTerminal()
        let panesButton = app.buttons["terminal.panes"]
        XCTAssertTrue(panesButton.waitForExistence(timeout: 5))
        let initialPaneLabel = panesButton.label

        let sessions = app.buttons["terminal.sessions"]
        XCTAssertTrue(sessions.isHittable)
        sessions.tap()
        let sessionsSheet = app.otherElements["terminal.sessions.sheet"]
        XCTAssertTrue(sessionsSheet.waitForExistence(timeout: 5))
        app.buttons["terminal.sessions.close"].tap()
        XCTAssertTrue(sessionsSheet.waitForNonExistence(timeout: 3))

        let windows = app.buttons["terminal.windows"]
        XCTAssertTrue(windows.isHittable)
        windows.tap()
        let windowsSheet = app.descendants(matching: .any)["terminal.windows.sheet"]
        XCTAssertTrue(windowsSheet.waitForExistence(timeout: 5))
        app.buttons["terminal.windows.close"].tap()
        XCTAssertTrue(windowsSheet.waitForNonExistence(timeout: 3))

        panesButton.tap()
        let panesSheet = app.descendants(matching: .any)["terminal.panes.sheet"]
        XCTAssertTrue(panesSheet.waitForExistence(timeout: 5))
        app.buttons["terminal.panes.close"].tap()
        XCTAssertTrue(panesSheet.waitForNonExistence(timeout: 3))
        XCTAssertEqual(panesButton.label, initialPaneLabel, "Opening and closing the picker must not create panes.")
        XCTAssertTrue(app.descendants(matching: .any)["terminal.input.ready"].waitForExistence(timeout: 5))
        attachScreenshot(named: "phone-session-window-pane-sheets-closed")
    }

    private func launchSeededTerminal() {
        app.launch()
        let session = app.descendants(matching: .any)["library.session.resume"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.buttons["terminal.toolbar-key.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["terminal.input.ready"].waitForExistence(timeout: 10))
        logPhoneConfiguration()
    }

    private func logPhoneConfiguration() {
        let requestedCategory: String
        if let index = app.launchArguments.firstIndex(of: "-UIPreferredContentSizeCategoryName"),
           app.launchArguments.indices.contains(index + 1) {
            requestedCategory = app.launchArguments[index + 1]
        } else {
            requestedCategory = "system-default"
        }
        print(
            "Phone UI test model=\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "physical-model-unavailable") "
                + "runnerOS=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "viewport=\(Int(app.frame.width))x\(Int(app.frame.height))pt "
                + "orientation=\(device.orientation.rawValue) "
                + "requestedCategory=\(requestedCategory)"
        )
    }

    private func setPreferredContentSizeCategory(_ category: String) {
        let argument = "-UIPreferredContentSizeCategoryName"
        var arguments = app.launchArguments
        if let index = arguments.firstIndex(of: argument) {
            let endIndex = min(index + 2, arguments.count)
            arguments.removeSubrange(index..<endIndex)
        }
        arguments.append(contentsOf: [argument, category])
        app.launchArguments = arguments
    }

    private func waitForStableHeight(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        var previousHeight: CGFloat?
        var stableSamples = 0
        let stable = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists else { return false }
                let currentHeight = element.frame.height
                guard currentHeight.isFinite, currentHeight > 0 else { return false }
                if let previousHeight, abs(currentHeight - previousHeight) <= 0.5 {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                }
                previousHeight = currentHeight
                return stableSamples >= 2
            },
            object: app
        )
        return XCTWaiter.wait(for: [stable], timeout: timeout) == .completed
    }

    private func showTerminalKeyboard(using screen: XCUIElement) {
        screen.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    private func assertControls(_ controls: [XCUIElement], in state: String) {
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing \(control.identifier) in \(state).")
            XCTAssertTrue(control.isHittable, "\(control.identifier) is not hittable in \(state).")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(control.identifier) is narrower than 44 pt in \(state).")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(control.identifier) is shorter than 44 pt in \(state).")
            XCTAssertTrue(app.frame.contains(control.frame), "\(control.identifier) is off-screen in \(state).")
        }
    }

    private func assertComposerControls(field: XCUIElement) {
        let controls = composerControlElements()
        for control in controls {
            XCTAssertTrue(control.isHittable, "\(control.identifier) must remain reachable after rotation.")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertLessThanOrEqual(field.frame.maxY, controls[0].frame.minY)
    }

    private func composerControlElements() -> [XCUIElement] {
        [
            app.buttons["terminal.composer.attachments"],
            app.buttons["terminal.composer.toggle"],
            app.buttons["terminal.composer.mic"],
            app.buttons["terminal.composer.send"],
        ]
    }

    private func assertKeyboardClearance(_ controls: [XCUIElement], state: String) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Software keyboard missing in \(state).")
        let keyboardFrame = keyboard.frame
        let appFrame = app.frame
        print(
            "Phone UI keyboard \(state): appFrame=\(Int(appFrame.minX)),\(Int(appFrame.minY)),\(Int(appFrame.width)),\(Int(appFrame.height))pt "
                + "keyboardFrame=\(Int(keyboardFrame.minX)),\(Int(keyboardFrame.minY)),\(Int(keyboardFrame.width)),\(Int(keyboardFrame.height))pt"
        )
        let keyboardIntersectsApp = appFrame.intersects(keyboardFrame)
        if !keyboardIntersectsApp {
            attachFullDisplayDiagnostic(named: "keyboard-offscreen-\(state)")
        }
        XCTAssertGreaterThan(keyboardFrame.height, 100, "Expected the software keyboard in \(state).")
        XCTAssertTrue(keyboardIntersectsApp, "Keyboard frame should intersect the app viewport in \(state).")
        for control in controls {
            XCTAssertTrue(control.isHittable, "\(control.identifier) must be hittable with the keyboard shown in \(state).")
            XCTAssertLessThanOrEqual(
                control.frame.maxY,
                keyboardFrame.minY + 1,
                "\(control.identifier) overlaps the software keyboard in \(state)."
            )
        }
    }

    private func dockControlElements() -> [XCUIElement] {
        [
            app.buttons["terminal.toolbar-key.0"],
            app.buttons["terminal.toolbar-key.1"],
            app.buttons["terminal.toolbar-key.2"],
            app.buttons["terminal.keyboard"],
            app.buttons["terminal.composer.toggle"],
            app.buttons["terminal.sessions"],
            app.buttons["terminal.windows"],
            app.buttons["terminal.panes"],
            app.buttons["terminal.home"],
        ]
    }

    private func waitForOrientation(_ orientation: UIDeviceOrientation) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "orientation == %d", orientation.rawValue),
            object: device
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        let layout = XCTNSPredicateExpectation(
            predicate: NSPredicate { [app] _, _ in
                guard let app else { return false }
                return orientation.isLandscape
                    ? app.frame.width > app.frame.height
                    : app.frame.height > app.frame.width
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed)
    }

    private func attachScreenshot(named name: String) {
        let appScreenshot = app.screenshot()
        let fullDisplayScreenshot = XCUIScreen.main.screenshot()
        print(
            "Phone UI screenshot \(name): appFrame=\(Int(app.frame.width))x\(Int(app.frame.height))pt "
                + "appImage=\(pixelSize(of: appScreenshot)) fullDisplayImage=\(pixelSize(of: fullDisplayScreenshot))"
        )

        let attachment = XCTAttachment(screenshot: appScreenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let fullDisplayAttachment = XCTAttachment(screenshot: fullDisplayScreenshot)
        fullDisplayAttachment.name = "\(name)-full-display"
        fullDisplayAttachment.lifetime = .keepAlways
        add(fullDisplayAttachment)
    }

    private func attachFullDisplayDiagnostic(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        print(
            "Phone UI diagnostic screenshot \(name): appFrame=\(Int(app.frame.width))x\(Int(app.frame.height))pt "
                + "fullDisplayImage=\(pixelSize(of: screenshot))"
        )
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pixelSize(of screenshot: XCUIScreenshot) -> String {
        if let image = screenshot.image.cgImage {
            return "\(image.width)x\(image.height)px"
        }
        let image = screenshot.image
        return "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))px"
    }
}
