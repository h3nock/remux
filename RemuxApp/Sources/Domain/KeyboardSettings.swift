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
        case missingKey
        case missingModifier
        case unsupportedModifiers
        case reservedSystemShortcut
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
            .home: KeyboardKeyBinding(input: "h", modifiers: [.command, .shift]),
            .windows: KeyboardKeyBinding(input: "o", modifiers: [.command]),
            .panes: KeyboardKeyBinding(input: "p", modifiers: [.command]),
            .attachments: KeyboardKeyBinding(input: "a", modifiers: [.command]),
            .commandPalette: KeyboardKeyBinding(input: "k", modifiers: [.command]),
            .increaseFontSize: KeyboardKeyBinding(input: "+", modifiers: [.command]),
            .decreaseFontSize: KeyboardKeyBinding(input: "-", modifiers: [.command]),
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
        var updatedBindings = bindings
        if let binding {
            let canonicalBinding = try Self.canonicalized(binding)
            for existingCommand in AppKeyboardCommand.allCases where existingCommand != command {
                guard let existingBinding = bindings[existingCommand] else { continue }
                if try Self.canonicalized(existingBinding) == canonicalBinding {
                    throw ValidationError.duplicateBinding(command: existingCommand)
                }
            }
            updatedBindings[command] = canonicalBinding
        } else {
            updatedBindings[command] = nil
        }
        return try KeyboardSettings(
            bindings: updatedBindings,
            hideButtonBarWhenPhysicalKeyboardConnected:
                hideButtonBarWhenPhysicalKeyboardConnected
        ).validated()
    }

    func validated() throws -> KeyboardSettings {
        var canonicalBindings: [AppKeyboardCommand: KeyboardKeyBinding] = [:]
        var commandsByBinding: [KeyboardKeyBinding: AppKeyboardCommand] = [:]
        for command in AppKeyboardCommand.allCases {
            guard let binding = bindings[command] else { continue }
            let canonicalBinding = try Self.canonicalized(binding)
            if let existingCommand = commandsByBinding[canonicalBinding] {
                throw ValidationError.duplicateBinding(command: existingCommand)
            }
            commandsByBinding[canonicalBinding] = command
            canonicalBindings[command] = canonicalBinding
        }
        return KeyboardSettings(
            bindings: canonicalBindings,
            hideButtonBarWhenPhysicalKeyboardConnected:
                hideButtonBarWhenPhysicalKeyboardConnected
        )
    }

    private static func canonicalized(
        _ binding: KeyboardKeyBinding
    ) throws -> KeyboardKeyBinding {
        guard !binding.input.isEmpty else {
            throw ValidationError.missingKey
        }
        guard !binding.modifiers.isEmpty else {
            throw ValidationError.missingModifier
        }
        let supportedModifiers: KeyboardKeyModifiers = [
            .command,
            .shift,
            .option,
            .control,
        ]
        guard binding.modifiers.subtracting(supportedModifiers).isEmpty else {
            throw ValidationError.unsupportedModifiers
        }
        let canonicalBinding = KeyboardKeyBinding(
            input: binding.input.count == 1
                ? binding.input.lowercased()
                : binding.input,
            modifiers: binding.modifiers
        )
        guard canonicalBinding != KeyboardKeyBinding(
            input: "h",
            modifiers: [.command]
        ) else {
            throw ValidationError.reservedSystemShortcut
        }
        return canonicalBinding
    }
}
