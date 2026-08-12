import CoreGraphics
import XCTest
@testable import Remux

final class PanePreviewLayoutTests: XCTestCase {
    func testWindowGridUsesTwoColumnTileBudget() {
        let metrics = PanePreviewLayout.windowMetrics(availableWidth: 361)

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 175, height: 172))
        XCTAssertEqual(metrics.previewPointSize, CGSize(width: 159, height: 120))
    }

    func testWindowPhysicalPixelBudgetTracksWindowGridMetrics() {
        let budget = PanePreviewLayout.windowPhysicalPixelBudget(
            availableWidth: 361,
            scale: 3
        )

        XCTAssertEqual(budget.width, 477)
        XCTAssertEqual(budget.height, 360)
    }

    func testPaneMapUsesSquareCanvasAndPreservesRelativePaneGeometry() throws {
        let metrics = try XCTUnwrap(PanePreviewLayout.paneMapMetrics(
            windowGrid: GhosttyTerminalGridSize(columns: 83, rows: 44),
            availableWidth: 361,
            maximumHeight: 400
        ))

        XCTAssertEqual(metrics.size.width, 361, accuracy: 0.001)
        XCTAssertEqual(metrics.size.height, 361, accuracy: 0.001)

        let rightPane = metrics.frame(for: GhosttyTerminalGridRect(
            x: 42,
            y: 0,
            columns: 41,
            rows: 44
        ))
        XCTAssertEqual(rightPane.minX, metrics.cellSize.width * 42, accuracy: 0.001)
        XCTAssertEqual(rightPane.maxX, metrics.size.width, accuracy: 0.001)
        XCTAssertEqual(rightPane.height, metrics.size.height, accuracy: 0.001)
    }

    func testPaneMapPreviewBudgetMatchesItsMaximumDisplayBounds() {
        let budget = PanePreviewLayout.paneMapPhysicalPixelBudget(
            availableWidth: 361,
            maximumHeight: 460,
            scale: 3
        )

        XCTAssertEqual(budget.width, 1_083)
        XCTAssertEqual(budget.height, 1_083)
    }
}
