import XCTest
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
