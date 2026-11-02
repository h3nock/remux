import Foundation
import GhosttyKit
import UIKit

enum GhosttyRuntimeSelectionDirection {
    case previous
    case next

    func advancedIndex(from index: Int, count: Int) -> Int {
        precondition(count > 0)
        return switch self {
        case .previous: (index - 1 + count) % count
        case .next: (index + 1) % count
        }
    }
}

func ghosttyDiagnosticShortID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(8))
}

func ghosttyDiagnosticPointer(_ pointer: UnsafeMutableRawPointer?) -> String {
    guard let pointer else { return "nil" }
    return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
}

func ghosttyDiagnosticRect(_ rect: CGRect) -> String {
    String(
        format: "%.1fx%.1f@%.1f,%.1f",
        rect.width,
        rect.height,
        rect.minX,
        rect.minY
    )
}

func ghosttyDiagnosticSurfaceSize(_ size: ghostty_surface_size_s) -> String {
    "\(size.columns)x\(size.rows) cells \(size.width_px)x\(size.height_px)px cell=\(size.cell_width_px)x\(size.cell_height_px)"
}

/// A selection in a pane's history, in Ghostty's endpoint roles, with rows counted from the top of the
/// history: rows that stay with their lines while the viewport moves and output arrives.
struct GhosttyHistorySelection: Equatable {
    var start: GhosttyTerminalCell
    var end: GhosttyTerminalCell

    /// Where an endpoint shows in the viewport, and whether it is on screen.
    struct Shown: Equatable {
        let cell: GhosttyTerminalCell
        let isOnScreen: Bool
    }

    /// The endpoints in reading order.
    var ordered: (first: GhosttyTerminalCell, last: GhosttyTerminalCell) {
        start <= end ? (start, end) : (end, start)
    }

    /// Whether it could continue across a row edge. A wide character can leave the last column as
    /// padding when it wraps, so a match ending one column short also needs backend completion.
    func reachesRowEdge(columns: UInt16) -> Bool {
        guard columns > 0 else { return false }
        let (first, last) = ordered
        return first.column == 0 || Int(last.column) + 2 >= Int(columns)
    }

    /// Where the endpoints show in a viewport of `rows` × `columns` whose top row is history row `top`:
    /// an endpoint on screen at its cell; one above at the viewport's first cell and one below at its
    /// last, so the highlight covers the selection's part on screen. Nil when none of it is on screen.
    func shown(top: UInt64, rows: UInt64, columns: UInt16) -> (start: Shown, end: Shown)? {
        let (first, last) = ordered
        let (bottom, overflow) = top.addingReportingOverflow(rows)
        guard rows > 0, columns > 0, !overflow, first.row < bottom, last.row >= top else { return nil }
        func shown(_ cell: GhosttyTerminalCell) -> Shown {
            if cell.row < top { return Shown(cell: GhosttyTerminalCell(row: 0, column: 0), isOnScreen: false) }
            if cell.row >= bottom {
                return Shown(cell: GhosttyTerminalCell(row: rows - 1, column: columns - 1), isOnScreen: false)
            }
            return Shown(
                cell: GhosttyTerminalCell(row: cell.row - top, column: min(cell.column, columns - 1)),
                isOnScreen: true
            )
        }
        return (shown(start), shown(end))
    }
}

/// Pane input the composer awaits before sending what follows. The result
/// says whether the backend delivered the input.
@MainActor
protocol TerminalPaneInputSink: AnyObject {
    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool
    func sendKeyEventAwaitingCommandCompletion(_ event: GhosttySurfaceKeyEvent) async -> Bool
}

/// Stable screen-facing projection of one pane renderer.
/// The renderer owns native lifetime and display updates; this type contains
/// only UIKit presentation state and direct terminal interaction forwarding.
@MainActor
final class GhosttyManagedSurface {
    let id: UUID
    let view: GhosttyKitSurfaceView
    private(set) var controlSurface: GhosttyKitControlSurface

    private weak var inputSink: (any TerminalPaneInputSink)?
    private(set) var isFocused = false
    private(set) var isVisible = false
    private(set) var rendererIsAvailable = true
    private(set) var rendererRecoverySnapshot: CGImage?
    private(set) var scrollState: GhosttySurfaceScrollState
    private(set) var scrollRoute: GhosttySurfaceScrollRoute
    private var remoteScroll: (state: GhosttySurfaceScrollState, route: GhosttySurfaceScrollRoute)?
    /// The selection of a pane whose server keeps its history. Its terminal holds only the rows on
    /// screen, repainted in place as the server's viewport moves, so the selection lives here in history
    /// rows, and the terminal's selection draws the part of it on screen.
    private(set) var historySelection: GhosttyHistorySelection?
    var onScrollStateChange: (() -> Void)?
    var onLocalSelectionGeometryChange: (() -> Void)?
    var onRendererRecoveryChange: (() -> Void)?

    init(
        id: UUID,
        view: GhosttyKitSurfaceView,
        controlSurface: GhosttyKitControlSurface,
        inputSink: any TerminalPaneInputSink,
        interactionState: GhosttySurfaceInteractionState
    ) {
        self.id = id
        self.view = view
        self.controlSurface = controlSurface
        self.inputSink = inputSink
        scrollState = interactionState.scrollState
        scrollRoute = interactionState.scrollRoute
    }

    func applyTerminalTheme(_ theme: TerminalTheme) {
        view.applyTerminalTheme(theme)
    }

    @discardableResult
    func sendInput(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard rendererIsAvailable else { return .surfaceRejected }
        guard controlSurface.sendInput(text) else { return .surfaceRejected }
        onLocalSelectionGeometryChange?()
        return .accepted
    }

    @discardableResult
    func sendPaste(_ text: String) -> FocusedTerminalInputSubmissionResult {
        guard !text.isEmpty else { return .empty }
        guard rendererIsAvailable else { return .surfaceRejected }
        return controlSurface.sendPaste(text) ? .accepted : .surfaceRejected
    }

    func sendPasteAwaitingCommandCompletion(_ text: String) async -> Bool {
        guard !text.isEmpty, rendererIsAvailable, let inputSink else { return false }
        return await inputSink.sendPasteAwaitingCommandCompletion(text)
    }

    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> FocusedTerminalInputSubmissionResult {
        guard rendererIsAvailable else { return .surfaceRejected }
        guard controlSurface.sendKeyEvent(event) else { return .surfaceRejected }
        onLocalSelectionGeometryChange?()
        return .accepted
    }

    func sendKeyEventAwaitingCommandCompletion(
        _ event: GhosttySurfaceKeyEvent
    ) async -> Bool {
        guard rendererIsAvailable, let inputSink else { return false }
        let delivered = await inputSink.sendKeyEventAwaitingCommandCompletion(event)
        if delivered {
            onLocalSelectionGeometryChange?()
        }
        return delivered
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        _ = controlSurface.setVisible(visible)
    }

    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        _ = controlSurface.setFocused(focused)
    }

    func prepareForPermanentRemoval() {
        onScrollStateChange = nil
        setFocused(false)
        setVisible(false)
        view.isHidden = true
        view.removeFromSuperview()
        onLocalSelectionGeometryChange?()
        onLocalSelectionGeometryChange = nil
        onRendererRecoveryChange = nil
    }

    func replaceControlSurface(_ replacement: GhosttyKitControlSurface) {
        controlSurface = replacement
        // A new renderer starts without a selection.
        historySelection = nil
        refreshInteractionState()
        isFocused = false
        isVisible = false
    }

    func beginRendererRecovery(snapshot: CGImage?) {
        rendererIsAvailable = false
        if let snapshot {
            rendererRecoverySnapshot = snapshot
        }
        onRendererRecoveryChange?()
    }

    func finishRendererReplacement(isAvailable: Bool) {
        rendererIsAvailable = isAvailable
        if isAvailable {
            rendererRecoverySnapshot = nil
        }
        onRendererRecoveryChange?()
    }

    func refreshInteractionState() {
        let state = controlSurface.interactionState()
        let scroll = remoteScroll ?? (state.scrollState, state.scrollRoute)
        let changed = scroll.state != scrollState || scroll.route != scrollRoute
        scrollState = scroll.state
        scrollRoute = scroll.route
        if changed { onScrollStateChange?() }
        onLocalSelectionGeometryChange?()
    }

    /// For a pane its server scrolls, as Herdr's: the server's history position and where a scroll
    /// goes replace the local terminal's, which only shows what the server painted.
    func setRemoteScroll(_ state: GhosttySurfaceScrollState, route: GhosttySurfaceScrollRoute) {
        remoteScroll = (state, route)
        drawHistorySelection()
        refreshInteractionState()
    }

    // MARK: Selection

    func selectWord(at point: CGPoint) -> GhosttyLocalSelectionOutcome {
        let outcome = controlSurface.selectWord(at: point)
        recordHistorySelection(outcome)
        return shown(outcome)
    }

    /// A link that doesn't match leaves the selection as it was.
    func selectLink(at point: CGPoint) -> GhosttyLocalLinkSelectionOutcome {
        let outcome = controlSurface.selectLink(at: point)
        guard case .match(let snapshot, let explicitTarget) = outcome else { return outcome }
        recordHistorySelection(.snapshot(snapshot))
        return .match(snapshot: shown(snapshot), explicitTarget: explicitTarget)
    }

    func setSelectionEndpoint(
        _ endpoint: ghostty_terminal_surface_selection_endpoint_e,
        at point: CGPoint
    ) -> GhosttyLocalSelectionOutcome {
        let outcome = controlSurface.setSelectionEndpoint(endpoint, at: point)
        recordHistorySelection(outcome, moved: endpoint)
        return shown(outcome)
    }

    /// Selects cells given in history rows, for a pane whose server keeps its history.
    func select(_ selection: GhosttyHistorySelection) -> GhosttyLocalSelectionOutcome {
        guard remoteScroll != nil else { return .unavailable }
        historySelection = selection
        drawHistorySelection()
        return selectionSnapshot()
    }

    func clearSelection() -> GhosttyLocalSelectionOutcome {
        historySelection = nil
        return controlSurface.clearSelection()
    }

    /// Ends the selection for something other than the screen's own gestures, as input to the pane; the
    /// screen then lets its handles go.
    func endSelection() {
        guard historySelection != nil || Self.isActive(controlSurface.selectionSnapshot()) else { return }
        _ = clearSelection()
        onLocalSelectionGeometryChange?()
    }

    func selectionSnapshot() -> GhosttyLocalSelectionOutcome {
        shown(controlSurface.selectionSnapshot())
    }

    /// The history cell at `point` in the pane, for a pane whose server keeps its history.
    func historyCell(at point: CGPoint) -> GhosttyTerminalCell? {
        guard let remoteScroll, let cell = controlSurface.viewportCell(at: point) else { return nil }
        return GhosttyTerminalCell(row: remoteScroll.state.offset + cell.row, column: cell.column)
    }

    /// Records where a selection change left the selection in history rows, for a pane whose server keeps
    /// its history: both endpoints for a new selection, only the `moved` one for a moved endpoint, since
    /// the other may be off screen, where the terminal holds it at the viewport's edge.
    private func recordHistorySelection(
        _ outcome: GhosttyLocalSelectionOutcome,
        moved: ghostty_terminal_surface_selection_endpoint_e? = nil
    ) {
        guard let remoteScroll else { return }
        guard case .snapshot(let snapshot) = outcome, snapshot.isActive else {
            historySelection = nil
            return
        }
        let top = remoteScroll.state.offset
        func inHistory(_ frame: CGRect?) -> GhosttyTerminalCell? {
            guard let frame, let cell = controlSurface.viewportCell(of: frame) else { return nil }
            return GhosttyTerminalCell(row: top + cell.row, column: cell.column)
        }
        if let moved, var selection = historySelection {
            if moved == GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START {
                selection.start = inHistory(snapshot.start) ?? selection.start
            } else {
                selection.end = inHistory(snapshot.end) ?? selection.end
            }
            historySelection = selection
        } else if let start = inHistory(snapshot.start), let end = inHistory(snapshot.end) {
            historySelection = GhosttyHistorySelection(start: start, end: end)
        } else {
            historySelection = nil
        }
    }

    /// Draws the part of the selection on screen with the terminal's selection, as the server's viewport
    /// moves. With none of it on screen the terminal has no selection, and the selection waits here until
    /// it comes back.
    private func drawHistorySelection() {
        guard let selection = historySelection, let remoteScroll else { return }
        let size = controlSurface.viewportSize
        guard let shown = selection.shown(top: remoteScroll.state.offset, rows: size.rows, columns: size.columns) else {
            _ = controlSurface.clearSelection()
            return
        }
        guard Self.isActive(controlSurface.selectionSnapshot())
            || startTerminalSelection(from: shown.start.cell, to: shown.end.cell)
        else { return }
        _ = controlSurface.setSelectionEndpoint(GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START, toViewportCell: shown.start.cell)
        _ = controlSurface.setSelectionEndpoint(GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END, toViewportCell: shown.end.cell)
    }

    /// The terminal starts a selection only as the word at a cell with text, so a selection coming back on
    /// screen starts at the first cell of its part on screen that has text, and its endpoints then move to
    /// that part's ends. A part with no text has nothing to start from and isn't drawn.
    private func startTerminalSelection(from start: GhosttyTerminalCell, to end: GhosttyTerminalCell) -> Bool {
        let columns = controlSurface.viewportSize.columns
        var cell = min(start, end)
        while cell <= max(start, end) {
            if Self.isActive(controlSurface.selectWord(atViewportCell: cell)) { return true }
            cell = cell.column + 1 < columns
                ? GhosttyTerminalCell(row: cell.row, column: cell.column + 1)
                : GhosttyTerminalCell(row: cell.row + 1, column: 0)
        }
        return false
    }

    private func shown(_ outcome: GhosttyLocalSelectionOutcome) -> GhosttyLocalSelectionOutcome {
        guard case .snapshot(let snapshot) = outcome else { return outcome }
        return .snapshot(shown(snapshot))
    }

    /// The selection as the screen shows it: for a pane whose server keeps its history, an endpoint off
    /// screen has no handle, and a selection with no part drawn is still there.
    private func shown(_ snapshot: GhosttyLocalSelectionSnapshot) -> GhosttyLocalSelectionSnapshot {
        guard let remoteScroll, let selection = historySelection else { return snapshot }
        let size = controlSurface.viewportSize
        guard snapshot.isActive,
              let shown = selection.shown(top: remoteScroll.state.offset, rows: size.rows, columns: size.columns)
        else { return .offScreen }
        return snapshot.showing(start: shown.start.isOnScreen, end: shown.end.isOnScreen)
    }

    private static func isActive(_ outcome: GhosttyLocalSelectionOutcome) -> Bool {
        if case .snapshot(let snapshot) = outcome { snapshot.isActive } else { false }
    }

    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard rendererIsAvailable else { return false }
        return controlSurface.sendMouseButton(event)
    }

    func sendMousePosition(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) {
        guard rendererIsAvailable else { return }
        _ = controlSurface.sendMousePosition(position, mods: mods)
    }

    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) {
        guard rendererIsAvailable else { return }
        _ = controlSurface.sendMouseScroll(event)
        refreshInteractionState()
    }

    @discardableResult
    func scrollToPosition(row: UInt64, cellOffset: Double) -> GhosttySurfaceScrollState {
        guard rendererIsAvailable else { return scrollState }
        let next = controlSurface.scrollToPosition(row: row, cellOffset: cellOffset)
        guard next != scrollState else { return scrollState }
        scrollState = next
        onScrollStateChange?()
        onLocalSelectionGeometryChange?()
        return scrollState
    }

    func notifyLocalSelectionGeometryChanged() {
        onLocalSelectionGeometryChange?()
    }

    func isMouseCaptured() -> Bool {
        rendererIsAvailable && controlSurface.isMouseCaptured()
    }

    func diagnosticSummary() -> String {
        "surface=\(ghosttyDiagnosticShortID(id)) handle=\(String(describing: controlSurface.handle)) visible=\(isVisible) focused=\(isFocused) view=\(ghosttyDiagnosticRect(view.frame)) bounds=\(ghosttyDiagnosticRect(view.bounds)) size=\(ghosttyDiagnosticSurfaceSize(controlSurface.currentSize())) scroll=total:\(scrollState.total) offset:\(scrollState.offset) len:\(scrollState.len) route:\(scrollRoute)"
    }
}
