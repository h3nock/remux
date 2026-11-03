import Foundation

struct GhosttyModifierState: Equatable {
    private(set) var controlArmed = false

    var isControlArmed: Bool {
        controlArmed
    }

    mutating func toggleControl() {
        controlArmed.toggle()
    }

    mutating func clearControl() {
        controlArmed = false
    }

    mutating func apply(to text: String) -> String {
        guard controlArmed else { return text }
        defer { controlArmed = false }
        return Self.controlText(for: text) ?? text
    }

    mutating func apply(to event: GhosttySurfaceKeyEvent) -> GhosttySurfaceKeyEvent {
        guard controlArmed else { return event }
        defer { controlArmed = false }

        return GhosttySurfaceKeyEvent(
            action: event.action,
            keyCode: event.keyCode,
            text: event.text,
            composing: event.composing,
            mods: event.mods.union(.ctrl),
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
