import SwiftUI
import UIKit

/// Finds the window UIKit draws the software keyboard in.
///
/// The keyboard is drawn above every window the app creates, so anything meant to sit on top of it has to be added to
/// the keyboard's own window. UIKit announces that window the first time the keyboard appears and keeps it for the
/// life of the app; it is the only window shown above the alert level.
@MainActor
final class GhosttyKeyboardWindowTracker {
    static let shared = GhosttyKeyboardWindowTracker()

    private(set) weak var window: UIWindow?
    private var observer: NSObjectProtocol?

    /// Where showing a view over the keyboard has been checked: on iPhone, iOS 26 and 27. UIKit changes the keyboard's
    /// window from one release to the next (before iOS 26 it claims every touch on a view added to it), so a newer
    /// release stays off until it has been checked. So does the iPad, where the app's window needn't fill the screen
    /// the keyboard's window covers.
    static var isSupported: Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 28.0, *) { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Call at launch: the window is announced once, when the keyboard first appears. Does nothing where drawing over
    /// the keyboard is not supported; the window then stays unknown.
    func start() {
        guard Self.isSupported, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? UIWindow, window.windowLevel > .alert else { return }
            MainActor.assumeIsolated {
                self?.window = window
            }
        }
    }
}

/// Shows one SwiftUI view over the whole screen, keyboard included.
///
/// On iOS 26 and 27 the keyboard's window takes a touch only where something in it draws, even a color too faint to
/// see; every other touch goes on to the app's own windows, out of the view's reach.
@MainActor
final class GhosttyKeyboardOverlayPresenter {
    private var controller: UIViewController?

    /// False when the keyboard's window is not known.
    var canPresent: Bool {
        GhosttyKeyboardWindowTracker.shared.window?.isHidden == false
    }

    /// Shows `content` in the keyboard's window, in place of what this presenter showed before. False, showing
    /// nothing, when that window is not known.
    func present(_ content: some View) -> Bool {
        guard let window = GhosttyKeyboardWindowTracker.shared.window, !window.isHidden else { return false }

        dismiss()
        let controller = UIHostingController(rootView: content.ignoresSafeArea())
        controller.view.backgroundColor = .clear
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        self.controller = controller
        return true
    }

    func dismiss() {
        controller?.view.removeFromSuperview()
        controller = nil
    }
}
