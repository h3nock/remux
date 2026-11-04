import CoreGraphics
import XCTest
import UIKit
@testable import Remux

final class GhosttyKeyboardVisibilityProjectionTests: XCTestCase {
    private let screenBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    private func performKeyboardToggleTransaction(
        _ projection: GhosttyKeyboardToggleProjection,
        resultingMode: GhosttyKeyboardChromeMode,
        coordinator: inout GhosttyKeyboardViewportTransitionCoordinator
    ) -> [String] {
        var calls: [String] = []
        coordinator.performKeyboardToggleTransition(
            projection: projection,
            beginTransition: {
                calls.append("begin:\($0.target.traceLabel)")
            },
            applyKeyboardToggle: {
                calls.append("toggle")
                return resultingMode
            },
            completeTransition: {
                calls.append("complete")
            }
        )
        return calls
    }

    func testVisibleOverlappingKeyboardBeginsShownTransitionInSystemMode() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544.4, width: 390, height: 299.6),
            screenBounds: screenBounds,
            animationDuration: 0.42,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 300)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertEqual(projection.animationDuration, 0.42)
        XCTAssertEqual(projection.fallbackDelay, 0.44, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testZeroHeightKeyboardFrameIsHiddenWithZeroOverlap() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 0),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 0)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testBottomEdgeNonOverlappingKeyboardFrameIsHidden() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 0)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testHiddenNotificationWithoutExplicitSystemDismissDoesNotBeginTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testRequestedHideBeginsHiddenTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: true
        )

        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertTrue(projection.shouldBeginViewportTransition)
    }

    func testShownNotificationWhileKeyboardModeIsHiddenDoesNotBeginTransition() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: 0.25,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertTrue(projection.isVisible)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertFalse(projection.shouldBeginViewportTransition)
    }

    func testDefaultAnimationDurationFeedsFallbackDelay() {
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
            screenBounds: screenBounds,
            animationDuration: nil,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false
        )

        XCTAssertEqual(projection.animationDuration, 0.35, accuracy: 0.0001)
        XCTAssertEqual(projection.fallbackDelay, 0.37, accuracy: 0.0001)
    }

    func testFallbackDelayClampsToMinimumAndMaximum() {
        XCTAssertEqual(
            GhosttyKeyboardVisibilityProjection.fallbackDelay(animationDuration: 0.01),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            GhosttyKeyboardVisibilityProjection.fallbackDelay(animationDuration: 2.0),
            1.0,
            accuracy: 0.0001
        )
    }

    func testToggleProjectionShowsSystemKeyboardWhenInputIsAvailable() throws {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: true
        )

        XCTAssertEqual(projection.previousMode, .hidden)
        XCTAssertEqual(projection.expectedMode, .system)
        XCTAssertTrue(projection.isInputAvailable)
        XCTAssertTrue(projection.startsSystemKeyboardTransition)
        XCTAssertEqual(projection.transitionTarget, .shown)
        XCTAssertEqual(try XCTUnwrap(projection.fallbackDelay), 2.0, accuracy: 0.0001)
        XCTAssertTrue(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionDoesNotStartShownTransitionWithoutInput() {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: false
        )

        XCTAssertEqual(projection.previousMode, .hidden)
        XCTAssertEqual(projection.expectedMode, .system)
        XCTAssertFalse(projection.isInputAvailable)
        XCTAssertFalse(projection.startsSystemKeyboardTransition)
        XCTAssertNil(projection.transitionTarget)
        XCTAssertNil(projection.fallbackDelay)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionHidesSystemKeyboardWhenInputIsAvailable() throws {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .system,
            isInputAvailable: true
        )

        XCTAssertEqual(projection.previousMode, .system)
        XCTAssertEqual(projection.expectedMode, .hidden)
        XCTAssertTrue(projection.isInputAvailable)
        XCTAssertTrue(projection.startsSystemKeyboardTransition)
        XCTAssertEqual(projection.transitionTarget, .hidden)
        XCTAssertEqual(try XCTUnwrap(projection.fallbackDelay), 1.0, accuracy: 0.0001)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testToggleProjectionDoesNotStartHiddenTransitionWithoutInput() {
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .system,
            isInputAvailable: false
        )

        XCTAssertEqual(projection.previousMode, .system)
        XCTAssertEqual(projection.expectedMode, .hidden)
        XCTAssertFalse(projection.isInputAvailable)
        XCTAssertFalse(projection.startsSystemKeyboardTransition)
        XCTAssertNil(projection.transitionTarget)
        XCTAssertNil(projection.fallbackDelay)
        XCTAssertFalse(projection.shouldAwaitSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleShowRecordsAwaitingPresentation() throws {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: true
        )

        let request = try XCTUnwrap(coordinator.transitionRequest(forToggle: projection))

        XCTAssertEqual(
            request,
            GhosttyKeyboardViewportTransitionRequest(
                target: .shown,
                allowsTargetOverride: true,
                fallbackDelay: GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
            )
        )
        XCTAssertTrue(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleHideClearsAwaitingPresentation() throws {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        _ = coordinator.prepareUnexpectedHideRecovery()

        let request = try XCTUnwrap(
            coordinator.transitionRequest(
                forToggle: GhosttyKeyboardToggleProjection(
                    keyboardMode: .system,
                    isInputAvailable: true
                )
            )
        )

        XCTAssertEqual(
            request,
            GhosttyKeyboardViewportTransitionRequest(
                target: .hidden,
                allowsTargetOverride: true,
                fallbackDelay: GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
            )
        )
        XCTAssertFalse(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleTransactionBeginsShownTransitionBeforeApplyingInputMode() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: true
        )

        let calls = performKeyboardToggleTransaction(
            projection,
            resultingMode: .system,
            coordinator: &coordinator
        )

        XCTAssertEqual(calls, ["begin:shown", "toggle"])
        XCTAssertTrue(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleTransactionBeginsHiddenTransitionBeforeApplyingInputMode() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        _ = coordinator.prepareUnexpectedHideRecovery()
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .system,
            isInputAvailable: true
        )

        let calls = performKeyboardToggleTransaction(
            projection,
            resultingMode: .hidden,
            coordinator: &coordinator
        )

        XCTAssertEqual(calls, ["begin:hidden", "toggle"])
        XCTAssertFalse(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleTransactionSkipsTransitionWhenInputIsUnavailable() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: false
        )

        let calls = performKeyboardToggleTransaction(
            projection,
            resultingMode: .hidden,
            coordinator: &coordinator
        )

        XCTAssertEqual(calls, ["toggle"])
        XCTAssertFalse(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorToggleTransactionCompletesWhenInputModeMissesExpectedState() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        let projection = GhosttyKeyboardToggleProjection(
            keyboardMode: .hidden,
            isInputAvailable: true
        )

        let calls = performKeyboardToggleTransaction(
            projection,
            resultingMode: .hidden,
            coordinator: &coordinator
        )

        XCTAssertEqual(calls, ["begin:shown", "toggle", "complete"])
        XCTAssertTrue(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorVisibleKeyboardClearsAwaitingPresentation() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        _ = coordinator.prepareUnexpectedHideRecovery()

        coordinator.observeKeyboardVisibility(isVisible: false)
        XCTAssertTrue(coordinator.isAwaitingSystemKeyboardPresentation)

        coordinator.observeKeyboardVisibility(isVisible: true)
        XCTAssertFalse(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testTransitionCoordinatorBeginRecordsKeyboardLifecycleAndIssuesFallbackToken() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        var viewport = GhosttyTerminalViewportCoordinator()
        let liveSize = CGSize(width: 402, height: 726)

        XCTAssertEqual(viewport.observeLiveSize(liveSize).outcome, .appliedStableSize)
        let result = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(
                target: .hidden,
                fallbackDelay: 0.42
            ),
            viewportCoordinator: &viewport,
            liveSize: liveSize
        )

        XCTAssertTrue(result.didStart)
        XCTAssertEqual(result.fallbackToken, 1)
        XCTAssertEqual(result.fallbackDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(viewport.isKeyboardTransitionActive)
        XCTAssertFalse(viewport.isFrozen)
        XCTAssertEqual(viewport.keyboardTransitionTarget, .hidden)
    }

    func testTransitionCoordinatorAlreadyActiveBeginReschedulesFallbackAndUpdatesOverride() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        var viewport = GhosttyTerminalViewportCoordinator()
        let liveSize = CGSize(width: 402, height: 726)

        XCTAssertEqual(viewport.observeLiveSize(liveSize).outcome, .appliedStableSize)
        let first = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(
                target: .shown,
                fallbackDelay: 0.25
            ),
            viewportCoordinator: &viewport,
            liveSize: liveSize
        )
        let second = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(
                target: .hidden,
                allowsTargetOverride: true,
                fallbackDelay: 0.5
            ),
            viewportCoordinator: &viewport,
            liveSize: liveSize
        )

        XCTAssertTrue(first.didStart)
        XCTAssertFalse(second.didStart)
        XCTAssertEqual(first.fallbackToken, 1)
        XCTAssertEqual(second.fallbackToken, 2)
        XCTAssertEqual(viewport.keyboardTransitionTarget, .hidden)
    }

    func testTransitionCoordinatorCompletionInvalidatesFallbackTokenAfterGeometryUpdate() throws {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        var viewport = GhosttyTerminalViewportCoordinator()
        let keyboardSize = CGSize(width: 402, height: 452)
        let fullSize = CGSize(width: 402, height: 726)

        XCTAssertEqual(viewport.observeLiveSize(keyboardSize).outcome, .appliedStableSize)
        _ = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(target: .hidden),
            viewportCoordinator: &viewport,
            liveSize: keyboardSize
        )
        XCTAssertTrue(viewport.observeLiveSize(fullSize).didApplyStableSize)

        let completion = try XCTUnwrap(
            coordinator.completeTransition(
                viewportCoordinator: &viewport,
                liveSize: fullSize
            )
        )

        XCTAssertEqual(completion.target, .hidden)
        XCTAssertFalse(viewport.isKeyboardTransitionActive)
        XCTAssertEqual(viewport.effectiveSize(liveSize: fullSize), fullSize)
    }

    func testTransitionCoordinatorFallbackCompletionRejectsStaleTokenAndCompletesCurrentActive() throws {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()
        var viewport = GhosttyTerminalViewportCoordinator()
        let keyboardSize = CGSize(width: 402, height: 452)
        let fullSize = CGSize(width: 402, height: 726)

        XCTAssertEqual(viewport.observeLiveSize(keyboardSize).outcome, .appliedStableSize)
        let first = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(target: .hidden),
            viewportCoordinator: &viewport,
            liveSize: keyboardSize
        )
        let second = coordinator.beginTransition(
            GhosttyKeyboardViewportTransitionRequest(target: .hidden),
            viewportCoordinator: &viewport,
            liveSize: keyboardSize
        )

        XCTAssertNil(
            coordinator.completeTransitionFromFallback(
                token: first.fallbackToken,
                viewportCoordinator: &viewport,
                liveSize: fullSize
            )
        )
        XCTAssertTrue(viewport.isKeyboardTransitionActive)

        let completion = try XCTUnwrap(
            coordinator.completeTransitionFromFallback(
                token: second.fallbackToken,
                viewportCoordinator: &viewport,
                liveSize: fullSize
            )
        )

        XCTAssertEqual(completion.target, .hidden)
        XCTAssertFalse(viewport.isKeyboardTransitionActive)
    }

    func testTransitionCoordinatorUnexpectedHideRecoveryRequestsShownTransition() {
        var coordinator = GhosttyKeyboardViewportTransitionCoordinator()

        let request = coordinator.prepareUnexpectedHideRecovery()

        XCTAssertEqual(
            request,
            GhosttyKeyboardViewportTransitionRequest(
                target: .shown,
                allowsTargetOverride: true,
                fallbackDelay: GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
            )
        )
        XCTAssertTrue(coordinator.isAwaitingSystemKeyboardPresentation)
    }

    func testFallbackTokenGateIssuesIncreasingTokens() {
        var gate = GhosttyKeyboardViewportFallbackTokenGate()

        let first = gate.issueToken()
        let second = gate.issueToken()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
    }

    func testFallbackTokenGateAcceptsCurrentToken() {
        var gate = GhosttyKeyboardViewportFallbackTokenGate()

        let token = gate.issueToken()

        XCTAssertTrue(gate.accepts(token))
    }

    func testFallbackTokenGateRescheduleRejectsOlderToken() {
        var gate = GhosttyKeyboardViewportFallbackTokenGate()

        let first = gate.issueToken()
        let second = gate.issueToken()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }

    func testFallbackTokenGateInvalidationRejectsCurrentToken() {
        var gate = GhosttyKeyboardViewportFallbackTokenGate()

        let token = gate.issueToken()
        gate.invalidate()

        XCTAssertFalse(gate.accepts(token))
    }

    func testCompletionProjectionCompletesDidShowForMatchingTarget() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .shown,
            activeTransitionTarget: .shown,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: true,
            isInputAvailable: false,
            isSelectionSheetPresented: true,
            isAwaitingSystemKeyboardPresentation: true,
            isSceneActive: false
        )

        XCTAssertEqual(projection.action, .complete)
    }

    func testCompletionProjectionIgnoresDidShowTargetMismatchWithoutRecoveryPolicy() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .shown,
            activeTransitionTarget: .hidden,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false,
            isInputAvailable: true,
            isSelectionSheetPresented: false,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .ignoreTargetMismatch)
    }

    func testCompletionProjectionCompletesDidHideWhenPolicyAllowsMatchingTarget() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .hidden,
            activeTransitionTarget: nil,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: true,
            isInputAvailable: true,
            isSelectionSheetPresented: false,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .complete)
    }

    func testCompletionProjectionIgnoresDidHideTargetMismatchWhenPolicyAllows() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .hidden,
            activeTransitionTarget: .shown,
            keyboardMode: .hidden,
            isDismissSystemKeyboardRequested: true,
            isInputAvailable: true,
            isSelectionSheetPresented: false,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .ignoreTargetMismatch)
    }

    func testCompletionProjectionIgnoresDidHideByPolicyWhenRecoveryIsIneligible() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .hidden,
            activeTransitionTarget: .hidden,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false,
            isInputAvailable: false,
            isSelectionSheetPresented: false,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .ignorePolicy)
    }

    func testCompletionProjectionRecoversUnexpectedHideWhenPolicyRejectsAndRecoveryIsEligible() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .hidden,
            activeTransitionTarget: .shown,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false,
            isInputAvailable: true,
            isSelectionSheetPresented: false,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .recoverUnexpectedHide)
    }

    func testCompletionProjectionDoesNotRecoverUnexpectedHideWhileTransientInputOwnerIsPresented() {
        let projection = GhosttyKeyboardViewportCompletionProjection(
            eventTarget: .hidden,
            activeTransitionTarget: .shown,
            keyboardMode: .system,
            isDismissSystemKeyboardRequested: false,
            isInputAvailable: true,
            isSelectionSheetPresented: false,
            isTransientInputOwnerPresented: true,
            isAwaitingSystemKeyboardPresentation: false,
            isSceneActive: true
        )

        XCTAssertEqual(projection.action, .ignorePolicy)
    }
}

@MainActor
final class GhosttyKeyboardWindowGeometryTests: XCTestCase {
    func testLayoutGuideReconciliationExcludesHiddenSafeAreaStrip() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(GhosttyKeyboardWindowGeometry.dockedOverlapHeight(
            layoutFrame: CGRect(x: 0, y: 566, width: 800, height: 34),
            windowBounds: bounds, bottomSafeAreaInset: 34), 0)
        XCTAssertEqual(GhosttyKeyboardWindowGeometry.dockedOverlapHeight(
            layoutFrame: CGRect(x: 0, y: 300, width: 800, height: 300),
            windowBounds: bounds, bottomSafeAreaInset: 34), 300)
    }

    func testLayoutGuideReconciliationUsesNewWindowGeometryAfterFold() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertEqual(GhosttyKeyboardWindowGeometry.dockedOverlapHeight(
            layoutFrame: CGRect(x: 0, y: 500, width: 400, height: 300),
            windowBounds: bounds, bottomSafeAreaInset: 20), 300)
        XCTAssertEqual(GhosttyKeyboardWindowGeometry.dockedOverlapHeight(
            layoutFrame: CGRect(x: 0, y: 780, width: 400, height: 20),
            windowBounds: bounds, bottomSafeAreaInset: 20), 0)
    }

    func testKeyboardFrameConvertsFromSourceCoordinatesIntoWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        let source = UIView(frame: CGRect(x: -500, y: 0, width: 1000, height: 800))
        window.addSubview(source)
        let notification = Notification(name: UIResponder.keyboardWillChangeFrameNotification,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect:
                CGRect(x: 500, y: 500, width: 500, height: 300))])
        let frame = GhosttyKeyboardWindowGeometry.frameEnd(notification: notification,
            window: window, coordinateSpace: source)
        XCTAssertEqual(frame, CGRect(x: 0, y: 500, width: 500, height: 300))
        XCTAssertEqual(GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
            frameEnd: frame, screenBounds: window.bounds), 300)
    }

    func testKeyboardOutsideSplitWindowDoesNotCountAsVisible() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 800)
        let projection = GhosttyKeyboardVisibilityProjection(
            frameEnd: CGRect(x: 500, y: 500, width: 500, height: 300),
            screenBounds: bounds, animationDuration: 0,
            keyboardMode: .system, isDismissSystemKeyboardRequested: false)
        XCTAssertFalse(projection.isVisible)
        XCTAssertEqual(projection.overlapHeight, 0)
    }

    func testMissingOrHiddenKeyboardUsesCurrentWindowBoundsAfterResize() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.bounds.size = CGSize(width: 800, height: 600)
        for notification in [
            Notification(name: UIResponder.keyboardWillChangeFrameNotification),
            Notification(name: UIResponder.keyboardWillHideNotification,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect:
                    CGRect(x: 0, y: 300, width: 800, height: 300))])
        ] {
            let frame = GhosttyKeyboardWindowGeometry.frameEnd(notification: notification,
                window: window, coordinateSpace: window)
            XCTAssertEqual(frame, CGRect(x: 0, y: 600, width: 800, height: 0))
        }
    }
}
