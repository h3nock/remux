import XCTest
@testable import Remux

final class PhysicalKeyboardChromeStateTests: XCTestCase {
    func testConnectedHideEnabledStartsFloatingAndHidden() {
        let state = PhysicalKeyboardChromeState(
            isPhysicalKeyboardConnected: true,
            hidesChrome: true
        )

        XCTAssertTrue(state.usesFloatingChrome)
        XCTAssertFalse(state.isChromeVisible)
        XCTAssertNil(state.autoHideToken)
    }

    func testTerminalTapRevealsAndSchedulesAutoHide() {
        var state = PhysicalKeyboardChromeState(
            isPhysicalKeyboardConnected: true,
            hidesChrome: true
        )

        state.terminalTapped()

        XCTAssertTrue(state.isChromeVisible)
        XCTAssertNotNil(state.autoHideToken)
        state.autoHideElapsed(token: state.autoHideToken!)
        XCTAssertFalse(state.isChromeVisible)
    }

    func testChromeInteractionRestartsTimer() {
        var state = PhysicalKeyboardChromeState(
            isPhysicalKeyboardConnected: true,
            hidesChrome: true
        )
        state.terminalTapped()
        let first = state.autoHideToken

        state.chromeInteracted()

        XCTAssertNotEqual(state.autoHideToken, first)
        state.autoHideElapsed(token: first!)
        XCTAssertTrue(state.isChromeVisible)
    }

    func testHideDisabledKeepsFloatingChromeVisible() {
        var state = PhysicalKeyboardChromeState(
            isPhysicalKeyboardConnected: true,
            hidesChrome: false
        )
        state.terminalTapped()

        XCTAssertTrue(state.usesFloatingChrome)
        XCTAssertTrue(state.isChromeVisible)
        XCTAssertNil(state.autoHideToken)
    }

    func testDisconnectRestoresNormalMeasuredChrome() {
        var state = PhysicalKeyboardChromeState(
            isPhysicalKeyboardConnected: true,
            hidesChrome: true
        )

        state.keyboardConnectionChanged(isConnected: false, hidesChrome: true)

        XCTAssertFalse(state.usesFloatingChrome)
        XCTAssertTrue(state.isChromeVisible)
        XCTAssertNil(state.autoHideToken)
    }
}
