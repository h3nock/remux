import UIKit

/// A popup the backend shows over the terminal area, framed as Herdr's client frames one: a box of lines on
/// the outer cells of its viewport grid, drawn as the panes' lines are, the popup's title in its top line, and
/// the popup's terminal in the cells inside, at the panes' font. Remux adds the tab it is open over at the
/// top line's other end. The terminal area hosts it over the panes and under the selection's handles, and a
/// touch on its terminal does what it does on a pane's (`GhosttyCompositeViewportContainerView`). It takes
/// the area's bounds; each new placement of its terminal is recorded in the diagnostics, for the popup's
/// layout record.
final class GhosttyTerminalPopupFrameView: UIView {
    /// The popup's terminal. It draws the grid of Herdr's frames at its cells' size from the top left of the
    /// cells inside the frame: while Herdr's frames catch up with a new grid, the grid drawn has more or fewer
    /// cells than there are, as the panes' canvas does.
    let terminal = GhosttyPaneScrollContainerView()
    /// The surface the terminal draws, once the popup has one.
    private(set) var surface: GhosttyManagedSurface?
    /// The cells inside the frame, which the terminal draws only within.
    private let content = UIView()
    /// The frame's lines on the grid's canvas, in front of the panes, which the canvas hides.
    private let lines = GhosttyPaneLinesUIView()
    private let title = UILabel()
    private let tab = UILabel()
    private var popup: GhosttyTerminalViewportPresentationProjection.Popup?
    private var drawable: CGSize?
    private var recorded: (cells: CGRect, drawable: CGSize)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "terminal.popup"
        lines.accessibilityElementsHidden = true
        content.clipsToBounds = true
        content.isAccessibilityElement = true
        content.accessibilityLabel = "Terminal"
        content.accessibilityIdentifier = "terminal.popup.content"
        terminal.backgroundColor = .clear
        title.accessibilityTraits = .header
        title.accessibilityIdentifier = "terminal.popup.title"
        tab.accessibilityIdentifier = "terminal.popup.tab"
        for label in [title, tab] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        addSubview(lines)
        addSubview(content)
        addSubview(title)
        addSubview(tab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `popup`, its terminal drawn by `surface` once it has one and the grid and cell it draws.
    func show(
        _ popup: GhosttyTerminalViewportPresentationProjection.Popup,
        surface: GhosttyManagedSurface?,
        displayScale: CGFloat,
        submitScroll: ((UUID, GhosttySurfaceMouseScrollEvent) -> GhosttyMouseInputSubmissionOutcome)?,
        submitPointer: ((UUID, CGPoint, GhosttySurfaceKeyEvent.Mods) -> GhosttyMouseInputSubmissionOutcome)?
    ) {
        self.popup = popup
        title.text = popup.title
        tab.text = popup.tabLabel.map { "over \($0)" }
        tab.isHidden = popup.tabLabel == nil
        guard let surface, let grid = popup.grid, let cell = popup.cell, cell.contentScale > 0 else {
            detachSurface()
            return
        }
        self.surface = surface
        drawable = CGSize(
            width: Double(grid.columns) * Double(cell.pixelWidth) / cell.contentScale,
            height: Double(grid.rows) * Double(cell.pixelHeight) / cell.contentScale
        )
        if terminal.superview !== content { content.addSubview(terminal) }
        terminal.update(
            surface: surface,
            displayScale: displayScale,
            submitRouteForwardedMouseScroll: submitScroll,
            submitRouteForwardedMousePosition: submitPointer
        )
    }

    /// Lays the popup out on its own viewport, at the panes' font. Its covered tab may keep another grid.
    /// Call it without animation, as the panes are laid out: its cell geometry never animates.
    func place(
        cellMetrics: GhosttyTerminalCellDisplayMetrics?,
        inks: GhosttyPaneLinesUIView.Inks,
        background: UIColor
    ) {
        guard let popup, let cellMetrics,
              let layout = GhosttyCompositeViewportLayout(bounds: bounds, grid: popup.viewportGrid, cellMetrics: cellMetrics),
              let contentFrame = Self.contentFrame(layout: layout, windowGrid: popup.viewportGrid, size: bounds.size)
        else {
            // Without the grid it is drawn on, the popup still hides the panes.
            backgroundColor = background
            for view in [lines, content, title, tab] { view.isHidden = true }
            return
        }
        // The held tab can have a larger grid than this viewport. Cover the margins as well as the
        // popup's canvas, so none of the underlying panes can show through after a rotation.
        backgroundColor = background
        lines.isHidden = false
        content.isHidden = false
        // The frame's canvas uses the same background as its surrounding margins.
        if lines.backgroundColor != background { lines.backgroundColor = background }
        lines.frame = CGRect(origin: layout.origin, size: layout.canvasSize)
        lines.update(lines: popup.border, layout: layout, inks: inks)
        content.frame = contentFrame
        placeLabels(on: layout, columns: popup.viewportGrid.columns, framed: Popup.isFramed(popup.viewportGrid), inks: inks, background: background)
        if let drawable {
            let frame = CGRect(origin: .zero, size: drawable)
            if terminal.frame != frame {
                terminal.frame = frame
                terminal.layoutIfNeeded()
            }
            record(drawable: drawable)
        }
    }

    /// Whether `point`, in this view's space, is on the popup's terminal's cells.
    func terminalContains(_ point: CGPoint) -> Bool {
        popup != nil && !content.isHidden && content.frame.contains(point)
    }

    func dismantle() {
        detachSurface()
        popup = nil
    }

    private func detachSurface() {
        surface = nil
        drawable = nil
        terminal.detachCurrentSurfaceForRemoval()
        terminal.removeFromSuperview()
    }

    private typealias Popup = GhosttyTerminalViewportPresentationProjection.Popup

    /// Where the popup's terminal draws on `layout`, within the area of `size`: until Herdr's frames have the
    /// grid of a smaller area, as while the keyboard comes up, the grid runs past it, and its terminal draws
    /// only the cells the area has, as the panes do.
    static func contentFrame(layout: GhosttyCompositeViewportLayout, windowGrid: GhosttyTerminalGridSize, size: CGSize) -> CGRect? {
        guard let content = Popup.content(in: windowGrid) else { return nil }
        let frame = layout.frame(for: content).intersection(CGRect(origin: .zero, size: size))
        return frame.isNull ? nil : frame
    }

    /// The top line's cells between its corners: the title from the first, as Herdr's client writes it,
    /// and the tab at the other end. The label's cells take the place of the line under it, as a title's do in
    /// Herdr's client.
    private func placeLabels(
        on layout: GhosttyCompositeViewportLayout,
        columns: UInt32,
        framed: Bool,
        inks: GhosttyPaneLinesUIView.Inks,
        background: UIColor
    ) {
        guard let popup, framed else {
            title.isHidden = true
            tab.isHidden = true
            return
        }
        let cell = layout.cellSize
        let font = Self.labelFont(cellWidth: cell.width)
        for (label, ink) in [(title, popup.titleInk), (tab, popup.tabInk)] {
            let color = inks.color(of: ink)
            if label.font != font { label.font = font }
            if label.textColor != color { label.textColor = color }
            if label.backgroundColor != background { label.backgroundColor = background }
        }
        title.isHidden = false
        tab.isHidden = popup.tabLabel == nil
        let line = CGRect(
            x: layout.origin.x + cell.width,
            y: layout.origin.y,
            width: CGFloat(max(Int(columns) - 2, 0)) * cell.width,
            height: cell.height
        )
        let widths = Self.labelWidths(
            title: title.sizeThatFits(line.size).width,
            tab: tab.isHidden ? 0 : tab.sizeThatFits(line.size).width,
            line: line.width,
            gap: cell.width
        )
        title.frame = CGRect(x: line.minX, y: line.minY, width: widths.title, height: line.height)
        tab.frame = CGRect(x: line.maxX - widths.tab, y: line.minY, width: widths.tab, height: line.height)
    }

    /// The widths of the title and the tab on a top line `line` wide, a cell, `gap`, at least between them: as
    /// they are when both fit, and when they don't, the shorter as it is up to half the room, and the other
    /// in the rest, cut short at its end.
    static func labelWidths(title: CGFloat, tab: CGFloat, line: CGFloat, gap: CGFloat) -> (title: CGFloat, tab: CGFloat) {
        let room = max(line - gap, 0)
        if title + tab <= room { return (title, tab) }
        let half = room / 2
        if tab <= half { return (room - tab, tab) }
        if title <= half { return (title, room - title) }
        return (half, half)
    }

    /// The system's monospaced font at the size whose characters are a cell wide. Herdr's client writes the
    /// title in the terminal's own font, which isn't one UIKit has; this one follows the terminal's font
    /// size, a character a cell.
    static func labelFont(cellWidth: CGFloat) -> UIFont {
        let reference = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: reference]).width
        return UIFont.monospacedSystemFont(ofSize: 100 * cellWidth / advance, weight: .regular)
    }

    private func record(drawable: CGSize) {
        guard GhosttyRuntimeTrace.diagnosticsEnabled, window != nil else { return }
        let cells = content.convert(content.bounds, to: nil)
        guard recorded.map({ $0.cells != cells || $0.drawable != drawable }) ?? true else { return }
        recorded = (cells, drawable)
        let orientation = window?.windowScene?.interfaceOrientation.isLandscape == true ? "landscape" : "portrait"
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        GhosttyRuntimeTrace.diagnostics(
            "popup host orientation=\(orientation) scale=\(scale) "
                + "cells=\(cells.width)x\(cells.height)pt@(\(cells.minX),\(cells.minY)) "
                + "drawable=\(drawable.width)x\(drawable.height)pt"
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recorded = nil
    }
}
