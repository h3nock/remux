import UIKit
import XCTest
@testable import Remux

final class KeyboardShortcutCaptureTests: XCTestCase {
    func testNormalizesPrintableInputAndCombinedModifiers() throws {
        XCTAssertEqual(
            try KeyboardShortcutCapture.binding(
                input: "G",
                modifierFlags: [.command, .shift, .alternate]
            ),
            KeyboardKeyBinding(
                input: "g",
                modifiers: [.command, .shift, .option]
            )
        )
    }

    func testPreservesArrowInput() throws {
        XCTAssertEqual(
            try KeyboardShortcutCapture.binding(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.control]
            ),
            KeyboardKeyBinding(
                input: UIKeyCommand.inputLeftArrow,
                modifiers: [.control]
            )
        )
    }

    func testRejectsBareAndModifierOnlyKeys() {
        XCTAssertThrowsError(
            try KeyboardShortcutCapture.binding(input: "x", modifierFlags: [])
        )
        XCTAssertThrowsError(
            try KeyboardShortcutCapture.binding(input: "", modifierFlags: [.command])
        )
    }

    func testClearProducesUnassignedBinding() {
        XCTAssertNil(KeyboardShortcutCapture.clearedBinding())
    }
}
