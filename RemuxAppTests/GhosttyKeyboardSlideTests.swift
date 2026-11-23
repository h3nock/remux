import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyKeyboardSlideTests: XCTestCase {
    func testNoSlideWhileTheAreaShowsTheWholeCanvas() {
        let slide = GhosttyKeyboardSlide(areaHeight: 726, canvasHeight: 726, keptLine: 700, cursorRoom: 680, scale: 3)
        XCTAssertEqual(slide, GhosttyKeyboardSlide(areaHeight: 800, canvasHeight: 726, keptLine: nil, cursorRoom: nil, scale: 3))
        XCTAssertEqual(slide.pan, 0)
        XCTAssertEqual(slide.limit, 0)
    }

    func testSlidesJustFarEnoughToKeepTheLineAboveTheAreasBottom() {
        // A prompt whose row ends 300 pt down stays put above a 459 pt area.
        XCTAssertEqual(GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 300, cursorRoom: 280, scale: 3).pan, 0)
        // A prompt at the bottom moves up by what the keyboard covers.
        let slide = GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 726, cursorRoom: 700, scale: 3)
        XCTAssertEqual(slide.pan, 267)
        XCTAssertEqual(slide.limit, 267)
        // In between, just far enough.
        XCTAssertEqual(GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 600, cursorRoom: 580, scale: 3).pan, 141)
    }

    func testNeverSlidesTheCursorsRowOffTheTop() {
        // A footer far below a cursor near the top: the cursor's row stays in view.
        let slide = GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 726, cursorRoom: 40, scale: 3)
        XCTAssertEqual(slide.pan, 40)
        XCTAssertEqual(slide.limit, 40)
    }

    func testKeepsTheCanvasBottomWithNothingToKeep() {
        XCTAssertEqual(GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: nil, cursorRoom: nil, scale: 3).pan, 267)
    }

    func testMovesOnWholePixels() {
        let slide = GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 600.2, cursorRoom: 580.25, scale: 3)
        XCTAssertEqual(slide.pan * 3, (slide.pan * 3).rounded())
        XCTAssertEqual(slide.pan, 141 + 1.0 / 3, accuracy: 0.0001)
    }

    func testOutputMovesTheCanvasUpButNotBackDown() {
        let slide = GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 600, cursorRoom: 580, scale: 3)
        // Output that reaches lower moves it up.
        XCTAssertEqual(slide.following(currentPan: 100), 141)
        // Rows that leave the bottom don't bring it back down.
        XCTAssertEqual(slide.following(currentPan: 200), 200)
        // The cursor's row reaching the top does.
        let cleared = GhosttyKeyboardSlide(areaHeight: 459, canvasHeight: 726, keptLine: 20, cursorRoom: 0, scale: 3)
        XCTAssertEqual(cleared.following(currentPan: 200), 0)
    }
}
