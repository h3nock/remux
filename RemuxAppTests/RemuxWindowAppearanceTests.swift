import SwiftUI
import UIKit
import XCTest
@testable import Remux

@MainActor
final class RemuxWindowAppearanceTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var priorKeyWindow: UIWindow?

    override func setUp() async throws {
        priorKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    override func tearDown() async throws {
        for window in windows {
            window.rootViewController?.view.subviews.forEach { $0.removeFromSuperview() }
            window.rootViewController = nil
            window.isHidden = true
        }
        windows.removeAll()
        priorKeyWindow?.makeKeyAndVisible()
        priorKeyWindow = nil
    }

    func testDarkTerminalThenSystemAppearanceRestoresPriorLightWindowWhileViewStaysAttached() async throws {
        let scene = try activeWindowScene()
        let (window, hostView) = makeWindow(in: scene, style: .light)
        let appearanceView = RemuxWindowAppearanceUIView()
        hostView.addSubview(appearanceView)
        appearanceView.frame = hostView.bounds
        appearanceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        await settle(window)
        appearanceView.preferredColorScheme = .dark
        await settle(window)

        XCTAssertTrue(appearanceView.window === window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(appearanceView.traitCollection.userInterfaceStyle, .dark)

        appearanceView.preferredColorScheme = nil
        await settle(window)

        XCTAssertTrue(appearanceView.window === window, "Home must stay hosted in the same window while appearance is restored.")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(appearanceView.traitCollection.userInterfaceStyle, .light)
    }

    func testMovingAppearanceViewRestoresOldWindowAndStylesNewWindow() async throws {
        let scene = try activeWindowScene()
        let (firstWindow, firstHost) = makeWindow(in: scene, style: .light)
        let (secondWindow, secondHost) = makeWindow(in: scene, style: .unspecified)
        let secondWindowInitialStyle = secondWindow.traitCollection.userInterfaceStyle
        let appearanceView = RemuxWindowAppearanceUIView()
        firstHost.addSubview(appearanceView)
        appearanceView.frame = firstHost.bounds
        appearanceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        appearanceView.preferredColorScheme = .dark
        await settle(firstWindow)
        XCTAssertEqual(firstWindow.overrideUserInterfaceStyle, .dark)

        appearanceView.removeFromSuperview()
        secondHost.addSubview(appearanceView)
        appearanceView.frame = secondHost.bounds
        appearanceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        await settle(firstWindow)
        await settle(secondWindow)

        XCTAssertTrue(appearanceView.window === secondWindow)
        XCTAssertEqual(firstWindow.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(secondWindow.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(appearanceView.traitCollection.userInterfaceStyle, .dark)

        appearanceView.preferredColorScheme = nil
        await settle(secondWindow)
        XCTAssertEqual(secondWindow.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(secondWindow.traitCollection.userInterfaceStyle, secondWindowInitialStyle)
    }

    func testExternalWindowAppearanceChangeIsPreservedWhenViewDetaches() async throws {
        let scene = try activeWindowScene()
        let (window, hostView) = makeWindow(in: scene, style: .unspecified)
        let appearanceView = RemuxWindowAppearanceUIView()
        hostView.addSubview(appearanceView)
        appearanceView.frame = hostView.bounds
        appearanceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        appearanceView.preferredColorScheme = .dark
        await settle(window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)

        window.overrideUserInterfaceStyle = .light
        await settle(window)
        XCTAssertEqual(appearanceView.traitCollection.userInterfaceStyle, .light)

        appearanceView.removeFromSuperview()
        await settle(window)

        XCTAssertNil(appearanceView.window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(hostView.traitCollection.userInterfaceStyle, .light)
    }

    func testExternalWindowAppearanceSurvivesReapplicationBeforeViewDetaches() async throws {
        let scene = try activeWindowScene()
        let (window, hostView) = makeWindow(in: scene, style: .unspecified)
        let appearanceView = RemuxWindowAppearanceUIView()
        hostView.addSubview(appearanceView)
        appearanceView.frame = hostView.bounds
        appearanceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        appearanceView.preferredColorScheme = .dark
        await settle(window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)

        window.overrideUserInterfaceStyle = .light
        await settle(window)
        XCTAssertEqual(appearanceView.traitCollection.userInterfaceStyle, .light)

        // Mirrors a later SwiftUI update after another owner changed the window.
        appearanceView.preferredColorScheme = .light
        await settle(window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)

        appearanceView.removeFromSuperview()
        await settle(window)

        XCTAssertNil(appearanceView.window)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(hostView.traitCollection.userInterfaceStyle, .light)
    }

    private func activeWindowScene(file: StaticString = #filePath, line: UInt = #line) throws -> UIWindowScene {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return try XCTUnwrap(scene, "A foreground UIKit window scene should host the appearance view.", file: file, line: line)
    }

    private func makeWindow(
        in scene: UIWindowScene,
        style: UIUserInterfaceStyle
    ) -> (window: UIWindow, hostView: UIView) {
        let window = UIWindow(windowScene: scene)
        let rootViewController = UIViewController()
        rootViewController.view = UIView(frame: scene.coordinateSpace.bounds)
        rootViewController.view.backgroundColor = .systemBackground
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = style
        window.makeKeyAndVisible()
        windows.append(window)
        return (window, rootViewController.view)
    }

    private func settle(_ window: UIWindow) async {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        await Task.yield()
        window.setNeedsLayout()
        window.layoutIfNeeded()
    }
}
