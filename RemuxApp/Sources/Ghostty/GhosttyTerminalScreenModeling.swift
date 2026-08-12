import CoreGraphics
import Foundation
import GhosttyKit

/// The model surface `GhosttySurfaceScreen` renders against: projections of
/// terminal readiness/topology, focused-surface input routing, tmux topology
/// actions, and the selection-sheet/preview plumbing.
///
/// The tmux session stack implements it (`TmuxTerminalScreenAdapter`). The
/// screen owns presentation behavior only; everything engine-specific flows
/// through this boundary.
enum GhosttyTmuxModelActionOutcome: Equatable, Sendable {
    case queued
    case missingTarget(GhosttyTmuxActionMissingTarget)

    var isHandled: Bool {
        switch self {
        case .queued:
            true
        case .missingTarget:
            false
        }
    }

    var isQueued: Bool {
        self == .queued
    }
}

struct GhosttyTmuxCommandFailureEvent: Equatable {
    let token: UInt64
    let message: String
}

/// App-level scene lifecycle phases forwarded into terminal screen models.
enum GhosttyAppLifecyclePhase: Equatable {
    case active
    case inactive
    case background
}

@MainActor
protocol GhosttyTerminalRenderingModeling: ObservableObject {
    var terminalScreenPresentationProjection: GhosttyTerminalScreenPresentationProjection { get }
    var terminalInteractionProjection: GhosttyTerminalInteractionProjection { get }
    var terminalManagedSurfaceLookup: GhosttyManagedSurfaceLookup { get }
    var commandFailureEvent: GhosttyTmuxCommandFailureEvent? { get }
    var stateTraceLabel: String { get }

    func prepareInitialViewport(
        size: CGSize,
        scale: CGFloat,
        claimActiveViewport: Bool
    )

    /// Host hint that the terminal viewport is (not) in its settled
    /// shape — false while a transient overlay (software keyboard) is
    /// changing the layout. Engines use it to decide which reported
    /// viewport is safe to carry into a reconnect.
    func setViewportStabilityHint(stable: Bool)
}

extension GhosttyTerminalRenderingModeling {
    func prepareInitialViewport(size: CGSize, scale: CGFloat) {
        prepareInitialViewport(
            size: size,
            scale: scale,
            claimActiveViewport: false
        )
    }
}

@MainActor
protocol GhosttyTerminalInputModeling: ObservableObject {
    // MARK: Focused/targeted input routing

    @discardableResult
    func sendInputToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult

    @discardableResult
    func sendPasteToFocusedSurface(_ text: String) -> FocusedTerminalInputSubmissionResult

    @discardableResult
    func sendPaste(_ text: String, to surfaceID: UUID) -> FocusedTerminalInputSubmissionResult

    func sendPasteAwaitingCommandCompletion(_ text: String, to surfaceID: UUID) async -> Bool

    @discardableResult
    func sendKeyEvent(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) -> FocusedTerminalInputSubmissionResult

    func sendKeyEventAwaitingCommandCompletion(
        _ event: GhosttySurfaceKeyEvent,
        to surfaceID: UUID
    ) async -> Bool

    @discardableResult
    func sendKeyEventToFocusedSurface(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult

    func isMouseCaptured(for surfaceID: UUID) -> Bool

    @discardableResult
    func sendMouseButton(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseButtonEvent
    ) -> GhosttyMouseInputSubmissionOutcome

    @discardableResult
    func sendMousePosition(
        to surfaceID: UUID,
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods
    ) -> GhosttyMouseInputSubmissionOutcome

    @discardableResult
    func sendMouseScroll(
        to surfaceID: UUID,
        _ event: GhosttySurfaceMouseScrollEvent
    ) -> GhosttyMouseInputSubmissionOutcome

}

@MainActor
protocol GhosttyTmuxActionModeling: ObservableObject {
    // MARK: tmux topology actions

    func reclaimActiveTmuxViewport()

    func claimActiveTmuxViewportIfNeeded()

    @discardableResult
    func focusTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func focusTmuxTopLevel(_ id: UUID) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func focusAdjacentTmuxTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func createTmuxWindow() -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func splitFocusedTmuxPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func setFocusedTmuxPaneZoomed(_ zoomed: Bool) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func closeTmuxPane(_ id: UUID) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func closeTmuxWindow(_ id: UUID) -> GhosttyTmuxModelActionOutcome

    @discardableResult
    func enterFocusedTmuxCopyMode() -> GhosttyTmuxModelActionOutcome

    // MARK: Topology action interaction effects

    func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect
    func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect
    func closeTmuxWindowInteractionEffect(_ id: UUID) -> GhosttyTmuxTopologyActionInteractionEffect
    func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTmuxTopologyActionInteractionEffect
}

@MainActor
protocol GhosttyTmuxSelectionModeling: ObservableObject {
    func makePanePreviewSession(
        leafIDs: [UUID],
        previewSizing: GhosttyPanePreviewSession.PreviewSizing
    ) -> GhosttyPanePreviewSession

    // MARK: Selection sheets

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection?
    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection?
    func paneCount(topLevelID: UUID) -> Int
    func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?
    ) -> GhosttyPaneSelectionSheetTopologyProjection
    func windowSelectionSheetRenderProjection() -> GhosttyWindowSelectionSheetRenderProjection
    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection
}

@MainActor
protocol GhosttyTerminalScreenModeling:
    GhosttyTerminalRenderingModeling,
    GhosttyTerminalInputModeling,
    GhosttyTmuxActionModeling,
    GhosttyTmuxSelectionModeling
{}
