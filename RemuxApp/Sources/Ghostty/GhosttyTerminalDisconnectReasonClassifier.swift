import Foundation
import LocalAuthentication
import NIOCore
import NIOPosix

enum GhosttyTerminalDisconnectReasonClassifier {
    static func transportStartFailure(_ error: any Error) -> TerminalDisconnectReason {
        let message = String(describing: error)

        if let tailscaleCheckError = error as? TailscaleSSHCheckError {
            return TerminalDisconnectReason(
                kind: .authentication,
                message: tailscaleCheckError.localizedDescription
            )
        }

        if error is LAError || error is SecureEnclaveSSHError {
            return TerminalDisconnectReason(kind: .keyUnlock, message: error.localizedDescription)
        }

        if isServerUnreachable(error) {
            return TerminalDisconnectReason(kind: .serverUnreachable, message: message)
        }

        if let trustedHostError = error as? TrustedHostStoreError {
            switch trustedHostError {
            case .hostKeyTrustRequired(let challenge):
                return TerminalDisconnectReason(
                    kind: .hostKey,
                    message: message,
                    hostKeyChallenge: challenge
                )
            case .staleHostKeyTrust, .invalidHostKey:
                return TerminalDisconnectReason(kind: .hostKey, message: message)
            }
        }

        if let sshError = error as? SSHTmuxControlTransportError {
            switch sshError {
            case .remoteExit(let status, let diagnostics):
                if let message = tmuxExecutableFailureMessage(
                    status: status,
                    diagnostics: diagnostics
                ) {
                    return TerminalDisconnectReason(
                        kind: .tmuxUnavailable,
                        message: message
                    )
                }
                return TerminalDisconnectReason(kind: .remoteExit, message: message)
            case .channelRequestFailed:
                return TerminalDisconnectReason(kind: .profile, message: message)
            case .closed:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .stalePreparedConnection:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .alreadyStarted, .unsupportedInboundChannel, .controlSessionNoResponse:
                return TerminalDisconnectReason(kind: .profile, message: message)
            }
        }

        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("auth") ||
            lowercasedMessage.contains("password") ||
            lowercasedMessage.contains("permission denied") {
            return TerminalDisconnectReason(kind: .authentication, message: message)
        }

        return TerminalDisconnectReason(kind: .unknown, message: message)
    }

    private static func tmuxExecutableFailureMessage(
        status: Int,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> String? {
        TmuxExecutableProblem(
            exitStatus: status,
            output: diagnostics?.messages ?? ""
        )?.message
    }

    private static func isServerUnreachable(_ error: any Error) -> Bool {
        if error is NIOConnectionError {
            return true
        }

        if let channelError = error as? ChannelError,
           case .connectTimeout = channelError {
            return true
        }

        return false
    }

    static func foregroundMissingHost() -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
    }
}
