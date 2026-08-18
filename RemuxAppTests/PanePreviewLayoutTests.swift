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
        XCTAssertEqual(metrics.capturePointSize, CGSize(width: 159, height: 120))
    }

    func testLandscapeWindowGridUsesThreeColumnFourByThreeCards() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 852, height: 393)
        )

        XCTAssertEqual(metrics.columnCount, 3)
        XCTAssertEqual(metrics.tilePointSize, CGSize(width: 266, height: 200))
        XCTAssertEqual(metrics.capturePointSize, CGSize(width: 250, height: 188))
    }

    func testWindowPhysicalPixelBudgetUsesResolvedMetrics() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 393, height: 852)
        )
        let budget = PanePreviewLayout.windowPhysicalPixelBudget(
            metrics: metrics,
            scale: 3
        )

        XCTAssertEqual(budget.width, 477)
        XCTAssertEqual(budget.height, 360)
    }

    func testLandscapeWindowGridUsesAvailableContentBudget() {
        let availableHeight: CGFloat = 393
        let navigationBarHeight: CGFloat = 44
        let maximumContentHeight = TerminalSelectionSheetLayout.maximumContentHeight(
            availableHeight: availableHeight,
            navigationBarHeight: navigationBarHeight
        )
        let windowHeight = PanePreviewLayout.gridIdealHeight(
            itemCount: 100,
            metrics: PanePreviewLayout.windowMetrics(
                availableSize: CGSize(width: 852, height: availableHeight)
            ),
            maximumContentHeight: maximumContentHeight
        )
        XCTAssertEqual(
            maximumContentHeight + TerminalSelectionSheetLayout.fixedChromeHeight(
                navigationBarHeight: navigationBarHeight
            ),
            availableHeight
        )
        XCTAssertEqual(windowHeight, maximumContentHeight)
        XCTAssertEqual(
            TerminalSelectionSheetLayout.sheetHeight(
                contentHeight: windowHeight,
                navigationBarHeight: navigationBarHeight
            ),
            availableHeight
        )
    }

    func testWindowGridPreservesItsPartialNextRowAffordanceWithinTheBudget() {
        let metrics = PanePreviewLayout.windowMetrics(
            availableSize: CGSize(width: 393, height: 852)
        )
        let expectedHeight = metrics.tilePointSize.height
            + metrics.gridSpacing
            + metrics.tilePointSize.height * 0.5
        let height = PanePreviewLayout.gridIdealHeight(
            itemCount: 5,
            metrics: metrics,
            maximumContentHeight: 320
        )

        XCTAssertEqual(height, expectedHeight)
        XCTAssertLessThanOrEqual(height, 320)
    }

}
