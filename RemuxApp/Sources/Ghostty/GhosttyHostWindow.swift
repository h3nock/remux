import SwiftUI
import UIKit

/// The window a SwiftUI view is shown in, for what only the window knows, such as where it sits on its screen. It is
/// read when needed and never observed, so a view isn't redrawn when its window changes.
@MainActor
final class GhosttyHostWindowReference {
    fileprivate(set) weak var window: UIWindow?

    /// The window's frame in its screen's coordinates, the space UIKit gives keyboard frames in. On an iPhone it is the
    /// screen's bounds; an iPad window can be smaller than its screen and anywhere on it.
    var frameOnScreen: CGRect? {
        guard let window else { return nil }
        return window.convert(window.bounds, to: window.screen.coordinateSpace)
    }
}

/// Put behind a view to fill `reference` with the window the view is in.
struct GhosttyHostWindowReader: UIViewRepresentable {
    let reference: GhosttyHostWindowReference

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.reference = reference
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.reference = reference
    }

    final class ReaderView: UIView {
        var reference: GhosttyHostWindowReference? {
            didSet { reference?.window = window }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reference?.window = window
        }
    }
}
