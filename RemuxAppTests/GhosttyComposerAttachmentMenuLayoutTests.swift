import XCTest
@testable import Remux

final class GhosttyComposerAttachmentMenuLayoutTests: XCTestCase {
    private typealias Layout = GhosttyComposerAttachmentMenuLayout

    func testOverTheKeyboardTheMenuHangsItsPaddingBelowTheBar() {
        let bar = CGRect(x: 8, y: 463, width: 386, height: 108)

        let overhang = Layout.overhang(itemCount: 3, barFrameOnScreen: bar, screenHeight: 874, isKeyboardUp: true)

        XCTAssertEqual(overhang, Layout.inset)
    }

    func testOverTheKeyboardOnAShortScreenTheMenuMovesDownToStayOnScreen() {
        // A small phone in landscape: little room above the keyboard for Camera, Photos and Files.
        let bar = CGRect(x: 60, y: 62, width: 500, height: 108)

        let overhang = Layout.overhang(itemCount: 3, barFrameOnScreen: bar, screenHeight: 375, isKeyboardUp: true)
        let menuTopOnScreen = bar.minY + Layout.frame(itemCount: 3, barSize: bar.size, overhang: overhang).minY

        XCTAssertGreaterThan(overhang, Layout.inset)
        XCTAssertEqual(menuTopOnScreen, Layout.screenMargin, accuracy: 0.001)
    }

    func testWithTheKeyboardDownTheMenuHangsOnlyAsFarAsTheRoomBelowAllows() {
        let barAboveHomeIndicator = CGRect(x: 8, y: 732, width: 386, height: 108)
        let barOnHomeButtonPhone = CGRect(x: 8, y: 559, width: 359, height: 108)

        XCTAssertEqual(
            Layout.overhang(itemCount: 2, barFrameOnScreen: barAboveHomeIndicator, screenHeight: 874, isKeyboardUp: false),
            Layout.inset
        )
        XCTAssertEqual(
            Layout.overhang(itemCount: 2, barFrameOnScreen: barOnHomeButtonPhone, screenHeight: 667, isKeyboardUp: false),
            0
        )
    }
}
