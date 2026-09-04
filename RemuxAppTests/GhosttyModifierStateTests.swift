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

    func testShiftLatchUppercasesLetterAndClears() {
        var state = GhosttyModifierState()
        state.toggleShift()

        XCTAssertEqual(state.apply(to: "a"), "A")
        XCTAssertFalse(state.isShiftArmed)
    }

    func testShiftLatchFallsBackToPlainTextAndClears() {
        var state = GhosttyModifierState()
        state.toggleShift()

        XCTAssertEqual(state.apply(to: "7"), "7")
        XCTAssertFalse(state.isShiftArmed)
    }

    func testShiftLatchLeavesMultiCharacterTextUntouched() {
        var state = GhosttyModifierState()
        state.toggleShift()

        XCTAssertEqual(state.apply(to: "ls"), "ls")
        XCTAssertFalse(state.isShiftArmed)
    }

    func testShiftLatchAddsShiftModifierToKeyEvent() {
        var state = GhosttyModifierState()
        state.toggleShift()
        let event = GhosttySurfaceKeyEvent(keyCode: .tab)

        XCTAssertEqual(
            state.apply(to: event),
            GhosttySurfaceKeyEvent(keyCode: .tab, mods: [.shift])
        )
        XCTAssertFalse(state.isShiftArmed)
    }

    func testControlAndShiftLatchesCombineOnKeyEventAndClear() {
        var state = GhosttyModifierState()
        state.toggleControl()
        state.toggleShift()
        let event = GhosttySurfaceKeyEvent(keyCode: .arrowUp)

        XCTAssertEqual(
            state.apply(to: event),
            GhosttySurfaceKeyEvent(keyCode: .arrowUp, mods: [.ctrl, .shift])
        )
        XCTAssertFalse(state.isControlArmed)
        XCTAssertFalse(state.isShiftArmed)
    }

    func testControlAndShiftLatchesCombineOnTextAndClear() {
        var state = GhosttyModifierState()
        state.toggleControl()
        state.toggleShift()

        XCTAssertEqual(state.apply(to: "a"), "\u{01}")
        XCTAssertFalse(state.isControlArmed)
        XCTAssertFalse(state.isShiftArmed)
    }

    func testTogglingControlLeavesShiftLatchAlone() {
        var state = GhosttyModifierState()
        state.toggleShift()
        state.toggleControl()
        state.toggleControl()

        XCTAssertTrue(state.isShiftArmed)
        XCTAssertFalse(state.isControlArmed)
    }

    func testClearModifiersDisarmsBothLatches() {
        var state = GhosttyModifierState()
        state.toggleControl()
        state.toggleShift()

        state.clearModifiers()

        XCTAssertFalse(state.isControlArmed)
        XCTAssertFalse(state.isShiftArmed)
        XCTAssertEqual(state.apply(to: "a"), "a")
    }
}
