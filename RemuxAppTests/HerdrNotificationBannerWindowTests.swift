import UIKit
import XCTest
@testable import Remux

/// The banner's window takes taps, never the keyboard: the app's window stays key, so the terminal or
/// composer a banner opens onto keeps a keyboard UIKit shows.
@MainActor
final class HerdrNotificationBannerWindowTests: XCTestCase {
    private var appWindow: UIWindow?

    override func tearDown() async throws {
        appWindow?.isHidden = true
        appWindow = nil
    }

    func testTheBannersWindowNeverBecomesKey() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        appWindow = window
        let anchor = HerdrNotificationBannerAnchor()
        window.rootViewController?.view.addSubview(anchor)
        anchor.show(center: HerdrNotificationCenter(), shownWorkspaceID: nil, holdsUnsavedInput: false, onOpen: { _ in })
        defer { anchor.removeOverlay() }
        let overlay = try XCTUnwrap(
            scene.windows.first { String(describing: type(of: $0)) == "OverlayWindow" && !$0.isHidden },
            "no banner window"
        )
        XCTAssertTrue(window.isKeyWindow)

        // A tap on the banner asks its window to become key, as this does.
        overlay.makeKey()

        XCTAssertFalse(overlay.isKeyWindow, "the banner's window took the keyboard's key window")
        XCTAssertTrue(window.isKeyWindow, "the app's window lost key to the banner")
    }
}
