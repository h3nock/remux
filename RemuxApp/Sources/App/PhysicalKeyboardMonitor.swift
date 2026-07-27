import Foundation
import GameController

struct PhysicalKeyboardConnectionProjection {
    static func isConnected(
        environment: [String: String],
        isSystemKeyboardConnected: Bool
    ) -> Bool {
        if environment["REMUX_UI_TEST_PHYSICAL_KEYBOARD"] == "1" {
            return true
        }
        if environment["REMUX_UI_TESTING"] == "1" {
            return false
        }
        return isSystemKeyboardConnected
    }
}

@MainActor
final class PhysicalKeyboardMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(
        notificationCenter: NotificationCenter = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.notificationCenter = notificationCenter
        isConnected = PhysicalKeyboardConnectionProjection.isConnected(
            environment: environment,
            isSystemKeyboardConnected: GCKeyboard.coalesced != nil
        )

        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            notificationTokens.append(
                notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isConnected = PhysicalKeyboardConnectionProjection.isConnected(
                            environment: environment,
                            isSystemKeyboardConnected: GCKeyboard.coalesced != nil
                        )
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
