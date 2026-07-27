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
