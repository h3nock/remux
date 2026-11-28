import Citadel
import Foundation

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

        // What reaches a session as cancelled is the user's Cancel Connection on a Tailscale check: an attempt the
        // app ends itself is dropped before it is classified. So it stays closed until the user reconnects.
        if error is CancellationError {
            return TerminalDisconnectReason(kind: .userClosed, message: message)
        }

        if let tailscaleCheckError = error as? TailscaleSSHCheckError {
            return TerminalDisconnectReason(
                kind: .verificationExpired,
                message: tailscaleCheckError.localizedDescription
            )
        }

        // A saved key that can't be read, or a key made on this device that can't be used here, is replaced like
        // credentials the server turned down; a locked device only pauses a device key, so the session reconnects by
        // itself once it's unlocked.
        if let error = error as? SSHPrivateKeyUnreadableError {
            return TerminalDisconnectReason(kind: .authentication, message: error.localizedDescription)
        }
        if let error = error as? SecureEnclaveSSHError {
            let kind: TerminalDisconnectReason.Kind = switch error {
            case .keyUnusable: .authentication
            case .unavailableWhileLocked: .transportIO
            case .unavailable, .passcodeNotSet, .keyUnreadable: .unknown
            }
            return TerminalDisconnectReason(kind: kind, message: error.localizedDescription)
        }

        // The saved settings can't make a connection: the panel shows why under its own words.
        if let configurationError = error as? RemuxSSHConfigurationError {
            let reason = configurationError.localizedDescription
            return TerminalDisconnectReason(kind: .profile, message: reason, detail: reason)
        }

        if let connectError = error as? RemuxSSHConnectError {
            return TerminalDisconnectReason(kind: .serverUnreachable, message: message, detail: connectError.reason)
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
            case .stalePreparedConnection, .connectionUnresponsive:
                return TerminalDisconnectReason(kind: .transportIO, message: message)
            case .alreadyStarted, .unsupportedInboundChannel, .controlSessionNoResponse:
                return TerminalDisconnectReason(kind: .profile, message: message)
            }
        }

        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return TerminalDisconnectReason(kind: .authentication, message: message)
            case .channelCreationFailed:
                break
            }
        }

        return TerminalDisconnectReason(kind: .unknown, message: message)
    }

    static func foregroundMissingHost() -> TerminalDisconnectReason {
        TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
    }
}
