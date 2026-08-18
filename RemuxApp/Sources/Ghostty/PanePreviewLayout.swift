import CoreGraphics
import UIKit

/// Single source of truth for window-preview geometry and capture budgets.
///
/// Used by:
/// - the screen when creating a preview session
/// - the window selection sheet for preview placement
///
/// Capture resolves once when the picker opens. Rendering and sheet sizing use
/// the live available size, so rotation updates the grid without recapturing
/// the existing 4:3 preview images.
enum PanePreviewLayout {
    struct Metrics: Equatable {
        let columnCount: Int
        let tilePointSize: CGSize
        /// Terminal image size inside the card, before display scaling.
        let capturePointSize: CGSize
        let gridSpacing: CGFloat

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
    static func gridIdealHeight(
        itemCount: Int,
        metrics: Metrics,
        maximumContentHeight: CGFloat
    ) -> CGFloat {
        let fullHeight = metrics.gridHeight(itemCount: itemCount)
        let budget = max(0, maximumContentHeight)
        guard fullHeight > budget else { return fullHeight }
        guard budget > 0 else { return 0 }

        let tile = metrics.tilePointSize.height
        let spacing = metrics.gridSpacing
        let peek = tile * 0.5

        func completedHeight(rows: Int) -> CGFloat {
            CGFloat(rows) * tile + CGFloat(max(0, rows - 1)) * spacing
        }

        var rows = 0
        while completedHeight(rows: rows + 1) <= budget {
            rows += 1
        }
        guard rows > 0 else { return budget }

        let heightWithPeek = completedHeight(rows: rows) + spacing + peek
        return min(heightWithPeek, fullHeight, budget)
    }

    private static let defaultPreviewAspectRatio: CGFloat = 4.0 / 3.0
    private static let previewCaptureHorizontalInset: CGFloat = 8
    private static let portraitCardHeightRatio: CGFloat = 1.10
    private static let landscapeCardHeightRatio: CGFloat = 3.0 / 4.0

    /// The "New Window" affordance is a fixed sheet action, not a trailing grid
    /// cell, so dense sessions can scroll without hiding the create command.
    private static let portraitColumnCount: Int = 2
    private static let landscapeColumnCount: Int = 3
    private static let windowGridSpacing: CGFloat = 10

    /// Fallback image scale for previews rendered outside an environment-backed
    /// screen view.
    @MainActor
    static func currentScale() -> CGFloat {
        let scale = UIScreen.main.scale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    static func windowMetrics(
        availableSize: CGSize
    ) -> Metrics {
        let contentWidth = TerminalSelectionSheetLayout.contentWidth(
            availableWidth: availableSize.width
        )
        let usesLandscapeLayout = availableSize.width > availableSize.height
        let columnCount = usesLandscapeLayout ? landscapeColumnCount : portraitColumnCount
        let cardHeightRatio = usesLandscapeLayout
            ? landscapeCardHeightRatio
            : portraitCardHeightRatio
        let totalGridSpacing = CGFloat(columnCount - 1) * windowGridSpacing
        let tileWidth = max(
            1,
            floor((contentWidth - totalGridSpacing) / CGFloat(columnCount))
        )
        let captureWidth = max(1, tileWidth - previewCaptureHorizontalInset * 2)
        let captureHeight = ceil(captureWidth / defaultPreviewAspectRatio)
        let tileHeight = ceil(tileWidth * cardHeightRatio)
        return .init(
            columnCount: columnCount,
            tilePointSize: CGSize(width: tileWidth, height: tileHeight),
            capturePointSize: CGSize(width: captureWidth, height: captureHeight),
            gridSpacing: windowGridSpacing
        )
    }

    static func windowPhysicalPixelBudget(
        metrics: Metrics,
        scale: CGFloat
    ) -> (width: UInt32, height: UInt32) {
        let safeScale = max(scale, 1)
        let widthPx = (metrics.capturePointSize.width * safeScale).rounded(.up)
        let heightPx = (metrics.capturePointSize.height * safeScale).rounded(.up)
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
