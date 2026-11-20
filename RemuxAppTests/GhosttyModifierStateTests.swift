import XCTest
@testable import Remux

final class GhosttyModifierStateTests: XCTestCase {
    func testControlLatchTransformsLetterAndClears() {
        var state = GhosttyModifierState()
        state.toggle(.control)

        XCTAssertEqual(state.apply(to: "c"), "\u{03}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchTransformsBracketIntoEscape() {
        var state = GhosttyModifierState()
        state.toggle(.control)

        XCTAssertEqual(state.apply(to: "["), "\u{1B}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchTransformsSpaceIntoNul() {
        var state = GhosttyModifierState()
        state.toggle(.control)

        XCTAssertEqual(state.apply(to: " "), "\u{00}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchFallsBackToPlainTextAndClears() {
        var state = GhosttyModifierState()
        state.toggle(.control)

        XCTAssertEqual(state.apply(to: "7"), "7")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchAddsCtrlModifierToKeyEvent() {
        var state = GhosttyModifierState()
        state.toggle(.control)
        let event = GhosttySurfaceKeyEvent(keyCode: .arrowUp)

        XCTAssertEqual(
            state.apply(to: event),
            GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl])
        )
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlTextRequiresExactlyOneASCIIScalar() {
        XCTAssertEqual(GhosttyModifierState.controlText(for: "c"), "\u{03}")
        // One Character, two scalars: c with a combining acute.
        XCTAssertNil(GhosttyModifierState.controlText(for: "c\u{0301}"))
        XCTAssertNil(GhosttyModifierState.controlText(for: "你"))
        XCTAssertNil(GhosttyModifierState.controlText(for: "ni"))
    }

    func testControlLatchPassesInputMethodCommitsThroughAndClears() {
        var state = GhosttyModifierState()
        state.toggle(.control)

        XCTAssertEqual(state.apply(to: "c\u{0301}"), "c\u{0301}")
        XCTAssertFalse(state.isControlArmed)

        state.toggle(.control)
        XCTAssertEqual(state.apply(to: "你好"), "你好")
        XCTAssertFalse(state.isControlArmed)
    }

    func testAltPutsEscapeBeforeOneKeyAndClears() {
        var state = GhosttyModifierState()
        state.toggle(.option)

        XCTAssertEqual(state.apply(to: "b"), "\u{1B}b")
        XCTAssertTrue(state.armed.isEmpty)

        // The keyboard's Return arrives as CR, so Alt+Return is ESC CR, as a terminal sends Meta+Return.
        state.toggle(.option)
        XCTAssertEqual(state.apply(to: "\r"), "\u{1B}\r")
    }

    func testControlAndAltTogetherMakeEscapeAndTheControlCharacter() {
        var state = GhosttyModifierState()
        state.toggle(.control)
        state.toggle(.option)

        XCTAssertEqual(state.apply(to: "x"), "\u{1B}\u{18}")
        XCTAssertTrue(state.armed.isEmpty)
    }

    func testShiftCapitalizesALetterOnlyAndClears() {
        var state = GhosttyModifierState()
        state.toggle(.shift)
        XCTAssertEqual(state.apply(to: "a"), "A")
        XCTAssertTrue(state.armed.isEmpty)

        state.toggle(.shift)
        XCTAssertEqual(state.apply(to: "1"), "1")
        XCTAssertTrue(state.armed.isEmpty)

        for (letter, capital) in [("é", "É"), ("ф", "Ф"), ("ß", "ß"), ("-", "-")] {
            state.toggle(.shift)
            XCTAssertEqual(state.apply(to: letter), capital)
        }

        state.toggle(.shift)
        state.toggle(.option)
        XCTAssertEqual(state.apply(to: "f"), "\u{1B}F")
    }

    func testModifiersPassLongerTextThroughAndClear() {
        var state = GhosttyModifierState()
        state.toggle(.option)
        state.toggle(.shift)

        XCTAssertEqual(state.apply(to: "你好"), "你好")
        XCTAssertTrue(state.armed.isEmpty)
    }

    func testToggleTurnsOneModifierOffAndKeepsTheOthers() {
        var state = GhosttyModifierState()
        state.toggle(.control)
        state.toggle(.option)
        state.toggle(.control)

        XCTAssertEqual(state.armed, .option)
    }

    func testArmedModifiersAllJoinAKeyEvent() {
        var state = GhosttyModifierState()
        state.toggle(.shift)
        state.toggle(.option)

        XCTAssertEqual(
            state.apply(to: GhosttySurfaceKeyEvent(keyCode: .arrowLeft)),
            GhosttySurfaceKeyEvent(keyCode: .arrowLeft, mods: [.shift, .alt])
        )
        XCTAssertTrue(state.armed.isEmpty)

        // Control joins the Shift that Shift-Tab carries.
        state.toggle(.control)
        XCTAssertEqual(
            state.apply(to: GhosttySurfaceKeyEvent(keyCode: .tab, mods: [.shift])),
            GhosttySurfaceKeyEvent(keyCode: .tab, mods: [.shift, .ctrl])
        )
    }
}
