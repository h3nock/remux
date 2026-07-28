import Foundation

enum AppKeyboardCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case previousWindow
    case nextWindow
    case previousSession
    case nextSession
    case home
    case windows
    case newWindow
    case panes
    case attachments
    case increaseFontSize
    case decreaseFontSize
    case commandPalette

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .previousWindow:
            "Previous Window"
        case .nextWindow:
            "Next Window"
        case .previousSession:
            "Previous Session"
        case .nextSession:
            "Next Session"
        case .home:
            "Home"
        case .windows:
            "Session Windows"
        case .newWindow:
            "New Window"
        case .panes:
            "Panes"
        case .attachments:
            "Attachments"
        case .commandPalette:
            "Command Palette"
        case .increaseFontSize:
            "Increase Font Size"
        case .decreaseFontSize:
            "Decrease Font Size"
        }
    }

    var requiresTerminal: Bool {
        switch self {
        case .previousWindow, .nextWindow, .windows, .newWindow, .panes, .attachments:
            true
        case .previousSession, .nextSession, .home, .commandPalette,
             .increaseFontSize, .decreaseFontSize:
            false
        }
    }
}
