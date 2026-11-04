import XCTest
@testable import Remux

final class GhosttyKeyboardChromeSizingTests: XCTestCase {
    func testDefaultToolbarRequiresAnAlternateLayoutOnANarrowPhone() {
        XCTAssertGreaterThan(
            GhosttyKeyboardChromeSizing.singleRowWidth(
                toolbarKeyCount: 3,
                isCompact: true
            ),
            304
        )
    }

    func testCompactTwoRowLayoutFitsThreeHundredFourPointViewport() {
        XCTAssertLessThanOrEqual(
            GhosttyKeyboardChromeSizing.twoRowWidth(
                toolbarKeyCount: 3,
                isCompact: true
            ),
            304
        )
    }

    func testExpandedTwoRowLayoutFitsWidePortraitWithItsLargerMargins() {
        XCTAssertLessThanOrEqual(
            GhosttyKeyboardChromeSizing.twoRowWidth(toolbarKeyCount: 3, isCompact: false),
            430 - 24
        )
    }
}
