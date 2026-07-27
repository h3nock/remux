import SwiftUI
import UIKit
import XCTest
@testable import Remux

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
        XCTAssertEqual(AppKeyboardCommandRouter.route(.panes, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.attachments, in: context), .unavailable)
        XCTAssertEqual(AppKeyboardCommandRouter.route(.home, in: context), .showHome)
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
    func testHostingControllerExposesGlobalCommands() throws {
        let center = AppKeyboardCommandCenter()
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )

        controller.update(settings: .default, commandCenter: center)

        let commands = try XCTUnwrap(controller.keyCommands)
        XCTAssertEqual(
            Set(commands.compactMap { $0.propertyList as? String }),
            Set(
                AppKeyboardCommand.allCases
                    .filter { !$0.requiresTerminal }
                    .map(\.rawValue)
            )
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
        controller.update(settings: .default, commandCenter: center)
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
        controller.update(settings: .default, commandCenter: center)
        center.register(controller)

        center.setShortcutCaptureActive(true)
        XCTAssertTrue((controller.keyCommands ?? []).isEmpty)

        center.setShortcutCaptureActive(false)
        XCTAssertFalse((controller.keyCommands ?? []).isEmpty)
    }
}

final class AppKeyboardCommandCenterTests: XCTestCase {
    @MainActor
    func testDispatchesCommandsThroughCurrentHandler() {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []

        center.update(settings: .default) {
            receivedCommands.append($0)
        }
        center.perform(.commandPalette)

        XCTAssertEqual(receivedCommands, [.commandPalette])
    }
}

final class AppKeyboardCommandResponderActionTests: XCTestCase {
    @MainActor
    func testDispatchesRegisteredCommandThroughCurrentCenter() throws {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []
        center.update(settings: .default) {
            receivedCommands.append($0)
        }

        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(settings: .default, commandCenter: center)
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
    func testHandlesConfiguredRawGlobalChordAndIgnoresPlainText() {
        let center = AppKeyboardCommandCenter()
        var receivedCommands: [AppKeyboardCommand] = []
        center.update(settings: .default) {
            receivedCommands.append($0)
        }
        let controller = AppKeyboardCommandHostingController(
            rootView: AnyView(EmptyView()),
            commandCenter: center
        )
        controller.update(settings: .default, commandCenter: center)

        XCTAssertTrue(
            controller.handleKeyPress(
                input: "h",
                modifierFlags: [.command, .shift]
            )
        )
        XCTAssertFalse(
            controller.handleKeyPress(input: "h", modifierFlags: [])
        )
        XCTAssertEqual(receivedCommands, [.home])
    }
}
