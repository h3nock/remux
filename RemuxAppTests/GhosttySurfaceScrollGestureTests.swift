import CoreGraphics
import UIKit
import XCTest
@testable import Remux

final class GhosttySurfaceScrollGestureTests: XCTestCase {
    /// The keyboard's layout pass runs inside its animation; the pane's own frames must not join it.
    @MainActor
    func testPaneContainerLayoutInsideAnotherAnimationAnimatesNoPaneFrames() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 440, height: 512))
        window.addSubview(container)
        window.isHidden = false
        container.layoutIfNeeded()

        UIView.animate(withDuration: 1) {
            container.frame = CGRect(x: 0, y: 0, width: 440, height: 795)
            container.layoutIfNeeded()
        }

        XCTAssertFalse(container.subviews.isEmpty)
        for subview in container.subviews {
            XCTAssertNil(subview.layer.animationKeys(), "\(type(of: subview)) frame was animated")
        }
        window.isHidden = true
    }

    func testPaneScrollGeometryRejectsUnsizedDisplayViewport() {
        XCTAssertNil(GhosttyPaneScrollGeometry.displayViewportSize(for: .zero))
        XCTAssertNil(GhosttyPaneScrollGeometry.displayViewportSize(for: CGRect(x: 0, y: 0, width: 120, height: 0)))
        XCTAssertNil(GhosttyPaneScrollGeometry.displayViewportSize(for: CGRect(x: 0, y: 0, width: 0, height: 240)))
        XCTAssertNil(GhosttyPaneScrollGeometry.displayViewportSize(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 240)))
    }

    func testPaneScrollGeometryReturnsPositiveDisplayViewport() {
        XCTAssertEqual(
            GhosttyPaneScrollGeometry.displayViewportSize(for: CGRect(x: 0, y: 0, width: 120, height: 240)),
            CGSize(width: 120, height: 240)
        )
    }

    func testVerticalDominantVelocityAllowsRouteForwardingPanToBegin() {
        XCTAssertTrue(GhosttySurfacePanGesture.verticalScrollShouldBegin(forVelocity: CGPoint(x: 30, y: 80)))
        XCTAssertFalse(GhosttySurfacePanGesture.horizontalNavigationShouldBegin(forVelocity: CGPoint(x: 30, y: 80)))
    }

    func testHorizontalDominantVelocityAllowsWindowPanToBegin() {
        XCTAssertTrue(GhosttySurfacePanGesture.horizontalNavigationShouldBegin(forVelocity: CGPoint(x: 120, y: 40)))
        XCTAssertFalse(GhosttySurfacePanGesture.verticalScrollShouldBegin(forVelocity: CGPoint(x: 120, y: 40)))
    }

    func testSurfaceContainerPanRejectsSingleWindow() {
        XCTAssertFalse(
            GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
                topLevelCount: 1,
                velocity: CGPoint(x: 120, y: 0)
            )
        )
    }

    func testSurfaceContainerPanAllowsZeroVelocityForTranslationDrivenNavigation() {
        XCTAssertTrue(
            GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
                topLevelCount: 2,
                velocity: .zero
            )
        )
    }

    func testSurfaceContainerPanRejectsVerticalIntent() {
        XCTAssertFalse(
            GhosttySurfacePanGesture.surfaceContainerPanShouldBegin(
                topLevelCount: 2,
                velocity: CGPoint(x: 30, y: 120)
            )
        )
    }

    func testZeroVelocityDoesNotCommitPanAxis() {
        XCTAssertFalse(GhosttySurfacePanGesture.horizontalNavigationShouldBegin(forVelocity: .zero))
        XCTAssertFalse(GhosttySurfacePanGesture.verticalScrollShouldBegin(forVelocity: .zero))
    }

    func testRouteForwardingPanUsesTranslationForSlowVerticalDrag() {
        XCTAssertTrue(
            GhosttySurfacePanGesture.routeForwardingScrollShouldBegin(
                forVelocity: .zero,
                translation: CGPoint(x: 2, y: 12)
            )
        )
    }

    func testRouteForwardingPanRejectsResolvedHorizontalTranslation() {
        XCTAssertFalse(
            GhosttySurfacePanGesture.routeForwardingScrollShouldBegin(
                forVelocity: CGPoint(x: 0, y: 120),
                translation: CGPoint(x: 12, y: 2)
            )
        )
    }

    func testSmallTranslationDoesNotResolveGestureAxis() {
        XCTAssertNil(
            GhosttySurfacePanGesture.axis(
                forTranslation: CGPoint(x: 2, y: 5)
            )
        )
    }

    func testVerticalDominantTranslationResolvesVerticalAxis() {
        XCTAssertEqual(
            GhosttySurfacePanGesture.axis(
                forTranslation: CGPoint(x: 4, y: 12)
            ),
            .vertical
        )
    }

    func testHorizontalDominantTranslationResolvesHorizontalAxis() {
        XCTAssertEqual(
            GhosttySurfacePanGesture.axis(
                forTranslation: CGPoint(x: 12, y: 4)
            ),
            .horizontal
        )
    }

    func testAxisResolutionPreservesExistingDecision() {
        XCTAssertEqual(
            GhosttySurfacePanGesture.axis(
                forTranslation: CGPoint(x: 100, y: 1),
                currentAxis: .vertical
            ),
            .vertical
        )
    }

    func testZeroTranslationProducesNoScrollEvent() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        XCTAssertTrue(
            gesture.events(
                forTranslation: .zero
            ).isEmpty
        )
    }

    func testFirstVerticalDragStartsPreciseScrollSession() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: 12)
        )

        XCTAssertEqual(events.count, 1)
        let event = events.first
        XCTAssertEqual(event?.deltaX, 0)
        XCTAssertEqual(event?.deltaY, 24)
        XCTAssertEqual(event?.mods, .init(precision: true, momentum: .began))
    }

    func testCustomPreciseScaleAppliesToEmittedDeltas() {
        var gesture = GhosttyRouteForwardingScrollGesture(preciseScale: 1)

        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: 12)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, 12)
    }

    func testDefaultPreciseScaleMatchesLongStandingValue() {
        XCTAssertEqual(GhosttyRouteForwardingScrollGesture().preciseScale, 2)
        XCTAssertEqual(GhosttyRouteForwardingScrollGesture.defaultPreciseScale, 2)
    }

    func testSecondVerticalDragContinuesPreciseScrollSession() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        _ = gesture.events(
            forTranslation: CGPoint(x: 0, y: 12)
        )
        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: -4)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, -8)
        XCTAssertEqual(events.first?.mods, .init(precision: true, momentum: .changed))
    }

    func testTinyVerticalDeltasAreAccumulatedUntilDispatchable() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        XCTAssertTrue(
            gesture.events(
                forTranslation: CGPoint(x: 0, y: 0.2)
            ).isEmpty
        )

        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: 0.3)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, 1)
        XCTAssertEqual(events.first?.mods, .init(precision: true, momentum: .began))
    }

    func testHorizontalNavigationUsesTranslationDirection() {
        XCTAssertEqual(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: -72, y: 4),
                velocity: CGPoint(x: -120, y: 0),
                axis: .horizontal,
                didNavigate: false
            ),
            .next
        )

        XCTAssertEqual(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: 72, y: 4),
                velocity: CGPoint(x: 120, y: 0),
                axis: .horizontal,
                didNavigate: false
            ),
            .previous
        )
    }

    func testHorizontalNavigationCanUseFlingVelocityBeforeLargeTranslation() {
        XCTAssertEqual(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: -18, y: 2),
                velocity: CGPoint(x: -520, y: 20),
                axis: .horizontal,
                didNavigate: false
            ),
            .next
        )
    }

    func testHorizontalNavigationRequiresHorizontalIntent() {
        XCTAssertNil(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: 80, y: 2),
                velocity: CGPoint(x: 600, y: 0),
                axis: .vertical,
                didNavigate: false
            )
        )
    }

    func testHorizontalNavigationIsSuppressedAfterNavigationFires() {
        XCTAssertNil(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: -120, y: 0),
                velocity: CGPoint(x: -700, y: 0),
                axis: .horizontal,
                didNavigate: true
            )
        )
    }

    func testHorizontalNavigationRejectsAmbiguousDiagonalMovement() {
        XCTAssertNil(
            GhosttySurfacePanGesture.windowNavigationDirection(
                forTranslation: CGPoint(x: 58, y: 54),
                velocity: CGPoint(x: 300, y: 290),
                axis: .horizontal,
                didNavigate: false
            )
        )
    }

    func testEndedPhaseClosesActiveScrollSessionEvenWithZeroFinalDelta() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        _ = gesture.events(
            forTranslation: CGPoint(x: 0, y: 4)
        )
        let events = gesture.events(
            forTranslation: .zero,
            phase: .ended
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, 0)
        XCTAssertEqual(events.first?.mods, .init(precision: true, momentum: .ended))
    }

    func testCancelledPhaseClosesActiveScrollSessionWithFinalDelta() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        _ = gesture.events(
            forTranslation: CGPoint(x: 0, y: 4)
        )
        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: -3),
            phase: .cancelled
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, -6)
        XCTAssertEqual(events.first?.mods, .init(precision: true, momentum: .cancelled))
    }

    func testResetStartsNextVerticalScrollSessionFresh() {
        var gesture = GhosttyRouteForwardingScrollGesture()

        _ = gesture.events(
            forTranslation: CGPoint(x: 0, y: 4)
        )
        gesture.reset()
        let events = gesture.events(
            forTranslation: CGPoint(x: 0, y: 2)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.deltaY, 4)
        XCTAssertEqual(events.first?.mods, .init(precision: true, momentum: .began))
    }

    func testPaneScrollGeometryMapsScrollbarStateToUIKitOffset() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 12,
            len: 20,
            cellOffset: 0.5
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.contentOffsetY(
                for: state,
                cellHeight: 10,
                maxContentOffsetY: 800
            ),
            125
        )
    }

    func testPaneScrollGeometryMapsBottomStateToUIKitBottomOffset() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 80,
            len: 20,
            cellOffset: 0
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.contentOffsetY(
                for: state,
                cellHeight: 10,
                maxContentOffsetY: 900
            ),
            900
        )
    }

    func testPaneScrollGeometryMapsScrollbarStateToScrollPosition() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 12,
            len: 20,
            cellOffset: 0.5
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.position(for: state),
            GhosttyPaneScrollPosition(row: 12, cellOffset: 0.5)
        )
    }

    func testPaneScrollGeometryClampsMaxRowPositionToCellBoundary() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 90,
            len: 20,
            cellOffset: 0.5
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.position(for: state),
            GhosttyPaneScrollPosition(row: 80, cellOffset: 0)
        )
    }

    func testPaneScrollPositionUsesToleranceForDuplicateScrollSubmissions() {
        let position = GhosttyPaneScrollPosition(row: 12, cellOffset: 0.5)

        XCTAssertTrue(position.approximatelyEquals(GhosttyPaneScrollPosition(row: 12, cellOffset: 0.500_000_5)))
        XCTAssertFalse(position.approximatelyEquals(GhosttyPaneScrollPosition(row: 12, cellOffset: 0.500_002)))
        XCTAssertFalse(position.approximatelyEquals(GhosttyPaneScrollPosition(row: 13, cellOffset: 0.5)))
    }

    func testPaneScrollGeometryMapsUIKitOffsetToFractionalPosition() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 0,
            len: 20,
            cellOffset: 0
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.position(
                forContentOffsetY: 125,
                cellHeight: 10,
                displayScale: 2,
                state: state,
                maxContentOffsetY: 800
            ),
            GhosttyPaneScrollPosition(row: 12, cellOffset: 0.5)
        )
    }

    func testPaneScrollGeometryClampsBottomToAlignedRow() {
        let state = GhosttySurfaceScrollState(
            total: 100,
            offset: 0,
            len: 20,
            cellOffset: 0
        )

        XCTAssertEqual(
            GhosttyPaneScrollGeometry.position(
                forContentOffsetY: 900,
                cellHeight: 10,
                displayScale: 2,
                state: state,
                maxContentOffsetY: 800
            ),
            GhosttyPaneScrollPosition(row: 80, cellOffset: 0)
        )
    }

    /// The scroll view resting at its end, as after a fling back to the bottom, is the last row for every history
    /// length. On a 3x phone with 53-pixel cells, dividing in points put the resting end at 1567.9999999999998 rows
    /// for a 1568-row history, one row short.
    func testPaneScrollGeometryRestingAtTheEndIsTheLastRow() {
        for (scale, cellPixels) in [(CGFloat(3), CGFloat(53)), (2, 34), (3, 49)] {
            let cellHeight = cellPixels / scale
            for maxRow in UInt64(1)...2000 {
                let state = GhosttySurfaceScrollState(total: maxRow + 44, offset: maxRow, len: 44, cellOffset: 0)
                let maxOffset = CGFloat(maxRow) * cellHeight
                // UIKit rests the scroll view on the device pixel nearest its end.
                let resting = (maxOffset * scale).rounded() / scale
                XCTAssertEqual(
                    GhosttyPaneScrollGeometry.position(
                        forContentOffsetY: resting,
                        cellHeight: cellHeight,
                        displayScale: scale,
                        state: state,
                        maxContentOffsetY: maxOffset
                    ),
                    GhosttyPaneScrollPosition(row: maxRow, cellOffset: 0),
                    "\(maxRow) rows at \(scale)x with \(cellPixels)-pixel cells"
                )
            }
        }
    }

    func testPaneScrollGeometryKeepsAPositionOnePixelAboveTheEnd() {
        let cellHeight: CGFloat = 53.0 / 3
        let state = GhosttySurfaceScrollState(total: 1612, offset: 1568, len: 44, cellOffset: 0)
        let maxOffset = 1568 * cellHeight
        let position = GhosttyPaneScrollGeometry.position(
            forContentOffsetY: maxOffset - 1.0 / 3,
            cellHeight: cellHeight,
            displayScale: 3,
            state: state,
            maxContentOffsetY: maxOffset
        )
        XCTAssertEqual(position?.row, 1567)
        XCTAssertEqual(position?.cellOffset ?? 0, 52.0 / 53, accuracy: 1e-12)
    }
}
