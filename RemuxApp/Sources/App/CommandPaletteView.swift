import SwiftUI
import UIKit

struct CommandPaletteView: View {
    let commands: [CommandPaletteItem]
    let snapshots: () -> [TerminalViewportSnapshot]
    let onSelect: (CommandPaletteAction) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [CommandPaletteItem] = []
    @State private var selectedResultID: CommandPaletteItem.ID?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command")
                CommandPaletteSearchField(
                    text: $query,
                    onMoveSelection: moveSelection,
                    onActivateSelection: activateSelectedResult,
                    onDismiss: onDismiss
                )
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(LibraryHomePalette.rowSurface)

            Divider()
                .overlay(LibraryHomePalette.separator)

            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LibraryHomePalette.background)
            } else {
                ScrollViewReader { proxy in
                    List(results) { item in
                        Button {
                            onSelect(item.action)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .accessibilityIdentifier("command-palette.item.\(item.id)")
                        .accessibilityAddTraits(
                            item.id == selectedResultID ? .isSelected : []
                        )
                        .disabled(!item.isEnabled)
                        .listRowBackground(
                            item.id == selectedResultID
                                ? LibraryHomePalette.controlAccent.opacity(0.22)
                                : LibraryHomePalette.rowSurface
                        )
                        .listRowSeparatorTint(LibraryHomePalette.separator)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(LibraryHomePalette.background)
                    .onChange(of: selectedResultID) { _, id in
                        guard let id else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 620, maxHeight: 520)
        .background(
            LibraryHomePalette.background,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(LibraryHomePalette.separator, lineWidth: 1)
        }
        .shadow(radius: 30)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
        .task {
            updateResults(commands)
        }
        .onChange(of: query) { _, value in
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                if !value.isEmpty {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled else { return }
                updateResults(
                    CommandPaletteSearch.results(
                        query: value,
                        commands: commands,
                        snapshots: snapshots()
                    )
                )
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func updateResults(_ newResults: [CommandPaletteItem]) {
        results = newResults
        selectedResultID = CommandPaletteSelection.initialID(in: newResults)
    }

    private func moveSelection(_ direction: CommandPaletteSelectionDirection) {
        selectedResultID = CommandPaletteSelection.moving(
            from: selectedResultID,
            direction: direction,
            in: results
        )
    }

    private func activateSelectedResult() {
        guard
            let selectedResultID,
            let result = results.first(where: {
                $0.id == selectedResultID && $0.isEnabled
            })
        else {
            return
        }
        onSelect(result.action)
    }
}

private struct CommandPaletteSearchField: UIViewRepresentable {
    @Binding var text: String
    let onMoveSelection: (CommandPaletteSelectionDirection) -> Void
    let onActivateSelection: () -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> CommandPaletteTextField {
        let field = CommandPaletteTextField()
        field.placeholder = "Type a command or search visible terminals"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = .label
        field.tintColor = .label
        field.accessibilityIdentifier = "command-palette.search"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(field)
        return field
    }

    func updateUIView(_ field: CommandPaletteTextField, context: Context) {
        configure(field)
    }

    private func configure(_ field: CommandPaletteTextField) {
        if field.text != text {
            field.text = text
        }
        field.onTextChange = { value in
            text = value
        }
        field.onMoveSelection = onMoveSelection
        field.onActivateSelection = onActivateSelection
        field.onDismiss = onDismiss
    }
}

final class CommandPaletteTextField: UITextField, UITextFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onMoveSelection: ((CommandPaletteSelectionDirection) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            priorityKeyCommand(
                input: "\r",
                action: #selector(activateSelection)
            ),
            priorityKeyCommand(
                input: UIKeyCommand.inputEscape,
                action: #selector(dismissPalette)
            ),
        ]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusWhenAttached()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses: Set<UIPress> = []
        for press in presses {
            guard
                let key = press.key,
                handleKeyPress(
                    input: key.charactersIgnoringModifiers,
                    modifierFlags: key.modifierFlags
                )
            else {
                unhandledPresses.insert(press)
                continue
            }
        }
        if !unhandledPresses.isEmpty {
            super.pressesBegan(unhandledPresses, with: event)
        }
    }

    func handleKeyPress(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> Bool {
        let actionModifiers: UIKeyModifierFlags = [
            .command,
            .shift,
            .alternate,
            .control,
        ]
        guard modifierFlags.intersection(actionModifiers).isEmpty else {
            return false
        }

        switch input {
        case UIKeyCommand.inputUpArrow:
            onMoveSelection?(.previous)
        case UIKeyCommand.inputDownArrow:
            onMoveSelection?(.next)
        case "\r", "\n":
            onActivateSelection?()
        case UIKeyCommand.inputEscape:
            onDismiss?()
        default:
            return false
        }
        return true
    }

    func focusWhenAttached() {
        guard window != nil, !isFirstResponder else { return }
        if becomeFirstResponder() {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else {
                return
            }
            _ = self.becomeFirstResponder()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onActivateSelection?()
        return false
    }

    private func priorityKeyCommand(
        input: String,
        action: Selector
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: [],
            action: action
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc
    private func activateSelection() {
        onActivateSelection?()
    }

    @objc
    private func dismissPalette() {
        onDismiss?()
    }

    @objc
    private func textDidChange() {
        onTextChange?(text ?? "")
    }
}
