import Foundation

enum AppKeyboardCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case previousWindow
    case nextWindow
    case previousSession
    case nextSession
    case home
    case windows
    case panes
    case attachments
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
        case .panes:
            "Panes"
        case .attachments:
            "Attachments"
        case .commandPalette:
            "Command Palette"
        }
    }

    var requiresTerminal: Bool {
        switch self {
        case .previousWindow, .nextWindow, .windows, .panes, .attachments:
            true
        case .previousSession, .nextSession, .home, .commandPalette:
            false
        }
    }
}
