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
    @Published private(set) var availableCommands: [AppKeyboardCommand] = []
    private var commandHandler: ((AppKeyboardCommand) -> Void)?
    private weak var hostingController: AppKeyboardCommandHostingController?
    private var isShortcutCaptureActive = false
    private weak var commandPaletteOwner: AnyObject?
    private var commandPaletteHandlers: CommandPaletteHandlers?
    private weak var selectedTerminalOwner: AnyObject?
    private var selectedTerminalCommandHandler: ((AppKeyboardCommand) -> Void)?

    func update(
        settings: KeyboardSettings,
        availableCommands: [AppKeyboardCommand],
        onCommand: @escaping (AppKeyboardCommand) -> Void
    ) {
        commandHandler = onCommand
        if self.settings != settings {
            self.settings = settings
        }
        if self.availableCommands != availableCommands {
            self.availableCommands = availableCommands
        }
    }

    func perform(_ command: AppKeyboardCommand) {
        commandHandler?(command)
    }

    @discardableResult
    func performIfAvailable(_ command: AppKeyboardCommand) -> Bool {
        guard
            !isShortcutCaptureActive,
            availableCommands.contains(command),
            let commandHandler
        else {
            return false
        }
        commandHandler(command)
        return true
    }

    func registerSelectedTerminal(
        owner: AnyObject,
        onCommand: @escaping (AppKeyboardCommand) -> Void
    ) {
        selectedTerminalOwner = owner
        selectedTerminalCommandHandler = onCommand
    }

    func unregisterSelectedTerminal(owner: AnyObject) {
        guard selectedTerminalOwner === owner else { return }
        selectedTerminalOwner = nil
        selectedTerminalCommandHandler = nil
    }

    @discardableResult
    func performSelectedTerminal(_ command: AppKeyboardCommand) -> Bool {
        guard
            command.requiresTerminal,
            selectedTerminalOwner != nil,
            let selectedTerminalCommandHandler
        else {
            return false
        }
        selectedTerminalCommandHandler(command)
        return true
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
        controller.update(
            settings: center.settings,
            availableCommands: center.availableCommands,
            commandCenter: center
        )
        center.register(controller)
        return controller
    }

    func updateUIViewController(
        _ controller: AppKeyboardCommandHostingController,
        context: Context
    ) {
        controller.updateContent(AnyView(content))
        controller.update(
            settings: center.settings,
            availableCommands: center.availableCommands,
            commandCenter: center
        )
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
    private var availableCommands: [AppKeyboardCommand] = []
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

    func updateContent(_ rootView: AnyView) {
        contentController.rootView = rootView
    }

    func update(
        settings: KeyboardSettings,
        availableCommands: [AppKeyboardCommand],
        commandCenter: AppKeyboardCommandCenter
    ) {
        self.commandCenter = commandCenter
        keyboardSettings = settings
        self.availableCommands = availableCommands
        appKeyCommands = AppKeyboardKeyCommandBuilder.commands(
            settings: settings,
            commands: availableCommands,
            action: #selector(performAppKeyboardCommand(_:))
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
            availableCommands.contains(command)
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
    private func performAppKeyboardCommand(_ sender: UIKeyCommand) {
        guard
            let rawValue = sender.propertyList as? String,
            let command = AppKeyboardCommand(rawValue: rawValue),
            availableCommands.contains(command)
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

struct SelectedTerminalKeyboardCommandRegistrationView: UIViewRepresentable {
    let commandCenter: AppKeyboardCommandCenter?
    let isSelected: Bool
    let onCommand: (AppKeyboardCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.update(
            commandCenter: commandCenter,
            isSelected: isSelected,
            onCommand: onCommand
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            commandCenter: commandCenter,
            isSelected: isSelected,
            onCommand: onCommand
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator {
        private weak var commandCenter: AppKeyboardCommandCenter?
        private var onCommand: (AppKeyboardCommand) -> Void = { _ in }
        private var isRegistered = false

        func update(
            commandCenter: AppKeyboardCommandCenter?,
            isSelected: Bool,
            onCommand: @escaping (AppKeyboardCommand) -> Void
        ) {
            self.onCommand = onCommand

            if self.commandCenter !== commandCenter {
                if isRegistered {
                    self.commandCenter?.unregisterSelectedTerminal(owner: self)
                }
                self.commandCenter = commandCenter
                isRegistered = false
            }

            guard isSelected, let commandCenter else {
                if isRegistered {
                    self.commandCenter?.unregisterSelectedTerminal(owner: self)
                    isRegistered = false
                }
                return
            }

            guard !isRegistered else { return }
            commandCenter.registerSelectedTerminal(
                owner: self,
                onCommand: { [weak self] command in
                    self?.onCommand(command)
                }
            )
            isRegistered = true
        }

        func disconnect() {
            if isRegistered {
                commandCenter?.unregisterSelectedTerminal(owner: self)
            }
            commandCenter = nil
            isRegistered = false
        }
    }
}
