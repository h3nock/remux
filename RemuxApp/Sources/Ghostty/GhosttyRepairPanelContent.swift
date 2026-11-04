import Foundation

/// What the panel over a session that couldn't open, or stopped, says and offers.
struct GhosttyRepairPanelContent: Equatable {
    struct Action: Equatable {
        enum Kind: Equatable {
            case cancel
            case trustHostKey
            case updateCredentials
            case retry
            case editServer
            case reconnect
            case close
            case restart
        }

        let kind: Kind
        let title: String
        let systemImage: String
        let accessibilityIdentifier: String
        var isPrimary = false
    }

    let title: String
    let message: String
    /// The server's own words.
    let detail: String?
    /// The key the server offered, to compare before trusting it.
    let hostKey: String?
    let actions: [Action]

    /// `serverName` is the server's name in Remux.
    init(reason: TerminalDisconnectReason?, sessionName: String, serverName: String) {
        detail = reason?.detail
        hostKey = reason?.hostKeyChallenge.flatMap(Self.hostKey)

        if let challenge = reason?.hostKeyChallenge {
            let canTrust = challenge.receivedKeyFingerprint != nil
            switch challenge.kind {
            case .unknown:
                title = "Verify Server"
                message = canTrust
                    ? "First connection to \(challenge.host). Trust it only if this fingerprint matches the server."
                    : Self.unreadableKeyMessage(host: challenge.host)
            case .changed:
                title = "Host Key Changed"
                message = canTrust
                    ? "\(challenge.host) has a different key than last time. Trust it only if you expected this."
                    : Self.unreadableKeyMessage(host: challenge.host)
            }
            let trust = Action(
                kind: .trustHostKey,
                title: challenge.kind == .unknown ? "Trust Server" : "Trust New Key",
                systemImage: "checkmark.shield",
                accessibilityIdentifier: "terminal.status.hostKey.updateTrust",
                isPrimary: true
            )
            actions = [Self.cancel] + (canTrust ? [trust] : [])
            return
        }

        switch reason?.kind {
        case .authentication:
            title = "Authentication Failed"
            message = "\(serverName) rejected the saved password or key."
            actions = [Action(
                kind: .updateCredentials,
                title: "Update Credentials",
                systemImage: "key",
                accessibilityIdentifier: "terminal.status.auth.updateCredentials",
                isPrimary: true
            )]
        case .verificationExpired:
            title = "Verification Expired"
            message = "Tailscale verification wasn't completed in time."
            actions = [Self.retry("verificationExpired")]
        case .serverUnreachable:
            title = "Server Unreachable"
            message = "Check the address, port, network, or VPN."
            actions = [Self.retry("unreachable"), Self.editServer("unreachable")]
        case .backendUnavailable(let backend):
            title = "\(backend.displayName) Unavailable"
            message = reason?.message ?? ""
            actions = [Self.retry(backend.rawValue), Self.editServer(backend.rawValue)]
        case .sessionEnded:
            title = "Session Ended"
            message = "\(sessionName) is no longer running on \(serverName)."
            actions = [
                Action(
                    kind: .close,
                    title: "Close",
                    systemImage: "xmark",
                    accessibilityIdentifier: "terminal.status.sessionEnded.close",
                    isPrimary: true
                ),
                Action(
                    kind: .restart,
                    title: "Restart",
                    systemImage: "arrow.clockwise",
                    accessibilityIdentifier: "terminal.status.sessionEnded.restart"
                ),
            ]
        case .remoteExit:
            title = "Disconnected"
            message = reason?.message ?? ""
            actions = [Self.reconnect]
        case .transportIO:
            title = "Disconnected"
            message = "The connection was lost."
            actions = [Self.reconnect]
        case .hostKey:
            // Without a challenge: the key couldn't be read, or its trust changed while connecting. Reconnecting
            // asks again when there's a key to review.
            title = "Disconnected"
            message = "Remux couldn't verify this server's key."
            actions = [Self.reconnect]
        case .profile, .runtime, .userClosed, .unknown, nil:
            title = "Disconnected"
            message = "Something went wrong with this session."
            actions = [Self.reconnect]
        }
    }

    private static func hostKey(_ challenge: SSHHostKeyTrustChallenge) -> String? {
        challenge.receivedKeyFingerprint.map { "\(challenge.receivedKeyType) \($0)" }
    }

    private static func unreadableKeyMessage(host: String) -> String {
        "Remux couldn't read the key \(host) offered, so it can't be trusted."
    }

    private static let cancel = Action(
        kind: .cancel,
        title: "Cancel",
        systemImage: "xmark",
        accessibilityIdentifier: "terminal.status.hostKey.cancel"
    )

    private static let reconnect = Action(
        kind: .reconnect,
        title: "Reconnect",
        systemImage: "arrow.clockwise",
        accessibilityIdentifier: "terminal.status.reconnect",
        isPrimary: true
    )

    private static func retry(_ identifierKind: String) -> Action {
        Action(
            kind: .retry,
            title: "Retry",
            systemImage: "arrow.clockwise",
            accessibilityIdentifier: "terminal.status.\(identifierKind).retry",
            isPrimary: true
        )
    }

    private static func editServer(_ identifierKind: String) -> Action {
        Action(
            kind: .editServer,
            title: "Edit Server",
            systemImage: "slider.horizontal.3",
            accessibilityIdentifier: "terminal.status.\(identifierKind).editServer"
        )
    }
}
