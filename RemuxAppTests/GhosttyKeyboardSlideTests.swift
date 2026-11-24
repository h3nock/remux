import CoreGraphics
import Foundation
import XCTest
@testable import Remux

final class GhosttyKeyboardSlideTests: XCTestCase {
    private let surfaces = [NSObject(), NSObject()]
    /// An iPhone 14 Pro Max row: 53 pixels at 3x.
    private static let row: CGFloat = 53.0 / 3

    private func inputs(
        area: CGFloat = 459,
        canvas: CGFloat = 726,
        line: CGFloat?,
        room: CGFloat?,
        surface: Int = 0,
        scrolledBack: Bool = false
    ) -> GhosttyKeyboardSlide.Inputs {
        GhosttyKeyboardSlide.Inputs(
            surface: ObjectIdentifier(surfaces[surface]),
            areaHeight: area,
            canvasHeight: canvas,
            keptLine: line,
            cursorRoom: room,
            rowHeight: Self.row,
            isScrolledBack: scrolledBack,
            scale: 3
        )
    }

    private func pans(_ steps: [GhosttyKeyboardSlide.Inputs]) -> [CGFloat] {
        var slide: GhosttyKeyboardSlide?
        return steps.map { inputs in
            slide = .next(after: slide, inputs: inputs)
            return slide!.pan
        }
    }

    func testNoSlideWhileTheAreaShowsTheWholeCanvas() {
        XCTAssertEqual(pans([inputs(area: 726, line: 700, room: 680), inputs(area: 800, line: nil, room: nil)]), [0, 0])
    }

    func testSlidesJustFarEnoughToKeepTheLineAboveTheAreasBottom() {
        // A prompt whose row ends 300 pt down stays put above a 459 pt area.
        XCTAssertEqual(pans([inputs(line: 300, room: 280)]), [0])
        // A prompt at the bottom moves up by what the keyboard covers.
        XCTAssertEqual(pans([inputs(line: 726, room: 700)]), [267])
        // In between, just far enough.
        XCTAssertEqual(pans([inputs(line: 600, room: 580)]), [141])
    }

    func testNeverSlidesTheCursorsRowOffTheTop() {
        // A footer far below a cursor near the top: the cursor's row stays in view.
        XCTAssertEqual(pans([inputs(line: 726, room: 40)]), [40])
    }

    func testKeepsTheCanvasBottomWithNothingToKeep() {
        XCTAssertEqual(pans([inputs(line: nil, room: nil)]), [267])
    }

    func testMovesOnWholePixels() {
        let pan = pans([inputs(line: 600.2, room: 580.25)])[0]
        XCTAssertEqual(pan * 3, (pan * 3).rounded())
        XCTAssertEqual(pan, 141 + 1.0 / 3, accuracy: 0.0001)
    }

    func testOutputFollowsWhatIsDrawnLower() {
        XCTAssertEqual(pans([inputs(line: 500, room: 480), inputs(line: 600, room: 580)]), [41, 141])
    }

    func testHoldsWhileUpToTwoRowsLeaveTheBottom() {
        // Hints under the input come and go: two rows, then one.
        let hints = pans([
            inputs(line: 600, room: 560),
            inputs(line: 600 - 2 * Self.row, room: 560),
            inputs(line: 600, room: 560),
            inputs(line: 600 - Self.row, room: 560),
        ])
        XCTAssertEqual(hints, [141, 141, 141, 141])
    }

    func testMoreThanTwoRowsLeavingTheBottomWorksItOutAfresh() {
        // An eight-row menu under the input closes.
        let menu = pans([inputs(line: 700, room: 520), inputs(line: 700 - 8 * Self.row, room: 520)])
        XCTAssertEqual(menu[0], 241)
        XCTAssertEqual(menu[1], ((700 - 8 * Self.row - 459) * 3).rounded() / 3)
        // `clear`: the prompt on the first row brings the canvas home.
        XCTAssertEqual(pans([inputs(line: 726, room: 700), inputs(line: 20, room: 0)]), [267, 0])
    }

    func testTheCursorsRowStaysInViewWhileHolding() {
        // Rows leave the bottom as the cursor moves up to the top: the hold gives way to keep the cursor's row.
        XCTAssertEqual(pans([inputs(line: 600, room: 560), inputs(line: 600 - Self.row, room: 100)]), [141, 100])
    }

    func testWorksItOutAfreshForAnotherAreaCanvasOrSurface() {
        let shown = inputs(line: 600, room: 560)
        let lower = inputs(line: 600 - 2 * Self.row, room: 560)
        let fresh: CGFloat = ((600 - 2 * Self.row - 459) * 3).rounded() / 3
        XCTAssertEqual(pans([shown, inputs(area: 460, line: 600 - 2 * Self.row, room: 560)])[1], fresh - 1)
        XCTAssertEqual(pans([shown, inputs(canvas: 727, line: 600 - 2 * Self.row, room: 560)])[1], fresh)
        XCTAssertEqual(pans([shown, inputs(line: 600 - 2 * Self.row, room: 560, surface: 1)])[1], fresh)
        // The same inputs hold.
        XCTAssertEqual(pans([shown, lower])[1], 141)
    }

    func testHoldsWhereItIsWhileTheSurfaceShowsItsHistory() {
        // Opening the keyboard over history doesn't move the canvas.
        let closed = inputs(area: 726, line: 726, room: nil, scrolledBack: true)
        XCTAssertEqual(pans([closed, inputs(line: 726, room: nil, scrolledBack: true)]), [0, 0])
        // Output while reading doesn't move it either, and a smaller covered height brings it within that height.
        XCTAssertEqual(
            pans([
                inputs(line: 600, room: 560),
                inputs(line: 726, room: nil, scrolledBack: true),
                inputs(area: 650, line: 726, room: nil, scrolledBack: true),
            ]),
            [141, 141, 76]
        )
        // Back at the live rows, the slide follows them again.
        XCTAssertEqual(
            pans([
                inputs(line: 600, room: 560),
                inputs(line: 726, room: nil, scrolledBack: true),
                inputs(line: 726, room: 700),
            ]),
            [141, 141, 267]
        )
    }
}
