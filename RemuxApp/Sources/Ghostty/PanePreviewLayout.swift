import CoreGraphics

/// Single source of truth for window-preview geometry and capture budgets.
///
/// A tile is a picture of its window's focused pane over a caption. A preview
/// holds the pane's own pixels for the area the picture shows, with the scale
/// they are drawn at, so it is scaled once, as it is drawn, and a tile of
/// another size is captured again.
enum PanePreviewLayout {
    struct Metrics: Equatable {
        let columnCount: Int
        let tilePointSize: CGSize
        /// The tile's picture: its terminal background, with the preview inside the insets.
        let picturePointSize: CGSize
        let gridSpacing: CGFloat
        /// Wider than the gap under a picture, so a caption reads as its own picture's.
        let rowSpacing: CGFloat

        /// The preview image's size inside the picture, before display scaling.
        var capturePointSize: CGSize {
            CGSize(
                width: max(1, picturePointSize.width - PanePreviewLayout.pictureInset * 2),
                height: max(1, picturePointSize.height - PanePreviewLayout.pictureInset * 2)
            )
        }

        func gridHeight(itemCount: Int) -> CGFloat {
            guard itemCount > 0 else { return 0 }
            let rows = (itemCount + columnCount - 1) / columnCount
            return CGFloat(rows) * tilePointSize.height
                + CGFloat(rows - 1) * rowSpacing
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
        let spacing = metrics.rowSpacing
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

    static let captionHeight: CGFloat = 20
    static let pictureToCaptionSpacing: CGFloat = 6
    /// The picture's own padding, as a terminal has.
    static let pictureInset: CGFloat = 6
    /// The smallest a preview draws its pane's pixels, so text stays readable in a tile narrow for its
    /// window; such a preview shows the window's leading part.
    private static let minimumPreviewZoom: CGFloat = 0.4
    private static let rowsBelowCursor = 3

    private static let portraitCardHeightRatio: CGFloat = 1.10
    private static let landscapeCardHeightRatio: CGFloat = 3.0 / 4.0

    private static let portraitColumnCount: Int = 2
    private static let landscapeColumnCount: Int = 3
    private static let windowGridSpacing: CGFloat = 10
    private static let windowRowSpacing: CGFloat = 16

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
        let tileHeight = ceil(tileWidth * cardHeightRatio)
        return .init(
            columnCount: columnCount,
            tilePointSize: CGSize(width: tileWidth, height: tileHeight),
            picturePointSize: CGSize(
                width: tileWidth,
                height: max(1, tileHeight - captionHeight - pictureToCaptionSpacing)
            ),
            gridSpacing: windowGridSpacing,
            rowSpacing: windowRowSpacing
        )
    }

    static func windowPhysicalPixelBudget(
        metrics: Metrics,
        scale: CGFloat
    ) -> GhosttyPanePreviewSession.PixelBudget {
        let safeScale = max(scale, 1)
        return .init(
            width: clampUInt32((metrics.capturePointSize.width * safeScale).rounded(.down)),
            height: clampUInt32((metrics.capturePointSize.height * safeScale).rounded(.down))
        )
    }

    /// How large a preview draws its pane's pixels: its window's whole width fits the preview, so every
    /// preview of a session draws text at one size and a split pane takes its share of the width.
    /// `windowWidth` is the window's, in the pane's pixels.
    static func previewZoom(
        windowWidth: Int,
        budget: GhosttyPanePreviewSession.PixelBudget
    ) -> CGFloat {
        guard windowWidth > 0 else { return 1 }
        return min(1, max(minimumPreviewZoom, CGFloat(budget.width) / CGFloat(windowWidth)))
    }

    /// The part of a pane's published frame its preview shows, in the frame's pixels: from the left
    /// edge, where lines start, in whole rows ending a few below the cursor's, which hold a program's
    /// footer when it has one and are empty under a shell's prompt. Fewer rows there, or above, show
    /// the pane's last, or first, rows.
    ///
    /// `cursorRowTop` is the top of the cursor's row; nil shows the frame's last rows, which then may
    /// start part-way through a row.
    static func previewSourceRect(
        frameWidth: Int,
        frameHeight: Int,
        cellHeight: Int,
        cursorRowTop: CGFloat?,
        budget: GhosttyPanePreviewSession.PixelBudget,
        zoom: CGFloat
    ) -> CGRect? {
        guard frameWidth > 0, frameHeight > 0, budget.width > 0, budget.height > 0,
              zoom.isFinite, zoom > 0
        else { return nil }

        let width = min(frameWidth, Int((CGFloat(budget.width) / zoom).rounded(.up)))
        let maximumHeight = max(1, Int((CGFloat(budget.height) / zoom).rounded(.down)))
        guard cellHeight > 0, cellHeight <= maximumHeight,
              let cursorRowTop, cursorRowTop.isFinite,
              cursorRowTop >= 0, cursorRowTop < CGFloat(frameHeight)
        else {
            let height = min(frameHeight, maximumHeight)
            return CGRect(x: 0, y: frameHeight - height, width: width, height: height)
        }

        let cursorTop = Int(cursorRowTop.rounded())
        let rows = maximumHeight / cellHeight
        let firstRowTop = cursorTop % cellHeight
        let lastRowBottom = cursorTop + (frameHeight - cursorTop) / cellHeight * cellHeight
        let bottom = min(lastRowBottom, cursorTop + (1 + rowsBelowCursor) * cellHeight)
        let top = max(firstRowTop, bottom - rows * cellHeight)
        return CGRect(x: 0, y: top, width: width, height: min(rows * cellHeight, lastRowBottom - top))
    }

    private static func clampUInt32(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 1 }
        let clamped = min(value, CGFloat(UInt32.max))
        return max(1, UInt32(clamped))
    }

}
