import CoreGraphics
import XCTest
@testable import Remux

final class PanePreviewLayoutTests: XCTestCase {
    func testPortraitWindowGridUsesTwoColumnPortraitCards() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 393, height: 852)
        )

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 193))
        XCTAssertEqual(metrics.picturePointSize, CGSize(width: 175, height: 167))
        XCTAssertEqual(metrics.capturePointSize, CGSize(width: 163, height: 155))
    }

    func testLandscapeWindowGridUsesThreeColumnFourByThreeCards() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 852, height: 393)
        )

        XCTAssertEqual(metrics.columnCount, 3)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 266, height: 200))
        XCTAssertEqual(metrics.picturePointSize, CGSize(width: 266, height: 174))
        XCTAssertEqual(metrics.capturePointSize, CGSize(width: 254, height: 162))
    }

    func testWindowPhysicalPixelBudgetUsesResolvedMetrics() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 393, height: 852)
        )
        let budget = PanePreviewLayout.windowPhysicalPixelBudget(
            metrics: metrics,
            scale: 3
        )

        XCTAssertEqual(budget, .init(width: 489, height: 465))
    }

    func testPreviewFitsItsWindowsWidth() {
        let budget = GhosttyPanePreviewSession.PixelBudget(width: 489, height: 465)

        // A 50-column window of 24-pixel cells.
        XCTAssertEqual(PanePreviewLayout.previewZoom(windowWidth: 1_200, budget: budget), 489.0 / 1_200)
        // A window too wide for readable text shows its leading part, and a narrow one isn't enlarged.
        XCTAssertEqual(PanePreviewLayout.previewZoom(windowWidth: 4_800, budget: budget), 0.4)
        XCTAssertEqual(PanePreviewLayout.previewZoom(windowWidth: 240, budget: budget), 1)
    }

    // A 1200 x 2190 frame of 53-pixel rows under a 6-pixel top padding, and a 480 x 424 preview at
    // two fifths: the frame's whole width and 20 whole rows.
    private func sourceRect(cursorRow: Int?, frameWidth: Int = 1_200, frameHeight: Int = 2_190) -> CGRect? {
        PanePreviewLayout.previewSourceRect(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            cellHeight: 53,
            cursorRowTop: cursorRow.map { CGFloat(6 + $0 * 53) },
            budget: .init(width: 480, height: 424),
            zoom: 0.4
        )
    }

    func testPreviewEndsAtThePanesLastRowForACursorNearIt() {
        // 41 rows fit the frame; the last 20 are rows 21 to 40.
        let lastRows = CGRect(x: 0, y: 6 + 21 * 53, width: 1_200, height: 20 * 53)

        XCTAssertEqual(sourceRect(cursorRow: 40), lastRows)
        XCTAssertEqual(sourceRect(cursorRow: 37), lastRows)
    }

    func testPreviewEndsThreeRowsBelowACursorHigherUp() {
        // Rows 14 to 33, and rows 4 to 23.
        XCTAssertEqual(
            sourceRect(cursorRow: 30),
            CGRect(x: 0, y: 6 + 14 * 53, width: 1_200, height: 20 * 53)
        )
        XCTAssertEqual(
            sourceRect(cursorRow: 20),
            CGRect(x: 0, y: 6 + 4 * 53, width: 1_200, height: 20 * 53)
        )
    }

    func testPreviewStartsAtTheFirstRowForACursorNearTheTop() {
        XCTAssertEqual(
            sourceRect(cursorRow: 3),
            CGRect(x: 0, y: 6, width: 1_200, height: 20 * 53)
        )
    }

    func testPreviewOfAPaneShorterThanItShowsEveryRow() {
        // Five rows fit a 280-pixel frame.
        XCTAssertEqual(
            sourceRect(cursorRow: 4, frameHeight: 280),
            CGRect(x: 0, y: 6, width: 1_200, height: 5 * 53)
        )
    }

    func testPreviewOfASplitPaneIsAsWideAsThePane() {
        XCTAssertEqual(sourceRect(cursorRow: 40, frameWidth: 590)?.width, 590)
    }

    func testPreviewOfAWindowWiderThanItShowsTheLeadingPart() {
        XCTAssertEqual(sourceRect(cursorRow: 40, frameWidth: 4_800)?.width, 1_200)
    }

    func testPreviewWithoutACursorShowsTheEndOfTheFrame() {
        XCTAssertEqual(
            sourceRect(cursorRow: nil),
            CGRect(x: 0, y: 2_190 - 1_060, width: 1_200, height: 1_060)
        )
    }
}
