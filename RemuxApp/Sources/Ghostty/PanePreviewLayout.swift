import CoreGraphics
import UIKit

/// Single source of truth for window-preview and proportional pane-map
/// geometry plus their physical capture budgets.
///
/// Used by:
/// - `GhosttyPanePreviewSession` for the local image budget
/// - the window and pane selection sheets for preview placement
///
/// Capture once per session at session-init time. Rotation while a selection
/// sheet is open does not justify reissuing previews; we keep the originally
/// requested image regardless.
enum PanePreviewLayout {
    struct PaneMapMetrics: Equatable {
        let size: CGSize
        let cellSize: CGSize

        func frame(for pane: GhosttyTerminalGridRect) -> CGRect {
            CGRect(
                x: CGFloat(pane.x) * cellSize.width,
                y: CGFloat(pane.y) * cellSize.height,
                width: CGFloat(pane.columns) * cellSize.width,
                height: CGFloat(pane.rows) * cellSize.height
            )
        }
    }

    struct Metrics: Equatable {
        let columnCount: Int
        let tilePointSize: CGSize
        let previewPointSize: CGSize
        let gridSpacing: CGFloat
        let tilePadding: CGFloat

        func gridHeight(itemCount: Int) -> CGFloat {
            guard itemCount > 0 else { return 0 }
            let rows = (itemCount + columnCount - 1) / columnCount
            return CGFloat(rows) * tilePointSize.height
                + CGFloat(rows - 1) * gridSpacing
        }
    }

    /// Height for a selector sheet's scrollable grid. The whole grid shows
    /// exactly whenever it fits within the height budget — the sheet grows
    /// rather than hiding part of the final row. Only grids larger than the
    /// budget scroll, showing complete rows plus half of the next tile so
    /// the cut is an unmistakable scroll affordance.
    @MainActor
    static func gridIdealHeight(itemCount: Int, metrics: Metrics) -> CGFloat {
        let fullHeight = metrics.gridHeight(itemCount: itemCount)
        let budget = UIScreen.main.bounds.height * 0.72
        guard fullHeight > budget else { return fullHeight }

        let tile = metrics.tilePointSize.height
        let spacing = metrics.gridSpacing
        let peek = tile * 0.5

        func height(fullRows: Int) -> CGFloat {
            CGFloat(fullRows) * tile + CGFloat(fullRows - 1) * spacing + spacing + peek
        }

        var rows = 1
        while height(fullRows: rows + 1) <= budget {
            rows += 1
        }
        return min(height(fullRows: rows), fullHeight)
    }

    private static let defaultSheetContentWidth: CGFloat = 361
    private static let sheetHorizontalPadding: CGFloat = 32
    private static let defaultPreviewAspectRatio: CGFloat = 4.0 / 3.0
    private static let tilePadding: CGFloat = 8
    private static let windowCaptionHeight: CGFloat = 30
    private static let tileCaptionSpacing: CGFloat = 6

    /// Window grid uses a fixed two-column layout. The "New Window" affordance
    /// is a fixed sheet action, not a trailing grid cell, so dense sessions can
    /// scroll windows without hiding the create command.
    private static let windowGridColumnCount: Int = 2
    private static let windowGridSpacing: CGFloat = 10

    /// Display scale captured once at session init. Avoids touching
    /// UIScreen.main during request construction or rendering.
    @MainActor
    static func currentScale() -> CGFloat {
        let scale = UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    @MainActor
    static func currentSheetContentWidth() -> CGFloat {
        let width = UIScreen.main.bounds.width - sheetHorizontalPadding
        return width.isFinite && width > 0 ? width : defaultSheetContentWidth
    }

    static func paneMapMetrics(
        windowGrid: GhosttyTerminalGridSize,
        availableWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> PaneMapMetrics? {
        guard windowGrid.columns > 0, windowGrid.rows > 0,
              availableWidth.isFinite, availableWidth > 0,
              maximumHeight.isFinite, maximumHeight > 0
        else { return nil }

        let side = min(availableWidth, maximumHeight)
        guard side.isFinite, side > 0 else { return nil }

        return PaneMapMetrics(
            size: CGSize(width: side, height: side),
            cellSize: CGSize(
                width: side / CGFloat(windowGrid.columns),
                height: side / CGFloat(windowGrid.rows)
            )
        )
    }

    @MainActor
    static func paneMapMetricsForCurrentScreen(
        windowGrid: GhosttyTerminalGridSize
    ) -> PaneMapMetrics? {
        paneMapMetrics(
            windowGrid: windowGrid,
            availableWidth: currentSheetContentWidth(),
            maximumHeight: currentPaneMapMaximumHeight()
        )
    }

    @MainActor
    static func currentPaneMapMaximumHeight() -> CGFloat {
        UIScreen.main.bounds.height * 0.54
    }

    static func paneMapPhysicalPixelBudget(
        availableWidth: CGFloat,
        maximumHeight: CGFloat,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let safeScale = max(scale, 1)
        let side = min(availableWidth, maximumHeight)
        return (
            clampUInt32((side * safeScale).rounded(.up)),
            clampUInt32((side * safeScale).rounded(.up))
        )
    }

    @MainActor
    static func windowMetricsForCurrentScreen() -> Metrics {
        windowMetrics(availableWidth: currentSheetContentWidth())
    }

    static func windowMetrics(
        availableWidth: CGFloat
    ) -> Metrics {
        let safeAvailableWidth = max(availableWidth, 1)
        let columnCount = windowGridColumnCount
        let totalGridSpacing = CGFloat(columnCount - 1) * windowGridSpacing
        let tileWidth = max(
            1,
            floor((safeAvailableWidth - totalGridSpacing) / CGFloat(columnCount))
        )
        let previewWidth = max(1, tileWidth - tilePadding * 2)
        let previewHeight = ceil(previewWidth / defaultPreviewAspectRatio)
        let tileHeight = previewHeight + tileCaptionSpacing + windowCaptionHeight + tilePadding * 2
        return .init(
            columnCount: columnCount,
            tilePointSize: CGSize(width: tileWidth, height: tileHeight),
            previewPointSize: CGSize(width: previewWidth, height: previewHeight),
            gridSpacing: windowGridSpacing,
            tilePadding: tilePadding
        )
    }

    static func windowPhysicalPixelBudget(
        availableWidth: CGFloat,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let metrics = windowMetrics(availableWidth: availableWidth)
        let safeScale = max(scale, 1)
        let widthPx = (metrics.previewPointSize.width * safeScale).rounded(.up)
        let heightPx = (metrics.previewPointSize.height * safeScale).rounded(.up)
        return (
            clampUInt32(widthPx),
            clampUInt32(heightPx)
        )
    }

    private static func clampUInt32(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 1 }
        let clamped = min(value, CGFloat(UInt32.max))
        return max(1, UInt32(clamped))
    }
}
