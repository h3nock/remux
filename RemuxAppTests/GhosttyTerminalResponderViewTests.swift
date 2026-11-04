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
            sendKeyEvent: { _ in true }
        )

        XCTAssertTrue(view.hasText)
    }

    @MainActor
    func testDeleteBackwardSendsBackspaceKeyEvent() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
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
            }
        )

        view.deleteBackward()

        XCTAssertEqual(receivedEvents, [.init(keyCode: .backspace)])
    }

    @MainActor
    func testDeleteBackwardIsIgnoredWhenDisabled() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedEvents: [GhosttySurfaceKeyEvent] = []

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: {
                receivedEvents.append($0)
                return true
            }
        )

        view.deleteBackward()

        XCTAssertTrue(receivedEvents.isEmpty)
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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

    /// A hardware F1 to F12 or Insert is that key, with its modifiers, never the name UIKit gives it as text.
    func testHardwareCommandMappingResolvesFunctionKeysAndInsert() {
        let usages: [UIKeyboardHIDUsage] = [
            .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
            .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
        ]
        for (usage, code) in zip(usages, GhosttySurfaceKeyEvent.KeyCode.functionKeys) {
            XCTAssertEqual(
                GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(keyCode: usage, modifiers: []),
                .keyEvent(.init(keyCode: code)),
                "HID usage \(usage.rawValue)"
            )
        }
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwareKey(keyCode: .keyboardInsert, modifiers: []),
            .keyEvent(.init(keyCode: .insert))
        )
        XCTAssertEqual(
            GhosttyTerminalHardwareCommandMapping.resolveHardwarePress(
                keyCode: .keyboardF5,
                modifiers: [.shift],
                characters: "UIKeyInputF5",
                charactersIgnoringModifiers: "UIKeyInputF5"
            ),
            .keyEvent(.init(keyCode: .f5, mods: [.shift]))
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
            sendKeyEvent: { _ in true }
        )
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 7,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
        )

        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertFalse(view.isFirstResponder)

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
        )
        let initiallyBecameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(initiallyBecameFirstResponder)

        view.update(
            isEnabled: true,
            wantsFirstResponder: false,
            activationToken: 3,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
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
            sendKeyEvent: { _ in true }
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
    func testResponderProvidesCoherentVirtualTextDocument() throws {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        let beginning = try XCTUnwrap(
            view.beginningOfDocument as? GhosttyVirtualTextPosition
        )
        let end = try XCTUnwrap(
            view.endOfDocument as? GhosttyVirtualTextPosition
        )
        let selection = try XCTUnwrap(
            view.selectedTextRange as? GhosttyVirtualTextRange
        )
        let document = try XCTUnwrap(
            view.textRange(from: beginning, to: end)
        )

        XCTAssertEqual(beginning.offset, 0)
        XCTAssertEqual(end.offset, 1)
        XCTAssertEqual(selection.from.offset, 1)
        XCTAssertEqual(selection.to.offset, 1)
        XCTAssertEqual(view.text(in: document), " ")
        XCTAssertEqual(view.text(in: selection), "")
        XCTAssertNil(view.markedTextRange)
        let position = view.position(from: beginning, offset: 0)
        XCTAssertNotNil(position, "tokenizer requires non-nil position for offset 0")
    }

    @MainActor
    func testFloatingCursorCrossingFirstTierEmitsArrowAndPublishesTier() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedEvents: [GhosttySurfaceKeyEvent] = []
        var feedback: [GhosttyKeyboardCursorTrackpad.FeedbackState] = []

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
            onTrackpadFeedbackChange: { feedback.append($0) }
        )

        view.beginFloatingCursor(at: .zero)
        view.updateFloatingCursor(at: .init(x: 36, y: 0))
        view.endFloatingCursor()

        XCTAssertEqual(receivedEvents.map(\.keyCode), [.arrowRight])
        XCTAssertEqual(feedback, [
            .active,
            .init(
                isVisible: true,
                direction: .right,
                committedTier: .one,
                armingTier: nil,
                armingProgress: 0
            ),
            .hidden,
        ])
    }

    @MainActor
    func testFloatingCursorPartialArmingSendsNothing() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedEvents: [GhosttySurfaceKeyEvent] = []
        var feedback: [GhosttyKeyboardCursorTrackpad.FeedbackState] = []

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
            onTrackpadFeedbackChange: { feedback.append($0) }
        )

        view.beginFloatingCursor(at: .zero)
        view.updateFloatingCursor(at: .init(x: 22, y: 0))
        view.endFloatingCursor()

        XCTAssertTrue(receivedEvents.isEmpty)
        XCTAssertEqual(feedback, [
            .active,
            .init(
                isVisible: true,
                direction: .right,
                committedTier: .neutral,
                armingTier: .one,
                armingProgress: 0.5
            ),
            .hidden,
        ])
    }

    @MainActor
    func testDisablingResponderCancelsActiveTrackpadGesture() {
        let driver = GhosttyKeyboardCursorTrackpadDriver()
        let view = GhosttyTerminalResponderUIView(trackpadDriver: driver)
        var receivedEvents: [GhosttySurfaceKeyEvent] = []
        var feedback: [GhosttyKeyboardCursorTrackpad.FeedbackState] = []

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
            onTrackpadFeedbackChange: { feedback.append($0) }
        )

        view.beginFloatingCursor(at: .zero)
        view.updateFloatingCursor(at: .init(x: 36, y: 0))
        let eventCountBeforeDisable = receivedEvents.count

        view.update(
            isEnabled: false,
            wantsFirstResponder: false,
            activationToken: 1,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onTrackpadFeedbackChange: { feedback.append($0) }
        )

        XCTAssertEqual(feedback.last, .hidden)
        driver.repeatTick(at: .greatestFiniteMagnitude)
        XCTAssertEqual(receivedEvents.count, eventCountBeforeDisable)
    }

    // MARK: - Composition

    /// Input the responder sends, in order: committed and finished text, pastes and keys.
    @MainActor
    private final class Sent {
        var items: [String] = []
    }

    @MainActor
    private func composingView(_ sent: Sent) -> GhosttyTerminalResponderUIView {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                sent.items.append("text:" + $0)
                return true
            },
            sendFinishedText: {
                sent.items.append("finished:" + $0)
                return true
            },
            sendPaste: {
                sent.items.append("paste:" + $0)
                return true
            },
            sendKeyEvent: {
                sent.items.append($0.keyCode == .backspace ? "key:backspace" : "key:\($0.keyCode.rawValue)")
                return true
            }
        )
        return view
    }

    @MainActor
    private final class RecordingInputDelegate: NSObject, UITextInputDelegate {
        var calls: [String] = []
        func selectionWillChange(_ textInput: UITextInput?) { calls.append("selectionWillChange") }
        func selectionDidChange(_ textInput: UITextInput?) { calls.append("selectionDidChange") }
        func textWillChange(_ textInput: UITextInput?) { calls.append("textWillChange") }
        func textDidChange(_ textInput: UITextInput?) { calls.append("textDidChange") }
        @available(iOS 18.4, *)
        func conversationContext(_ context: UIConversationContext?, didChange textInput: UITextInput?) {}
    }

    @MainActor
    func testMarkedTextStaysLocalUntilTheKeyboardCommitsItOnce() throws {
        let sent = Sent()
        let view = composingView(sent)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.setMarkedText("ni\u{2006}hao", selectedRange: NSRange(location: 6, length: 0))

        let marked = try XCTUnwrap(view.markedTextRange)
        XCTAssertEqual(view.text(in: marked), "ni\u{2006}hao")
        XCTAssertTrue(sent.items.isEmpty)

        view.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        view.unmarkText()

        XCTAssertEqual(sent.items, ["text:你好"])
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testInsertTextReplacesTheCompositionAndIdleInsertsGoStraightThrough() {
        let sent = Sent()
        let view = composingView(sent)

        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        view.insertText("nihao")
        // Korean revises a syllable with an unmarked Backspace and insert.
        view.insertText("가")
        view.deleteBackward()
        view.insertText("간")

        XCTAssertEqual(sent.items, ["text:nihao", "text:가", "key:backspace", "text:간"])
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testKeyboardDeleteEditsTheCompositionWithoutTerminalBackspace() throws {
        let sent = Sent()
        let view = composingView(sent)

        view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0))
        view.deleteBackward()

        XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "ni")
        view.deleteBackward()
        view.deleteBackward()
        XCTAssertNil(view.markedTextRange)
        XCTAssertTrue(sent.items.isEmpty)

        view.deleteBackward()
        XCTAssertEqual(sent.items, ["key:backspace"])
    }

    @MainActor
    func testCompositionDocumentKeepsUTF16RangesAndTheIdlePlaceholder() throws {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        view.update(isEnabled: true, wantsFirstResponder: true, activationToken: 1,
                    sendText: { _ in true }, sendPaste: { _ in true }, sendKeyEvent: { _ in true })

        view.setMarkedText("日本😀", selectedRange: NSRange(location: 2, length: 0))

        let marked = try XCTUnwrap(view.markedTextRange as? GhosttyVirtualTextRange)
        XCTAssertEqual(marked.nsRange, NSRange(location: 1, length: 4))
        let selection = try XCTUnwrap(view.selectedTextRange as? GhosttyVirtualTextRange)
        XCTAssertEqual(selection.nsRange, NSRange(location: 3, length: 0))
        XCTAssertEqual((view.endOfDocument as? GhosttyVirtualTextPosition)?.offset, 5)

        // The keyboard moves the caret inside the composition, never outside it.
        view.selectedTextRange = GhosttyVirtualTextRange(NSRange(location: 1, length: 0))
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 1, length: 0))
        view.selectedTextRange = GhosttyVirtualTextRange(NSRange(location: 0, length: 0))
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 1, length: 0))

        // A replacement inside the composition edits it.
        view.replace(GhosttyVirtualTextRange(NSRange(location: 1, length: 2)), withText: "にほん")
        XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "にほん😀")

        view.setMarkedText(nil, selectedRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(view.text(in: GhosttyVirtualTextRange(NSRange(location: 0, length: 1))), " ")
        XCTAssertNil(view.text(in: GhosttyVirtualTextRange(NSRange(location: 0, length: 2))))
    }

    @MainActor
    func testAppActionsSettleTheDraftAndSynchronizeTheKeyboard() {
        let sent = Sent()
        let view = composingView(sent)
        let delegate = RecordingInputDelegate()
        view.inputDelegate = delegate
        let notified = ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"]

        // Keyboard edits never notify.
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(delegate.calls.isEmpty)

        XCTAssertEqual(view.resolveComposition(for: .finish(preservingModifiers: true)), .finished)
        XCTAssertEqual(sent.items, ["finished:ni"])
        XCTAssertEqual(delegate.calls, notified)

        // Nothing typed since: nothing to synchronize.
        delegate.calls.removeAll()
        XCTAssertEqual(view.resolveComposition(for: .finish(preservingModifiers: false)), .noDraft)
        XCTAssertTrue(delegate.calls.isEmpty)

        // Korean's assembly leaves context without a draft; an app action ends it.
        view.insertText("간")
        XCTAssertEqual(view.resolveComposition(for: .cancel), .noDraft)
        XCTAssertEqual(delegate.calls, notified)

        delegate.calls.removeAll()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(view.resolveComposition(for: .finish(preservingModifiers: false)), .finished)
        view.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(view.resolveComposition(for: .cancel), .canceled)
        XCTAssertNil(view.markedTextRange)

        XCTAssertEqual(sent.items, ["finished:ni", "text:간", "text:ni"])
        XCTAssertEqual(delegate.calls, notified + notified)
    }

    @MainActor
    func testToolbarDeletesLeaveTheDraftAndTheKeyboardAlone() throws {
        let sent = Sent()
        let view = composingView(sent)
        let delegate = RecordingInputDelegate()
        view.inputDelegate = delegate

        view.setMarkedText("ni\u{2006}hao", selectedRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(view.resolveComposition(for: .delete), .kept)
        XCTAssertEqual(view.resolveComposition(for: .delete), .kept)

        XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "ni\u{2006}hao")
        XCTAssertTrue(sent.items.isEmpty)
        XCTAssertTrue(delegate.calls.isEmpty)

        // The keyboard goes on composing from its own buffer, and commits once.
        view.setMarkedText("ni\u{2006}hao\u{2006}o", selectedRange: NSRange(location: 8, length: 0))
        view.insertText("nihaoo")
        XCTAssertEqual(sent.items, ["text:nihaoo"])

        // With no draft, a delete key is the terminal's, after the keyboard's context is synchronized.
        view.insertText("간")
        XCTAssertEqual(view.resolveComposition(for: .delete), .noDraft)
        XCTAssertEqual(delegate.calls.count, 4)
    }

    @MainActor
    func testPasteCancelsTheDraftAndPastesOnce() {
        let sent = Sent()
        let view = composingView(sent)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        UIPasteboard.general.string = "PASTE"
        view.paste(nil)

        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(sent.items, ["paste:PASTE"])
    }

    @MainActor
    func testDisablingInputCancelsTheDraftWithoutSendingIt() {
        let sent = Sent()
        let view = composingView(sent)
        view.update(isEnabled: true, wantsFirstResponder: true, activationToken: 1,
                    sendText: { _ in true }, sendPaste: { _ in true }, sendKeyEvent: { _ in true })
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))

        view.update(isEnabled: false, wantsFirstResponder: false, activationToken: 1,
                    sendText: {
                        sent.items.append("text:" + $0)
                        return true
                    }, sendPaste: { _ in true }, sendKeyEvent: { _ in true })

        XCTAssertNil(view.markedTextRange)
        view.unmarkText()
        XCTAssertTrue(sent.items.isEmpty)
    }

    // MARK: - Typed text

    /// The line a terminal shows after `items`: text is typed at its caret, and each Backspace
    /// erases the character before it.
    private func terminalLine(_ items: [String]) -> String {
        var line: [Character] = []
        for item in items {
            if item == "key:backspace" {
                if !line.isEmpty { line.removeLast() }
            } else if item.hasPrefix("text:") {
                line.append(contentsOf: item.dropFirst("text:".count))
            }
        }
        return String(line)
    }

    @MainActor
    private func typedRange(_ location: Int, _ length: Int) -> GhosttyVirtualTextRange {
        GhosttyVirtualTextRange(NSRange(location: location, length: length))
    }

    @MainActor
    func testDictationRevisesItsTypedTextInTheTerminal() throws {
        let sent = Sent()
        let view = composingView(sent)

        // The calls an iPhone made dictating "hello world this is a test": a first guess, revisions
        // of the whole guess up to the caret, then on stopping an empty replacement and the result.
        view.insertText("Hell")
        XCTAssertEqual(view.text(in: typedRange(0, 5)), " Hell")
        view.replace(typedRange(1, 4), withText: "Hello")
        view.replace(typedRange(1, 5), withText: "hello, this is")
        view.replace(typedRange(1, 14), withText: "hello, this is a")
        view.replace(typedRange(1, 16), withText: "hello, this is a test")
        view.replace(typedRange(1, 21), withText: "")
        view.insertText("hello, this is a test")

        // Only the part that changed is erased and retyped.
        XCTAssertEqual(
            sent.items,
            ["text:Hell", "text:o"]
                + Array(repeating: "key:backspace", count: 5) + ["text:hello, this is", "text: a", "text: test"]
                + Array(repeating: "key:backspace", count: 21) + ["text:hello, this is a test"]
        )
        XCTAssertEqual(terminalLine(sent.items), "hello, this is a test")
        XCTAssertEqual(view.text(in: typedRange(0, 22)), " hello, this is a test")
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 22, length: 0))

        // A second dictation in the same line goes on from the caret.
        view.insertText(" wor")
        view.replace(typedRange(22, 4), withText: " world")
        view.replace(typedRange(22, 6), withText: "")
        view.insertText(" world")
        XCTAssertEqual(terminalLine(sent.items), "hello, this is a test world")
        XCTAssertNil(view.markedTextRange)
    }

    @MainActor
    func testKeyboardSelectionsInTypedTextAreEditedInTheTerminal() {
        let sent = Sent()
        let view = composingView(sent)

        // Before a Backspace the keyboard can select what it deletes.
        view.insertText("spacinf t")
        view.selectedTextRange = typedRange(9, 1)
        view.deleteBackward()
        XCTAssertEqual(sent.items.suffix(1), ["key:backspace"])
        XCTAssertEqual(view.text(in: typedRange(0, 9)), " spacinf ")
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 9, length: 0))

        // A selection before the end is erased back to its start, and what followed it is retyped.
        view.selectedTextRange = typedRange(7, 1)
        view.deleteBackward()
        view.insertText("g")
        XCTAssertEqual(terminalLine(sent.items), "spacing ")
        XCTAssertEqual(view.text(in: typedRange(0, 9)), " spacing ")

        // The caret never moves into the placeholder.
        view.selectedTextRange = typedRange(0, 1)
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 8, length: 0))
    }

    @MainActor
    func testBackspaceGoesOnPastTheTypedText() {
        let sent = Sent()
        let view = composingView(sent)

        view.insertText("ab")
        view.deleteBackward()
        view.deleteBackward()
        XCTAssertEqual(view.text(in: typedRange(0, 1)), " ")
        XCTAssertEqual((view.selectedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 1, length: 0))

        // Past the typed text the terminal deletes what came before, and the placeholder stays.
        view.deleteBackward()
        view.deleteBackward()
        XCTAssertEqual(sent.items, ["text:ab"] + Array(repeating: "key:backspace", count: 4))
        XCTAssertEqual(view.text(in: typedRange(0, 1)), " ")
        XCTAssertNil(view.text(in: typedRange(0, 2)))
    }

    @MainActor
    func testBackspaceWithTheCaretBeforeTypedTextEndsTheContext() {
        let sent = Sent()
        let view = composingView(sent)
        let delegate = RecordingInputDelegate()
        view.inputDelegate = delegate

        // The terminal's caret stays after the typed text, so its Backspace deletes text the
        // document still holds.
        view.insertText("ab")
        view.selectedTextRange = typedRange(1, 0)
        view.deleteBackward()

        XCTAssertEqual(sent.items, ["text:ab", "key:backspace"])
        XCTAssertNil(view.text(in: typedRange(0, 2)))
        XCTAssertEqual(delegate.calls.count, 4)
    }

    @MainActor
    func testTypedTextEndsAtReturnAnArmedModifierAndUndeliveredInput() {
        let sent = Sent()
        var modifierArmed = false
        var delivers = true
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        let delegate = RecordingInputDelegate()
        view.inputDelegate = delegate
        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            sendText: {
                sent.items.append("text:" + $0)
                return delivers
            },
            sendPaste: { _ in true },
            sendKeyEvent: {
                sent.items.append($0.keyCode == .backspace ? "key:backspace" : "key:\($0.keyCode.rawValue)")
                return delivers
            },
            isModifierArmed: { modifierArmed }
        )
        let notified = ["textWillChange", "selectionWillChange", "selectionDidChange", "textDidChange"]

        view.insertText("ls")
        view.insertText("\n")
        XCTAssertEqual(view.text(in: typedRange(0, 1)), " ")
        XCTAssertNil(view.text(in: typedRange(0, 2)))
        XCTAssertEqual(delegate.calls, notified)

        // Text an armed modifier turns into a key isn't kept for the keyboard to revise.
        delegate.calls.removeAll()
        modifierArmed = true
        view.insertText("c")
        modifierArmed = false
        XCTAssertNil(view.text(in: typedRange(0, 2)))
        XCTAssertEqual(delegate.calls, notified)
        view.deleteBackward()
        XCTAssertEqual(sent.items, ["text:ls", "text:\n", "text:c", "key:backspace"])

        // What the terminal holds after a refused send is unknown, so nothing is kept.
        delegate.calls.removeAll()
        delivers = false
        view.insertText("x")
        XCTAssertNil(view.text(in: typedRange(0, 2)))
        XCTAssertEqual(delegate.calls, notified)
    }

    @MainActor
    func testAppActionsDisabledInputAndCapacityEndTheTypedText() {
        let sent = Sent()
        let view = composingView(sent)
        let delegate = RecordingInputDelegate()
        view.inputDelegate = delegate

        view.insertText("abc")
        XCTAssertEqual(view.resolveComposition(for: .finish(preservingModifiers: true)), .noDraft)
        XCTAssertNil(view.text(in: typedRange(0, 2)))
        XCTAssertEqual(delegate.calls.count, 4)

        view.insertText("abc")
        view.update(isEnabled: false, wantsFirstResponder: false, activationToken: 1,
                    sendText: { _ in true }, sendPaste: { _ in true }, sendKeyEvent: { _ in true })
        XCTAssertNil(view.text(in: typedRange(0, 2)))

        view.update(isEnabled: true, wantsFirstResponder: true, activationToken: 1,
                    sendText: { _ in true }, sendPaste: { _ in true }, sendKeyEvent: { _ in true })
        view.insertText(String(repeating: "a", count: GhosttyTerminalCompositionDocument.typedCapacity + 1))
        XCTAssertNil(view.text(in: typedRange(0, 2)))
    }

    @MainActor
    func testADraftAfterTypedTextLeavesItTypedUntilTheDraftCommits() throws {
        let sent = Sent()
        let view = composingView(sent)

        view.insertText("ab")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual((view.markedTextRange as? GhosttyVirtualTextRange)?.nsRange, NSRange(location: 3, length: 2))

        // Emptying the draft leaves the typed text, which the next Backspace deletes in the terminal.
        view.deleteBackward()
        view.deleteBackward()
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(view.text(in: typedRange(0, 3)), " ab")
        view.deleteBackward()
        XCTAssertEqual(sent.items, ["text:ab", "key:backspace"])

        // A commit ends the keyboard's context.
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        XCTAssertEqual(sent.items, ["text:ab", "key:backspace", "text:ni"])
        XCTAssertNil(view.text(in: typedRange(0, 2)))
    }

    @MainActor
    func testTerminalResponderOffersNoInlinePredictions() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        XCTAssertEqual(view.inlinePredictionType, .no)
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.keyboardType, .default)
    }
}
