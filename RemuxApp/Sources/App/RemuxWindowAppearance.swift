import SwiftUI
import UIKit

/// Owns appearance only while a terminal is visible, leaving Home to inherit
/// the window's original/system style without replacing retained terminals.
struct RemuxWindowAppearance: UIViewRepresentable {
    let colorScheme: ColorScheme?

    func makeUIView(context: Context) -> RemuxWindowAppearanceUIView {
        RemuxWindowAppearanceUIView(frame: .zero)
    }

    func updateUIView(_ view: RemuxWindowAppearanceUIView, context: Context) {
        view.preferredColorScheme = colorScheme
    }

    static func dismantleUIView(_ view: RemuxWindowAppearanceUIView, coordinator: ()) {
        view.restoreWindowAppearance()
    }
}

final class RemuxWindowAppearanceUIView: UIView {
    var preferredColorScheme: ColorScheme? {
        didSet { applyPreferredAppearance() }
    }

    private weak var styledWindow: UIWindow?
    private var previousStyle: UIUserInterfaceStyle = .unspecified
    private var appliedStyle: UIUserInterfaceStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPreferredAppearance()
    }

    func restoreWindowAppearance() {
        let previousWindow = styledWindow
        let originalStyle = previousStyle
        let ownedStyle = appliedStyle
        styledWindow = nil
        appliedStyle = nil
        // Avoid overwriting a more recent appearance choice by another owner.
        if let previousWindow, previousWindow.overrideUserInterfaceStyle == ownedStyle {
            previousWindow.overrideUserInterfaceStyle = originalStyle
        }
    }

    private func applyPreferredAppearance() {
        guard let preferredColorScheme, let window else {
            restoreWindowAppearance()
            return
        }
        if styledWindow !== window {
            restoreWindowAppearance()
            previousStyle = window.overrideUserInterfaceStyle
            styledWindow = window
        } else if let appliedStyle, window.overrideUserInterfaceStyle != appliedStyle {
            // Another owner changed the window while this view was attached.
            // Restore that newer choice when the terminal relinquishes it.
            previousStyle = window.overrideUserInterfaceStyle
        }
        let style: UIUserInterfaceStyle = preferredColorScheme == .dark ? .dark : .light
        appliedStyle = style
        if window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
        }
    }
}
