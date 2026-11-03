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

        if let message = keyUnlockMessage(for: error) {
            return TerminalDisconnectReason(kind: .keyUnlock, message: message)
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

    /// Why a key the user approves on this device didn't log in, in Remux's words: iOS has already said its
    /// own. Waiting for an action, a cancelled prompt and an unrecognized face all just need unlocking again.
    static func keyUnlockMessage(for error: any Error) -> String? {
        switch error {
        case let error as SecureEnclaveSSHError:
            return error.localizedDescription
        case let error as LAError where error.code == .passcodeNotSet:
            return SecureEnclaveSSHError.passcodeNotSet.localizedDescription
        case is LAError, is SSHKeyApprovalError:
            return "Unlock it with \(SecureEnclaveSSHKey.approvalMethodName) to connect."
        default:
            return nil
        }
    }

    /// Whether unlocking the key again could log in: it wasn't offered, the prompt was cancelled or the face
    /// wasn't recognized, unlike a device without a passcode or a key that no longer works here.
    static func isKeyLocked(_ error: any Error) -> Bool {
        switch error {
        case is SSHKeyApprovalError:
            return true
        case let error as LAError:
            return error.code != .passcodeNotSet
        default:
            return false
        }
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
