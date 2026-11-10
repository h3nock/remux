import SwiftUI

enum GhosttyShortcutSurfacePalette {
    static let contentFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let contentStroke = Color.primary.opacity(0.10)
    static let separator = Color(uiColor: .separator).opacity(0.55)

    static let embeddedFill = Color(uiColor: .secondarySystemFill)
    static let embeddedPressedFill = Color(uiColor: .tertiarySystemFill)
    static let embeddedSelectedFill = RemuxAccent.selectedFill

    static let cornerRadiusLarge: CGFloat = 22
    static let cornerRadiusMedium: CGFloat = 14
}

enum GhosttyShortcutTypography {
    static let sectionLabel = Font.system(size: 15, weight: .semibold)
    static let rowText = Font.system(size: 17, weight: .regular)
    static let collectionTitle = Font.system(size: 17, weight: .semibold)
    static let secondaryText = Font.system(size: 13, weight: .regular)
    static let badge = Font.system(size: 12, weight: .semibold)

    static let compactControl = Font.system(size: 14, weight: .semibold)
    static let chromeIcon = Font.system(size: 15.5, weight: .semibold)

    static let shortcutCommandCompact = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let shortcutCommandFull = Font.system(size: 17, weight: .semibold, design: .monospaced)
    static let shortcutHintCompact = Font.system(size: 11.5, weight: .medium)

    static func addShortcutTileTitle(isEmpty: Bool) -> Font {
        Font.system(size: isEmpty ? 14 : 12.5, weight: .semibold)
    }
}
