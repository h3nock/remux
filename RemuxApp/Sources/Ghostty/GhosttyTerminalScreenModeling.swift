import CoreGraphics
import Foundation
import GhosttyKit

enum GhosttyTerminalActionOutcome: Equatable, Sendable {
    case queued
    case missingTarget(GhosttyTerminalActionMissingTarget)

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

struct GhosttyTerminalCommandFailureEvent: Equatable {
    let token: UInt64
    let message: String
}

/// The status overlay's notice: a failed command, which is also an event the screen reacts to once, or
/// something a program did that the user should know, such as a copy. The overlay shows one at a time,
/// for its time, until a newer one replaces it.
@MainActor
final class GhosttyTerminalNotice {
    /// How long a failure stays on screen.
    nonisolated static let failureDuration: Duration = .seconds(4)

    private struct Shown {
        let token: UInt64
        let message: String
        let isFailure: Bool
    }

    private(set) var event: GhosttyTerminalCommandFailureEvent?
    private var shown: Shown?
    private var lastToken: UInt64 = 0
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    var failureMessage: String? {
        shown.flatMap { $0.isFailure ? $0.message : nil }
    }

    var informationMessage: String? {
        shown.flatMap { $0.isFailure ? nil : $0.message }
    }

    func presentFailure(_ message: String) {
        let token = show(message, isFailure: true, for: Self.failureDuration)
        event = GhosttyTerminalCommandFailureEvent(token: token, message: message)
        onChange()
    }

    func presentInformation(_ message: String, for duration: Duration) {
        show(message, isFailure: false, for: duration)
        onChange()
    }

    @discardableResult
    private func show(_ message: String, isFailure: Bool, for duration: Duration) -> UInt64 {
        lastToken &+= 1
        let token = lastToken
        shown = Shown(token: token, message: message, isFailure: isFailure)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.shown?.token == token else { return }
            self.shown = nil
            self.onChange()
        }
        return token
    }
}

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
    var commandFailureEvent: GhosttyTerminalCommandFailureEvent? { get }
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
    /// tmux's prefix key (Ctrl+B) is held briefly so Ctrl+B [ can open tmux's copy mode.
    var holdsTmuxPrefixKey: Bool { get }

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

    /// The text the pane's selection copies, from wherever the backend keeps the pane's history; nil
    /// when there is none to copy.
    func selectedText(in surfaceID: UUID) async -> String?

    /// Grows what a long-press at `point` selected to the whole link there, when the backend knows more
    /// of the link than the pane's terminal shows; true once it has.
    func completeLinkSelection(
        in surfaceID: UUID,
        at point: CGPoint,
        selected: GhosttyLongPressSelection
    ) async -> Bool
}

/// What a long-press selected from a pane's terminal.
enum GhosttyLongPressSelection: Equatable, Sendable {
    /// An OSC 8 link, whose id marks every cell of it, so the terminal has all of it.
    case explicitLink
    /// Text the terminal's link patterns matched.
    case link
    /// The word at the press, where no link matched.
    case word
}

@MainActor
protocol GhosttyTerminalActionModeling: ObservableObject {
    func reclaimActiveTmuxViewport()

    func claimActiveTmuxViewportIfNeeded()

    func refreshPaneMetadata(inTopLevel id: UUID)

    @discardableResult
    func focusPane(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func focusTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func focusAdjacentTopLevel(
        _ direction: GhosttyRuntimeSelectionDirection
    ) -> GhosttyTerminalActionOutcome

    /// `group`, when the backend groups its top-levels, is the group the window sheet shows.
    @discardableResult
    func createTopLevel(inGroup group: UUID?) -> GhosttyTerminalActionOutcome

    /// A new group, as a Herdr workspace, made from `group`, the group the window sheet shows.
    @discardableResult
    func createTopLevelGroup(from group: UUID?) -> GhosttyTerminalActionOutcome

    @discardableResult
    func splitFocusedPane(
        _ direction: ghostty_action_split_direction_e
    ) -> GhosttyTerminalActionOutcome

    @discardableResult
    func setFocusedPaneZoomed(_ zoomed: Bool) -> GhosttyTerminalActionOutcome

    @discardableResult
    func closePane(_ id: UUID) -> GhosttyTerminalActionOutcome

    @discardableResult
    func closeTopLevel(_ id: UUID) -> GhosttyTerminalActionOutcome

    /// Rename is offered only for projections with a rename field.
    @discardableResult
    func renameTopLevel(_ id: UUID, to name: String) -> Bool

    @discardableResult
    func renamePane(_ id: UUID, to name: String) -> Bool

    /// A close the backend's server asked the user to confirm, as Herdr's asks before a close that would
    /// close a worktree group, until the user answers it (`answerAskedCloseConfirmation(agreed:)`).
    var askedCloseConfirmation: GhosttyCloseConfirmation? { get }

    func answerAskedCloseConfirmation(agreed: Bool)

    @discardableResult
    func enterFocusedTmuxCopyMode() -> GhosttyTerminalActionOutcome

    // MARK: Topology action interaction effects

    func createTopLevelInteractionEffect() -> GhosttyTopologyActionInteractionEffect
    func splitFocusedPaneInteractionEffect() -> GhosttyTopologyActionInteractionEffect
    func closeTopLevelInteractionEffect(_ id: UUID) -> GhosttyTopologyActionInteractionEffect
    func closePaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID
    ) -> GhosttyTopologyActionInteractionEffect
}

/// What a backend calls its top-level groups of panes, as the screen shows it:
/// a tmux window, a Herdr tab.
struct GhosttyTopLevelNoun: Equatable, Sendable {
    let singular: String
    let plural: String

    static let window = GhosttyTopLevelNoun(singular: "Window", plural: "Windows")
}

@MainActor
protocol GhosttyTerminalSelectionModeling: ObservableObject {
    var topLevelNoun: GhosttyTopLevelNoun { get }

    /// The window sheet's previews of `leafIDs`; nil for a backend whose sheet lists its windows as rows
    /// saying what each holds.
    func makePanePreviewSession(
        leafIDs: [UUID],
        pixelBudget: GhosttyPanePreviewSession.PixelBudget
    ) -> GhosttyPanePreviewSession?

    // MARK: Selection sheets

    func windowSheetPresentationProjection() -> GhosttyWindowSheetPresentationProjection?
    func selectedPaneSheetPresentationProjection() -> GhosttyPaneSheetPresentationProjection?
    func paneCount(topLevelID: UUID) -> Int
    func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?
    ) -> GhosttyPaneSelectionSheetTopologyProjection
    /// The windows of `group`, or of the group on screen, for a backend that groups its top-levels.
    func windowSelectionSheetRenderProjection(group: UUID?) -> GhosttyWindowSelectionSheetRenderProjection
    func paneSelectionSheetRenderProjection(
        topLevelID: UUID
    ) -> GhosttyPaneSelectionSheetRenderProjection
}

/// The model surface `GhosttySurfaceScreen` renders against: projections of
/// terminal readiness/topology, focused-surface input routing, tmux topology
/// actions, and the selection-sheet/preview plumbing.
///
/// The tmux session stack implements it (`TmuxTerminalScreenAdapter`). The
/// screen owns presentation behavior only; everything engine-specific flows
/// through this boundary.
@MainActor
protocol GhosttyTerminalScreenModeling:
    GhosttyTerminalRenderingModeling,
    GhosttyTerminalInputModeling,
    GhosttyTerminalActionModeling,
    GhosttyTerminalSelectionModeling
{}
