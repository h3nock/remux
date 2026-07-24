import UIKit
import XCTest
@testable import Remux

final class GhosttyTerminalResponderViewTests: XCTestCase {
    @MainActor
    func testResponderReportsTextWhenEnabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        XCTAssertTrue(view.hasText)
    }

    @MainActor
    func testDeleteBackwardSendsBackspaceKeyEvent() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedEvent: GhosttySurfaceKeyEvent?

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: {
                receivedEvent = $0
                return true
            },
            onTrackpadStateChange: { _ in }
        )

        view.deleteBackward()

        XCTAssertEqual(receivedEvent, .init(keyCode: .backspace))
    }

    @MainActor
    func testInsertTextSendsRawTerminalInputWhenEnabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.insertText("hello")

        XCTAssertEqual(receivedText, ["hello"])
    }

    @MainActor
    func testReplaceTextSendsCommittedTerminalInputWhenEnabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.replace(view.selectedTextRange!, withText: "hello")

        XCTAssertEqual(receivedText, ["hello"])
    }

    @MainActor
    func testInsertTextIsIgnoredWhenDisabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.insertText("ignored")

        XCTAssertTrue(receivedText.isEmpty)
    }

    @MainActor
    func testReplaceTextIsIgnoredWhenDisabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.replace(view.selectedTextRange!, withText: "ignored")

        XCTAssertTrue(receivedText.isEmpty)
    }

    @MainActor
    func testPasteUsesPasteHandlerInsteadOfRawTextHandler() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var rawText: [String] = []
        var pastedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                rawText.append($0)
                return true
            },
            sendPaste: {
                pastedText.append($0)
                return true
            },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        UIPasteboard.general.string = "first\nsecond"
        view.paste(nil)

        XCTAssertTrue(rawText.isEmpty)
        XCTAssertEqual(pastedText, ["first\nsecond"])
    }

    @MainActor
    func testPasteIgnoresEmptyPasteboardString() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var pastedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: {
                pastedText.append($0)
                return true
            },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        UIPasteboard.general.string = ""
        view.paste(nil)

        XCTAssertTrue(pastedText.isEmpty)
    }

    func testHardwareCommandMappingResolvesBackspaceHIDUsage() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardDeleteOrBackspace,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .backspace))
        )
    }

    func testHardwareCommandMappingResolvesForwardDeleteHIDUsage() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardDeleteForward,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .delete))
        )
    }

    func testHardwareCommandMappingResolvesCoreNavigationHIDUsages() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardReturnOrEnter,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .enter))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardTab,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .tab))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardEscape,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .escape))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardUpArrow,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .arrowUp))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardRightArrow,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .arrowRight))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardHome,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .home))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardEnd,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .end))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardPageUp,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .pageUp))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardPageDown,
                modifiers: []
            ),
            .keyEvent(.init(keyCode: .pageDown))
        )
    }

    func testHardwareCommandMappingPreservesHIDModifiers() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardLeftArrow,
                modifiers: [.shift, .control]
            ),
            .keyEvent(.init(keyCode: .arrowLeft, mods: [.shift, .ctrl]))
        )
    }

    func testHardwarePressResolutionPrefersMappedHIDUsageOverPrintableText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardReturnOrEnter,
                modifiers: [],
                characters: "x",
                charactersIgnoringModifiers: "x"
            ),
            .keyEvent(.init(keyCode: .enter))
        )
    }

    func testHardwarePressResolutionUsesControlTextFromCharactersIgnoringModifiers() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardC,
                modifiers: .control,
                characters: "c",
                charactersIgnoringModifiers: "c"
            ),
            .text("\u{03}")
        )
    }

    func testHardwarePressResolutionUsesPrintableCharactersAfterUnmappedHID() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardA,
                modifiers: [],
                characters: "a",
                charactersIgnoringModifiers: "a"
            ),
            .text("a")
        )
    }

    func testHardwarePressResolutionRejectsCommandPrintableText() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardA,
                modifiers: .command,
                characters: "a",
                charactersIgnoringModifiers: "a"
            )
        )
    }

    func testHardwarePressResolutionRejectsControlPrintableTextWithoutControlTranslationInput() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardA,
                modifiers: .control,
                characters: "a",
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testHardwarePressResolutionReturnsNilForUnmappedEmptyPress() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardA,
                modifiers: [],
                characters: "",
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testHardwareCommandMappingRejectsUnmappedHIDUsageWithoutControlModifiers() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardA,
                modifiers: []
            )
        )
    }

    func testHardwareCommandMappingResolvesCtrlHardwareLetterToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardA,
                modifiers: .control,
                charactersIgnoringModifiers: "a"
            ),
            .text("\u{01}")
        )
    }

    func testHardwarePressResolutionResolvesControlPunctuationToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardOpenBracket,
                modifiers: .control,
                characters: "[",
                charactersIgnoringModifiers: "["
            ),
            .text("\u{1B}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardSpacebar,
                modifiers: .control,
                characters: " ",
                charactersIgnoringModifiers: " "
            ),
            .text("\u{00}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardHyphen,
                modifiers: .control,
                characters: "-",
                charactersIgnoringModifiers: "-"
            ),
            .text("\u{1F}")
        )
    }

    func testHardwareCommandMappingResolvesCommonControlCombosToText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardC,
                modifiers: .control,
                charactersIgnoringModifiers: "c"
            ),
            .text("\u{03}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardD,
                modifiers: .control,
                charactersIgnoringModifiers: "d"
            ),
            .text("\u{04}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardL,
                modifiers: .control,
                charactersIgnoringModifiers: "l"
            ),
            .text("\u{0C}")
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardZ,
                modifiers: .control,
                charactersIgnoringModifiers: "z"
            ),
            .text("\u{1A}")
        )
    }

    func testHardwareCommandMappingRejectsControlTextWhenCommandIsHeld() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(
                keyCode: .keyboardC,
                modifiers: [.command, .control],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testHardwareCommandMappingResolvesPrintableHardwareText() {
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "a",
                modifiers: []
            ),
            "a"
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "A",
                modifiers: .shift
            ),
            "A"
        )
    }

    func testHardwareCommandMappingDoesNotTurnShortcutsIntoPrintableText() {
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "c",
                modifiers: .command
            )
        )
        XCTAssertNil(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareText(
                characters: "c",
                modifiers: .control
            )
        )
    }

    func testTerminalInputNormalizerMapsLinefeedToCarriageReturn() {
        XCTAssertEqual(
            GhosttyTerminalInputNormalizer.normalize("echo hello\n"),
            "echo hello\r"
        )
    }

    func testTerminalInputNormalizerPreservesExistingCarriageReturn() {
        XCTAssertEqual(
            GhosttyTerminalInputNormalizer.normalize("echo hello\r"),
            "echo hello\r"
        )
    }

    @MainActor
    func testResponderRequestsFirstResponderWhenInputBecomesEnabledWithSameActivationToken() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 7,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 7,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        let becameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(becameFirstResponder)
    }

    @MainActor
    func testResponderDefersBecomeWhenWanted() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: true,
            wantsFirstResponder: false,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertFalse(view.isFirstResponder)

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        XCTAssertFalse(view.isFirstResponder)
        let becameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(becameFirstResponder)
    }

    @MainActor
    func testResponderReportsActualFirstResponderTransitions() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        var reportedStates: [Bool] = []
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 9,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in },
            onFirstResponderChange: { reportedStates.append($0) }
        )

        let becameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(becameFirstResponder)
        XCTAssertEqual(reportedStates.last, true)

        XCTAssertTrue(view.resignFirstResponder())
        let resignedFirstResponder = await waitUntil { !view.isFirstResponder }
        XCTAssertTrue(resignedFirstResponder)
        XCTAssertEqual(reportedStates.suffix(2), [true, false])
    }

    @MainActor
    func testResponderRecoversFirstResponderWhenStillEnabledWithSameActivationToken() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )
        let initiallyBecameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(initiallyBecameFirstResponder)

        XCTAssertTrue(view.resignFirstResponder())
        let didResignFirstResponder = await waitUntil { !view.isFirstResponder }
        XCTAssertTrue(didResignFirstResponder)

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        let recoveredFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(recoveredFirstResponder)
    }

    @MainActor
    func testResponderDefersResignWhenNoLongerWanted() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            _ = view.resignFirstResponder()
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )
        let initiallyBecameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(initiallyBecameFirstResponder)

        view.update(
            isEnabled: true,
            wantsFirstResponder: false,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        XCTAssertTrue(view.isFirstResponder)
        let didResignFirstResponder = await waitUntil { !view.isFirstResponder }
        XCTAssertTrue(didResignFirstResponder)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    func testResponderRejectsTextEditMenuActionsAfterUITextInputConformance() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        XCTAssertFalse(
            view.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil)
        )
        XCTAssertFalse(
            view.canPerformAction(#selector(UIResponderStandardEditActions.select(_:)), withSender: nil)
        )
        XCTAssertFalse(
            view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
        )
        XCTAssertFalse(
            view.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil)
        )
    }

    @MainActor
    func testResponderProvidesNonNilUITextInputDocumentEndpoints() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        XCTAssertNotNil(view.beginningOfDocument)
        XCTAssertNotNil(view.endOfDocument)
        XCTAssertNotNil(view.selectedTextRange)
        XCTAssertNil(view.markedTextRange)
        let position = view.position(from: view.beginningOfDocument, offset: 0)
        XCTAssertNotNil(position, "tokenizer requires non-nil position for offset 0")
    }

    @MainActor
    func testFloatingCursorSweepEmitsArrowRightKeyEvents() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedEvents: [GhosttySurfaceKeyEvent] = []
        var receivedHUDStates: [GhosttyKeyboardCursorTrackpad.HUDState] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { event in
                receivedEvents.append(event)
                return true
            },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )

        view.beginFloatingCursor(at: .init(x: 0, y: 0))
        // Cross the lock deadband so the trackpad commits to the horizontal axis.
        view.updateFloatingCursor(at: .init(x: 18, y: 0))
        // After lock, the next horizontal travel above the per-step threshold
        // should produce one or more arrow-right key events.
        view.updateFloatingCursor(at: .init(x: 38, y: 0))
        view.endFloatingCursor()

        XCTAssertFalse(receivedEvents.isEmpty)
        XCTAssertTrue(receivedEvents.allSatisfy { $0.keyCode == .arrowRight })
        XCTAssertEqual(receivedHUDStates.first?.isVisible, true)
        XCTAssertEqual(receivedHUDStates.last, .hidden)
    }

    @MainActor
    func testResignFirstResponderClearsTrackpadHUDDuringActiveGesture() async {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        var receivedHUDStates: [GhosttyKeyboardCursorTrackpad.HUDState] = []
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )
        _ = await waitUntil { view.isFirstResponder }

        view.beginFloatingCursor(at: .init(x: 0, y: 0))
        view.updateFloatingCursor(at: .init(x: 18, y: 0))
        XCTAssertTrue(receivedHUDStates.contains { $0.isVisible })

        _ = view.resignFirstResponder()

        XCTAssertEqual(receivedHUDStates.last, .hidden)
    }

    @MainActor
    func testRemovingResponderFromWindowDuringTrackpadGestureClearsHUD() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(view)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        var receivedHUDStates: [GhosttyKeyboardCursorTrackpad.HUDState] = []
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )

        view.beginFloatingCursor(at: .init(x: 0, y: 0))
        view.updateFloatingCursor(at: .init(x: 18, y: 0))
        XCTAssertTrue(receivedHUDStates.contains { $0.isVisible })

        // SwiftUI representable removal flows through removeFromSuperview ->
        // didMoveToWindow with window == nil. The HUD must reset to hidden so
        // the parent SwiftUI state doesn't strand.
        view.removeFromSuperview()

        XCTAssertEqual(receivedHUDStates.last, .hidden)
    }

    @MainActor
    func testDismantleRepresentableDuringTrackpadGestureClearsHUD() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedHUDStates: [GhosttyKeyboardCursorTrackpad.HUDState] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )

        view.beginFloatingCursor(at: .init(x: 0, y: 0))
        view.updateFloatingCursor(at: .init(x: 18, y: 0))

        GhosttyTerminalResponderRepresentable.dismantleUIView(view, coordinator: ())

        XCTAssertEqual(receivedHUDStates.last, .hidden)
    }

    @MainActor
    func testDisablingResponderDuringTrackpadGestureClearsHUD() {
        let driver = GhosttyKeyboardCursorTrackpadDriver()
        let view = GhosttyTerminalResponderUIView(trackpadDriver: driver)
        var receivedHUDStates: [GhosttyKeyboardCursorTrackpad.HUDState] = []
        var receivedEvents: [GhosttySurfaceKeyEvent] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: {
                receivedEvents.append($0)
                return true
            },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )

        view.beginFloatingCursor(at: .init(x: 0, y: 0))
        view.updateFloatingCursor(at: .init(x: 18, y: 0))
        view.updateFloatingCursor(at: .init(x: 28, y: 0))
        XCTAssertTrue(driver.isRepeatScheduled)

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { state in
                receivedHUDStates.append(state)
            }
        )

        XCTAssertEqual(receivedHUDStates.last, .hidden)
        XCTAssertFalse(driver.isRepeatScheduled)
        let eventCountAfterDisable = receivedEvents.count
        driver.repeatTick(at: .greatestFiniteMagnitude)
        XCTAssertEqual(receivedEvents.count, eventCountAfterDisable)
    }

    // MARK: - Marked text (IME composing)

    @MainActor
    func testSetMarkedTextStoresComposingRegionAndExposesMarkedTextRange() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0))

        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(view.text(in: view.markedTextRange!), "pin")
    }

    @MainActor
    func testSetMarkedTextWithNilClearsComposingRegion() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)

        view.setMarkedText(nil, selectedRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testUnmarkTextCommitsStoredMarkedTextToTerminal() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        // Simulate CJK IME: setMarkedText with the selected character, then unmarkText.
        view.setMarkedText("\u{4e2d}", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText()

        XCTAssertEqual(receivedText, ["\u{4e2d}"])
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testUnmarkTextWithNoMarkedTextDoesNotSendToTerminal() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.unmarkText()

        XCTAssertTrue(receivedText.isEmpty)
    }

    @MainActor
    func testInsertTextClearsActiveMarkedTextAndSendsCommittedCharacter() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        // Simulate IME path where insertText arrives while composing.
        view.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0))
        view.insertText("\u{62fc}")

        XCTAssertEqual(receivedText, ["\u{62fc}"])
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testDeleteBackwardDuringComposingClearsMarkedTextWithoutSendingBackspace() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []
        var receivedEvent: GhosttySurfaceKeyEvent?

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: {
                receivedEvent = $0
                return true
            },
            onTrackpadStateChange: { _ in }
        )

        view.setMarkedText("zh", selectedRange: NSRange(location: 2, length: 0))
        view.deleteBackward()

        XCTAssertNil(view.markedTextRange)
        XCTAssertTrue(receivedText.isEmpty)
        XCTAssertNil(receivedEvent)
    }

    @MainActor
    func testReplaceTextDuringComposingClearsMarkedTextAndSendsReplacement() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedText: [String] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                receivedText.append($0)
                return true
            },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        view.setMarkedText("wen", selectedRange: NSRange(location: 3, length: 0))
        view.replace(view.markedTextRange!, withText: "\u{6587}")

        XCTAssertEqual(receivedText, ["\u{6587}"])
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testMarkedTextRangeIsNilWithNoComposingText() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testEndOfDocumentReflectsMarkedTextLength() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadStateChange: { _ in }
        )

        let endBefore = view.endOfDocument as! GhosttyVirtualTextPosition
        XCTAssertEqual(endBefore.offset, 0)

        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))

        let endDuring = view.endOfDocument as! GhosttyVirtualTextPosition
        XCTAssertEqual(endDuring.offset, 5)

        view.unmarkText()

        let endAfter = view.endOfDocument as! GhosttyVirtualTextPosition
        XCTAssertEqual(endAfter.offset, 0)
    }
}
