import XCTest
@testable import Remux

final class GhosttyModifierStateTests: XCTestCase {
    func testControlLatchTransformsLetterAndClears() {
        var state = GhosttyModifierState()
        state.toggleControl()

        XCTAssertEqual(state.apply(to: "c"), "\u{03}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchTransformsBracketIntoEscape() {
        var state = GhosttyModifierState()
        state.toggleControl()

        XCTAssertEqual(state.apply(to: "["), "\u{1B}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchTransformsSpaceIntoNul() {
        var state = GhosttyModifierState()
        state.toggleControl()

        XCTAssertEqual(state.apply(to: " "), "\u{00}")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchFallsBackToPlainTextAndClears() {
        var state = GhosttyModifierState()
        state.toggleControl()

        XCTAssertEqual(state.apply(to: "7"), "7")
        XCTAssertFalse(state.isControlArmed)
    }

    func testControlLatchAddsCtrlModifierToKeyEvent() {
        var state = GhosttyModifierState()
        state.toggleControl()
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
        state.toggleControl()

        XCTAssertEqual(state.apply(to: "c\u{0301}"), "c\u{0301}")
        XCTAssertFalse(state.isControlArmed)

        state.toggleControl()
        XCTAssertEqual(state.apply(to: "你好"), "你好")
        XCTAssertFalse(state.isControlArmed)
    }
}
