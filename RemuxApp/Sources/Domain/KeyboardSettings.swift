import Foundation
import UIKit

struct KeyboardKeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: Int

    static let command = KeyboardKeyModifiers(rawValue: 1 << 0)
    static let shift = KeyboardKeyModifiers(rawValue: 1 << 1)
    static let option = KeyboardKeyModifiers(rawValue: 1 << 2)
    static let control = KeyboardKeyModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

struct KeyboardKeyBinding: Codable, Equatable, Hashable, Sendable {
    var input: String
    var modifiers: KeyboardKeyModifiers
}

struct KeyboardSettings: Codable, Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case missingModifier
        case duplicateBinding(command: AppKeyboardCommand)
    }

    static let `default` = KeyboardSettings(
        bindings: [
            .previousWindow: KeyboardKeyBinding(
                input: UIKeyCommand.inputLeftArrow,
                modifiers: [.command]
            ),
            .nextWindow: KeyboardKeyBinding(
                input: UIKeyCommand.inputRightArrow,
                modifiers: [.command]
            ),
            .previousSession: KeyboardKeyBinding(
                input: UIKeyCommand.inputLeftArrow,
                modifiers: [.command, .shift]
            ),
            .nextSession: KeyboardKeyBinding(
                input: UIKeyCommand.inputRightArrow,
                modifiers: [.command, .shift]
            ),
            .home: KeyboardKeyBinding(input: "h", modifiers: [.command]),
            .windows: KeyboardKeyBinding(input: "o", modifiers: [.command]),
            .panes: KeyboardKeyBinding(input: "p", modifiers: [.command]),
            .attachments: KeyboardKeyBinding(input: "a", modifiers: [.command]),
            .commandPalette: KeyboardKeyBinding(input: "k", modifiers: [.command]),
        ],
        hideButtonBarWhenPhysicalKeyboardConnected: true
    )

    private(set) var bindings: [AppKeyboardCommand: KeyboardKeyBinding]
    var hideButtonBarWhenPhysicalKeyboardConnected: Bool

    init(
        bindings: [AppKeyboardCommand: KeyboardKeyBinding],
        hideButtonBarWhenPhysicalKeyboardConnected: Bool
    ) {
        self.bindings = bindings
        self.hideButtonBarWhenPhysicalKeyboardConnected =
            hideButtonBarWhenPhysicalKeyboardConnected
    }

    func binding(for command: AppKeyboardCommand) -> KeyboardKeyBinding? {
        bindings[command]
    }

    func validated(
        updating command: AppKeyboardCommand,
        to binding: KeyboardKeyBinding?
    ) throws -> KeyboardSettings {
        if let binding {
            guard !binding.modifiers.isEmpty else {
                throw ValidationError.missingModifier
            }
            if let existingCommand = AppKeyboardCommand.allCases.first(where: {
                $0 != command && bindings[$0] == binding
            }) {
                throw ValidationError.duplicateBinding(command: existingCommand)
            }
        }

        var updatedBindings = bindings
        updatedBindings[command] = binding
        let updated = KeyboardSettings(
            bindings: updatedBindings,
            hideButtonBarWhenPhysicalKeyboardConnected:
                hideButtonBarWhenPhysicalKeyboardConnected
        )
        try updated.validate()
        return updated
    }

    func validated() throws -> KeyboardSettings {
        try validate()
        return self
    }

    private func validate() throws {
        var commandsByBinding: [KeyboardKeyBinding: AppKeyboardCommand] = [:]
        for command in AppKeyboardCommand.allCases {
            guard let binding = bindings[command] else { continue }
            guard !binding.modifiers.isEmpty else {
                throw ValidationError.missingModifier
            }
            if let existingCommand = commandsByBinding[binding] {
                throw ValidationError.duplicateBinding(command: existingCommand)
            }
            commandsByBinding[binding] = command
        }
    }
}
