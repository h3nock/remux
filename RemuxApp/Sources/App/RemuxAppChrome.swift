import SwiftUI
import UIKit

enum RemuxAppPalette {
    static let background = Color(uiColor: .remuxAppBackground)
    static let rowSurface = Color(uiColor: .remuxAppRowSurface)
    static let separator = Color(uiColor: .remuxAppSeparator)
    static let sectionHeader = Color(uiColor: .remuxAppSectionHeader)
    static let rowIconForeground = Color(uiColor: .remuxAppRowIconForeground)
    static let rowIconSurface = Color(uiColor: .remuxAppRowIconSurface)
}

typealias LibraryHomePalette = RemuxAppPalette

extension View {
    func remuxAppListRowSurface() -> some View {
        listRowBackground(RemuxAppPalette.rowSurface)
            .listRowSeparatorTint(RemuxAppPalette.separator)
    }

    func remuxAppGroupedScrollBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(RemuxAppPalette.background.ignoresSafeArea())
    }

    @ViewBuilder
    func remuxSheetPresentationBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            presentationBackground(.regularMaterial)
        }
    }

    func libraryHomeListRowSurface() -> some View {
        remuxAppListRowSurface()
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
