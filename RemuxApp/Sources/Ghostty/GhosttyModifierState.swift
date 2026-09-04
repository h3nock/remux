import Foundation

struct GhosttyModifierState: Equatable {
    private(set) var controlArmed = false
    private(set) var shiftArmed = false

    var isControlArmed: Bool {
        controlArmed
    }

    var isShiftArmed: Bool {
        shiftArmed
    }

    private var isAnyModifierArmed: Bool {
        controlArmed || shiftArmed
    }

    mutating func toggleControl() {
        controlArmed.toggle()
    }

    mutating func toggleShift() {
        shiftArmed.toggle()
    }

    mutating func clearModifiers() {
        controlArmed = false
        shiftArmed = false
    }

    mutating func apply(to text: String) -> String {
        guard isAnyModifierArmed else { return text }
        defer { clearModifiers() }

        var outbound = text
        if shiftArmed {
            outbound = Self.shiftText(for: outbound) ?? outbound
        }
        if controlArmed {
            outbound = Self.controlText(for: outbound) ?? outbound
        }
        return outbound
    }

    mutating func apply(to event: GhosttySurfaceKeyEvent) -> GhosttySurfaceKeyEvent {
        guard isAnyModifierArmed else { return event }
        defer { clearModifiers() }

        var mods = event.mods
        if controlArmed {
            mods.insert(.ctrl)
        }
        if shiftArmed {
            mods.insert(.shift)
        }

        return GhosttySurfaceKeyEvent(
            action: event.action,
            keyCode: event.keyCode,
            text: event.text,
            composing: event.composing,
            mods: mods,
            consumedMods: event.consumedMods,
            unshiftedCodepoint: event.unshiftedCodepoint
        )
    }

    /// Shift applied to soft-keyboard text: a single character is uppercased.
    /// Anything else (digits, punctuation, multi-character input) has no
    /// layout-independent shifted form, so callers fall back to the original.
    static func shiftText(for text: String) -> String? {
        guard text.count == 1 else { return nil }
        let shifted = text.uppercased()
        guard shifted.count == 1, shifted != text else { return nil }
        return shifted
    }

    static func controlText(for text: String) -> String? {
        guard
            text.count == 1,
            let scalar = text.unicodeScalars.first,
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
