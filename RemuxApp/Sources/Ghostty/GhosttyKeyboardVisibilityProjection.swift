import CoreGraphics
import Foundation
import UIKit

enum GhosttyKeyboardViewportTransitionTarget: Equatable {
    case shown
    case hidden

    var traceLabel: String {
        switch self {
        case .shown:
            return "shown"
        case .hidden:
            return "hidden"
        }
    }
}

extension Optional where Wrapped == GhosttyKeyboardViewportTransitionTarget {
    var traceLabel: String {
        switch self {
        case .some(let target):
            return target.traceLabel
        case .none:
            return "nil"
        }
    }
}

struct GhosttyKeyboardViewportTransitionRequest: Equatable {
    let target: GhosttyKeyboardViewportTransitionTarget?
    let allowsTargetOverride: Bool
    let fallbackDelay: TimeInterval

    init(
        target: GhosttyKeyboardViewportTransitionTarget?,
        allowsTargetOverride: Bool = false,
        fallbackDelay: TimeInterval = GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
    ) {
        self.target = target
        self.allowsTargetOverride = allowsTargetOverride
        self.fallbackDelay = fallbackDelay
    }
}

struct GhosttyKeyboardViewportTransitionBeginResult: Equatable {
    let didStart: Bool
    let fallbackToken: UInt64
    let fallbackDelay: TimeInterval
}

struct GhosttyKeyboardViewportTransitionCompletionResult: Equatable {
    let target: GhosttyKeyboardViewportTransitionTarget?
}

struct GhosttyKeyboardVisibilityProjection: Equatable {
    let frameEnd: CGRect
    let screenBounds: CGRect
    let isVisible: Bool
    let overlapHeight: CGFloat
    let animationDuration: TimeInterval
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget
    let fallbackDelay: TimeInterval
    let shouldBeginViewportTransition: Bool

    init(
        frameEnd: CGRect,
        screenBounds: CGRect,
        animationDuration: TimeInterval?,
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool
    ) {
        self.frameEnd = frameEnd
        self.screenBounds = screenBounds

        let visibleOverlapHeight = GhosttyViewportSizing.normalizedHeight(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: frameEnd,
                screenBounds: screenBounds
            )
        )
        let resolvedAnimationDuration =
            animationDuration ?? GhosttyKeyboardViewportTransitionTiming.defaultAnimationDuration
        let target: GhosttyKeyboardViewportTransitionTarget =
            visibleOverlapHeight > 0 ? .shown : .hidden

        self.isVisible = visibleOverlapHeight > 0
        self.overlapHeight = visibleOverlapHeight
        self.animationDuration = resolvedAnimationDuration
        self.transitionTarget = target
        self.fallbackDelay = Self.fallbackDelay(animationDuration: resolvedAnimationDuration)
        self.shouldBeginViewportTransition = GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
            notificationTarget: target,
            keyboardMode: keyboardMode,
            isDismissSystemKeyboardRequested: isDismissSystemKeyboardRequested
        )
    }

    var transitionRequest: GhosttyKeyboardViewportTransitionRequest? {
        guard shouldBeginViewportTransition else { return nil }
        return GhosttyKeyboardViewportTransitionRequest(
            target: transitionTarget,
            fallbackDelay: fallbackDelay
        )
    }

    static func fallbackDelay(animationDuration: TimeInterval) -> TimeInterval {
        min(
            max(
                animationDuration + GhosttyKeyboardViewportTransitionTiming.fallbackGraceInterval,
                GhosttyKeyboardViewportTransitionTiming.minimumFallbackDelay
            ),
            GhosttyKeyboardViewportTransitionTiming.maximumFallbackDelay
        )
    }
}

struct GhosttyKeyboardToggleProjection: Equatable {
    let previousMode: GhosttyKeyboardChromeMode
    let expectedMode: GhosttyKeyboardChromeMode
    let isInputAvailable: Bool
    let startsSystemKeyboardTransition: Bool
    let transitionTarget: GhosttyKeyboardViewportTransitionTarget?
    let fallbackDelay: TimeInterval?
    let shouldAwaitSystemKeyboardPresentation: Bool

    init(
        keyboardMode: GhosttyKeyboardChromeMode,
        isInputAvailable: Bool
    ) {
        let expectedMode = keyboardMode.toggledKeyboard()
        let startsSystemKeyboardTransition = Self.isSystemKeyboardTransition(
            from: keyboardMode,
            to: expectedMode
        ) && isInputAvailable

        self.previousMode = keyboardMode
        self.expectedMode = expectedMode
        self.isInputAvailable = isInputAvailable
        self.startsSystemKeyboardTransition = startsSystemKeyboardTransition
        self.transitionTarget = startsSystemKeyboardTransition
            ? Self.transitionTarget(for: expectedMode)
            : nil
        self.fallbackDelay = startsSystemKeyboardTransition
            ? Self.fallbackDelay(for: expectedMode)
            : nil
        self.shouldAwaitSystemKeyboardPresentation =
            startsSystemKeyboardTransition && expectedMode == .system
    }

    var transitionRequest: GhosttyKeyboardViewportTransitionRequest? {
        guard startsSystemKeyboardTransition,
              let transitionTarget,
              let fallbackDelay
        else {
            return nil
        }

        return GhosttyKeyboardViewportTransitionRequest(
            target: transitionTarget,
            allowsTargetOverride: true,
            fallbackDelay: fallbackDelay
        )
    }

    private static func isSystemKeyboardTransition(
        from previousMode: GhosttyKeyboardChromeMode,
        to nextMode: GhosttyKeyboardChromeMode
    ) -> Bool {
        (previousMode == .hidden && nextMode == .system)
            || (previousMode == .system && nextMode == .hidden)
    }

    private static func transitionTarget(
        for keyboardMode: GhosttyKeyboardChromeMode
    ) -> GhosttyKeyboardViewportTransitionTarget {
        switch keyboardMode {
        case .system:
            return .shown
        case .hidden:
            return .hidden
        }
    }

    private static func fallbackDelay(
        for keyboardMode: GhosttyKeyboardChromeMode
    ) -> TimeInterval {
        switch keyboardMode {
        case .system:
            return GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
        case .hidden:
            return GhosttyKeyboardViewportTransitionTiming.defaultFallbackDelay
        }
    }
}

struct GhosttyKeyboardViewportTransitionCoordinator: Equatable {
    private(set) var isAwaitingSystemKeyboardPresentation = false
    private var fallbackGate = GhosttyKeyboardViewportFallbackTokenGate()

    mutating func transitionRequest(
        forToggle projection: GhosttyKeyboardToggleProjection
    ) -> GhosttyKeyboardViewportTransitionRequest? {
        guard let request = projection.transitionRequest else { return nil }
        isAwaitingSystemKeyboardPresentation = projection.shouldAwaitSystemKeyboardPresentation
        return request
    }

    mutating func performKeyboardToggleTransition(
        projection: GhosttyKeyboardToggleProjection,
        beginTransition: (GhosttyKeyboardViewportTransitionRequest) -> Void,
        applyKeyboardToggle: () -> GhosttyKeyboardChromeMode,
        completeTransition: () -> Void
    ) {
        if let request = transitionRequest(forToggle: projection) {
            beginTransition(request)
        }

        let resultingMode = applyKeyboardToggle()
        if projection.startsSystemKeyboardTransition,
           resultingMode != projection.expectedMode {
            completeTransition()
        }
    }

    mutating func observeKeyboardVisibility(isVisible: Bool) {
        guard isVisible else { return }
        isAwaitingSystemKeyboardPresentation = false
    }

    mutating func clearAwaitingSystemKeyboardPresentation() {
        isAwaitingSystemKeyboardPresentation = false
    }

    mutating func prepareUnexpectedHideRecovery() -> GhosttyKeyboardViewportTransitionRequest {
        isAwaitingSystemKeyboardPresentation = true
        return GhosttyKeyboardViewportTransitionRequest(
            target: .shown,
            allowsTargetOverride: true,
            fallbackDelay: GhosttyKeyboardViewportTransitionTiming.systemPresentationFallbackDelay
        )
    }

    mutating func beginTransition(
        _ request: GhosttyKeyboardViewportTransitionRequest,
        viewportCoordinator: inout GhosttyTerminalViewportCoordinator,
        liveSize: CGSize
    ) -> GhosttyKeyboardViewportTransitionBeginResult {
        let didStart = viewportCoordinator.beginKeyboardTransition(
            target: request.target,
            allowsTargetOverride: request.allowsTargetOverride,
            liveSize: liveSize
        )
        return GhosttyKeyboardViewportTransitionBeginResult(
            didStart: didStart,
            fallbackToken: fallbackGate.issueToken(),
            fallbackDelay: request.fallbackDelay
        )
    }

    mutating func completeTransition(
        viewportCoordinator: inout GhosttyTerminalViewportCoordinator,
        liveSize: CGSize
    ) -> GhosttyKeyboardViewportTransitionCompletionResult? {
        guard viewportCoordinator.isKeyboardTransitionActive else { return nil }

        fallbackGate.invalidate()
        isAwaitingSystemKeyboardPresentation = false
        let target = viewportCoordinator.keyboardTransitionTarget
        viewportCoordinator.completeKeyboardTransition(liveSize: liveSize)
        return GhosttyKeyboardViewportTransitionCompletionResult(target: target)
    }

    mutating func completeTransitionFromFallback(
        token: UInt64,
        viewportCoordinator: inout GhosttyTerminalViewportCoordinator,
        liveSize: CGSize
    ) -> GhosttyKeyboardViewportTransitionCompletionResult? {
        guard fallbackGate.accepts(token) else { return nil }
        guard viewportCoordinator.isKeyboardTransitionActive else { return nil }
        return completeTransition(
            viewportCoordinator: &viewportCoordinator,
            liveSize: liveSize
        )
    }
}

struct GhosttyKeyboardViewportFallbackTokenGate: Equatable {
    private var currentToken: UInt64 = 0

    mutating func issueToken() -> UInt64 {
        currentToken += 1
        return currentToken
    }

    mutating func invalidate() {
        currentToken += 1
    }

    func accepts(_ token: UInt64) -> Bool {
        currentToken == token
    }
}

enum GhosttyKeyboardViewportCompletionAction: Equatable {
    case complete
    case ignoreTargetMismatch
    case ignorePolicy
    case recoverUnexpectedHide
}

struct GhosttyKeyboardViewportCompletionProjection: Equatable {
    let eventTarget: GhosttyKeyboardViewportTransitionTarget
    let activeTransitionTarget: GhosttyKeyboardViewportTransitionTarget?
    let action: GhosttyKeyboardViewportCompletionAction

    init(
        eventTarget: GhosttyKeyboardViewportTransitionTarget,
        activeTransitionTarget: GhosttyKeyboardViewportTransitionTarget?,
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool,
        isInputAvailable: Bool,
        isSelectionSheetPresented: Bool,
        isTransientInputOwnerPresented: Bool = false,
        isAwaitingSystemKeyboardPresentation: Bool,
        isSceneActive: Bool
    ) {
        self.eventTarget = eventTarget
        self.activeTransitionTarget = activeTransitionTarget

        if eventTarget == .hidden,
           !GhosttyKeyboardViewportTransitionPolicy.shouldBeginVisibilityTransition(
               notificationTarget: .hidden,
               keyboardMode: keyboardMode,
               isDismissSystemKeyboardRequested: isDismissSystemKeyboardRequested
           ) {
            self.action = GhosttyKeyboardViewportTransitionPolicy
                .shouldRecoverSystemKeyboardAfterIgnoredHide(
                    keyboardMode: keyboardMode,
                    isDismissSystemKeyboardRequested: isDismissSystemKeyboardRequested,
                    isInputAvailable: isInputAvailable,
                    isSelectionSheetPresented: isSelectionSheetPresented,
                    isTransientInputOwnerPresented: isTransientInputOwnerPresented,
                    isAwaitingSystemKeyboardPresentation: isAwaitingSystemKeyboardPresentation,
                    isSceneActive: isSceneActive
                )
                ? .recoverUnexpectedHide
                : .ignorePolicy
            return
        }

        self.action = Self.matches(
            activeTransitionTarget,
            eventTarget: eventTarget
        )
            ? .complete
            : .ignoreTargetMismatch
    }

    private static func matches(
        _ activeTransitionTarget: GhosttyKeyboardViewportTransitionTarget?,
        eventTarget: GhosttyKeyboardViewportTransitionTarget
    ) -> Bool {
        activeTransitionTarget == nil || activeTransitionTarget == eventTarget
    }
}

enum GhosttyKeyboardViewportTransitionPolicy {
    static func shouldBeginVisibilityTransition(
        notificationTarget: GhosttyKeyboardViewportTransitionTarget,
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool
    ) -> Bool {
        switch notificationTarget {
        case .shown:
            return keyboardMode == .system

        case .hidden:
            guard !(keyboardMode == .system && !isDismissSystemKeyboardRequested) else {
                return false
            }
            return true
        }
    }

    static func shouldRecoverSystemKeyboardAfterIgnoredHide(
        keyboardMode: GhosttyKeyboardChromeMode,
        isDismissSystemKeyboardRequested: Bool,
        isInputAvailable: Bool,
        isSelectionSheetPresented: Bool,
        isTransientInputOwnerPresented: Bool = false,
        isAwaitingSystemKeyboardPresentation: Bool,
        isSceneActive: Bool
    ) -> Bool {
        keyboardMode == .system
            && !isDismissSystemKeyboardRequested
            && isInputAvailable
            && !isSelectionSheetPresented
            && !isTransientInputOwnerPresented
            && !isAwaitingSystemKeyboardPresentation
            && isSceneActive
    }
}

enum GhosttyKeyboardViewportTransitionTiming {
    static let defaultAnimationDuration: TimeInterval = 0.35
    static let fallbackGraceInterval: TimeInterval = 0.02
    static let minimumFallbackDelay: TimeInterval = 0.25
    static let maximumFallbackDelay: TimeInterval = 1.0
    static let defaultFallbackDelay: TimeInterval = 1.0
    static let systemPresentationFallbackDelay: TimeInterval = 2.0
}

@MainActor
enum GhosttyKeyboardWindowGeometry {
    static func dockedOverlapHeight(
        layoutFrame: CGRect,
        windowBounds: CGRect,
        bottomSafeAreaInset: CGFloat
    ) -> CGFloat {
        let overlap = GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
            frameEnd: layoutFrame, screenBounds: windowBounds
        )
        // With no docked keyboard, UIKit's guide occupies the bottom safe area.
        guard overlap > max(bottomSafeAreaInset, 0) else { return 0 }
        return GhosttyViewportSizing.normalizedHeight(overlap)
    }

    static func frameEnd(notification: Notification, window: UIWindow, coordinateSpace: any UICoordinateSpace) -> CGRect {
        // A hide notification describes the end state even if its reported frame
        // still overlaps the window during a display transition.
        guard notification.name != UIResponder.keyboardWillHideNotification,
              let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return CGRect(x: window.bounds.minX, y: window.bounds.maxY, width: window.bounds.width, height: 0)
        }
        return window.convert(frame, from: coordinateSpace)
    }
}
