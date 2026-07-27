import Foundation
import UIKit

struct AppKeyboardCommandRouteContext: Equatable {
    var selectedSessionID: SavedWorkspace.ID?
    var isSelectedTerminalReady: Bool
    var orderedActiveSessionIDs: [SavedWorkspace.ID]
}

enum AppKeyboardCommandRoute: Equatable {
    case terminal(AppKeyboardCommand)
    case showHome
    case showCommandPalette
    case showSession(SavedWorkspace.ID)
    case adjustFontSize(by: Float32)
    case unavailable
}

enum AppKeyboardCommandRouter {
    static func route(
        _ command: AppKeyboardCommand,
        in context: AppKeyboardCommandRouteContext
    ) -> AppKeyboardCommandRoute {
        switch command {
        case .previousWindow, .nextWindow, .windows, .panes, .attachments:
            guard
                context.selectedSessionID != nil,
                context.isSelectedTerminalReady
            else {
                return .unavailable
            }
            return .terminal(command)

        case .home:
            return .showHome

        case .commandPalette:
            return .showCommandPalette

        case .increaseFontSize:
            return .adjustFontSize(by: 1)

        case .decreaseFontSize:
            return .adjustFontSize(by: -1)

        case .previousSession:
            return sessionRoute(offset: -1, in: context)

        case .nextSession:
            return sessionRoute(offset: 1, in: context)
        }
    }

    static func isAvailable(
        _ command: AppKeyboardCommand,
        in context: AppKeyboardCommandRouteContext
    ) -> Bool {
        route(command, in: context) != .unavailable
    }

    private static func sessionRoute(
        offset: Int,
        in context: AppKeyboardCommandRouteContext
    ) -> AppKeyboardCommandRoute {
        let ids = context.orderedActiveSessionIDs
        guard !ids.isEmpty else { return .unavailable }

        guard
            let selectedSessionID = context.selectedSessionID,
            let selectedIndex = ids.firstIndex(of: selectedSessionID)
        else {
            return .showSession(offset < 0 ? ids[ids.count - 1] : ids[0])
        }

        let destinationIndex = (selectedIndex + offset + ids.count) % ids.count
        return .showSession(ids[destinationIndex])
    }
}

struct AppKeyboardCommandResolver {
    private let commandsByBinding: [KeyboardKeyBinding: AppKeyboardCommand]

    init(settings: KeyboardSettings) {
        self.commandsByBinding = Dictionary(
            uniqueKeysWithValues: AppKeyboardCommand.allCases.compactMap { command in
                settings.binding(for: command).map { ($0, command) }
            }
        )
    }

    func command(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> AppKeyboardCommand? {
        command(
            input: input,
            modifiers: KeyboardKeyModifiers(modifierFlags)
        )
    }

    func command(
        input: String,
        modifiers: KeyboardKeyModifiers
    ) -> AppKeyboardCommand? {
        let binding = KeyboardKeyBinding(
            input: Self.normalizedInput(input),
            modifiers: modifiers
        )
        return commandsByBinding[binding]
    }

    private static func normalizedInput(_ input: String) -> String {
        input.count == 1 ? input.lowercased() : input
    }
}

extension KeyboardKeyModifiers {
    init(_ flags: UIKeyModifierFlags) {
        var value: KeyboardKeyModifiers = []
        if flags.contains(.command) {
            value.insert(.command)
        }
        if flags.contains(.shift) {
            value.insert(.shift)
        }
        if flags.contains(.alternate) {
            value.insert(.option)
        }
        if flags.contains(.control) {
            value.insert(.control)
        }
        self = value
    }

    var uiKeyModifierFlags: UIKeyModifierFlags {
        var value: UIKeyModifierFlags = []
        if contains(.command) {
            value.insert(.command)
        }
        if contains(.shift) {
            value.insert(.shift)
        }
        if contains(.option) {
            value.insert(.alternate)
        }
        if contains(.control) {
            value.insert(.control)
        }
        return value
    }
}
