import Foundation

@MainActor
struct ShortcutExecutor {
    let sendText: (String) -> Bool
    let sendKey: (GhosttySurfaceKeyEvent) -> Bool
    let autoSubmitBoundary: () async -> Bool

    init(
        sendText: @escaping (String) -> Bool,
        sendKey: @escaping (GhosttySurfaceKeyEvent) -> Bool,
        autoSubmitBoundary: @escaping () async -> Bool = {
            do {
                try await Task.sleep(for: .milliseconds(75))
                return true
            } catch {
                return false
            }
        }
    ) {
        self.sendText = sendText
        self.sendKey = sendKey
        self.autoSubmitBoundary = autoSubmitBoundary
    }

    @discardableResult
    func execute(_ shortcut: Shortcut) async -> Bool {
        await execute(shortcut.sequence)
    }

    @discardableResult
    func execute(_ sequence: ShortcutSequence) async -> Bool {
        switch sequence {
        case .text(let text, let submit):
            guard sendText(text) else { return false }
            guard submit else { return true }
            guard await autoSubmitBoundary() else { return false }
            return sendEnterKeyTap()

        case .control(let text):
            guard let translated = GhosttyModifierState.controlText(for: text) else {
                return false
            }
            return sendText(translated)

        case .key(let key, let modifiers):
            return sendKey(
                GhosttySurfaceKeyEvent(
                    keyCode: key.ghosttyKeyCode,
                    mods: modifiers.ghosttyModifiers
                )
            )
        }
    }

    private func sendEnterKeyTap() -> Bool {
        let keyCode = GhosttySurfaceKeyEvent.KeyCode.enter
        guard sendKey(GhosttySurfaceKeyEvent(action: .press, keyCode: keyCode)) else {
            return false
        }
        _ = sendKey(GhosttySurfaceKeyEvent(action: .release, keyCode: keyCode))
        return true
    }
}

private extension ShortcutModifiers {
    var ghosttyModifiers: GhosttySurfaceKeyEvent.Mods {
        var result: GhosttySurfaceKeyEvent.Mods = []
        if contains(.control) { result.insert(.ctrl) }
        if contains(.option) { result.insert(.alt) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}
