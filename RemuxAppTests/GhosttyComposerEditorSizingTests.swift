import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyComposerEditorSizingTests: XCTestCase {
    func testLongPortraitDraftStopsGrowingAfterSixLines() {
        XCTAssertEqual(height(measured: 900, available: 800), 130)
    }

    func testLandscapeDraftLeavesRoomForTerminalAndControls() {
        XCTAssertEqual(height(measured: 900, available: 180, compact: true), 50)
    }

    func testKeyboardReducedViewportCapsPortraitDraftBeforeSixLines() {
        XCTAssertEqual(height(measured: 900, available: 240), 84)
    }

    func testLargerTextAlwaysKeepsAtLeastOneCompleteLine() {
        XCTAssertEqual(height(measured: 900, available: 100, line: 70, compact: true), 80)
    }

    func testEmptyDraftStillHasUsableEditingHeight() {
        XCTAssertEqual(height(measured: 0, available: 800), 36)
    }

    func testShortDraftDoesNotExpandToTheMaximum() {
        XCTAssertEqual(height(measured: 60, available: 800), 60)
    }

    func testUnavailableGeometryUsesLineCap() {
        for available: CGFloat in [0, -.infinity, .nan] {
            XCTAssertEqual(height(measured: 900, available: available), 130)
        }
    }

    private func height(
        measured: CGFloat,
        available: CGFloat,
        line: CGFloat = 20,
        compact: Bool = false
    ) -> CGFloat {
        GhosttyComposerEditorSizing.height(
            measuredHeight: measured,
            lineHeight: line,
            verticalInsets: 10,
            availableHeight: available,
            isCompactHeight: compact
        )
    }
}
