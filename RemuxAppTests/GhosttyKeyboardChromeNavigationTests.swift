import XCTest
import SwiftUI
@testable import Remux

/// The toolbar's Tabs and Panes buttons, which a popup over the tab holds as Herdr's client holds its tab bar.
final class GhosttyKeyboardChromeNavigationTests: XCTestCase {
    func testNavigationStatusIncludesSelectedWindowAndPaneCount() {
        let status = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: 1, windowCount: 3, paneCount: 2)
        XCTAssertEqual(status.windowBadge, "2")
        XCTAssertEqual(status.windowAccessibilityLabel, "Window 2 of 3")
        XCTAssertEqual(status.paneBadge, "2")
        XCTAssertEqual(status.paneAccessibilityLabel, "Panes, 2 panes")
    }

    func testNavigationStatusOmitsBadgesForSingleItemsAndCapsLargeCounts() {
        let single = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: nil, windowCount: 1, paneCount: 1)
        XCTAssertNil(single.windowBadge)
        XCTAssertNil(single.paneBadge)
        XCTAssertEqual(single.windowAccessibilityLabel, "Window 1 of 1")
        XCTAssertEqual(single.paneAccessibilityLabel, "Panes, 1 pane")
        let large = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: 99, windowCount: 3, paneCount: 100)
        XCTAssertEqual(large.windowBadge, "3")
        XCTAssertEqual(large.paneBadge, "99+")
        let empty = GhosttyKeyboardChromeStatus(topLevelNoun: .window,
            selectedWindowIndex: nil, windowCount: 0, paneCount: 0)
        XCTAssertEqual(empty.windowAccessibilityLabel, "Windows")
        XCTAssertEqual(empty.paneAccessibilityLabel, "Panes")
    }

    /// While a popup holds the tab, Tabs and Panes stay on the toolbar, dimmed, and say why; once it
    /// closes they work and say what they do again.
    func testAPopupHoldsTheToolbarsTabsAndPanes() {
        let held = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: true, windowCount: 3, paneCount: 2)
        XCTAssertFalse(held.isTabsEnabled)
        XCTAssertFalse(held.isPanesEnabled)
        XCTAssertEqual(held.tabsHint, GhosttyKeyboardChromeNavigation.heldByPopupHint)
        XCTAssertEqual(held.panesHint, GhosttyKeyboardChromeNavigation.heldByPopupHint)

        let free = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 3, paneCount: 2)
        XCTAssertTrue(free.isTabsEnabled)
        XCTAssertTrue(free.isPanesEnabled)
        XCTAssertEqual(free.tabsHint, "switch or create")
        XCTAssertEqual(free.panesHint, "switch or split")
    }

    /// Without a popup the buttons follow the terminal's input and what there is to list, as before.
    func testWithoutAPopupTheButtonsFollowInputAndCounts() {
        let noInput = GhosttyKeyboardChromeNavigation(isEnabled: false, isHeldByPopup: false, windowCount: 1, paneCount: 1)
        XCTAssertFalse(noInput.isTabsEnabled)
        XCTAssertFalse(noInput.isPanesEnabled)
        let one = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 1, paneCount: 1)
        XCTAssertEqual(one.tabsHint, "create")
        XCTAssertEqual(one.panesHint, "split or stack")
        let none = GhosttyKeyboardChromeNavigation(isEnabled: true, isHeldByPopup: false, windowCount: 0, paneCount: 0)
        XCTAssertFalse(none.isTabsEnabled)
        XCTAssertFalse(none.isPanesEnabled)
    }
}

final class GhosttyRailViewportTests: XCTestCase {
    func testStatusAndKeyboardBoundTheScrollableArea() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 700),
            avoiding: [CGRect(x: 300, y: 20, width: 76, height: 110),
                       CGRect(x: 0, y: 400, width: 400, height: 300)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 142, width: 76, height: 246))
    }

    func testKeyboardResizingDoesNotDiscardATallSystemRegion() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 200),
            avoiding: [CGRect(x: 300, y: 0, width: 76, height: 110)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 122, width: 76, height: 66))
    }

    func testBottomOcclusionAndUnrelatedHorizontalRegion() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 700),
            avoiding: [CGRect(x: 300, y: 600, width: 76, height: 100),
                       CGRect(x: 0, y: 0, width: 200, height: 700)], spacing: 12)
        XCTAssertEqual(frame, CGRect(x: 300, y: 12, width: 76, height: 576))
    }

    func testFullyBlockedRailHasNoVisibleViewport() {
        let frame = GhosttyRailViewport.availableFrame(
            in: CGRect(x: 300, y: 0, width: 76, height: 100),
            avoiding: [CGRect(x: 300, y: 0, width: 76, height: 150)], spacing: 12)
        XCTAssertEqual(frame.height, 0)
    }
}

final class GhosttyTerminalSafeAreaPolicyTests: XCTestCase {
    func testBottomControlsRestoreReservationWithoutLosingTopPolicy() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges(.bottom, hasBottomControls: true), [])
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges([.top, .bottom], hasBottomControls: true), .top)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.contentEdges([.top, .bottom], hasBottomControls: false), [.top, .bottom])
    }

    func testInnerLandscapeAddsMissingTopBandWithoutDoublingInsets() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 0, bottomInset: 34), 34)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 34, bottomInset: 34), 0)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: true, topInset: 0, bottomInset: 34), 0)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.additionalTopSpacing(preservesSafeAreas: true, hasVerticalControls: true, isCompact: true, isLandscape: false, topInset: 0, bottomInset: 34), 0)
    }

    func testOuterDisplayExtendsOnlyAtBottom() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: true, hasVerticalControls: true, isCompact: true, isLandscape: false), .bottom)
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: true, isLandscape: false), .bottom)
    }
    func testInnerLandscapeExtendsAtBothEdges() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: true), [.top, .bottom])
    }
    func testInnerPortraitAndHorizontalControlsKeepSafeAreas() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: true, isCompact: false, isLandscape: false), [])
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: false, hasVerticalControls: false, isCompact: true, isLandscape: false), [])
    }
    func testEnabledSpacingPreservesAllEdges() {
        XCTAssertEqual(GhosttyTerminalSafeAreaPolicy.ignoredEdges(preservesSafeAreas: true, hasVerticalControls: true, isCompact: false, isLandscape: true), [])
    }
}

final class GhosttyWholeRowLayoutTests: XCTestCase {
    func testResizingControlsAlwaysUsesTheFinalAvailableArea() {
        // Hidden keyboard, visible keyboard, six growing Compose sizes, then
        // shrinking Compose and returning to the original available height.
        let heights: [CGFloat] = [790, 510, 488, 466, 444, 422, 400, 378, 444, 488, 510, 790]
        for scale: CGFloat in [2, 3] {
            for height in heights {
                let fitted = GhosttyWholeRowLayout.viewportHeight(availableHeight: height, cellPixelHeight: 47, scale: scale)
                let expectedRows = floor((height * scale).rounded() / 47)
                XCTAssertEqual((fitted * scale).rounded(), expectedRows * 47, accuracy: 0.001)
                XCTAssertLessThan(height - fitted, 47 / scale)
                XCTAssertGreaterThanOrEqual(height - fitted, 0)
            }
        }
    }

    func testTrimmingRemainderPreservesWholeRowCount() {
        for pixels in [1590, 1600, 1602, 1603] {
            let height = CGFloat(pixels) / 3
            let remainder = height - GhosttyWholeRowLayout.viewportHeight(availableHeight: height, cellPixelHeight: 48, scale: 3)
            XCTAssertEqual(floor((height * 3).rounded() / 48), floor(((height - remainder) * 3).rounded() / 48))
            XCTAssertEqual(((height - remainder) * 3).rounded().truncatingRemainder(dividingBy: 48), 0)
        }
    }
}

final class GhosttyTerminalControlsGeometryTests: XCTestCase {
    func testComposerGrowthAndSelectionKeepTopGapStable() {
        for windowHeight: CGFloat in [820, 510, 496] {
            for controlsHeight: CGFloat in [78, 99, 120, 141, 162, 183, 183, 120, 78] {
                let bounds = CGRect(x: 13, y: 21, width: 700, height: windowHeight)
                let frames = GhosttyTerminalControlsGeometry.frames(bounds: bounds, controlsHeight: controlsHeight,
                    cellPixelHeight: 47, scale: 3, centersControls: false)
                XCTAssertEqual(frames.controls.minY, frames.terminal.maxY, accuracy: 0.001)
                XCTAssertEqual(frames.controls.height, controlsHeight)
                XCTAssertLessThanOrEqual(frames.controls.maxY, bounds.maxY + 0.001)
                XCTAssertLessThan(bounds.maxY - frames.controls.maxY, 47 / 3)
                XCTAssertEqual((frames.terminal.height * 3).rounded().truncatingRemainder(dividingBy: 47), 0)
            }
        }
    }

    func testPillsAreCenteredInSpaceBelowTerminal() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 820)
        let frames = GhosttyTerminalControlsGeometry.frames(bounds: bounds, controlsHeight: 54,
            cellPixelHeight: 47, scale: 3, centersControls: true)
        XCTAssertEqual(frames.controls.minY - frames.terminal.maxY,
                       bounds.maxY - frames.controls.maxY, accuracy: 0.001)
    }
}
