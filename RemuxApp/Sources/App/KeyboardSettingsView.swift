import SwiftUI
import UIKit

struct KeyboardSettingsView: View {
    @State private var settings: KeyboardSettings
    @State private var capturingCommand: AppKeyboardCommand?
    @State private var validationMessage: String?
    let onChange: (KeyboardSettings) -> Void

    init(
        initialSettings: KeyboardSettings,
        onChange: @escaping (KeyboardSettings) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Hide button bar when a physical keyboard is connected",
                    isOn: hideButtonBarBinding
                )
                .accessibilityIdentifier("keyboard-settings.hide-button-bar")
            }

            Section("Key Bindings") {
                ForEach(AppKeyboardCommand.allCases) { command in
                    HStack {
                        Text(command.displayTitle)
                        Spacer()
                        Text(KeyboardBindingDescription.text(settings.binding(for: command)))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity, alignment: .center)
                        Button("Set") {
                            validationMessage = nil
                            capturingCommand = command
                        }
                        .accessibilityIdentifier("keyboard-settings.set.\(command.rawValue)")
                        if settings.binding(for: command) != nil {
                            Button("Clear") {
                                update(command, binding: nil)
                            }
                            .accessibilityIdentifier("keyboard-settings.clear.\(command.rawValue)")
                        }
                    }
                    .accessibilityIdentifier("keyboard-settings.binding.\(command.rawValue)")
                }
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("keyboard-settings.validation")
                }
            }
        }
        .navigationTitle("Physical Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("keyboard-settings.form")
        .sheet(item: $capturingCommand) { command in
            NavigationStack {
                VStack(spacing: 20) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 48))
                    Text("Press the shortcut for \(command.displayTitle)")
                        .multilineTextAlignment(.center)
                    Text("Use at least one modifier key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    KeyboardShortcutCaptureView { result in
                        switch result {
                        case .success(let binding):
                            update(command, binding: binding)
                            if validationMessage == nil {
                                capturingCommand = nil
                            }
                        case .failure:
                            validationMessage = "A shortcut needs a key and at least one modifier."
                        }
                    }
                    .frame(width: 1, height: 1)
                }
                .padding()
                .navigationTitle("Set Shortcut")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { capturingCommand = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var hideButtonBarBinding: Binding<Bool> {
        Binding(
            get: { settings.hideButtonBarWhenPhysicalKeyboardConnected },
            set: { value in
                var updated = settings
                updated.hideButtonBarWhenPhysicalKeyboardConnected = value
                settings = updated
                onChange(updated)
            }
        )
    }

    private func update(
        _ command: AppKeyboardCommand,
        binding: KeyboardKeyBinding?
    ) {
        do {
            let updated = try settings.validated(updating: command, to: binding)
            settings = updated
            validationMessage = nil
            onChange(updated)
        } catch KeyboardSettings.ValidationError.duplicateBinding(let existingCommand) {
            validationMessage = "That shortcut is already assigned to \(existingCommand.displayTitle)."
        } catch {
            validationMessage = "A shortcut needs a key and at least one modifier."
        }
    }

}

enum KeyboardBindingDescription {
    static func text(_ binding: KeyboardKeyBinding?) -> String {
        guard let binding else { return "Unassigned" }
        var parts: [String] = []
        if binding.modifiers.contains(.control) { parts.append("⌃") }
        if binding.modifiers.contains(.option) { parts.append("⌥") }
        if binding.modifiers.contains(.shift) { parts.append("⇧") }
        if binding.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyDescription(binding.input))
        return parts.joined(separator: " ")
    }

    private static func keyDescription(_ input: String) -> String {
        switch input {
        case UIKeyCommand.inputLeftArrow:
            "←"
        case UIKeyCommand.inputRightArrow:
            "→"
        case UIKeyCommand.inputUpArrow:
            "↑"
        case UIKeyCommand.inputDownArrow:
            "↓"
        default:
            input.uppercased()
        }
    }
}
