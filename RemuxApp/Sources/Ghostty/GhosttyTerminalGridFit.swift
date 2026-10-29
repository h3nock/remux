import Foundation

/// The font size at which a terminal's grid fills an area, as a popup's grid is shown over the whole
/// terminal area: the largest that fits, so the text is drawn at its own size rather than scaled. Ghostty
/// sizes a cell from the font in whole pixels, so a size is measured, not computed from the base cell.
struct GhosttyTerminalGridFit: Equatable {
    let fontSize: Float32
    let cell: GhosttyTerminalCellDisplayMetrics

    /// Sizes are tried in half points.
    static let step: Float32 = 0.5
    /// No larger than three times the screen's font, so a grid of a few cells stays readable text.
    static let maximumScale: Float32 = 3
    static let minimumFontSize: Float32 = 4
    /// Cells are whole pixels, so the base cell's rounding can put the largest size that fits a little
    /// above the size it suggests; the search starts this much higher.
    static let estimateHeadroom: Float32 = 1.1
    /// A fit this many points short of the best is kept while it still fits: a new size takes a new
    /// renderer.
    static let slack: Float32 = 1

    /// The fit to show `columns` × `rows` in an area of `areaPixels`: `current` while it still fits and is
    /// within `slack` of the best, else the best, measured with `measure` from the screen's font at
    /// `baseFontSize`, whose cell is `baseCell`. Nil when not even the smallest size fits.
    static func next(
        current: Self?,
        columns: UInt16,
        rows: UInt16,
        areaPixels: (width: UInt32, height: UInt32),
        baseFontSize: Float32,
        baseCell: GhosttyTerminalCellDisplayMetrics,
        measure: (Float32) -> GhosttyTerminalCellDisplayMetrics?
    ) -> Self? {
        guard columns > 0, rows > 0, areaPixels.width > 0, areaPixels.height > 0,
              baseFontSize > 0, baseCell.pixelWidth > 0, baseCell.pixelHeight > 0
        else { return nil }
        func fits(_ cell: GhosttyTerminalCellDisplayMetrics) -> Bool {
            UInt64(columns) * UInt64(cell.pixelWidth) <= UInt64(areaPixels.width)
                && UInt64(rows) * UInt64(cell.pixelHeight) <= UInt64(areaPixels.height)
        }
        let ratio = min(
            Double(areaPixels.width) / (Double(columns) * Double(baseCell.pixelWidth)),
            Double(areaPixels.height) / (Double(rows) * Double(baseCell.pixelHeight))
        )
        let largest = min(Float32(ratio) * baseFontSize * estimateHeadroom, maximumScale * baseFontSize)
        var size = (largest / step).rounded(.down) * step
        var best: Self?
        while size >= minimumFontSize {
            if let cell = measure(size), fits(cell) {
                best = Self(fontSize: size, cell: cell)
                break
            }
            size -= step
        }
        guard let best else { return nil }
        if let current, current.cell.contentScale == baseCell.contentScale, fits(current.cell),
           current.fontSize <= best.fontSize,
           best.fontSize - current.fontSize <= slack {
            return current
        }
        return best
    }
}
