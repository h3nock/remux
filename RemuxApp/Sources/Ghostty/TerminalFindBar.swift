import SwiftUI
import UIKit

/// Native editing stays local; only committed query changes become backend intent.
struct TerminalFindBar: UIViewRepresentable {
    @Binding var query: String
    @Binding var wantsKeyboard: Bool
    let presentation: TerminalFindPresentation
    let onQuery: (String) -> Void
    let onNavigate: (Int) -> Void
    let onClose: () -> Void

    func makeUIView(context: Context) -> TerminalFindBarView { TerminalFindBarView() }

    static func dismantleUIView(_ view: TerminalFindBarView, coordinator: ()) {
        view.wantsKeyboard = false
    }

    func updateUIView(_ view: TerminalFindBarView, context: Context) {
        view.onQuery = { query = $0; onQuery($0) }
        view.onNavigate = onNavigate
        view.onClose = onClose
        view.onKeyboard = { wantsKeyboard = $0 }
        if view.field.text != query, view.field.markedTextRange == nil { view.field.text = query }
        view.count.text = presentation.status
        view.previousButton.isEnabled = presentation.canNavigate
        view.nextButton.isEnabled = presentation.canNavigate
        view.wantsKeyboard = wantsKeyboard
    }
}

final class TerminalFindBarView: UIView, UITextFieldDelegate {
    let field = FindQueryField()
    let count = UILabel()
    let previousButton = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    var onQuery: ((String) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onKeyboard: ((Bool) -> Void)?
    var wantsKeyboard = true { didSet { reconcileFocus() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Close Find"
        close.accessibilityIdentifier = "terminal.find.close"
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        field.onEscape = { [weak self] in self?.close() }
        field.placeholder = "Find"
        field.font = .systemFont(ofSize: 16)
        field.textColor = .label
        field.autocapitalizationType = .none; field.autocorrectionType = .no
        field.spellCheckingType = .no; field.smartQuotesType = .no; field.smartDashesType = .no
        field.clearButtonMode = .whileEditing; field.returnKeyType = .search
        field.accessibilityLabel = "Find in pane"
        field.accessibilityIdentifier = "terminal.find.query"
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabel
        count.accessibilityIdentifier = "terminal.find.count"
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fieldStack = UIStackView(arrangedSubviews: [field, count])
        fieldStack.axis = .horizontal; fieldStack.spacing = 5; fieldStack.alignment = .center
        let fieldGroup = material(fieldStack, inset: 13)
        for (button, symbol, label, id, step) in [
            (previousButton, "chevron.up", "Previous match", "previous", -1),
            (nextButton, "chevron.down", "Next match", "next", 1)
        ] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "terminal.find." + id
            button.addAction(UIAction { [weak self] _ in self?.onNavigate?(step) }, for: .touchUpInside)
        }
        let closeGroup = material(UIStackView(arrangedSubviews: [close]))
        let arrows = UIStackView(arrangedSubviews: [previousButton, nextButton]); arrows.distribution = .fillEqually
        let arrowGroup = material(arrows)
        let stack = UIStackView(arrangedSubviews: [closeGroup, fieldGroup, arrowGroup])
        stack.axis = .horizontal; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeGroup.widthAnchor.constraint(equalToConstant: 44), arrowGroup.widthAnchor.constraint(equalToConstant: 88)
        ])
        tintColor = .label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func material(_ content: UIView, inset: CGFloat = 0) -> UIView {
        let group = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        group.layer.cornerRadius = 23; group.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        group.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: group.contentView.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: group.contentView.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: group.contentView.topAnchor), content.bottomAnchor.constraint(equalTo: group.contentView.bottomAnchor)
        ])
        return group
    }

    override func didMoveToWindow() { super.didMoveToWindow(); reconcileFocus() }
    private func reconcileFocus() {
        if wantsKeyboard, window != nil, !field.isFirstResponder { field.becomeFirstResponder() }
        else if !wantsKeyboard, field.isFirstResponder { field.resignFirstResponder() }
    }
    private func queryChanged() {
        guard field.markedTextRange == nil else { return }
        onQuery?(field.text ?? "")
    }
    func textFieldDidChangeSelection(_ textField: UITextField) { queryChanged() }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if !wantsKeyboard { wantsKeyboard = true; onKeyboard?(true) }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        wantsKeyboard = false; onKeyboard?(false)
        return true
    }
    private func close() {
        wantsKeyboard = false
        onKeyboard?(false)
        onClose?()
    }
}

final class FindQueryField: UITextField {
    var onEscape: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeFind))]
    }
    @objc private func escapeFind() { onEscape?() }
}
