import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyPhoneChromeLayoutTests: XCTestCase {
    func testNarrowPortraitUsesCompactChrome() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844)
        )

        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testWidePortraitUsesExpandedChrome() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 430, height: 932)
        )

        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 12)
        XCTAssertEqual(layout.bottomPadding, 4)
    }

    func testLandscapeUsesCompactChromeWithoutKeyboard() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 844, height: 390)
        )

        XCTAssertTrue(layout.isLandscape)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testKeyboardFrameInsideScreenIsVisible() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameReportsVisibleOverlapHeight() {
        XCTAssertEqual(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            300
        )
    }

    func testKeyboardFrameAtBottomEdgeIsHidden() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameAtBottomEdgeReportsNoOverlapHeight() {
        XCTAssertEqual(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            0
        )
    }

    func testZeroHeightKeyboardFrameIsHiddenForHardwareKeyboard() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 0),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameVisibilityUsesScreenBoundsMaxYForRotation() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 190, width: 844, height: 200),
                screenBounds: CGRect(x: 0, y: 0, width: 844, height: 390)
            )
        )
    }

    func testKeyboardChromeReplacementHeightExcludesBottomSafeArea() {
        XCTAssertEqual(
            GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
                keyboardOverlapHeight: 308,
                bottomSafeAreaHeight: 34
            ),
            274
        )
    }

    func testBottomChromeReservationTracksSettledChromeHeight() {
        var reservation = GhosttyBottomChromeReservation()

        XCTAssertEqual(reservation.layoutHeight(fallback: 52), 52)
        XCTAssertTrue(reservation.observe(renderedHeight: 91.2, isTransient: false))
        XCTAssertEqual(reservation.settledHeight, 92)
        XCTAssertEqual(reservation.layoutHeight(fallback: 52), 92)
    }

    func testBottomChromeReservationIgnoresTransientDictationHeight() {
        var reservation = GhosttyBottomChromeReservation()
        reservation.observe(renderedHeight: 124, isTransient: false)

        XCTAssertFalse(reservation.observe(renderedHeight: 54, isTransient: true))
        XCTAssertEqual(reservation.settledHeight, 124)
    }

    func testBottomChromeReservationAdoptsFinalComposerHeightAfterDictation() {
        var reservation = GhosttyBottomChromeReservation()
        reservation.observe(renderedHeight: 92, isTransient: false)
        reservation.observe(renderedHeight: 54, isTransient: true)

        XCTAssertTrue(reservation.observe(renderedHeight: 138, isTransient: false))
        XCTAssertEqual(reservation.settledHeight, 138)
    }

    func testDictationMeterUsesMaximumWidthOnWideCenterLane() {
        let count = GhosttyComposerDictationMeterSizing.visibleBarCount(
            availableWidth: 300,
            sampleCount: GhosttyComposerAudioLevelModel.historyCapacity
        )

        XCTAssertEqual(count, 49)
    }

    func testDictationMeterFollowsTargetWidthInPortraitCenterLane() {
        let count = GhosttyComposerDictationMeterSizing.visibleBarCount(
            availableWidth: 240,
            sampleCount: GhosttyComposerAudioLevelModel.historyCapacity
        )

        XCTAssertEqual(count, 46)
    }

    func testDictationMeterAdaptsBarCountToCenterLane() {
        let count = GhosttyComposerDictationMeterSizing.visibleBarCount(
            availableWidth: 200,
            sampleCount: GhosttyComposerAudioLevelModel.historyCapacity
        )

        XCTAssertEqual(count, 38)
    }

    func testDictationMeterPreservesControlBreathingRoomInCompactLane() {
        let count = GhosttyComposerDictationMeterSizing.visibleBarCount(
            availableWidth: 160,
            sampleCount: GhosttyComposerAudioLevelModel.historyCapacity
        )
        XCTAssertEqual(count, 30)
    }

    func testDictationMeterNeverInventsMoreBarsThanHistoryContains() {
        XCTAssertEqual(
            GhosttyComposerDictationMeterSizing.visibleBarCount(
                availableWidth: 240,
                sampleCount: 12
            ),
            12
        )
    }
}
