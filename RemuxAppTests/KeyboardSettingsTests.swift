import UIKit
import XCTest
@testable import Remux

final class KeyboardSettingsTests: XCTestCase {
    func testDefaultsAssignEveryDocumentedCommand() {
        let settings = KeyboardSettings.default

        XCTAssertEqual(
            settings.binding(for: .previousWindow),
            KeyboardKeyBinding(input: UIKeyCommand.inputLeftArrow, modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .nextWindow),
            KeyboardKeyBinding(input: UIKeyCommand.inputRightArrow, modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .previousSession),
            KeyboardKeyBinding(input: UIKeyCommand.inputLeftArrow, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            settings.binding(for: .nextSession),
            KeyboardKeyBinding(input: UIKeyCommand.inputRightArrow, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            settings.binding(for: .home),
            KeyboardKeyBinding(input: "h", modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .windows),
            KeyboardKeyBinding(input: "o", modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .panes),
            KeyboardKeyBinding(input: "p", modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .attachments),
            KeyboardKeyBinding(input: "a", modifiers: [.command])
        )
        XCTAssertEqual(
            settings.binding(for: .commandPalette),
            KeyboardKeyBinding(input: "k", modifiers: [.command])
        )
        XCTAssertTrue(settings.hideButtonBarWhenPhysicalKeyboardConnected)
    }

    func testUpdatingBindingCanClearOrAssignCustomChord() throws {
        let cleared = try KeyboardSettings.default.validated(updating: .home, to: nil)
        let custom = KeyboardKeyBinding(input: "g", modifiers: [.control, .option])
        let reassigned = try cleared.validated(updating: .home, to: custom)

        XCTAssertNil(cleared.binding(for: .home))
        XCTAssertEqual(reassigned.binding(for: .home), custom)
    }

    func testUpdatingBindingRejectsBareKey() {
        XCTAssertThrowsError(
            try KeyboardSettings.default.validated(
                updating: .home,
                to: KeyboardKeyBinding(input: "g", modifiers: [])
            )
        ) { error in
            XCTAssertEqual(error as? KeyboardSettings.ValidationError, .missingModifier)
        }
    }

    func testUpdatingBindingRejectsChordAlreadyAssignedToAnotherCommand() {
        XCTAssertThrowsError(
            try KeyboardSettings.default.validated(
                updating: .home,
                to: KeyboardSettings.default.binding(for: .commandPalette)
            )
        ) { error in
            XCTAssertEqual(
                error as? KeyboardSettings.ValidationError,
                .duplicateBinding(command: .commandPalette)
            )
        }
    }
}
