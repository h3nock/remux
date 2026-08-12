import CoreGraphics
import Foundation
import GhosttyKit

struct GhosttySurfaceDisplayMetrics: Equatable, Sendable {
    let contentScale: Double
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init(contentScale: Double, pixelWidth: UInt32, pixelHeight: UInt32) {
        self.contentScale = contentScale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init(size: CGSize, scale: CGFloat) {
        let rawScale = Double(scale)
        let safeScale = rawScale.isFinite && rawScale > 0 ? rawScale : 1
        contentScale = safeScale
        pixelWidth = Self.pixelDimension(points: size.width, scale: safeScale)
        pixelHeight = Self.pixelDimension(points: size.height, scale: safeScale)
    }

    private static func pixelDimension(points: CGFloat, scale: Double) -> UInt32 {
        let points = Double(points)
        guard points.isFinite, points > 0 else { return 1 }
        let pixels = (points * scale).rounded(.toNearestOrAwayFromZero)
        guard pixels.isFinite, pixels > 0 else { return 1 }
        return UInt32(min(pixels, Double(UInt32.max)))
    }
}

struct GhosttyTerminalCellDisplayMetrics: Equatable, Sendable {
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let contentScale: Double

    var pointWidth: CGFloat {
        CGFloat(Double(pixelWidth) / contentScale)
    }

    var pointHeight: CGFloat {
        CGFloat(Double(pixelHeight) / contentScale)
    }
}

struct GhosttyTerminalViewportMeasurement: Equatable, Sendable {
    let controlViewport: TmuxControlViewport
    let displayMetrics: GhosttySurfaceDisplayMetrics
    let cellMetrics: GhosttyTerminalCellDisplayMetrics

    init?(
        measuredSize: ghostty_surface_size_s,
        displayMetrics: GhosttySurfaceDisplayMetrics
    ) {
        guard let controlViewport = TmuxControlViewport(ghosttySurfaceSize: measuredSize),
              measuredSize.cell_width_px > 0,
              measuredSize.cell_height_px > 0
        else { return nil }
        self.controlViewport = controlViewport
        self.displayMetrics = displayMetrics
        cellMetrics = GhosttyTerminalCellDisplayMetrics(
            pixelWidth: measuredSize.cell_width_px,
            pixelHeight: measuredSize.cell_height_px,
            contentScale: displayMetrics.contentScale
        )
    }

    func displayMetrics(columns: UInt32, rows: UInt32) -> GhosttySurfaceDisplayMetrics? {
        let (pixelWidth, widthOverflow) = columns.multipliedReportingOverflow(
            by: cellMetrics.pixelWidth
        )
        let (pixelHeight, heightOverflow) = rows.multipliedReportingOverflow(
            by: cellMetrics.pixelHeight
        )
        guard columns > 0, rows > 0,
              !widthOverflow, !heightOverflow,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        return GhosttySurfaceDisplayMetrics(
            contentScale: displayMetrics.contentScale,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

struct GhosttySurfaceScrollState: Equatable {
    static let empty = GhosttySurfaceScrollState(total: 0, offset: 0, len: 0, cellOffset: 0)

    let total: UInt64
    let offset: UInt64
    let len: UInt64
    let cellOffset: Double

    init(total: UInt64, offset: UInt64, len: UInt64, cellOffset: Double) {
        self.total = total
        self.offset = offset
        self.len = len
        self.cellOffset = cellOffset
    }

    init(cValue: ghostty_terminal_surface_scrollbar_s) {
        self.init(
            total: cValue.total,
            offset: cValue.offset,
            len: cValue.len,
            cellOffset: cValue.cell_offset
        )
    }

    var maxRow: UInt64 {
        total > len ? total - len : 0
    }
}

enum GhosttySurfaceScrollRoute: Equatable {
    case viewport
    case altScreenCursor
    case mouseReport

    init(cValue: ghostty_terminal_surface_scroll_route_e) {
        switch cValue {
        case GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_ALTERNATE_SCREEN_CURSOR:
            self = .altScreenCursor
        case GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_REMOTE_MOUSE:
            self = .mouseReport
        default:
            self = .viewport
        }
    }
}

struct GhosttySurfaceInteractionState: Equatable {
    static let empty = GhosttySurfaceInteractionState(
        scrollState: .empty,
        scrollRoute: .viewport,
        mouseCaptured: false
    )

    let scrollState: GhosttySurfaceScrollState
    let scrollRoute: GhosttySurfaceScrollRoute
    let mouseCaptured: Bool

    init(cValue: ghostty_terminal_surface_interaction_state_s) {
        scrollState = GhosttySurfaceScrollState(cValue: cValue.scrollbar)
        scrollRoute = GhosttySurfaceScrollRoute(cValue: cValue.route)
        mouseCaptured = cValue.mouse_captured
    }

    private init(
        scrollState: GhosttySurfaceScrollState,
        scrollRoute: GhosttySurfaceScrollRoute,
        mouseCaptured: Bool
    ) {
        self.scrollState = scrollState
        self.scrollRoute = scrollRoute
        self.mouseCaptured = mouseCaptured
    }
}

private func ghosttyTerminalCellFrame(
    _ value: ghostty_terminal_surface_cell_geometry_s,
    scaleFactor: Double
) -> CGRect? {
    guard value.visible else { return nil }
    return CGRect(
        x: CGFloat(value.x_px / scaleFactor),
        y: CGFloat(value.y_px / scaleFactor),
        width: CGFloat(Double(value.width_px) / scaleFactor),
        height: CGFloat(Double(value.height_px) / scaleFactor)
    )
}

struct GhosttyLocalSelectionSnapshot: Equatable {
    static let inactive = GhosttyLocalSelectionSnapshot(
        cValue: ghostty_terminal_surface_selection_snapshot_s(),
        scaleFactor: 1
    )

    let start: CGRect?
    let end: CGRect?
    let isActive: Bool

    init(cValue: ghostty_terminal_surface_selection_snapshot_s, scaleFactor: Double) {
        start = ghosttyTerminalCellFrame(cValue.start, scaleFactor: scaleFactor)
        end = ghosttyTerminalCellFrame(cValue.end, scaleFactor: scaleFactor)
        isActive = cValue.active
    }
}

enum GhosttyLocalSelectionOutcome: Equatable {
    case snapshot(GhosttyLocalSelectionSnapshot)
    case unavailable
}

enum GhosttyLocalLinkSelectionOutcome: Equatable {
    case match(
        snapshot: GhosttyLocalSelectionSnapshot,
        explicitTarget: String?
    )
    case noMatch(snapshot: GhosttyLocalSelectionSnapshot)
    case unavailable
}

extension TmuxControlViewport {
    init?(ghosttySurfaceSize size: ghostty_surface_size_s) {
        guard size.columns > 0, size.rows > 0 else { return nil }
        self.init(
            columns: size.columns,
            rows: size.rows,
            pixelWidth: size.width_px,
            pixelHeight: size.height_px
        )
    }
}

/// Lean MainActor wrapper over one externally owned terminal surface.
/// Native lifetime fencing is owned by TmuxSessionController/TmuxPaneSurface;
/// this wrapper adds no lock, ownership mode, or alternate backend.
@MainActor
final class GhosttyKitControlSurface {
    enum Failure: Equatable {
        case native(ghostty_terminal_surface_result_e)
        case scaleChanged
    }

    let handle: ghostty_terminal_surface_t

    private let scaleFactor: Double
    private let onFailure: (Failure) -> Void
    private var invalidated = false
    private var failureReported = false

    init(
        surface: ghostty_terminal_surface_t,
        scaleFactor: Double,
        onFailure: @escaping (Failure) -> Void
    ) {
        handle = surface
        self.scaleFactor = scaleFactor
        self.onFailure = onFailure
    }

    var isInvalidated: Bool { invalidated }

    func invalidate() {
        invalidated = true
    }

    @discardableResult
    func sendInput(_ text: String) -> Bool {
        guard !invalidated else { return false }
        guard !text.isEmpty else { return true }
        return withUTF8(text) { pointer, count in
            Self.accepted(ghostty_terminal_surface_input(handle, pointer, count))
        }
    }

    @discardableResult
    func sendPaste(_ text: String) -> Bool {
        guard !invalidated else { return false }
        guard !text.isEmpty else { return true }
        return withUTF8(text) { pointer, count in
            Self.accepted(ghostty_terminal_surface_paste(handle, pointer, count))
        }
    }

    @discardableResult
    func sendKeyEvent(_ event: GhosttySurfaceKeyEvent) -> Bool {
        guard !invalidated else { return false }
        return event.withCValue {
            Self.accepted(ghostty_terminal_surface_key(handle, $0))
        }
    }

    func keyTranslationMods(_ mods: GhosttySurfaceKeyEvent.Mods) -> GhosttySurfaceKeyEvent.Mods {
        guard !invalidated else { return mods }
        let filtered = ghostty_terminal_surface_key_translation_mods(
            handle,
            ghostty_input_mods_e(mods.rawValue)
        )
        return GhosttySurfaceKeyEvent.Mods(rawValue: UInt32(filtered.rawValue))
    }

    @discardableResult
    func sendMouseButton(_ event: GhosttySurfaceMouseButtonEvent) -> Bool {
        guard !invalidated else { return false }
        return event.withCValues {
            Self.accepted(ghostty_terminal_surface_mouse_button(handle, $0, $1, $2))
        }
    }

    @discardableResult
    func sendMousePosition(
        _ position: CGPoint,
        mods: GhosttySurfaceKeyEvent.Mods = []
    ) -> Bool {
        guard !invalidated else { return false }
        return Self.accepted(ghostty_terminal_surface_mouse_pos(
            handle,
            Double(position.x) * scaleFactor,
            Double(position.y) * scaleFactor,
            ghostty_input_mods_e(mods.rawValue)
        ))
    }

    @discardableResult
    func sendMouseScroll(_ event: GhosttySurfaceMouseScrollEvent) -> Bool {
        guard !invalidated else { return false }
        return Self.accepted(ghostty_terminal_surface_mouse_scroll(
            handle,
            event.deltaX,
            event.deltaY,
            ghostty_input_scroll_mods_t(event.mods.rawValue)
        ))
    }

    func interactionState() -> GhosttySurfaceInteractionState {
        guard !invalidated else { return .empty }
        var state = ghostty_terminal_surface_interaction_state_s()
        let result = ghostty_terminal_surface_interaction_state(handle, &state)
        guard report(result) else { return .empty }
        return GhosttySurfaceInteractionState(cValue: state)
    }

    func scrollToPosition(row: UInt64, cellOffset: Double) -> GhosttySurfaceScrollState {
        guard !invalidated else { return .empty }
        var state = ghostty_terminal_surface_interaction_state_s()
        let result = ghostty_terminal_surface_scroll_to_position(
            handle,
            row,
            cellOffset,
            &state
        )
        _ = report(result)
        return GhosttySurfaceScrollState(cValue: state.scrollbar)
    }

    func isMouseCaptured() -> Bool {
        interactionState().mouseCaptured
    }

    func selectionSnapshot() -> GhosttyLocalSelectionOutcome {
        guard !invalidated else { return .unavailable }
        var snapshot = ghostty_terminal_surface_selection_snapshot_s()
        let result = ghostty_terminal_surface_selection_snapshot(handle, &snapshot)
        return selectionOutcome(result, snapshot: snapshot, retryCommittedWake: false)
    }

    func cursorGeometry() -> CGRect? {
        guard !invalidated else { return nil }
        var geometry = ghostty_terminal_surface_cell_geometry_s()
        let result = ghostty_terminal_surface_cursor_geometry(handle, &geometry)
        guard report(result) else { return nil }
        return ghosttyTerminalCellFrame(geometry, scaleFactor: scaleFactor)
    }

    func selectWord(at point: CGPoint) -> GhosttyLocalSelectionOutcome {
        mutateSelection { snapshot in
            ghostty_terminal_surface_select_word(
                handle,
                Double(point.x) * scaleFactor,
                Double(point.y) * scaleFactor,
                snapshot
            )
        }
    }

    func selectLink(at point: CGPoint) -> GhosttyLocalLinkSelectionOutcome {
        guard !invalidated else { return .unavailable }

        var snapshotValue = ghostty_terminal_surface_selection_snapshot_s()
        var matched = false
        var target = ghostty_text_s()
        let result = ghostty_terminal_surface_select_link(
            handle,
            Double(point.x) * scaleFactor,
            Double(point.y) * scaleFactor,
            &snapshotValue,
            &matched,
            &target
        )
        defer {
            if target.text != nil {
                let freeResult = ghostty_terminal_surface_free_text(handle, &target)
                assert(freeResult == GHOSTTY_TERMINAL_SURFACE_INPUT_CONSUMED_NO_OUTPUT)
            }
        }

        let snapshot = GhosttyLocalSelectionSnapshot(
            cValue: snapshotValue,
            scaleFactor: scaleFactor
        )
        switch result {
        case GHOSTTY_TERMINAL_SURFACE_RESULT_OK where matched:
            let explicitTarget = target.text == nil
                ? nil
                : Self.decodeGhosttyText(target)
            return .match(snapshot: snapshot, explicitTarget: explicitTarget)
        case GHOSTTY_TERMINAL_SURFACE_RESULT_OK:
            return .noMatch(snapshot: snapshot)
        case GHOSTTY_TERMINAL_SURFACE_RESULT_INVALID_INPUT,
             GHOSTTY_TERMINAL_SURFACE_RESULT_OUT_OF_MEMORY:
            return .unavailable
        case GHOSTTY_TERMINAL_SURFACE_RESULT_FAILED:
            let retry = ghostty_terminal_surface_terminal_changed(handle)
            guard retry == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
                fail(.native(retry))
                return .unavailable
            }
            return .unavailable
        default:
            fail(.native(result))
            return .unavailable
        }
    }

    func setSelectionEndpoint(
        _ endpoint: ghostty_terminal_surface_selection_endpoint_e,
        at point: CGPoint
    ) -> GhosttyLocalSelectionOutcome {
        mutateSelection { snapshot in
            ghostty_terminal_surface_set_selection_endpoint(
                handle,
                endpoint,
                Double(point.x) * scaleFactor,
                Double(point.y) * scaleFactor,
                snapshot
            )
        }
    }

    func clearSelection() -> GhosttyLocalSelectionOutcome {
        mutateSelection { snapshot in
            ghostty_terminal_surface_clear_selection(handle, snapshot)
        }
    }

    func readSelection() -> String? {
        guard !invalidated else { return nil }
        var text = ghostty_text_s()
        let result = ghostty_terminal_surface_read_selection(handle, &text)
        guard result == GHOSTTY_TERMINAL_SURFACE_INPUT_SENT else { return nil }
        defer {
            let freeResult = ghostty_terminal_surface_free_text(handle, &text)
            assert(freeResult == GHOSTTY_TERMINAL_SURFACE_INPUT_CONSUMED_NO_OUTPUT)
        }
        return Self.decodeGhosttyText(text)
    }

    @discardableResult
    func updateDisplay(metrics: GhosttySurfaceDisplayMetrics) -> Bool {
        guard !invalidated else { return false }
        guard metrics.contentScale == scaleFactor else {
            fail(.scaleChanged)
            return false
        }
        return report(ghostty_terminal_surface_set_size(
            handle,
            metrics.pixelWidth,
            metrics.pixelHeight
        ))
    }

    @discardableResult
    func setFocused(_ focused: Bool) -> Bool {
        guard !invalidated else { return false }
        return report(ghostty_terminal_surface_set_focused(handle, focused))
    }

    @discardableResult
    func setVisible(_ visible: Bool) -> Bool {
        guard !invalidated else { return false }
        return report(ghostty_terminal_surface_set_visible(handle, visible))
    }

    func currentSize() -> ghostty_surface_size_s {
        guard !invalidated else { return ghostty_surface_size_s() }
        var size = ghostty_surface_size_s()
        let result = ghostty_terminal_surface_size(handle, &size)
        guard report(result) else { return ghostty_surface_size_s() }
        return size
    }

    static func decodeGhosttyText(_ text: ghostty_text_s) -> String {
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
            as: UTF8.self
        )
    }

    private func mutateSelection(
        _ operation: (UnsafeMutablePointer<ghostty_terminal_surface_selection_snapshot_s>)
            -> ghostty_terminal_surface_result_e
    ) -> GhosttyLocalSelectionOutcome {
        guard !invalidated else { return .unavailable }
        var snapshot = ghostty_terminal_surface_selection_snapshot_s()
        let result = operation(&snapshot)
        return selectionOutcome(result, snapshot: snapshot, retryCommittedWake: true)
    }

    private func selectionOutcome(
        _ result: ghostty_terminal_surface_result_e,
        snapshot value: ghostty_terminal_surface_selection_snapshot_s,
        retryCommittedWake: Bool
    ) -> GhosttyLocalSelectionOutcome {
        let snapshot = GhosttyLocalSelectionSnapshot(
            cValue: value,
            scaleFactor: scaleFactor
        )
        switch result {
        case GHOSTTY_TERMINAL_SURFACE_RESULT_OK,
             GHOSTTY_TERMINAL_SURFACE_RESULT_INVALID_INPUT:
            return .snapshot(snapshot)
        case GHOSTTY_TERMINAL_SURFACE_RESULT_OUT_OF_MEMORY:
            return .unavailable
        case GHOSTTY_TERMINAL_SURFACE_RESULT_FAILED where retryCommittedWake:
            let retry = ghostty_terminal_surface_terminal_changed(handle)
            guard retry == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
                fail(.native(retry))
                return .unavailable
            }
            return .snapshot(snapshot)
        default:
            fail(.native(result))
            return .unavailable
        }
    }

    private func withUTF8<Result>(
        _ text: String,
        body: (UnsafePointer<UInt8>?, Int) -> Result
    ) -> Result {
        if let result = text.utf8.withContiguousStorageIfAvailable({ buffer in
            body(buffer.baseAddress, buffer.count)
        }) {
            return result
        }
        return Array(text.utf8).withUnsafeBufferPointer {
            body($0.baseAddress, $0.count)
        }
    }

    @discardableResult
    private func report(_ result: ghostty_terminal_surface_result_e) -> Bool {
        guard result == GHOSTTY_TERMINAL_SURFACE_RESULT_OK else {
            fail(.native(result))
            return false
        }
        return true
    }

    private func fail(_ failure: Failure) {
        guard !failureReported else { return }
        failureReported = true
        invalidated = true
        onFailure(failure)
    }

    private static func accepted(_ result: ghostty_terminal_surface_input_result_e) -> Bool {
        result == GHOSTTY_TERMINAL_SURFACE_INPUT_SENT
            || result == GHOSTTY_TERMINAL_SURFACE_INPUT_CONSUMED_NO_OUTPUT
    }
}
