import XCTest
import SwiftUI
@testable import Remux

/// The toolbar's Tabs and Panes buttons, which a popup over the tab holds as Herdr's client holds its tab bar.
final class GhosttyKeyboardChromeNavigationTests: XCTestCase {
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
