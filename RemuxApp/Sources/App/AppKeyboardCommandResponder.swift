import SwiftUI
import UIKit

struct AppKeyboardCommandResponder: UIViewRepresentable {
    var settings: KeyboardSettings
    var isEnabled: Bool
    var onCommand: (AppKeyboardCommand) -> Void

    func makeUIView(context: Context) -> AppKeyboardCommandResponderView {
        AppKeyboardCommandResponderView()
    }

    func updateUIView(
        _ view: AppKeyboardCommandResponderView,
        context: Context
    ) {
        view.update(
            settings: settings,
            isEnabled: isEnabled,
            onCommand: onCommand
        )
    }
}

final class AppKeyboardCommandResponderView: UIView {
    private var appKeyCommands: [UIKeyCommand] = []
    private var commandHandler: ((AppKeyboardCommand) -> Void)?
    private var isEnabled = false

    override var canBecomeFirstResponder: Bool {
        isEnabled
    }

    override var keyCommands: [UIKeyCommand]? {
        appKeyCommands
    }

    func update(
        settings: KeyboardSettings,
        isEnabled: Bool,
        onCommand: @escaping (AppKeyboardCommand) -> Void
    ) {
        self.isEnabled = isEnabled
        commandHandler = onCommand
        appKeyCommands = AppKeyboardCommand.allCases.compactMap { command -> UIKeyCommand? in
            guard let binding = settings.binding(for: command) else { return nil }
            let keyCommand = UIKeyCommand(
                title: command.displayTitle,
                image: nil,
                action: #selector(performAppKeyboardCommand(_:)),
                input: binding.input,
                modifierFlags: binding.modifiers.uiKeyModifierFlags,
                propertyList: command.rawValue
            )
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }

        if isEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasExternalFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }

    private var hasExternalFirstResponder: Bool {
        guard let window, let responder = firstResponder(in: window) else {
            return false
        }
        return responder !== self
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) {
                return responder
            }
        }
        return nil
    }

    @objc
    private func performAppKeyboardCommand(_ sender: UIKeyCommand) {
        guard
            let rawValue = sender.propertyList as? String,
            let command = AppKeyboardCommand(rawValue: rawValue)
        else {
            return
        }
        commandHandler?(command)
    }
}
