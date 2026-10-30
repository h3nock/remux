import CoreGraphics
import XCTest
@testable import Remux

final class GhosttyTerminalViewportCoordinatorTests: XCTestCase {
    func testLiveSizeObservationReportsAppliedStableSizeTransaction() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)

        let observation = coordinator.observeLiveSize(full)

        XCTAssertEqual(observation.previousLiveSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(observation.liveSize, full)
        XCTAssertEqual(observation.previousEffectiveSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(observation.effectiveSize, full)
        XCTAssertFalse(observation.wasFrozen)
        XCTAssertTrue(observation.didChangeLiveSize)
        XCTAssertTrue(observation.didApplyStableSize)
        XCTAssertEqual(observation.outcome, .appliedStableSize)
    }

    func testLiveSizeObservationReportsHeldStableSizeTransaction() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        coordinator.setSheetPresented(true, liveSize: keyboard)

        let observation = coordinator.observeLiveSize(full)

        XCTAssertEqual(observation.previousLiveSize, keyboard)
        XCTAssertEqual(observation.liveSize, full)
        XCTAssertEqual(observation.previousEffectiveSize, keyboard)
        XCTAssertEqual(observation.effectiveSize, keyboard)
        XCTAssertTrue(observation.wasFrozen)
        XCTAssertTrue(observation.didChangeLiveSize)
        XCTAssertFalse(observation.didApplyStableSize)
        XCTAssertEqual(observation.outcome, .observedWithoutStableUpdate)
    }

    func testLiveSizeObservationReportsUnchangedTransaction() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(full).outcome, .appliedStableSize)

        let observation = coordinator.observeLiveSize(full)

        XCTAssertEqual(observation.previousLiveSize, full)
        XCTAssertEqual(observation.liveSize, full)
        XCTAssertEqual(observation.previousEffectiveSize, full)
        XCTAssertEqual(observation.effectiveSize, full)
        XCTAssertFalse(observation.wasFrozen)
        XCTAssertFalse(observation.didChangeLiveSize)
        XCTAssertFalse(observation.didApplyStableSize)
        XCTAssertEqual(observation.outcome, .unchanged)
    }

    func testLiveSizeReconciliationAdoptsStaleStoredViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        coordinator.requestTopologyRefocus(liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        coordinator.completeTopologyRefocus(
            liveSize: full,
            releasePolicy: .preserveCurrentEffective
        )
        XCTAssertEqual(coordinator.latestLiveSize, full)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        let observation = coordinator.reconcileLiveSize(full)

        XCTAssertFalse(observation.didChangeLiveSize)
        XCTAssertTrue(observation.didApplyStableSize)
        XCTAssertEqual(observation.effectiveSize, full)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testLiveSizeReconciliationRespectsActiveGeometryHold() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        coordinator.setSheetPresented(true, liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)

        let observation = coordinator.reconcileLiveSize(full)

        XCTAssertFalse(observation.didChangeLiveSize)
        XCTAssertFalse(observation.didApplyStableSize)
        XCTAssertEqual(observation.outcome, .unchanged)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testTopologyRefocusPreservesPreviousStableViewportThroughKeyboardChurn() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)
        let keyboard = CGSize(width: 402, height: 452)
        let partial = CGSize(width: 402, height: 527)

        XCTAssertEqual(coordinator.observeLiveSize(full).outcome, .appliedStableSize)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)

        coordinator.setSheetPresented(true, liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        coordinator.requestTopologyRefocus(liveSize: full)
        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            liveSize: full
        )
        coordinator.setSheetPresented(false, liveSize: full)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        XCTAssertFalse(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        coordinator.completeKeyboardTransition(liveSize: keyboard)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)

        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            liveSize: keyboard
        )
        XCTAssertFalse(coordinator.observeLiveSize(partial).didApplyStableSize)
        coordinator.completeKeyboardTransition(liveSize: partial)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: partial), keyboard)

        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        XCTAssertEqual(
            coordinator.completeTopologyRefocus(
                liveSize: full,
                releasePolicy: .preserveCurrentEffective
            ),
            .release(previousEffectiveSize: keyboard)
        )

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testGenericKeyboardTransitionTracksUsableLiveViewportWithoutTopologyHold() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            liveSize: keyboard
        )
        XCTAssertTrue(coordinator.observeLiveSize(full).didApplyStableSize)
        XCTAssertTrue(coordinator.isKeyboardTransitionActive)
        XCTAssertFalse(coordinator.isFrozen)
        coordinator.completeKeyboardTransition(liveSize: full)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertFalse(coordinator.isKeyboardTransitionActive)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testSystemKeyboardShowTracksUsableLiveViewportBeforePresentationCompletes() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)
        let keyboard = CGSize(width: 402, height: 452)

        XCTAssertEqual(coordinator.observeLiveSize(full).outcome, .appliedStableSize)
        coordinator.beginKeyboardTransition(
            target: .shown,
            allowsTargetOverride: true,
            liveSize: full
        )

        XCTAssertTrue(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        XCTAssertTrue(coordinator.isKeyboardTransitionActive)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
        XCTAssertEqual(coordinator.lastStableSize, keyboard)

        coordinator.completeKeyboardTransition(liveSize: keyboard)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertFalse(coordinator.isKeyboardTransitionActive)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
    }

    func testSheetDismissalReleasesGeometryWhileKeyboardTransitionRemainsActive() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        coordinator.beginKeyboardTransition(
            target: .hidden,
            allowsTargetOverride: true,
            liveSize: full
        )

        XCTAssertEqual(
            coordinator.setSheetPresented(false, liveSize: full),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertTrue(coordinator.isKeyboardTransitionActive)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)

        coordinator.completeKeyboardTransition(liveSize: full)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertFalse(coordinator.isKeyboardTransitionActive)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testUsableLiveSizeReleasesUnsizedInitialLayoutFreeze() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)
        let keyboard = CGSize(width: 402, height: 452)

        XCTAssertEqual(coordinator.observeLiveSize(full).outcome, .appliedStableSize)
        XCTAssertEqual(
            coordinator.observeLiveSize(CGSize(width: 0, height: 0)).outcome,
            .observedWithoutStableUpdate
        )
        XCTAssertTrue(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: CGSize(width: 0, height: 0)), full)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertNil(coordinator.frozenSize)
        XCTAssertEqual(coordinator.lastStableSize, keyboard)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
    }

    func testSheetPresentationReportsCurrentEffectiveHoldForReplacement() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )

        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        XCTAssertEqual(
            coordinator.setSheetPresented(true, liveSize: full),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testTopologyRefocusRequestReportsEffectiveHold() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)

        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: full),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertTrue(coordinator.isTopologyRefocusActive)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }

    func testTopologyRefocusCancelReportsReleaseAndAdoptsLatestLiveViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)

        XCTAssertEqual(
            coordinator.cancelTopologyRefocus(liveSize: full),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testInactiveTopologyRefocusCancelReportsNoEffect() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(full).outcome, .appliedStableSize)

        XCTAssertEqual(coordinator.cancelTopologyRefocus(liveSize: full), .inactive)
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testCoveredPresentationKeepsKeyboardViewportWhileLiveLayoutExpands() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        XCTAssertEqual(
            coordinator.setCoveredPresentation(true, liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )

        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        XCTAssertEqual(
            coordinator.setCoveredPresentation(false, liveSize: keyboard),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
    }

    func testCoveredPresentationWithoutKeyboardReleasesAtUnchangedFullViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(full).didApplyStableSize)
        coordinator.setCoveredPresentation(true, liveSize: full)

        XCTAssertEqual(
            coordinator.setCoveredPresentation(false, liveSize: full),
            .release(previousEffectiveSize: full)
        )
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    func testCoveredPresentationReleasesAtFinalRotatedViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let portrait = CGSize(width: 402, height: 452)
        let coveredLandscape = CGSize(width: 852, height: 360)
        let finalLandscape = CGSize(width: 852, height: 248)

        XCTAssertTrue(coordinator.observeLiveSize(portrait).didApplyStableSize)
        coordinator.setCoveredPresentation(true, liveSize: portrait)
        XCTAssertFalse(coordinator.observeLiveSize(coveredLandscape).didApplyStableSize)
        XCTAssertFalse(coordinator.reconcileLiveSize(finalLandscape).didApplyStableSize)

        coordinator.setCoveredPresentation(false, liveSize: finalLandscape)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.latestLiveSize, finalLandscape)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: finalLandscape), finalLandscape)
    }

    func testCoveredPresentationComposesWithSheetAndTopologyHolds() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        coordinator.setSheetPresented(true, liveSize: keyboard)
        coordinator.setCoveredPresentation(true, liveSize: keyboard)
        coordinator.requestTopologyRefocus(liveSize: keyboard)
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)

        coordinator.setCoveredPresentation(false, liveSize: full)
        XCTAssertTrue(coordinator.isFrozen)
        coordinator.setSheetPresented(false, liveSize: full)
        XCTAssertTrue(coordinator.isFrozen)
        coordinator.completeTopologyRefocus(liveSize: full, releasePolicy: .adoptLatestLive)

        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), full)
    }

    /// The Tabs or Panes sheet is a cover too, so its own hold and the cover's hold the same size. The sheet's
    /// ends as it goes, while the keyboard is still down; the size stays the keyboard's until the cover's
    /// ends with the keyboard back, so the terminal is never resized to the full area in between.
    func testASheetsHoldEndingBeforeItsCoversKeepsOneSize() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertTrue(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        coordinator.setCoveredPresentation(true, liveSize: keyboard)
        XCTAssertEqual(coordinator.setSheetPresented(true, liveSize: keyboard), .hold(effectiveSize: keyboard))
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)

        XCTAssertEqual(coordinator.setSheetPresented(false, liveSize: full), .release(previousEffectiveSize: keyboard))
        XCTAssertTrue(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)

        XCTAssertFalse(coordinator.observeLiveSize(keyboard).didApplyStableSize)
        XCTAssertEqual(coordinator.setCoveredPresentation(false, liveSize: keyboard), .release(previousEffectiveSize: keyboard))
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: keyboard), keyboard)
    }

    func testTopologyRefocusCompleteReportsReleaseAndPreservesCurrentEffectiveViewport() {
        var coordinator = GhosttyTerminalViewportCoordinator()
        let keyboard = CGSize(width: 402, height: 452)
        let full = CGSize(width: 402, height: 726)

        XCTAssertEqual(coordinator.observeLiveSize(keyboard).outcome, .appliedStableSize)
        XCTAssertEqual(
            coordinator.requestTopologyRefocus(liveSize: keyboard),
            .hold(effectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.observeLiveSize(full).didApplyStableSize)

        XCTAssertEqual(
            coordinator.completeTopologyRefocus(
                liveSize: full,
                releasePolicy: .preserveCurrentEffective
            ),
            .release(previousEffectiveSize: keyboard)
        )
        XCTAssertFalse(coordinator.isFrozen)
        XCTAssertEqual(coordinator.effectiveSize(liveSize: full), keyboard)
    }
}
