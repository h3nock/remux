import Foundation
import LocalAuthentication
import NIOCore
import NIOPosix

enum GhosttyTerminalDisconnectReasonClassifier {
    /// A tmux control session that couldn't start. `tmuxPath` is the one set in Edit Server, nil for Automatic:
    /// what a tmux that can't run says depends on it.
    static func tmuxStartFailure(_ error: any Error, tmuxPath: String?) -> TerminalDisconnectReason {
        if case .remoteExit(let status, let diagnostics)? = error as? SSHTmuxControlTransportError,
           let failure = RemoteProgramFailure(exitStatus: status, stderr: diagnostics?.messages ?? "") {
            return BackendProblem(failure, path: tmuxPath).disconnectReason(for: .tmux)
        }
        return transportStartFailure(error)
    }

    static func transportStartFailure(_ error: any Error) -> TerminalDisconnectReason {
        let message = String(describing: error)

        if let tailscaleCheckError = error as? TailscaleSSHCheckError {
            return TerminalDisconnectReason(
                kind: .verificationExpired,
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
            case .remoteExit(_, let diagnostics):
                return TerminalDisconnectReason(
                    kind: .remoteExit,
                    message: "The server closed the connection before tmux started.",
                    detail: RemoteProgramCommand.startupMessage(in: diagnostics?.messages ?? "")
                )
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
