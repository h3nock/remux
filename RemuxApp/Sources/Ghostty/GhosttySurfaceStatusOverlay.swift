import SwiftUI

struct GhosttySurfaceStatusOverlay: View {
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle

    let projection: GhosttyTerminalStatusOverlayProjection
    let loadingTitle: String
    let sessionName: String
    /// The session's server, as Remux names it.
    let serverName: String
    let onReconnect: () -> Void
    let onCloseSession: () -> Void
    let onRestartSession: () -> Void
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
        switch projection {
        case .failed:
            return .bottom
        case .switching:
            return .center
        default:
            return .topLeading
        }
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
            noticeCapsule(commandFailureMessage, accessibilityIdentifier: "terminal.command.failure")

        case .notice(let message):
            noticeCapsule(message, accessibilityIdentifier: "terminal.notice")

        case .switching(let tab):
            switchingCapsule(tab)

        case .waitingForPanes:
            openingSessionOverlay(accessibilityIdentifier: "terminal.status.waiting")

        case .ready:
            Text("terminal ready")
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("terminal.status.ready")

        case .failed(_, let reason):
            repairPanel(GhosttyRepairPanelContent(reason: reason, sessionName: sessionName, serverName: serverName))
        }
    }

    private func noticeCapsule(_ message: String, accessibilityIdentifier: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
            .padding(10)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// The notice's capsule with a spinner, while the screen still shows the tab before.
    private func switchingCapsule(_ tab: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .tint(Color.white.opacity(0.88))
            HStack(spacing: 0) {
                Text("Switching to ")
                    .fixedSize()
                Text(tab)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.62))
        .clipShape(Capsule())
        .frame(maxWidth: 280)
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Switching to \(tab)")
        .accessibilityIdentifier("terminal.status.switching")
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

    private func repairPanel(_ content: GhosttyRepairPanelContent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GhosttySheetPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(content.message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(GhosttySheetPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("terminal.status.detail")
                }
            }

            if let hostKey = content.hostKey {
                Text(hostKey)
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

            HStack(spacing: 12) {
                ForEach(content.actions, id: \.accessibilityIdentifier) { action in
                    GhosttyRepairActionButton(
                        title: action.title,
                        systemName: action.systemImage,
                        accessibilityIdentifier: action.accessibilityIdentifier,
                        chromeStyle: chromeStyle,
                        isPrimary: action.isPrimary,
                        action: handler(for: action.kind)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .ghosttyTerminalRepairPanelSurface()
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("terminal.status.failed")
    }

    private func handler(for kind: GhosttyRepairPanelContent.Action.Kind) -> () -> Void {
        switch kind {
        case .cancel: onCancel
        case .trustHostKey: onTrustHostKey
        case .updateCredentials: onUpdateCredentials
        case .retry, .reconnect: onReconnect
        case .editServer: onEditServer
        case .close: onCloseSession
        case .restart: onRestartSession
        }
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
