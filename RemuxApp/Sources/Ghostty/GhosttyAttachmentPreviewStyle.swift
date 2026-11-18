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

enum GhosttyAttachmentPreviewStyle {
    static let contentFill = GhosttySheetPalette.row
    static let contentStroke = GhosttySheetPalette.stroke
    static let controlFill = GhosttySheetPalette.controlFill
    static let controlPressedFill = Color(uiColor: .tertiarySystemFill)
    static let controlStroke = GhosttySheetPalette.stroke
    static let contentCornerRadius: CGFloat = 16
    static let contentPadding = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    /// Around a file, text or link page. A picture page has none: it runs edge to edge.
    static let pagePadding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    /// The band under the page that holds the thumbnails: 48 pt thumbnails, their selection ring, and room.
    static let thumbnailBandHeight: CGFloat = 68
}

/// A preview picture filling a square `side` points across, decoded at that size: a chip or a thumbnail shows a small
/// square, not the whole preview. Used with `.equatable()`, it is decoded again only when the preview changes, not each
/// time the view around it is drawn.
struct GhosttyAttachmentPreviewSquare: View, Equatable {
    let imageData: Data
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = Int((side * displayScale).rounded(.up))
        if let image = GhosttyAttachmentImagePreviewData.thumbnail(from: imageData, filling: pixels) {
            Image(uiImage: UIImage(cgImage: image, scale: displayScale, orientation: .up))
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(GhosttySheetPalette.secondary)
        }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.side == rhs.side && lhs.imageData == rhs.imageData
    }
}

extension View {
    @ViewBuilder
    func ghosttyAttachmentPreviewContentSurface() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: GhosttyAttachmentPreviewStyle.contentCornerRadius,
            style: .continuous
        )

        self
            .background(GhosttyAttachmentPreviewStyle.contentFill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(GhosttyAttachmentPreviewStyle.contentStroke, lineWidth: 1)
            }
            .contentShape(shape)
    }
}
