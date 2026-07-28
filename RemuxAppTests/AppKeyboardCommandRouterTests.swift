import SwiftUI
import UIKit
import XCTest
@testable import Remux

private struct AppKeyboardCommandHostContentProbe: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.text = text
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.text = text
    }
}

final class AppKeyboardCommandRouterTests: XCTestCase {
    func testHomeRouteKeepsGlobalCommandsAndDisablesTerminalCommands() {
        let context = AppKeyboardCommandRouteContext(
            selectedSessionID: nil,
            isSelectedTerminalReady: false,
            orderedActiveSessionIDs: []
        )

        XCTAssertEqual(AppKeyboardCommandRouter.route(.home, in: context), .showHome)
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.commandPalette, in: context),
            .showCommandPalette
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.previousWindow, in: context),
            .unavailable
        )
        XCTAssertEqual(AppKeyboardCommandRouter.route(.windows, in: context), .unavailable)
    }

    func testFontSizeCommandsAreGlobalAdjustments() {
        let context = AppKeyboardCommandRouteContext(
            selectedSessionID: nil,
            isSelectedTerminalReady: false,
            orderedActiveSessionIDs: []
        )

        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.increaseFontSize, in: context),
            .adjustFontSize(by: 1)
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.decreaseFontSize, in: context),
            .adjustFontSize(by: -1)
        )
    }

    func testSelectedTerminalCommandsRouteLocally() {
        let selectedID = UUID()
        let context = AppKeyboardCommandRouteContext(
            selectedSessionID: selectedID,
            isSelectedTerminalReady: true,
            orderedActiveSessionIDs: [selectedID]
        )

        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.previousWindow, in: context),
            .terminal(.previousWindow)
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.windows, in: context),
            .terminal(.windows)
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.newWindow, in: context),
            .terminal(.newWindow)
        )
    }

    func testSessionNavigationWrapsInSuppliedHomeOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let ordered = [first, second, third]

        XCTAssertEqual(
            AppKeyboardCommandRouter.route(
                .previousSession,
                in: AppKeyboardCommandRouteContext(
                    selectedSessionID: first,
                    isSelectedTerminalReady: true,
                    orderedActiveSessionIDs: ordered
                )
            ),
            .showSession(third)
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(
                .nextSession,
                in: AppKeyboardCommandRouteContext(
                    selectedSessionID: third,
                    isSelectedTerminalReady: true,
                    orderedActiveSessionIDs: ordered
                )
            ),
            .showSession(first)
        )
    }

    func testSessionNavigationFromHomeChoosesNearestEnd() {
        let first = UUID()
        let last = UUID()
        let context = AppKeyboardCommandRouteContext(
            selectedSessionID: nil,
            isSelectedTerminalReady: false,
            orderedActiveSessionIDs: [first, last]
        )

        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.nextSession, in: context),
            .showSession(first)
        )
        XCTAssertEqual(
            AppKeyboardCommandRouter.route(.previousSession, in: context),
            .showSession(last)
        )
    }

    func testDisconnectedSelectedTerminalDisablesTerminalCommands() {
        let selectedID = UUID()
        let context = AppKeyboardCommandRouteContext(
            selectedSessionID: selectedID,
            isSelectedTerminalReady: false,
            orderedActiveSessionIDs: [selectedID]
        )

        XCTAssertEqual(AppKeyboardCommandRouter.route(.windows, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.newWindow, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.panes, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.attachments, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.home, in: context), .showHome)
    }

    func testTerminalReadinessTransitionsDriveCommandAvailability() {
        let workspaceID = UUID()
        let attempt = TerminalRuntimeAttemptKey(
            workspaceID: workspaceID,
            instanceID: UUID()
        )
        var readiness = TerminalKeyboardReadiness()

        func availableCommands() -> [AppKeyboardCommand] {
            AppKeyboardCommandRouter.availableCommands(
                in: AppKeyboardCommandRouteContext(
                    selectedSessionID: workspaceID,
                    isSelectedTerminalReady: readiness.isReady(for: attempt),
                    orderedActiveSessionIDs: [workspaceID]
                )
            )
        }

        XCTAssertFalse(availableCommands().contains(.newWindow))

        readiness.update(isReady: true, for: attempt)
        XCTAssertTrue(availableCommands().contains(.newWindow))

        readiness.update(isReady: false, for: attempt)
        XCTAssertFalse(availableCommands().contains(.newWindow))
    }

    func testTerminalReadinessDoesNotCarryAcrossReconnectAttempt() {
        let workspaceID = UUID()
        let oldAttempt = TerminalRuntimeAttemptKey(
            workspaceID: workspaceID,
            instanceID: UUID()
        )
        let replacementAttempt = TerminalRuntimeAttemptKey(
            workspaceID: workspaceID,
            instanceID: UUID()
        )
        var readiness = TerminalKeyboardReadiness()

        readiness.update(isReady: true, for: oldAttempt)

        XCTAssertTrue(readiness.isReady(for: oldAttempt))
        XCTAssertFalse(readiness.isReady(for: replacementAttempt))
    }

    func testTerminalSurfaceMapsNewWindowToTopologyCreation() {
        XCTAssertEqual(
            GhosttySurfaceKeyboardCommandRouter.route(.newWindow),
            .createWindow
        )
        XCTAssertEqual(
            GhosttySurfaceKeyboardCommandRouter.route(.commandPalette),
            .forward(.commandPalette)
        )
    }

    func testConfiguredChordResolverMatchesOnlyAssignedModifiedChord() throws {
        let settings = try KeyboardSettings.default.validated(
            updating: .home,
            to: KeyboardKeyBinding(input: "g", modifiers: [.control, .option])
        )
        let resolver = AppKeyboardCommandResolver(settings: settings)

        XCTAssertEqual(
            resolver.command(
                input: "G",
                modifierFlags: [.control, .alternate, .alphaShift]
            ),
            .home
        )
        XCTAssertNil(resolver.command(input: "g", modifierFlags: [.control]))
        XCTAssertNil(resolver.command(input: "h", modifierFlags: [.command]))
    }
}

final class AppKeyboardCommandResponderTests: XCTestCase {
    @MainActor
    func testHostingControllerUpdatesRenderedContent() async throws {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(AppKeyboardCommandHostContentProbe(text: "Initial")),
            commandCenter: center
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let contentController = try XCTUnwrap(controller.children.first)
        let renderedLabel = await waitForSubview(
            of: UILabel.self,
            in: contentController.view
        )
        let label = try XCTUnwrap(renderedLabel)
        XCTAssertEqual(label.text, "Initial")

        controller.updateContent(
            AnyView(AppKeyboardCommandHostContentProbe(text: "Updated"))
        )

        let didRenderUpdate = await waitUntil {
            label.text == "Updated"
        }
        XCTAssertTrue(didRenderUpdate)
    }

    @MainActor
    func testHostingControllerExposesOnlyAvailableAppCommands() throws {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        let availableCommands = AppKeyboardCommandRouter.availableCommands(
            in: AppKeyboardCommandRouteContext(
                selectedSessionID: nil,
                isSelectedTerminalReady: false,
                orderedActiveSessionIDs: []
            )
        )
        XCTAssertEqual(availableCommands, [
            .home,
            .increaseFontSize,
            .decreaseFontSize,
            .commandPalette,
        ])

        controller.update(
            settings: .default,
            availableCommands: availableCommands,
            commandCenter: center
        )

        let commands = try XCTUnwrap(controller.keyCommands)
        XCTAssertEqual(
            Set(commands.compactMap { $0.propertyList as? String }),
            Set(availableCommands.map(\.rawValue))
        )
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
    }

    @MainActor
    func testTextFieldResponderChainReachesGlobalCommandTarget() throws {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases,
            commandCenter: center
        )
        controller.loadViewIfNeeded()

        let contentController = try XCTUnwrap(controller.children.first)
        let textField = UITextField()
        contentController.view.addSubview(textField)
        let command = try XCTUnwrap(
            controller.keyCommands?.first(where: {
                $0.propertyList as? String
                    == AppKeyboardCommand.commandPalette.rawValue
            })
        )
        let action = try XCTUnwrap(command.action)

        let target = textField.target(
            forAction: action,
            withSender: command
        ) as? AppKeyboardCommandHostingController
        XCTAssertTrue(target === controller)
    }

    @MainActor
    func testShortcutCaptureSuspendsAndRestoresGlobalCommands() {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases,
            commandCenter: center
        )
        center.register(controller)

        center.setShortcutCaptureActive(true)
        XCTAssertTrue((controller.keyCommands ?? []).isEmpty)

        center.setShortcutCaptureActive(false)
        XCTAssertFalse((controller.keyCommands ?? []).isEmpty)
    }

    @MainActor
    private func firstSubview<View: UIView>(
        of type: View.Type,
        in rootView: UIView
    ) -> View? {
        if let rootView = rootView as? View {
            return rootView
        }
        for subview in rootView.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func waitForSubview<View: UIView>(
        of type: View.Type,
        in rootView: UIView,
        timeout: TimeInterval = 1
    ) async -> View? {
        var match: View?
        _ = await waitUntil(timeout: timeout) {
            rootView.layoutIfNeeded()
            match = self.firstSubview(of: type, in: rootView)
            return match != nil
        }
        return match
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

final class AppKeyboardCommandCenterTests: XCTestCase {
    @MainActor
    func testDispatchesCommandsThroughCurrentHandler() {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []

        center.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases
        ) {
            receivedCommands.append($0)
        }
        center.perform(.commandPalette)

        XCTAssertEqual(receivedCommands, [.commandPalette])
    }

    @MainActor
    func testPerformsOnlyCurrentlyAvailableCommands() {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []

        center.update(
            settings: .default,
            availableCommands: [.home]
        ) {
            receivedCommands.append($0)
        }

        XCTAssertFalse(center.performIfAvailable(.newWindow))
        XCTAssertTrue(center.performIfAvailable(.home))

        center.setShortcutCaptureActive(true)
        XCTAssertFalse(center.performIfAvailable(.home))
        XCTAssertEqual(receivedCommands, [.home])
    }
}

final class AppKeyboardCommandResponderActionTests: XCTestCase {
    @MainActor
    func testDispatchesRegisteredCommandThroughCurrentCenter() throws {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []
        center.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases
        ) {
            receivedCommands.append($0)
        }

        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases,
            commandCenter: center
        )
        let registeredCommand = try XCTUnwrap(
            controller.keyCommands?.first(where: {
                $0.propertyList as? String == AppKeyboardCommand.commandPalette.rawValue
            })
        )
        let action = try XCTUnwrap(registeredCommand.action)
        XCTAssertTrue(controller.responds(to: action))
        XCTAssertTrue(
            controller.canPerformAction(action, withSender: registeredCommand)
        )
        XCTAssertTrue(
            UIApplication.shared.sendAction(
                action,
                to: controller,
                from: registeredCommand,
                for: nil
            )
        )

        XCTAssertEqual(receivedCommands, [.commandPalette])
    }

    @MainActor
    func testHandlesConfiguredRawAppChordsAndIgnoresPlainText() {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []
        center.update(
            settings: .default,
            availableCommands: [.home]
        ) {
            receivedCommands.append($0)
        }
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(
            settings: .default,
            availableCommands: [.home],
            commandCenter: center
        )

        XCTAssertTrue(
            controller.handleKeyPress(
                input: "h",
                modifierFlags: [.command, .shift]
            )
        )
        XCTAssertFalse(
            controller.handleKeyPress(input: "h", modifierFlags: [])
        )
        XCTAssertFalse(
            controller.handleKeyPress(
                input: "n",
                modifierFlags: [.command]
            )
        )
        XCTAssertEqual(receivedCommands, [.home])
    }

    @MainActor
    func testPaletteCommandsDispatchThroughGlobalResponderWhileTextOwnsFocus() throws {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(
            settings: .default,
            availableCommands: AppKeyboardCommand.allCases,
            commandCenter: center
        )
        center.register(controller)
        controller.loadViewIfNeeded()
        let contentController = try XCTUnwrap(controller.children.first)
        let textField = UITextField()
        contentController.view.addSubview(textField)

        let owner = NSObject()
        var actions: [String] = []
        center.registerCommandPalette(
            owner: owner,
            onMoveSelection: {
                switch $0 {
                case .previous:
                    actions.append("previous")
                case .next:
                    actions.append("next")
                }
            },
            onActivateSelection: {
                actions.append("activate")
            },
            onDismiss: {
                actions.append("dismiss")
            }
        )

        let expectedInputs = [
            UIKeyCommand.inputUpArrow,
            UIKeyCommand.inputDownArrow,
            "\r",
            UIKeyCommand.inputEscape,
        ]
        let commands = try XCTUnwrap(controller.keyCommands)
        for input in expectedInputs {
            let command = try XCTUnwrap(
                commands.first {
                    $0.input == input && $0.modifierFlags.isEmpty
                }
            )
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            let action = try XCTUnwrap(command.action)
            let target = textField.target(
                forAction: action,
                withSender: command
            ) as? AppKeyboardCommandHostingController
            XCTAssertTrue(target === controller)
            XCTAssertTrue(
                UIApplication.shared.sendAction(
                    action,
                    to: controller,
                    from: command,
                    for: nil
                )
            )
        }

        XCTAssertEqual(
            actions,
            ["previous", "next", "activate", "dismiss"]
        )

        center.unregisterCommandPalette(owner: owner)
        XCTAssertFalse(
            (controller.keyCommands ?? []).contains {
                expectedInputs.contains($0.input ?? "")
                    && $0.modifierFlags.isEmpty
            }
        )
    }
}
