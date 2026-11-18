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

    // MARK: A window's preview

    /// A 50 by 41 window of 24 by 53 pixel cells, whose preview shows 21 rows.
    private func windowPlan(
        panes: [PanePreviewLayout.WindowPane<Int>],
        focused: Int,
        cursorRow: Int
    ) -> PanePreviewLayout.WindowPreviewPlan<Int>? {
        PanePreviewLayout.windowPreviewPlan(
            grid: .init(columns: 50, rows: 41),
            panes: panes,
            focusedPaneID: focused,
            cellWidth: 24,
            cellHeight: 53,
            cursorRowTop: CGFloat(cursorRow * 53),
            budget: .init(width: 504, height: 483),
            zoom: 0.42
        )
    }

    func testPreviewOfPanesSideBySideShowsBothWithTheLineBetweenThem() {
        let plan = windowPlan(
            panes: [
                .init(id: 1, frame: .init(x: 0, y: 0, columns: 25, rows: 41)),
                .init(id: 2, frame: .init(x: 26, y: 0, columns: 24, rows: 41)),
            ],
            focused: 2,
            cursorRow: 40
        )
        XCTAssertEqual(plan?.size, CGSize(width: 1_200, height: 21 * 53))
        XCTAssertEqual(plan?.parts, [
            .init(id: 1, sourceRect: CGRect(x: 0, y: 20 * 53, width: 600, height: 21 * 53), origin: .zero),
            .init(
                id: 2,
                sourceRect: CGRect(x: 0, y: 20 * 53, width: 576, height: 21 * 53),
                origin: CGPoint(x: 624, y: 0)
            ),
        ])
        XCTAssertEqual(plan?.separators, [
            .init(start: CGPoint(x: 612, y: 0), end: CGPoint(x: 612, y: 21 * 53)),
        ])
    }

    func testPreviewOfStackedPanesFollowsTheFocusedPanesCursorInTheWindow() {
        let panes: [PanePreviewLayout.WindowPane<Int>] = [
            .init(id: 1, frame: .init(x: 0, y: 0, columns: 50, rows: 28)),
            .init(id: 2, frame: .init(x: 0, y: 29, columns: 50, rows: 12)),
        ]
        // The lower pane's last row is the window's: the preview ends there, and starts in the upper pane.
        let lower = windowPlan(panes: panes, focused: 2, cursorRow: 11)
        XCTAssertEqual(lower?.parts, [
            .init(id: 1, sourceRect: CGRect(x: 0, y: 20 * 53, width: 1_200, height: 8 * 53), origin: .zero),
            .init(
                id: 2,
                sourceRect: CGRect(x: 0, y: 0, width: 1_200, height: 12 * 53),
                origin: CGPoint(x: 0, y: 9 * 53)
            ),
        ])
        XCTAssertEqual(lower?.separators, [
            .init(start: CGPoint(x: 0, y: 8.5 * 53), end: CGPoint(x: 1_200, y: 8.5 * 53)),
        ])

        // A cursor near the window's top shows its first rows, which the lower pane has no part in.
        let upper = windowPlan(panes: panes, focused: 1, cursorRow: 5)
        XCTAssertEqual(upper?.parts, [
            .init(id: 1, sourceRect: CGRect(x: 0, y: 0, width: 1_200, height: 21 * 53), origin: .zero),
        ])
        XCTAssertEqual(upper?.separators, [])
    }

    func testPreviewOfAWindowWithoutItsFocusedPaneIsNil() {
        XCTAssertNil(windowPlan(
            panes: [.init(id: 1, frame: .init(x: 0, y: 0, columns: 50, rows: 41))],
            focused: 2,
            cursorRow: 40
        ))
    }

    // MARK: How a sheet of windows opens

    private func gridPresentation(itemCount: Int, currentIndex: Int?) -> PanePreviewLayout.GridPresentation {
        let metrics = PanePreviewLayout.windowMetrics(availableSize: CGSize(width: 402, height: 874))
        // Two rows and half of a third.
        let fittedHeight = metrics.gridHeight(itemCount: 4) + metrics.rowSpacing + metrics.tilePointSize.height / 2
        return PanePreviewLayout.gridPresentation(
            itemCount: itemCount,
            currentIndex: currentIndex,
            metrics: metrics,
            fittedHeight: fittedHeight
        )
    }

    func testASheetThatShowsEveryWindowOpensFitted() {
        XCTAssertEqual(gridPresentation(itemCount: 4, currentIndex: 3), .fitted)
    }

    func testASheetWithMoreWindowsThanItShowsCanBePulledToFullHeight() {
        XCTAssertEqual(gridPresentation(itemCount: 10, currentIndex: 0), .fittedOrFull)
        XCTAssertEqual(gridPresentation(itemCount: 10, currentIndex: 3), .fittedOrFull)
        XCTAssertEqual(gridPresentation(itemCount: 10, currentIndex: nil), .fittedOrFull)
    }

    func testASheetThatWouldNotShowTheCurrentWindowOpensAtFullHeight() {
        // The third row is only half in view at the fitted height.
        XCTAssertEqual(gridPresentation(itemCount: 10, currentIndex: 4), .full)
        XCTAssertEqual(gridPresentation(itemCount: 10, currentIndex: 9), .full)
    }
}
