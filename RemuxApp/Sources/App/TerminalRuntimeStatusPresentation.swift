import Foundation

struct TerminalRuntimeStatusPresentation: Equatable, Sendable {
    static let defaultLoadingTitle = "Opening session"

    enum Tone: Equatable, Sendable {
        case connecting
        case reconnecting
        case connected
        case disconnected
    }

    let label: String
    let tone: Tone
    let loadingTitle: String?

    static func projection(for state: TerminalRuntimeState) -> TerminalRuntimeStatusPresentation {
        switch state {
        case .connecting:
            return TerminalRuntimeStatusPresentation(
                label: "Connecting",
                tone: .connecting,
                loadingTitle: defaultLoadingTitle
            )
        case .reconnecting(let source):
            if source == .foreground {
                return TerminalRuntimeStatusPresentation(
                    label: "Restoring",
                    tone: .reconnecting,
                    loadingTitle: "Restoring session"
                )
            }
            return TerminalRuntimeStatusPresentation(
                label: "Reconnecting",
                tone: .reconnecting,
                loadingTitle: "Reconnecting"
            )
        case .connected:
            return TerminalRuntimeStatusPresentation(
                label: "Connected",
                tone: .connected,
                loadingTitle: nil
            )
        case .disconnected(let reason):
            return TerminalRuntimeStatusPresentation(
                label: disconnectedLabel(for: reason),
                tone: .disconnected,
                loadingTitle: nil
            )
        }
    }

    private static func disconnectedLabel(for reason: TerminalDisconnectReason) -> String {
        switch reason.kind {
        case .authentication:
            "Auth Failed"
        case .verificationExpired:
            "Not Verified"
        case .sessionEnded:
            "Ended"
        case .serverUnreachable:
            "Unreachable"
        case .hostKey:
            "Host Key"
        case .profile:
            "Profile Error"
        case .backendUnavailable(let backend):
            "\(backend.displayName) Error"
        case .remoteExit:
            "Exited"
        case .runtime:
            "Terminal Error"
        case .userClosed:
            "Closed"
        case .transportIO, .unknown:
            "Disconnected"
        }
    }
}
