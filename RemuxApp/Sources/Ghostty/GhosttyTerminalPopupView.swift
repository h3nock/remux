import SwiftUI
import UIKit

/// A popup the backend shows over the whole terminal area: its title as an inline navigation bar shows a
/// title, and its terminal below, at the font that fills the area with the popup's grid (the model fits it
/// to the size reported here), centred in what is left. A tap brings up the keyboard, as on a pane.
struct GhosttyTerminalPopupView: View {
    @Environment(\.displayScale) private var displayScale
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let terminalTheme: TerminalTheme
    let onAreaChange: (CGSize, CGFloat) -> Void
    let onTap: () -> Void

    /// An inline navigation bar's height.
    static let titleBarHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            GeometryReader { proxy in
                GhosttyTerminalPopupSurfaceHost(
                    popup: popup,
                    surfaceLookup: surfaceLookup,
                    displayScale: displayScale
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .onAppear { onAreaChange(proxy.size, displayScale) }
                .onChange(of: proxy.size) { _, size in onAreaChange(size, displayScale) }
                .onChange(of: displayScale) { _, scale in onAreaChange(proxy.size, scale) }
            }
            .accessibilityElement()
            .accessibilityLabel("Terminal")
            .accessibilityIdentifier("terminal.popup.content")
        }
        .background(terminalTheme.terminalSurfaceBackground)
        .environment(\.colorScheme, terminalTheme.terminalChromeColorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.popup")
    }

    private var titleBar: some View {
        Text(popup.title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: Self.titleBarHeight)
            .modifier(GhosttyInlineBarBackground())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("terminal.popup.title")
    }
}

/// An inline navigation bar's background: none from iOS 26, whose bars are clear over content; the bar
/// material and its hairline before.
private struct GhosttyInlineBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Hosts the popup's surface at its grid's size, centred on device pixels. Its touches go to the SwiftUI
/// tap above it.
private struct GhosttyTerminalPopupSurfaceHost: UIViewRepresentable {
    let popup: GhosttyTerminalViewportPresentationProjection.Popup
    let surfaceLookup: GhosttyManagedSurfaceLookup
    let displayScale: CGFloat

    func makeUIView(context: Context) -> GhosttyTerminalPopupHostView {
        let view = GhosttyTerminalPopupHostView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: GhosttyTerminalPopupHostView, context: Context) {
        view.update(popup: popup, surface: surfaceLookup.managedSurface(for: popup.id), displayScale: displayScale)
    }

    static func dismantleUIView(_ view: GhosttyTerminalPopupHostView, coordinator: ()) {
        view.dismantle()
    }
}

final class GhosttyTerminalPopupHostView: UIView {
    private let container = GhosttyPaneScrollContainerView()
    /// The grid's size in points, once the popup's renderer has a cell.
    private var gridSize: CGSize?
    private var displayScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        container.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        popup: GhosttyTerminalViewportPresentationProjection.Popup,
        surface: GhosttyManagedSurface?,
        displayScale: CGFloat
    ) {
        guard let surface, let cell = popup.cell, cell.contentScale > 0 else {
            dismantle()
            return
        }
        self.displayScale = max(displayScale, 1)
        gridSize = CGSize(
            width: Double(popup.columns) * Double(cell.pixelWidth) / cell.contentScale,
            height: Double(popup.rows) * Double(cell.pixelHeight) / cell.contentScale
        )
        if container.superview !== self { addSubview(container) }
        container.update(
            surface: surface,
            displayScale: self.displayScale,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        setNeedsLayout()
    }

    func dismantle() {
        gridSize = nil
        container.detachCurrentSurfaceForRemoval()
        container.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let gridSize else { return }
        func centred(_ room: CGFloat, _ length: CGFloat) -> CGFloat {
            (max(room - length, 0) / 2 * displayScale).rounded(.down) / displayScale
        }
        let frame = CGRect(
            x: centred(bounds.width, gridSize.width),
            y: centred(bounds.height, gridSize.height),
            width: gridSize.width,
            height: gridSize.height
        )
        // Cell geometry never animates, even in a layout pass inside another animation.
        UIView.performWithoutAnimation {
            guard container.frame != frame else { return }
            container.frame = frame
            container.layoutIfNeeded()
        }
    }
}
