import Foundation
import GameController

@MainActor
final class PhysicalKeyboardMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private let notificationCenter: NotificationCenter

    init(
        notificationCenter: NotificationCenter = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.notificationCenter = notificationCenter
        isConnected = environment["REMUX_UI_TEST_PHYSICAL_KEYBOARD"] == "1"
            || GCKeyboard.coalesced != nil

        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            notificationTokens.append(
                notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isConnected =
                            environment["REMUX_UI_TEST_PHYSICAL_KEYBOARD"] == "1"
                            || GCKeyboard.coalesced != nil
                    }
                }
            )
        }
    }

    deinit {
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
    }
}
