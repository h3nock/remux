import Foundation

struct GhosttyModifierState: Equatable {
    /// The toolbar modifiers armed for the next key, each applied once.
    private(set) var armed: ShortcutModifiers = []

    var isControlArmed: Bool {
        armed.contains(.control)
    }

    mutating func toggle(_ modifier: ShortcutModifiers) {
        armed.formSymmetricDifference(modifier)
    }

    mutating func clear(_ modifiers: ShortcutModifiers = [.control, .option, .shift]) {
        armed.subtract(modifiers)
    }

    /// Text that is one key takes every armed modifier: Shift capitalizes a letter, Control makes its
    /// control character, and Alt puts ESC before it, as a terminal sends Meta. Longer text, such as an
    /// input method's commit, goes as it is. Either way the modifiers are used up.
    mutating func apply(to text: String) -> String {
        guard !armed.isEmpty else { return text }
        defer { armed = [] }
        guard text.unicodeScalars.count == 1 else { return text }

        var output = text
        if armed.contains(.shift) {
            // A letter takes its capital when that is one character too; a digit, a symbol or ß stays as it is.
            let capital = output.uppercased()
            if capital.unicodeScalars.count == 1 {
                output = capital
            }
        }
        if armed.contains(.control) {
            output = Self.controlText(for: output) ?? output
        }
        if armed.contains(.option) {
            output = "\u{1B}" + output
        }
        return output
    }

    mutating func apply(to event: GhosttySurfaceKeyEvent) -> GhosttySurfaceKeyEvent {
        guard !armed.isEmpty else { return event }
        defer { armed = [] }

        return GhosttySurfaceKeyEvent(
            action: event.action,
            keyCode: event.keyCode,
            text: event.text,
            composing: event.composing,
            mods: event.mods.union(armed.ghosttyModifiers),
            consumedMods: event.consumedMods,
            unshiftedCodepoint: event.unshiftedCodepoint
        )
    }

    /// The control character for text that is exactly one ASCII scalar Ctrl translates. Anything
    /// else, as a letter with a combining mark or an input method's commit, has none.
    static func controlText(for text: String) -> String? {
        let scalars = text.unicodeScalars
        guard
            scalars.count == 1,
            let scalar = scalars.first,
            let translated = controlScalar(for: scalar)
        else {
            return nil
        }

        return String(translated)
    }

    static func controlScalar(for scalar: UnicodeScalar) -> UnicodeScalar? {
        switch scalar.value {
        case 0x41 ... 0x5A:
            return UnicodeScalar(scalar.value - 0x40)
        case 0x61 ... 0x7A:
            return UnicodeScalar(scalar.value - 0x60)
        case 0x20, 0x40:
            return UnicodeScalar(0x00)
        case 0x5B:
            return UnicodeScalar(0x1B)
        case 0x5C:
            return UnicodeScalar(0x1C)
        case 0x5D:
            return UnicodeScalar(0x1D)
        case 0x5E, 0x36:
            return UnicodeScalar(0x1E)
        case 0x5F, 0x2D:
            return UnicodeScalar(0x1F)
        default:
            return nil
        }
    }
}
