import SwiftUI
import UIKit

/// The app's accent, the same in every terminal theme: a theme sets only the terminal's colours and whether
/// the chrome around it is light or dark.
enum RemuxAccent {
    static let fill = Color.accentColor
    /// Text and glyphs drawn on `fill`.
    static let onFill = Color.white

    static let toolbarButtonActiveFill = fill.opacity(0.16)
    static let selectedFill = fill.opacity(0.18)
    static let selectedStroke = fill.opacity(0.76)

    /// `fill` for UIKit: the app's named accent colour, or the system blue `Color.accentColor` is without one.
    static let uiFill = UIColor(named: "AccentColor") ?? .systemBlue
    static let uiOnFill = UIColor.white
}

extension View {
    @ViewBuilder
    func remuxSheetPresentationBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            presentationBackground(.regularMaterial)
        }
    }
}
