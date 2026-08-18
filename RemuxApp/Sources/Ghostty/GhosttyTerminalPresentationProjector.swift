import Foundation

struct TerminalReadinessSnapshot: Equatable, Sendable {
    let phase: GhosttyTerminalRuntimePhase
    let transportWritable: Bool
    let topLevelCount: Int
    let selectedActiveLeafID: UUID?

    init(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool,
        topLevelCount: Int,
        selectedActiveLeafID: UUID?
    ) {
        precondition(topLevelCount >= 0, "topLevelCount must be non-negative")
        self.phase = phase
        self.transportWritable = transportWritable
        self.topLevelCount = topLevelCount
        self.selectedActiveLeafID = selectedActiveLeafID
    }

    var hasFocusedSurface: Bool {
        selectedActiveLeafID != nil
    }
}

enum TerminalReadinessProjector {
    static func snapshot(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool,
        topLevelCount: Int,
        selectedActiveLeafID: UUID?
    ) -> TerminalReadinessSnapshot {
        TerminalReadinessSnapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: topLevelCount,
            selectedActiveLeafID: selectedActiveLeafID
        )
    }

    static func runtimeState(_ snapshot: TerminalReadinessSnapshot) -> TerminalRuntimeState {
        runtimeState(
            phase: snapshot.phase,
            hasFocusedSurface: snapshot.hasFocusedSurface
        )
    }

    static func runtimeState(
        phase: GhosttyTerminalRuntimePhase,
        hasFocusedSurface: Bool
    ) -> TerminalRuntimeState {
        if phase == .running, hasFocusedSurface {
            return .connected
        }

        switch phase {
        case .idle, .starting, .running:
            return .connecting
        case .failed(let message, let reason):
            return .disconnected(
                reason ?? TerminalDisconnectReason(
                    kind: .unknown,
                    message: message
                )
            )
        }
    }

    static func isInputAvailable(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        isInputAvailable(
            phase: snapshot.phase,
            hasFocusedSurface: snapshot.hasFocusedSurface
        )
    }

    static func isInputAvailable(
        phase: GhosttyTerminalRuntimePhase,
        hasFocusedSurface: Bool
    ) -> Bool {
        phase == .running && hasFocusedSurface
    }

    static func isTransportAvailableForInput(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        isTransportAvailableForInput(
            phase: snapshot.phase,
            transportWritable: snapshot.transportWritable
        )
    }

    static func isTransportAvailableForInput(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool
    ) -> Bool {
        phase == .running && transportWritable
    }

    static func canSubmitInput(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        canSubmitInput(
            phase: snapshot.phase,
            transportWritable: snapshot.transportWritable,
            hasFocusedSurface: snapshot.hasFocusedSurface
        )
    }

    static func uiTestInputReady(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        canSubmitInput(snapshot)
    }

    static func canSubmitInput(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool,
        hasFocusedSurface: Bool
    ) -> Bool {
        isInputAvailable(phase: phase, hasFocusedSurface: hasFocusedSurface)
            && isTransportAvailableForInput(phase: phase, transportWritable: transportWritable)
    }

    static func isWaitingForPanes(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        isWaitingForPanes(phase: snapshot.phase, topLevelCount: snapshot.topLevelCount)
    }

    static func isWaitingForPanes(
        phase: GhosttyTerminalRuntimePhase,
        topLevelCount: Int
    ) -> Bool {
        precondition(topLevelCount >= 0, "topLevelCount must be non-negative")
        return phase == .running && topLevelCount == 0
    }

    static func isTerminalStatusReady(
        _ snapshot: TerminalReadinessSnapshot,
        commandFailureMessage: String?
    ) -> Bool {
        snapshot.phase == .running
            && snapshot.topLevelCount > 0
            && commandFailureMessage == nil
    }

    static func shouldTraceTerminalReady(_ snapshot: TerminalReadinessSnapshot) -> Bool {
        snapshot.phase == .running && snapshot.topLevelCount > 0
    }

    static func terminalReadyTraceFields(
        _ snapshot: TerminalReadinessSnapshot,
        managedSurfaceCount: Int,
        workspaceID: UUID
    ) -> [String: String] {
        precondition(managedSurfaceCount >= 0, "managedSurfaceCount must be non-negative")
        return [
            "topLevels": "\(snapshot.topLevelCount)",
            "managedSurfaces": "\(managedSurfaceCount)",
            "workspaceID": workspaceID.uuidString,
            "phase": traceValue(for: snapshot.phase),
            "transportWritable": "\(snapshot.transportWritable)",
            "selectedActiveLeafID": ghosttyDiagnosticShortID(snapshot.selectedActiveLeafID),
        ]
    }

    private static func traceValue(for phase: GhosttyTerminalRuntimePhase) -> String {
        switch phase {
        case .idle:
            "idle"
        case .starting:
            "starting"
        case .running:
            "running"
        case .failed:
            "failed"
        }
    }
}

struct GhosttyTerminalInteractionProjection: Equatable, Sendable {
    let isInputAvailable: Bool
    let hasFocusedSurface: Bool
    let selectedActiveLeafID: UUID?
    let selectedWindowIndex: Int?
    let windowCount: Int
    let paneCount: Int
    let isWaitingForPanes: Bool
}

enum GhosttyTerminalStatusOverlayProjection: Equatable, Sendable {
    case starting
    case commandFailure(String)
    case waitingForPanes(debugStatus: String, registryDebugSummary: String)
    case ready
    case failed(message: String, reason: TerminalDisconnectReason?)
}

struct GhosttyTerminalScreenPresentationProjection: Equatable {
    let readiness: TerminalReadinessSnapshot
    let interaction: GhosttyTerminalInteractionProjection
    let viewport: GhosttyTerminalViewportPresentationProjection
    let statusOverlay: GhosttyTerminalStatusOverlayProjection
}

struct GhosttyTerminalGridSize: Equatable, Sendable {
    let columns: UInt32
    let rows: UInt32
}

struct GhosttyTerminalGridRect: Equatable, Sendable {
    let x: UInt32
    let y: UInt32
    let columns: UInt32
    let rows: UInt32
}

/// One internal tmux pane boundary expressed in window-grid coordinates.
///
/// `firstPaneID` is the pane on the left of a vertical separator or above a
/// horizontal separator. `secondPaneID` is the pane on the other side. The
/// separator is presentation-only: it never changes either pane's grid rect.
struct GhosttyPaneSeparatorSegment: Equatable, Sendable {
    enum Orientation: Equatable, Sendable {
        case vertical
        case horizontal
    }

    let orientation: Orientation
    let position: CGFloat
    let start: CGFloat
    let end: CGFloat
    let firstPaneID: UUID
    let secondPaneID: UUID

    func focusedRange(focusedPaneID: UUID?, paneCount: Int) -> Range<CGFloat>? {
        guard let focusedPaneID,
              focusedPaneID == firstPaneID || focusedPaneID == secondPaneID,
              start < end
        else { return nil }

        guard paneCount == 2 else { return start..<end }

        let midpoint = start + (end - start) / 2
        return focusedPaneID == firstPaneID
            ? start..<midpoint
            : midpoint..<end
    }

    func frame(
        origin: CGPoint,
        cellSize: CGSize,
        lineWidth: CGFloat,
        range: Range<CGFloat>? = nil
    ) -> CGRect {
        let range = range ?? start..<end
        switch orientation {
        case .vertical:
            return CGRect(
                x: origin.x + position * cellSize.width - lineWidth / 2,
                y: origin.y + range.lowerBound * cellSize.height,
                width: lineWidth,
                height: (range.upperBound - range.lowerBound) * cellSize.height
            )
        case .horizontal:
            return CGRect(
                x: origin.x + range.lowerBound * cellSize.width,
                y: origin.y + position * cellSize.height - lineWidth / 2,
                width: (range.upperBound - range.lowerBound) * cellSize.width,
                height: lineWidth
            )
        }
    }
}

enum GhosttyPaneSeparatorLayout {
    struct Pane: Equatable, Sendable {
        let id: UUID
        let frame: GhosttyTerminalGridRect
    }

    static func segments(for panes: [Pane]) -> [GhosttyPaneSeparatorSegment] {
        guard panes.count > 1 else { return [] }

        var result: [GhosttyPaneSeparatorSegment] = []
        for firstIndex in panes.indices {
            for secondIndex in panes.index(after: firstIndex)..<panes.endIndex {
                if let segment = segment(
                    between: panes[firstIndex],
                    and: panes[secondIndex]
                ) {
                    result.append(segment)
                }
            }
        }
        return result
    }

    private static func segment(
        between first: Pane,
        and second: Pane
    ) -> GhosttyPaneSeparatorSegment? {
        let firstRight = Int64(first.frame.x) + Int64(first.frame.columns)
        let secondRight = Int64(second.frame.x) + Int64(second.frame.columns)
        if firstRight + 1 == Int64(second.frame.x)
            || secondRight + 1 == Int64(first.frame.x)
        {
            let firstIsLeft = firstRight < secondRight
            let left = firstIsLeft ? first : second
            let right = firstIsLeft ? second : first
            return makeSegment(
                orientation: .vertical,
                first: left,
                second: right,
                position: right.frame.x,
                firstSpan: (left.frame.y, left.frame.rows),
                secondSpan: (right.frame.y, right.frame.rows)
            )
        }

        let firstBottom = Int64(first.frame.y) + Int64(first.frame.rows)
        let secondBottom = Int64(second.frame.y) + Int64(second.frame.rows)
        if firstBottom + 1 == Int64(second.frame.y)
            || secondBottom + 1 == Int64(first.frame.y)
        {
            let firstIsTop = firstBottom < secondBottom
            let top = firstIsTop ? first : second
            let bottom = firstIsTop ? second : first
            return makeSegment(
                orientation: .horizontal,
                first: top,
                second: bottom,
                position: bottom.frame.y,
                firstSpan: (top.frame.x, top.frame.columns),
                secondSpan: (bottom.frame.x, bottom.frame.columns)
            )
        }

        return nil
    }

    private static func makeSegment(
        orientation: GhosttyPaneSeparatorSegment.Orientation,
        first: Pane,
        second: Pane,
        position: UInt32,
        firstSpan: (start: UInt32, length: UInt32),
        secondSpan: (start: UInt32, length: UInt32)
    ) -> GhosttyPaneSeparatorSegment? {
        let start = max(Int64(firstSpan.start), Int64(secondSpan.start))
        let end = min(
            Int64(firstSpan.start) + Int64(firstSpan.length),
            Int64(secondSpan.start) + Int64(secondSpan.length)
        )
        guard start < end else { return nil }

        return GhosttyPaneSeparatorSegment(
            orientation: orientation,
            position: CGFloat(position) - 0.5,
            start: CGFloat(start) - 0.5,
            end: CGFloat(end) + 0.5,
            firstPaneID: first.id,
            secondPaneID: second.id
        )
    }
}

struct GhosttyCompositeViewportLayout: Equatable {
    let origin: CGPoint
    let canvasSize: CGSize
    let cellSize: CGSize

    init?(
        bounds: CGRect,
        grid: GhosttyTerminalGridSize,
        cellMetrics: GhosttyTerminalCellDisplayMetrics
    ) {
        guard grid.columns > 0, grid.rows > 0,
              cellMetrics.pixelWidth > 0, cellMetrics.pixelHeight > 0,
              cellMetrics.contentScale.isFinite,
              cellMetrics.contentScale > 0
        else { return nil }
        let scale = CGFloat(cellMetrics.contentScale)
        cellSize = CGSize(
            width: CGFloat(cellMetrics.pixelWidth) / scale,
            height: CGFloat(cellMetrics.pixelHeight) / scale
        )
        canvasSize = CGSize(
            width: CGFloat(grid.columns) * cellSize.width,
            height: CGFloat(grid.rows) * cellSize.height
        )
        let unsnappedOrigin = CGPoint(
            x: max((bounds.width - canvasSize.width) / 2, 0),
            y: max((bounds.height - canvasSize.height) / 2, 0)
        )
        origin = CGPoint(
            x: (unsnappedOrigin.x * scale).rounded() / scale,
            y: (unsnappedOrigin.y * scale).rounded() / scale
        )
    }

    func frame(for gridRect: GhosttyTerminalGridRect) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(gridRect.x) * cellSize.width,
            y: origin.y + CGFloat(gridRect.y) * cellSize.height,
            width: CGFloat(gridRect.columns) * cellSize.width,
            height: CGFloat(gridRect.rows) * cellSize.height
        )
    }
}

/// The authoritative tmux window grid projected into one Remux viewport.
///
/// Pane rectangles remain expressed in tmux cells. UIKit converts them to
/// points only at the final layout boundary, so topology never depends on
/// device pixels or renderer state.
struct GhosttyTerminalViewportPresentationProjection: Equatable {
    struct Pane: Identifiable, Equatable, Sendable {
        let id: UUID
        let normalFrame: GhosttyTerminalGridRect
        let visibleFrame: GhosttyTerminalGridRect?
        let isFocused: Bool
        let tmuxCurrentCommand: String
        let tmuxCurrentPath: String
    }

    static let empty = GhosttyTerminalViewportPresentationProjection(
        windowGrid: nil,
        cellMetrics: nil,
        panes: [],
        focusedSurfaceID: nil,
        isServerZoomed: false,
        windowCount: 0
    )

    let windowGrid: GhosttyTerminalGridSize?
    let cellMetrics: GhosttyTerminalCellDisplayMetrics?
    let panes: [Pane]
    let focusedSurfaceID: UUID?
    let isServerZoomed: Bool
    let windowCount: Int

    var canNavigateWindows: Bool {
        windowCount > 1
    }
}

enum GhosttyTmuxTopologyActionInteractionEffect: Equatable, Sendable {
    case none
    case refocusOnly
    case refocusAndDismissOnQueued

    var requestsInputRefocus: Bool {
        switch self {
        case .none:
            false
        case .refocusOnly, .refocusAndDismissOnQueued:
            true
        }
    }

    var dismissesSelectionSheetOnQueued: Bool {
        self == .refocusAndDismissOnQueued
    }
}

struct GhosttyWindowSheetPresentationProjection: Equatable, Sendable {
    let previewLeafIDs: [UUID]
}

struct GhosttyPaneSheetPresentationProjection: Equatable, Sendable {
    let topLevelID: UUID
}

struct GhosttyPaneSelectionSheetTopologyProjection: Equatable, Sendable {
    let topLevelID: UUID?
    let shouldDismissPaneSheet: Bool
}

struct GhosttyWindowSelectionSheetRenderProjection: Equatable, Sendable {
    struct Window: Identifiable, Equatable, Sendable {
        let id: UUID
        let displayName: String
        let displayIndex: Int
        let totalCount: Int
        let paneCount: Int
        let isSelected: Bool
        let focusedPreviewPaneID: UUID?
    }

    let windows: [Window]
    let selectedWindowID: UUID?
    let previewLeafIDs: [UUID]
}

struct GhosttyPaneSelectionSheetRenderProjection: Equatable, Sendable {
    struct Pane: Identifiable, Equatable, Sendable {
        let id: UUID
        let frame: GhosttyTerminalGridRect?
        let tmuxCurrentCommand: String
        let tmuxCurrentPath: String
    }

    let panes: [Pane]
    let selectedPaneID: UUID?
    let isServerZoomed: Bool

    var paneCount: Int { panes.count }
}

@MainActor
enum GhosttyTerminalPresentationProjector {
    static func terminalScreenPresentationProjection(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool,
        commandFailureMessage: String?,
        debugStatus: String,
        registryDebugSummary: String,
        presentedSurfaceID: UUID?,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot,
        viewportProjection: GhosttyTerminalViewportPresentationProjection
    ) -> GhosttyTerminalScreenPresentationProjection {
        let readiness = TerminalReadinessProjector.snapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: snapshot.topLevels.count,
            selectedActiveLeafID: presentedSurfaceID
        )

        return GhosttyTerminalScreenPresentationProjection(
            readiness: readiness,
            interaction: terminalInteractionProjection(
                phase: phase,
                presentedSurfaceID: presentedSurfaceID,
                snapshot: snapshot
            ),
            viewport: viewportProjection,
            statusOverlay: terminalStatusOverlayProjection(
                readiness: readiness,
                commandFailureMessage: commandFailureMessage,
                debugStatus: debugStatus,
                registryDebugSummary: registryDebugSummary
            )
        )
    }

    static func terminalStatusOverlayProjection(
        readiness: TerminalReadinessSnapshot,
        commandFailureMessage: String?,
        debugStatus: String,
        registryDebugSummary: String
    ) -> GhosttyTerminalStatusOverlayProjection {
        switch readiness.phase {
        case .idle, .starting:
            return .starting
        case .failed(let message, let reason):
            return .failed(message: message, reason: reason)
        case .running:
            if let commandFailureMessage {
                return .commandFailure(commandFailureMessage)
            }
            let waitingProjection = GhosttyTerminalStatusOverlayProjection.waitingForPanes(
                debugStatus: debugStatus,
                registryDebugSummary: registryDebugSummary
            )
            if TerminalReadinessProjector.isWaitingForPanes(readiness) {
                return waitingProjection
            }
            if TerminalReadinessProjector.isTerminalStatusReady(
                readiness,
                commandFailureMessage: nil
            ) {
                return .ready
            }
            return waitingProjection
        }
    }

    static func terminalInteractionProjection(
        phase: GhosttyTerminalRuntimePhase,
        presentedSurfaceID: UUID?,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTerminalInteractionProjection {
        let selectedTopLevel = snapshot.selectedTopLevel
        let hasFocusedSurface = presentedSurfaceID != nil

        return GhosttyTerminalInteractionProjection(
            isInputAvailable: TerminalReadinessProjector.isInputAvailable(
                phase: phase,
                hasFocusedSurface: hasFocusedSurface
            ),
            hasFocusedSurface: hasFocusedSurface,
            selectedActiveLeafID: presentedSurfaceID,
            selectedWindowIndex: snapshot.selectedTopLevelIndex,
            windowCount: snapshot.topLevels.count,
            paneCount: selectedTopLevel?.leafIDs.count ?? 0,
            isWaitingForPanes: TerminalReadinessProjector.isWaitingForPanes(
                phase: phase,
                topLevelCount: snapshot.topLevels.count
            )
        )
    }

    static func createTmuxWindowInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    static func splitFocusedTmuxPaneInteractionEffect() -> GhosttyTmuxTopologyActionInteractionEffect {
        .refocusAndDismissOnQueued
    }

    static func closeTmuxWindowInteractionEffect(
        _ id: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard snapshot.topLevels.contains(where: { $0.id == id }) else {
            return .none
        }

        return snapshot.topLevels.count <= 1 ? .refocusAndDismissOnQueued : .none
    }

    static func closeTmuxPaneInteractionEffect(
        _ id: UUID,
        inTopLevel topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyTmuxTopologyActionInteractionEffect {
        guard
            let topLevel = snapshot.topLevels.first(where: { $0.id == topLevelID }),
            topLevel.leafIDs.contains(id)
        else {
            return .none
        }

        return topLevel.leafIDs.count == 1 ? .refocusOnly : .none
    }

    static func windowSheetPresentationProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyWindowSheetPresentationProjection? {
        guard !snapshot.topLevels.isEmpty else { return nil }

        return GhosttyWindowSheetPresentationProjection(
            previewLeafIDs: prioritizedWindowPreviewLeafIDs(snapshot: snapshot)
        )
    }

    static func selectedPaneSheetPresentationProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyPaneSheetPresentationProjection? {
        guard let topLevel = snapshot.selectedTopLevel else { return nil }

        return GhosttyPaneSheetPresentationProjection(topLevelID: topLevel.id)
    }

    static func paneCount(
        topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> Int {
        snapshot.topLevels.first(where: { $0.id == topLevelID })?.leafIDs.count ?? 0
    }

    static func paneSelectionSheetTopologyProjection(
        topLevelID: UUID?,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyPaneSelectionSheetTopologyProjection {
        guard let topLevelID else {
            return GhosttyPaneSelectionSheetTopologyProjection(
                topLevelID: nil,
                shouldDismissPaneSheet: false
            )
        }

        let topLevelIsSelected = snapshot.selectedTopLevelID == topLevelID
        return GhosttyPaneSelectionSheetTopologyProjection(
            topLevelID: topLevelID,
            shouldDismissPaneSheet: !topLevelIsSelected
        )
    }

    static func windowSelectionSheetRenderProjection(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> GhosttyWindowSelectionSheetRenderProjection {
        let topLevels = snapshot.topLevels
        let selectedWindowID = snapshot.selectedTopLevel?.id
        let totalCount = topLevels.count
        let windows = topLevels.enumerated().map { index, topLevel in
            GhosttyWindowSelectionSheetRenderProjection.Window(
                id: topLevel.id,
                displayName: displaySafeWindowName(topLevel.name),
                displayIndex: index + 1,
                totalCount: totalCount,
                paneCount: topLevel.leafIDs.count,
                isSelected: topLevel.id == selectedWindowID,
                focusedPreviewPaneID: topLevel.resolvedFocusedLeafID
            )
        }

        return GhosttyWindowSelectionSheetRenderProjection(
            windows: windows,
            selectedWindowID: selectedWindowID,
            previewLeafIDs: prioritizedWindowPreviewLeafIDs(snapshot: snapshot)
        )
    }

    private static func prioritizedWindowPreviewLeafIDs(
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot
    ) -> [UUID] {
        let selectedTopLevelID = snapshot.selectedTopLevelID
        let selected = snapshot.selectedTopLevel?.resolvedFocusedLeafID
        let remaining = snapshot.topLevels.lazy
            .filter { $0.id != selectedTopLevelID }
            .compactMap(\.resolvedFocusedLeafID)
        return [selected].compactMap { $0 } + remaining
    }

    private static func displaySafeWindowName(_ name: String) -> String {
        name.unicodeScalars.reduce(into: "") { result, scalar in
            guard scalar.properties.generalCategory != .control else { return }
            result.unicodeScalars.append(scalar)
        }
    }

    static func paneSelectionSheetRenderProjection(
        topLevelID: UUID,
        snapshot: GhosttyRuntimeSurfaceTopologySnapshot,
        viewport: GhosttyTerminalViewportPresentationProjection? = nil
    ) -> GhosttyPaneSelectionSheetRenderProjection {
        guard let topLevel = snapshot.topLevels.first(where: { $0.id == topLevelID }) else {
            return GhosttyPaneSelectionSheetRenderProjection(
                panes: [],
                selectedPaneID: nil,
                isServerZoomed: false
            )
        }

        let selectedPaneID = viewport?.focusedSurfaceID.flatMap { focusedID in
            topLevel.leafIDs.contains(focusedID) ? focusedID : nil
        } ?? topLevel.resolvedFocusedLeafID
        let viewportPanesByID = Dictionary(
            uniqueKeysWithValues: (viewport?.panes ?? []).map { ($0.id, $0) }
        )
        let panes = topLevel.leafIDs.map { paneID in
            GhosttyPaneSelectionSheetRenderProjection.Pane(
                id: paneID,
                frame: viewportPanesByID[paneID]?.normalFrame,
                tmuxCurrentCommand: viewportPanesByID[paneID]?.tmuxCurrentCommand ?? "",
                tmuxCurrentPath: viewportPanesByID[paneID]?.tmuxCurrentPath ?? ""
            )
        }

        return GhosttyPaneSelectionSheetRenderProjection(
            panes: panes,
            selectedPaneID: selectedPaneID,
            isServerZoomed: viewport?.isServerZoomed ?? false
        )
    }
}
