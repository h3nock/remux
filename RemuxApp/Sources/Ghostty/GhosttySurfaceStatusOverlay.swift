import SwiftUI

struct GhosttySurfaceStatusOverlay: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: GhosttyTerminalStatusOverlayProjection
    let loadingTitle: String
    let onReconnect: () -> Void
    let onUpdateCredentials: () -> Void
    let onEditServer: () -> Void
    let onCancel: () -> Void
    let onTrustHostKey: () -> Void

    var body: some View {
        ZStack(alignment: overlayAlignment) {
            overlayContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlayAlignment)
        .allowsHitTesting(allowsHitTesting)
    }

    private var overlayAlignment: Alignment {
        if case .failed = projection {
            return .bottom
        }

        return .topLeading
    }

    private var allowsHitTesting: Bool {
        if case .failed = projection {
            return true
        }

        return false
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch projection {
        case .starting:
            openingSessionOverlay(accessibilityIdentifier: "terminal.status.starting")

        case .commandFailure(let commandFailureMessage):
            Text(commandFailureMessage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.62))
                .clipShape(Capsule())
                .padding(10)
                .accessibilityIdentifier("terminal.command.failure")

        case .waitingForPanes:
            openingSessionOverlay(accessibilityIdentifier: "terminal.status.waiting")

        case .ready:
            Text("terminal ready")
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("terminal.status.ready")

        case .failed(let message, let reason):
            repairPanel(message: message, reason: reason)
        }
    }

    private func openingSessionOverlay(accessibilityIdentifier: String) -> some View {
        ProgressView(loadingTitle)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(GhosttySheetPalette.secondary)
            .tint(GhosttySheetPalette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.bottom, 84)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func repairPanel(
        message: String,
        reason: TerminalDisconnectReason?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption(for: reason))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(GhosttySheetPalette.tertiary)

                Text(title(for: reason))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GhosttySheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(displayMessage(for: reason, fallback: message))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if let hostKeyVerification = hostKeyVerification(for: reason?.hostKeyChallenge) {
                Text(hostKeyVerification)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhosttySheetPalette.controlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(GhosttySheetPalette.stroke, lineWidth: 1)
                }
            }

            repairActions(for: reason)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .ghosttyTerminalRepairPanelSurface()
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("terminal.status.failed")
    }

    @ViewBuilder
    private func repairActions(for reason: TerminalDisconnectReason?) -> some View {
        if let challenge = reason?.hostKeyChallenge {
            HStack(spacing: 12) {
                GhosttyRepairActionButton(
                    title: "Cancel",
                    systemName: "xmark",
                    accessibilityIdentifier: "terminal.status.hostKey.cancel",
                    chromeStyle: chromeStyle,
                    action: onCancel
                )

                if challenge.receivedKeyFingerprint != nil {
                    GhosttyRepairActionButton(
                        title: trustActionTitle(for: challenge),
                        systemName: "checkmark.shield",
                        accessibilityIdentifier: "terminal.status.hostKey.updateTrust",
                        chromeStyle: chromeStyle,
                        isPrimary: true,
                        action: onTrustHostKey
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if reason?.kind == .authentication {
            HStack {
                GhosttyRepairActionButton(
                    title: "Update Credentials",
                    systemName: "key",
                    accessibilityIdentifier: "terminal.status.auth.updateCredentials",
                    chromeStyle: chromeStyle,
                    isPrimary: true,
                    action: onUpdateCredentials
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if reason?.kind == .serverUnreachable || reason?.kind == .tmuxUnavailable {
            let identifierKind = reason?.kind == .tmuxUnavailable ? "tmux" : "unreachable"
            HStack(spacing: 12) {
                GhosttyRepairActionButton(
                    title: "Retry",
                    systemName: "arrow.clockwise",
                    accessibilityIdentifier: "terminal.status.\(identifierKind).retry",
                    chromeStyle: chromeStyle,
                    isPrimary: true,
                    action: onReconnect
                )

                GhosttyRepairActionButton(
                    title: "Edit Server",
                    systemName: "slider.horizontal.3",
                    accessibilityIdentifier: "terminal.status.\(identifierKind).editServer",
                    chromeStyle: chromeStyle,
                    action: onEditServer
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                GhosttyRepairActionButton(
                    title: "Reconnect",
                    systemName: "arrow.clockwise",
                    accessibilityIdentifier: "terminal.status.reconnect",
                    chromeStyle: chromeStyle,
                    isPrimary: true,
                    action: onReconnect
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(for reason: TerminalDisconnectReason?) -> String {
        if let challenge = reason?.hostKeyChallenge {
            switch challenge.kind {
            case .unknown:
                return "Verify Server"
            case .changed:
                return "Host Key Changed"
            }
        }

        if reason?.kind == .authentication {
            return "Authentication Failed"
        }

        if reason?.kind == .serverUnreachable {
            return "Server Unreachable"
        }

        if reason?.kind == .tmuxUnavailable {
            return "tmux Unavailable"
        }

        return "Disconnected"
    }

    private func caption(for reason: TerminalDisconnectReason?) -> String {
        if reason?.hostKeyChallenge != nil {
            return "SECURITY"
        }

        if reason?.kind == .authentication {
            return "AUTHENTICATION"
        }

        if reason?.kind == .serverUnreachable {
            return "CONNECTION"
        }

        if reason?.kind == .tmuxUnavailable {
            return "TMUX"
        }

        return "TERMINAL"
    }

    private func displayMessage(for reason: TerminalDisconnectReason?, fallback: String) -> String {
        if let challenge = reason?.hostKeyChallenge {
            switch challenge.kind {
            case .unknown:
                return "This is the first time Remux has seen the SSH host key for \(challenge.host). Trust it only if this fingerprint matches the server you expect."
            case .changed:
                return "The SSH host key for \(challenge.host) changed. Update trust only if this matches the server you expect."
            }
        }

        if reason?.kind == .authentication {
            return "The saved credentials were rejected. Update them to retry this session."
        }

        if reason?.kind == .serverUnreachable {
            return "Remux could not reach the server. Check the address, port, network, or VPN."
        }

        return fallback
    }

    private func trustActionTitle(for challenge: SSHHostKeyTrustChallenge?) -> String {
        guard let challenge else { return "Trust Server" }
        switch challenge.kind {
        case .unknown:
            return "Trust Server"
        case .changed:
            return "Update Trust"
        }
    }

    private func hostKeyVerification(for challenge: SSHHostKeyTrustChallenge?) -> String? {
        guard let challenge else {
            return nil
        }

        guard let fingerprint = challenge.receivedKeyFingerprint else {
            return "Fingerprint unavailable. Trust is unavailable."
        }

        return "Received \(challenge.receivedKeyType) \(fingerprint)"
    }
}

private struct GhosttyRepairActionButton: View {
    let title: String
    let systemName: String
    let accessibilityIdentifier: String
    let chromeStyle: GhosttyTerminalChromeStyle
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptic.chromeControlPress()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(isPrimary ? chromeStyle.accent : GhosttySheetPalette.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .buttonStyle(GhosttyRepairActionButtonStyle())
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct GhosttyRepairActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ghosttyTerminalRepairActionSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func ghosttyTerminalRepairPanelSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    .regular
                        .tint(GhosttyAttachmentSurfaceStyle.panelGlassTint),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentSurfaceStyle.panelGlassStroke, lineWidth: 0.75)
                }
                .shadow(color: GhosttyAttachmentSurfaceStyle.panelGlassShadow, radius: 18, y: 10)
                .contentShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .background {
                    shape.fill(GhosttyAttachmentSurfaceStyle.fallbackPanelFill)
                }
                .overlay {
                    shape.strokeBorder(GhosttyAttachmentSurfaceStyle.fallbackPanelStroke, lineWidth: 1)
                }
                .shadow(color: GhosttyAttachmentSurfaceStyle.fallbackShadow, radius: 18, y: 10)
        }
    }

    func ghosttyTerminalRepairActionSurface(isPressed: Bool) -> some View {
        let shape = Capsule()

        return self
            .background(
                isPressed
                    ? GhosttyAttachmentPreviewStyle.controlPressedFill
                    : GhosttyAttachmentPreviewStyle.controlFill,
                in: shape
            )
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.controlStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }
}
