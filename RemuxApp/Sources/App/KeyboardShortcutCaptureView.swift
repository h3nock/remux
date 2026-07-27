import SwiftUI
import UIKit

enum KeyboardShortcutCapture {
    enum ValidationError: Error, Equatable {
        case missingKey
        case missingModifier
    }

    static func binding(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) throws -> KeyboardKeyBinding {
        guard !input.isEmpty else { throw ValidationError.missingKey }
        let modifiers = KeyboardKeyModifiers(modifierFlags)
        guard !modifiers.isEmpty else { throw ValidationError.missingModifier }
        return KeyboardKeyBinding(
            input: input.count == 1 ? input.lowercased() : input,
            modifiers: modifiers
        )
    }

    static func clearedBinding() -> KeyboardKeyBinding? {
        nil
    }
}

struct KeyboardShortcutCaptureView: UIViewRepresentable {
    let onCapture: (Result<KeyboardKeyBinding, Error>) -> Void

    func makeUIView(context: Context) -> KeyboardShortcutCaptureUIView {
        let view = KeyboardShortcutCaptureUIView()
        view.onCapture = onCapture
        return view
    }

    func updateUIView(_ view: KeyboardShortcutCaptureUIView, context: Context) {
        view.onCapture = onCapture
        DispatchQueue.main.async { [weak view] in
            _ = view?.becomeFirstResponder()
        }
    }
}

final class KeyboardShortcutCaptureUIView: UIView {
    var onCapture: ((Result<KeyboardKeyBinding, Error>) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else {
            super.pressesBegan(presses, with: event)
            return
        }

        do {
            let binding = try KeyboardShortcutCapture.binding(
                input: key.charactersIgnoringModifiers,
                modifierFlags: key.modifierFlags
            )
            onCapture?(.success(binding))
        } catch {
            onCapture?(.failure(error))
        }
    }
}
