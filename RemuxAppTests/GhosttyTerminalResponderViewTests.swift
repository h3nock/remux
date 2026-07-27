import UIKit
import XCTest
@testable import Remux

final class GhosttyTerminalResponderViewTests: XCTestCase {
    @MainActor
    func testResponderPublishesPriorityAppKeyCommandsAndDispatchesSelection() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())
        var receivedCommands: [AppKeyboardCommand] = []

        view.update(
            isEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            keyboardSettings: .default,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true },
            onAppKeyboardCommand: {
                receivedCommands.append($0)
            }
        )

        let commands = view.keyCommands ?? []
        XCTAssertEqual(commands.count, AppKeyboardCommand.allCases.count)
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))

        let home = try! XCTUnwrap(commands.first { $0.input == "h" })
        view.perform(home.action, with: home)
        XCTAssertEqual(receivedCommands, [.home])
    }

    @MainActor
    func testResponderPublishesAppCommandsWithoutAcceptingTerminalText() {
        let view = GhosttyTerminalResponderUIView(trackpadDriver: GhosttyKeyboardCursorTrackpadDriver())

        view.update(
            isEnabled: false,
            areAppKeyboardCommandsEnabled: true,
            wantsFirstResponder: true,
            activationToken: 1,
            keyboardSettings: .default,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        XCTAssertFalse(view.hasText)
        XCTAssertEqual(view.keyCommands?.count, AppKeyboardCommand.allCases.count)
    }

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
    func testCommandOnlyResponderBecomesFirstResponderWithoutAcceptingText() async {
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
            areAppKeyboardCommandsEnabled: true,
            wantsFirstResponder: true,
            activationToken: 7,
            keyboardSettings: .default,
            sendText: { _ in true },
            sendPaste: { _ in true },
            sendKeyEvent: { _ in true }
        )

        let becameFirstResponder = await waitUntil { view.isFirstResponder }
        XCTAssertTrue(becameFirstResponder)
        XCTAssertFalse(view.hasText)
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
}
