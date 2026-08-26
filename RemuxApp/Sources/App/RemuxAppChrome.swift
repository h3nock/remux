import SwiftUI
import UIKit

enum RemuxAppPalette {
    static let background = Color(uiColor: .remuxAppBackground)
    static let rowSurface = Color(uiColor: .remuxAppRowSurface)
    static let separator = Color(uiColor: .remuxAppSeparator)
    static let sectionHeader = Color(uiColor: .remuxAppSectionHeader)
    static let toolbarTint = Color(uiColor: .remuxAppToolbarTint)
    static let controlAccent = Color(uiColor: .remuxAppControlAccent)
    static let rowIconForeground = Color(uiColor: .remuxAppRowIconForeground)
    static let rowIconSurface = Color(uiColor: .remuxAppRowIconSurface)
}

typealias LibraryHomePalette = RemuxAppPalette

extension TerminalTheme {
    var remuxAppColorScheme: ColorScheme {
        switch self {
        case .remuxLight:
            .light
        case .ghosttyDefault, .remuxDark:
            .dark
        }
    }

    var libraryColorScheme: ColorScheme {
        remuxAppColorScheme
    }
}

extension View {
    func remuxAppListRowSurface() -> some View {
        listRowBackground(RemuxAppPalette.rowSurface)
            .listRowSeparatorTint(RemuxAppPalette.separator)
    }

    func remuxAppChrome(theme: TerminalTheme) -> some View {
        preferredColorScheme(theme.remuxAppColorScheme)
            .tint(RemuxAppPalette.toolbarTint)
            .toolbarBackground(RemuxAppPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    func remuxAppGroupedScrollBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(RemuxAppPalette.background.ignoresSafeArea())
    }

    func libraryHomeListRowSurface() -> some View {
        remuxAppListRowSurface()
    }

    func libraryHomeChrome(theme: TerminalTheme) -> some View {
        remuxAppChrome(theme: theme)
    }

    func libraryHomeGroupedScrollBackground() -> some View {
        remuxAppGroupedScrollBackground()
    }
}

private extension UIColor {
    static let remuxAppBackground = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.15, green: 0.17, blue: 0.21, alpha: 1.0)
        default:
            .systemGroupedBackground
        }
    }

    static let remuxAppRowSurface = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.21, green: 0.23, blue: 0.28, alpha: 1.0)
        default:
            .secondarySystemGroupedBackground
        }
    }

    static let remuxAppSeparator = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor.white.withAlphaComponent(0.08)
        default:
            .separator
        }
    }

    static let remuxAppSectionHeader = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.72, green: 0.74, blue: 0.80, alpha: 1.0)
        default:
            .secondaryLabel
        }
    }

    static let remuxAppToolbarTint = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.91, green: 0.93, blue: 0.98, alpha: 1.0)
        default:
            .label
        }
    }

    static let remuxAppControlAccent = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.39, green: 0.64, blue: 1.0, alpha: 1.0)
        default:
            .systemBlue
        }
    }

    static let remuxAppRowIconForeground = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor(red: 0.79, green: 0.83, blue: 0.91, alpha: 1.0)
        default:
            .secondaryLabel
        }
    }

    static let remuxAppRowIconSurface = UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            UIColor.white.withAlphaComponent(0.07)
        default:
            .tertiarySystemFill
        }
    }
}
