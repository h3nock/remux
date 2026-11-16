import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture an attachment shows in the composer and the viewer: a JPEG at most `maxPixelDimension` on its long side.
enum GhosttyAttachmentImagePreviewData {
    static let maxPixelDimension = 1_280
    private static let compressionQuality = 0.84

    /// From pixels already decoded for sending, so the picture is not decoded a second time.
    static func previewData(for image: CGImage) -> Data? {
        GhosttyAttachmentImageCoding.data(
            for: image,
            as: .jpeg,
            lossyQuality: compressionQuality,
            maxPixelDimension: maxPixelDimension
        )
    }

    /// The preview in `data`, decoded just large enough to fill a square `side` pixels across.
    static func thumbnail(from data: Data, filling side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0 else {
            return nil
        }
        let longSide = (Double(side) * Double(max(width, height)) / Double(min(width, height))).rounded(.up)
        return GhosttyAttachmentImageCoding.uprightImage(from: source, maxPixelDimension: Int(longSide))
    }

    /// For a picture that is sent without being decoded, such as an animation: its primary frame.
    static func previewData(from source: CGImageSource) -> Data? {
        GhosttyAttachmentImageCoding
            .uprightImage(from: source, maxPixelDimension: maxPixelDimension)
            .flatMap(previewData(for:))
    }
}
