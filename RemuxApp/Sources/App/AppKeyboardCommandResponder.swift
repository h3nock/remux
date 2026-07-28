import SwiftUI
import UIKit

enum CommandPaletteKeyboardAction: String, CaseIterable {
    case previousResult
    case nextResult
    case activateSelection
    case dismiss

    var input: String {
        switch self {
        case .previousResult:
            UIKeyCommand.inputUpArrow
        case .nextResult:
            UIKeyCommand.inputDownArrow
        case .activateSelection:
            "\r"
        case .dismiss:
            UIKeyCommand.inputEscape
        }
    }

    var displayTitle: String {
        switch self {
        case .previousResult:
            "Previous Result"
        case .nextResult:
            "Next Result"
        case .activateSelection:
            "Choose Result"
        case .dismiss:
            "Close Command Palette"
        }
    }
}

@MainActor
final class AppKeyboardCommandCenter: ObservableObject {
    private struct CommandPaletteHandlers {
        let onMoveSelection: (CommandPaletteSelectionDirection) -> Void
        let onActivateSelection: () -> Void
        let onDismiss: () -> Void
    }

    @Published private(set) var settings: KeyboardSettings = .default
    private var commandHandler: ((AppKeyboardCommand) -> Void)?
    private weak var hostingController: AppKeyboardCommandHostingController?
    private var isShortcutCaptureActive = false
    private weak var commandPaletteOwner: AnyObject?
    private var commandPaletteHandlers: CommandPaletteHandlers?

    func update(
        settings: KeyboardSettings,
        onCommand: @escaping (AppKeyboardCommand) -> Void
    ) {
        commandHandler = onCommand
        if self.settings != settings {
            self.settings = settings
        }
    }

    func perform(_ command: AppKeyboardCommand) {
        commandHandler?(command)
    }

    func register(_ hostingController: AppKeyboardCommandHostingController) {
        self.hostingController = hostingController
        hostingController.setSuspended(isShortcutCaptureActive)
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        isShortcutCaptureActive = isActive
        hostingController?.setSuspended(isActive)
    }

    func registerCommandPalette(
        owner: AnyObject,
        onMoveSelection: @escaping (CommandPaletteSelectionDirection) -> Void,
        onActivateSelection: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        commandPaletteOwner = owner
        commandPaletteHandlers = CommandPaletteHandlers(
            onMoveSelection: onMoveSelection,
            onActivateSelection: onActivateSelection,
            onDismiss: onDismiss
        )
    }

    func unregisterCommandPalette(owner: AnyObject) {
        guard commandPaletteOwner === owner else { return }
        commandPaletteOwner = nil
        commandPaletteHandlers = nil
    }

    var hasRegisteredCommandPalette: Bool {
        commandPaletteOwner != nil && commandPaletteHandlers != nil
    }

    func perform(_ action: CommandPaletteKeyboardAction) {
        guard
            commandPaletteOwner != nil,
            let commandPaletteHandlers
        else {
            return
        }

        switch action {
        case .previousResult:
            commandPaletteHandlers.onMoveSelection(.previous)
        case .nextResult:
            commandPaletteHandlers.onMoveSelection(.next)
        case .activateSelection:
            commandPaletteHandlers.onActivateSelection()
        case .dismiss:
            commandPaletteHandlers.onDismiss()
        }
    }
}

private struct AppKeyboardCommandCenterKey: EnvironmentKey {
    static let defaultValue: AppKeyboardCommandCenter? = nil
}

extension EnvironmentValues {
    var appKeyboardCommandCenter: AppKeyboardCommandCenter? {
        get { self[AppKeyboardCommandCenterKey.self] }
        set { self[AppKeyboardCommandCenterKey.self] = newValue }
    }
}

struct AppKeyboardCommandHost<Content: View>: UIViewControllerRepresentable {
    @ObservedObject var center: AppKeyboardCommandCenter
    private let content: Content

    init(
        center: AppKeyboardCommandCenter,
        @ViewBuilder content: () -> Content
    ) {
        self.center = center
        self.content = content()
    }

    func makeUIViewController(context: Context) -> AppKeyboardCommandHostingController {
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(content),
            commandCenter: center
        )
        controller.update(settings: center.settings, commandCenter: center)
        center.register(controller)
        return controller
    }

    func updateUIViewController(
        _ controller: AppKeyboardCommandHostingController,
        context: Context
    ) {
        controller.update(settings: center.settings, commandCenter: center)
        center.register(controller)
    }
}

@MainActor
enum AppKeyboardKeyCommandBuilder {
    static func commands(
        settings: KeyboardSettings,
        commands: [AppKeyboardCommand],
        action: Selector
    ) -> [UIKeyCommand] {
        commands.compactMap { command -> UIKeyCommand? in
            guard let binding = settings.binding(for: command) else { return nil }
            let keyCommand = UIKeyCommand(
                title: command.displayTitle,
                image: nil,
                action: action,
                input: binding.input,
                modifierFlags: binding.modifiers.uiKeyModifierFlags,
                propertyList: command.rawValue
            )
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }
    }
}

final class AppKeyboardCommandHostingController: UIViewController {
    private let contentController: UIHostingController<AnyView>
    private weak var commandCenter: AppKeyboardCommandCenter?
    private var appKeyCommands: [UIKeyCommand] = []
    private var keyboardSettings: KeyboardSettings = .default
    private var isSuspended = false

    init(rootView: AnyView, commandCenter: AppKeyboardCommandCenter) {
        contentController = UIHostingController(rootView: rootView)
        self.commandCenter = commandCenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(contentController)
        contentController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentController.view)
        NSLayoutConstraint.activate([
            contentController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard !isSuspended else { return [] }
        guard commandCenter?.hasRegisteredCommandPalette == true else {
            return appKeyCommands
        }
        return appKeyCommands + commandPaletteKeyCommands
    }

    override var canBecomeFirstResponder: Bool {
        true
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

    func update(
        settings: KeyboardSettings,
        commandCenter: AppKeyboardCommandCenter
    ) {
        self.commandCenter = commandCenter
        keyboardSettings = settings
        appKeyCommands = AppKeyboardKeyCommandBuilder.commands(
            settings: settings,
            commands: AppKeyboardCommand.allCases.filter { !$0.requiresTerminal },
            action: #selector(performGlobalAppKeyboardCommand(_:))
        )
    }

    func setSuspended(_ isSuspended: Bool) {
        self.isSuspended = isSuspended
    }

    func handleKeyPress(
        input: String,
        modifierFlags: UIKeyModifierFlags
    ) -> Bool {
        guard !isSuspended else { return false }
        guard
            let command = AppKeyboardCommandResolver(settings: keyboardSettings)
                .command(input: input, modifierFlags: modifierFlags),
            !command.requiresTerminal
        else {
            return false
        }
        commandCenter?.perform(command)
        return true
    }

    private var commandPaletteKeyCommands: [UIKeyCommand] {
        CommandPaletteKeyboardAction.allCases.map { action in
            let command = UIKeyCommand(
                title: action.displayTitle,
                image: nil,
                action: #selector(performCommandPaletteKeyboardAction(_:)),
                input: action.input,
                modifierFlags: [],
                propertyList: action.rawValue
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc
    private func performGlobalAppKeyboardCommand(_ sender: UIKeyCommand) {
        guard
            let rawValue = sender.propertyList as? String,
            let command = AppKeyboardCommand(rawValue: rawValue),
            !command.requiresTerminal
        else {
            return
        }
        commandCenter?.perform(command)
    }

    @objc
    private func performCommandPaletteKeyboardAction(_ sender: UIKeyCommand) {
        guard
            let rawValue = sender.propertyList as? String,
            let action = CommandPaletteKeyboardAction(rawValue: rawValue)
        else {
            return
        }
        commandCenter?.perform(action)
    }
}
