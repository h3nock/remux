import SwiftUI
import UIKit

enum GhosttyAttachmentSurfaceStyle {
    static let panelGlassTint = Color.primary.opacity(0.055)
    static let panelGlassStroke = Color.primary.opacity(0.14)
    static let panelGlassShadow = Color.black.opacity(0.16)
    static let fallbackPanelFill = Color(uiColor: .secondarySystemBackground).opacity(0.72)
    static let fallbackPanelStroke = Color.primary.opacity(0.08)
    static let fallbackShadow = Color.black.opacity(0.20)
}

struct GhosttyAttachmentPreviewCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GhosttySheetPalette.primary)
            .ghosttyAttachmentPreviewCloseButtonSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhosttyAttachmentPreviewChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? RemuxAccent.fill : GhosttySheetPalette.primary)
            .ghosttyAttachmentPreviewChipSurface(
                isSelected: isSelected,
                isPressed: configuration.isPressed
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhosttyAttachmentPreviewActionButtonStyle: ButtonStyle {
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .ghosttyAttachmentPreviewActionSurface(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum GhosttyAttachmentPreviewStyle {
    static let contentFill = GhosttySheetPalette.row
    static let mediaFill = Color.black.opacity(0.84)
    static let contentStroke = GhosttySheetPalette.stroke
    static let controlFill = GhosttySheetPalette.controlFill
    static let controlPressedFill = Color(uiColor: .tertiarySystemFill)
    static let controlStroke = GhosttySheetPalette.stroke
    static let contentCornerRadius: CGFloat = 16
    static let chipTitleMaxWidth: CGFloat = 220
    static let contentPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
}

extension View {
    func ghosttyAttachmentPreviewCloseButtonSurface(isPressed: Bool) -> some View {
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

    func ghosttyAttachmentPreviewChipSurface(
        isSelected: Bool,
        isPressed: Bool
    ) -> some View {
        let shape = Capsule()
        let fill = attachmentPreviewChipFill(
            isSelected: isSelected,
            isPressed: isPressed
        )
        let stroke = isSelected ? GhosttySheetPalette.selectedStroke : GhosttyAttachmentPreviewStyle.controlStroke

        return self
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: isSelected ? 1 : 0.75)
            }
            .contentShape(shape)
    }

    private func attachmentPreviewChipFill(
        isSelected: Bool,
        isPressed: Bool
    ) -> Color {
        if isSelected {
            return RemuxAccent.selectedFill
        }

        return isPressed
            ? GhosttyAttachmentPreviewStyle.controlPressedFill
            : GhosttyAttachmentPreviewStyle.controlFill
    }

    @ViewBuilder
    func ghosttyAttachmentPreviewContentSurface(
        fill: Color = GhosttyAttachmentPreviewStyle.contentFill
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GhosttyAttachmentPreviewStyle.contentCornerRadius,
            style: .continuous
        )

        self
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.contentStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }

    func ghosttyAttachmentPreviewActionSurface(isPressed: Bool) -> some View {
        let shape = Circle()

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
