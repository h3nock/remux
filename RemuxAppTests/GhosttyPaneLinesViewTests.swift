import SwiftUI
import UIKit
import XCTest
@testable import Remux

/// The pane lines keep their place on the grid while the terminal area's size animates, as it does when the
/// keyboard comes up or goes down. Core Animation scales a layer's drawing to its bounds through a bounds
/// animation, so a line drawn into a layer whose bounds animate is drawn stretched until the animation ends,
/// while the panes, which are laid out without animation, stay where they are.
@MainActor
final class GhosttyPaneLinesViewTests: XCTestCase {
    /// 8 x 17.67 points at 3x.
    private let cell = GhosttyTerminalCellDisplayMetrics(pixelWidth: 24, pixelHeight: 53, contentScale: 3)
    private let grid = GhosttyTerminalGridSize(columns: 50, rows: 41)
    /// The terminal area with the keyboard down, and with it up.
    private let tall = CGSize(width: 402, height: 726)
    private let short = CGSize(width: 402, height: 459)

    /// The panes' lines draw in a view of their own on the grid's canvas, behind the panes, and the area's
    /// own layer, whose bounds the keyboard animates, draws nothing: through the animation the lines stay on
    /// the canvas, unanimated.
    func testThePanesLinesStayOnTheGridWhileTheTerminalAreaAnimates() throws {
        let projection = GhosttyTerminalViewportPresentationProjection(
            windowGrid: grid,
            cellMetrics: cell,
            panes: [],
            paneLines: box(ink: .separator),
            focusedSurfaceID: nil,
            isServerZoomed: false,
            windowCount: 1
        )
        let (window, host) = show(GhosttyCompositeViewportView(
            surfaceLookup: .empty,
            projection: projection,
            terminalTheme: TerminalTheme.allCases[0],
            trackpadDriver: GhosttyKeyboardCursorTrackpadDriver(),
            onSurfaceTap: nil,
            onPreviewSelection: nil,
            onWindowSwipe: nil,
            sendKeyEventToSurface: { _, _ in false },
            onTrackpadFeedbackChange: { _ in },
            isMouseCaptured: { _ in false },
            submitMouseButton: nil,
            submitMousePosition: nil,
            submitMouseScroll: nil,
            selectionSource: nil
        ))
        defer { hide(window) }
        let area = try XCTUnwrap(descendant(of: host.view, named: "GhosttyCompositeViewportContainerView"))
        XCTAssertEqual(area.bounds.size, tall)

        UIView.animate(withDuration: 0.4) {
            area.frame.size = self.short
            area.layoutIfNeeded()
        }
        area.layer.displayIfNeeded()

        XCTAssertNotNil(area.layer.animation(forKey: "bounds.size"), "the area's bounds didn't animate")
        XCTAssertNil(area.layer.contents, "the lines are drawn into the layer whose bounds animate")
        let lines = try XCTUnwrap(descendant(of: area, named: "GhosttyPaneLinesUIView"), "no view of the lines")
        XCTAssertEqual(lines.frame, canvas(in: short))
        XCTAssertEqual(lines.layer.animationKeys() ?? [], [], "the lines' geometry animated")
        XCTAssertEqual(area.subviews.first, lines, "the lines aren't behind the panes")
    }

    /// The popup's frame draws its lines the same way, on the canvas, above the panes: while the area under
    /// it animates its size, the frame's lines keep the canvas's place and size, unanimated.
    func testThePopupsFrameStaysOnTheGridWhileTheTerminalAreaAnimates() throws {
        let popup = GhosttyTerminalViewportPresentationProjection.Popup(
            id: UUID(),
            title: "popup",
            tabLabel: nil,
            viewportGrid: grid,
            border: box(ink: .color(red: 120, green: 160, blue: 240)),
            titleInk: .separator,
            tabInk: .separator,
            grid: nil,
            cell: nil
        )
        var projection = GhosttyTerminalViewportPresentationProjection(
            windowGrid: grid,
            cellMetrics: cell,
            panes: [],
            paneLines: [],
            focusedSurfaceID: nil,
            isServerZoomed: false,
            windowCount: 1
        )
        projection.popup = popup
        let (window, host) = show(viewport(projection, theme: TerminalTheme.allCases[0]))
        defer { hide(window) }
        let frame = try XCTUnwrap(descendant(of: host.view, named: "GhosttyTerminalPopupFrameView"), "no popup")
        let lines = try XCTUnwrap(descendant(of: frame, named: "GhosttyPaneLinesUIView"), "no view of the frame's lines")
        assertSize(lines.bounds.size, canvas(in: tall).size)
        let origin = lines.convert(CGPoint.zero, to: host.view)

        UIView.animate(withDuration: 0.4) {
            host.view.frame.size = self.short
            host.view.layoutIfNeeded()
        }

        assertSize(lines.bounds.size, canvas(in: short).size)
        XCTAssertEqual(lines.convert(CGPoint.zero, to: host.view), origin)
        XCTAssertEqual(lines.layer.animationKeys() ?? [], [], "the frame's lines' geometry animated")
    }

    /// A new theme reaches the lines: the area's theme sets the inks, and the lines are drawn again in the new
    /// theme's separator and accent.
    func testANewThemeDrawsThePanesLinesInItsInks() throws {
        let (first, second) = try XCTUnwrap(Self.themesOfOtherInks())
        let projection = twoPanes(focusingLeft: true)
        let (window, host) = show(viewport(projection, theme: first))
        defer { hide(window) }
        let lines = try XCTUnwrap(descendant(of: host.view, named: "GhosttyPaneLinesUIView"), "no view of the lines")
        assertLines(lines, left: Self.focus(first), right: Self.separator(first))

        host.rootView = viewport(projection, theme: second)
        settle(host)

        assertLines(lines, left: Self.focus(second), right: Self.separator(second))
    }

    /// The focus moving to another pane changes only the lines, no pane's frame: the lines are drawn again, the
    /// accent on the newly focused pane's sides.
    func testTheFocusMovingToAnotherPaneDrawsThePanesLinesAgain() throws {
        let theme = TerminalTheme.allCases[0]
        let (window, host) = show(viewport(twoPanes(focusingLeft: true), theme: theme))
        defer { hide(window) }
        let lines = try XCTUnwrap(descendant(of: host.view, named: "GhosttyPaneLinesUIView"), "no view of the lines")
        assertLines(lines, left: Self.focus(theme), right: Self.separator(theme))

        host.rootView = viewport(twoPanes(focusingLeft: false), theme: theme)
        settle(host)

        assertLines(lines, left: Self.separator(theme), right: Self.focus(theme))
    }

    /// Two panes side by side, the left one's left side and the right one's right side lined, in the accent on
    /// the focused pane's side and the separator on the other's.
    private func twoPanes(focusingLeft: Bool) -> GhosttyTerminalViewportPresentationProjection {
        let rows = grid.rows - 2
        let left = GhosttyTerminalGridRect(x: 1, y: 1, columns: 23, rows: rows)
        let right = GhosttyTerminalGridRect(x: 26, y: 1, columns: 23, rows: rows)
        let panes = [(left, focusingLeft), (right, !focusingLeft)].map { frame, focused in
            GhosttyTerminalViewportPresentationProjection.Pane(
                id: UUID(), normalFrame: frame, visibleFrame: frame, isFocused: focused, currentCommand: "", currentPath: ""
            )
        }
        let end = CGFloat(grid.rows) - 0.5
        return GhosttyTerminalViewportPresentationProjection(
            windowGrid: grid,
            cellMetrics: cell,
            panes: panes,
            paneLines: [
                GhosttyPaneLine(orientation: .vertical, position: 0.5, start: 0.5, end: end,
                                ink: focusingLeft ? .focus : .separator, width: 1, cap: .square),
                GhosttyPaneLine(orientation: .vertical, position: CGFloat(grid.columns) - 0.5, start: 0.5, end: end,
                                ink: focusingLeft ? .separator : .focus, width: 1, cap: .square),
            ],
            focusedSurfaceID: nil,
            isServerZoomed: false,
            windowCount: 1
        )
    }

    private func viewport(
        _ projection: GhosttyTerminalViewportPresentationProjection,
        theme: TerminalTheme
    ) -> GhosttyCompositeViewportView {
        GhosttyCompositeViewportView(
            surfaceLookup: .empty,
            projection: projection,
            terminalTheme: theme,
            trackpadDriver: GhosttyKeyboardCursorTrackpadDriver(),
            onSurfaceTap: nil,
            onPreviewSelection: nil,
            onWindowSwipe: nil,
            sendKeyEventToSurface: { _, _ in false },
            onTrackpadFeedbackChange: { _ in },
            isMouseCaptured: { _ in false },
            submitMouseButton: nil,
            submitMousePosition: nil,
            submitMouseScroll: nil,
            selectionSource: nil
        )
    }

    private static func separator(_ theme: TerminalTheme) -> UIColor {
        theme.terminalCompositeSeparatorUIColor
    }

    private static func focus(_ theme: TerminalTheme) -> UIColor {
        UIColor(theme.terminalChromeStyle.accent)
    }

    /// Two themes whose separators and accents both differ.
    private static func themesOfOtherInks() -> (TerminalTheme, TerminalTheme)? {
        for first in TerminalTheme.allCases {
            for second in TerminalTheme.allCases where second != first {
                if sRGB(of: separator(first)) != sRGB(of: separator(second)),
                   sRGB(of: focus(first)) != sRGB(of: focus(second)),
                   sRGB(of: focus(first)) != sRGB(of: separator(second)),
                   sRGB(of: separator(first)) != sRGB(of: focus(second)) {
                    return (first, second)
                }
            }
        }
        return nil
    }

    /// The lines view shows `left` along the canvas's left line and `right` along its right one, once drawn.
    private func assertLines(_ lines: UIView, left: UIColor, right: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        lines.layer.displayIfNeeded()
        let scale = lines.window?.screen.scale ?? 3
        let middle = lines.bounds.midY
        for (position, expected) in [(CGFloat(0.5), left), (CGFloat(grid.columns) - 0.5, right)] {
            // The middle of the line's pixels, in the view: the canvas's lines are laid out from the area's origin.
            let layout = GhosttyCompositeViewportLayout(bounds: CGRect(origin: .zero, size: tall), grid: grid, cellMetrics: cell)!
            let x = layout.origin.x + position * layout.cellSize.width - lines.frame.minX
            let shown = Self.sRGB(of: lines.layer, at: CGPoint(x: x, y: middle), scale: scale)
            let want = Self.sRGB(of: expected.resolvedColor(with: lines.traitCollection))
            XCTAssertTrue(zip(shown, want).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "\(shown) at \(position), wanted \(want)", file: file, line: line)
        }
    }

    /// The colour `layer` shows at `point`, in its own coordinates, as sRGB bytes.
    private static func sRGB(of layer: CALayer, at point: CGPoint, scale: CGFloat) -> [UInt8] {
        pixel { context in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -point.x + 0.5 / scale, y: -point.y + 0.5 / scale)
            layer.render(in: context)
        }
    }

    private static func sRGB(of color: UIColor) -> [UInt8] {
        pixel { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private static func pixel(_ draw: (CGContext) -> Void) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(context)
        }
        return Array(bytes[0..<3])
    }

    /// SwiftUI hands a new root view to its views on its next update.
    private func settle(_ host: UIViewController) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.view.layoutIfNeeded()
    }

    /// A box on the grid's outer cells, as Herdr draws a pane's or a popup's.
    private func box(ink: GhosttyPaneLine.Ink) -> [GhosttyPaneLine] {
        let columns = CGFloat(grid.columns), rows = CGFloat(grid.rows)
        return [
            GhosttyPaneLine(orientation: .horizontal, position: 0.5, start: 0.5, end: columns - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .horizontal, position: rows - 0.5, start: 0.5, end: columns - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .vertical, position: 0.5, start: 0.5, end: rows - 0.5, ink: ink, width: 1, cap: .square),
            GhosttyPaneLine(orientation: .vertical, position: columns - 0.5, start: 0.5, end: rows - 0.5, ink: ink, width: 1, cap: .square),
        ]
    }

    /// SwiftUI hands its views sizes a rounding away from the canvas's.
    private func assertSize(_ size: CGSize, _ expected: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(size.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func canvas(in size: CGSize) -> CGRect {
        let layout = GhosttyCompositeViewportLayout(bounds: CGRect(origin: .zero, size: size), grid: grid, cellMetrics: cell)!
        return CGRect(origin: layout.origin, size: layout.canvasSize)
    }

    private func show<Content: View>(_ content: Content) -> (UIWindow, UIHostingController<Content>) {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: tall))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func hide(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The first view under `root`, depth first, whose class is named `name`.
    private func descendant(of root: UIView, named name: String) -> UIView? {
        for view in root.subviews {
            if String(describing: type(of: view)) == name { return view }
            if let found = descendant(of: view, named: name) { return found }
        }
        return nil
    }
}
