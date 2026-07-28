import SwiftUI
import UIKit

enum CommandPaletteLayout {
    static let maximumVisibleResultCount = 6
    static let inputRowHeight: CGFloat = 44
    static let resultRowHeight: CGFloat = 56
    static let emptyResultHeight: CGFloat = 120
    static let screenMargin: CGFloat = 20
    static let cardInset: CGFloat = 10
    static let innerCornerRadius: CGFloat = 12

    static func resultAreaHeight(for resultCount: Int) -> CGFloat {
        guard resultCount > 0 else { return emptyResultHeight }
        return CGFloat(min(resultCount, maximumVisibleResultCount))
            * resultRowHeight
    }
}

struct CommandPaletteView: View {
    let commands: [CommandPaletteItem]
    let snapshots: () -> [TerminalViewportSnapshot]
    let onSelect: (CommandPaletteAction) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var paletteState: CommandPaletteState
    @State private var searchTask: Task<Void, Never>?

    init(
        commands: [CommandPaletteItem],
        snapshots: @escaping () -> [TerminalViewportSnapshot],
        onSelect: @escaping (CommandPaletteAction) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.commands = commands
        self.snapshots = snapshots
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _paletteState = State(
            initialValue: CommandPaletteState(results: commands)
        )
    }

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
            .padding(.horizontal, 12)
            .frame(height: CommandPaletteLayout.inputRowHeight)
            .background(LibraryHomePalette.rowSurface)

            Divider()
                .overlay(LibraryHomePalette.separator)

            if paletteState.results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity)
                    .frame(height: CommandPaletteLayout.emptyResultHeight)
                    .background(LibraryHomePalette.background)
            } else {
                ScrollViewReader { proxy in
                    List(paletteState.results) { item in
                        Button {
                            onSelect(item.action)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                minHeight: CommandPaletteLayout.resultRowHeight,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("command-palette.item.\(item.id)")
                        .accessibilityAddTraits(
                            item.id == paletteState.selectedResultID ? .isSelected : []
                        )
                        .disabled(!item.isEnabled)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: 16,
                                bottom: 0,
                                trailing: 16
                            )
                        )
                        .listRowBackground(
                            item.id == paletteState.selectedResultID
                                ? LibraryHomePalette.controlAccent.opacity(0.22)
                                : LibraryHomePalette.rowSurface
                        )
                        .listRowSeparatorTint(LibraryHomePalette.separator)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(LibraryHomePalette.background)
                    .frame(
                        height: CommandPaletteLayout.resultAreaHeight(
                            for: paletteState.results.count
                        )
                    )
                    .onChange(of: paletteState.selectedResultID) { _, id in
                        guard let id else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: CommandPaletteLayout.innerCornerRadius,
                style: .continuous
            )
        )
        .padding(CommandPaletteLayout.cardInset)
        .frame(maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            LibraryHomePalette.background,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(LibraryHomePalette.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
        .shadow(radius: 30)
        .padding(CommandPaletteLayout.screenMargin)
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
        paletteState.replaceResults(newResults)
    }

    private func moveSelection(_ direction: CommandPaletteSelectionDirection) {
        paletteState.moveSelection(direction)
    }

    private func activateSelectedResult() {
        guard let result = paletteState.selectedResult else { return }
        onSelect(result.action)
    }
}

private struct CommandPaletteSearchField: UIViewRepresentable {
    @Environment(\.appKeyboardCommandCenter) private var commandCenter
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
        field.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
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
        field.setCommandCenter(commandCenter)
    }

    static func dismantleUIView(
        _ field: CommandPaletteTextField,
        coordinator: ()
    ) {
        field.unregisterCommandPalette()
    }
}

final class CommandPaletteTextField: UITextField, UITextFieldDelegate {
    var onTextChange: ((String) -> Void)?
    var onMoveSelection: ((CommandPaletteSelectionDirection) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onDismiss: (() -> Void)?
    private weak var commandCenter: AppKeyboardCommandCenter?

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFont.preferredFont(forTextStyle: .footnote)
        adjustsFontForContentSizeCategory = true
        delegate = self
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unregisterCommandPalette()
            return
        }
        registerCommandPalette()
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

    func setCommandCenter(_ commandCenter: AppKeyboardCommandCenter?) {
        if self.commandCenter !== commandCenter {
            unregisterCommandPalette()
            self.commandCenter = commandCenter
        }
        registerCommandPalette()
    }

    func unregisterCommandPalette() {
        commandCenter?.unregisterCommandPalette(owner: self)
    }

    private func registerCommandPalette() {
        guard window != nil else { return }
        commandCenter?.registerCommandPalette(
            owner: self,
            onMoveSelection: { [weak self] direction in
                self?.onMoveSelection?(direction)
            },
            onActivateSelection: { [weak self] in
                self?.onActivateSelection?()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?()
            }
        )
    }

    @objc
    private func textDidChange() {
        onTextChange?(text ?? "")
    }
}
