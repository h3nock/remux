import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks and encodes attachment pictures with ImageIO, which reads a picture at the size asked for instead of
/// holding its full-size bitmap.
enum GhosttyAttachmentImageCoding {
    /// The primary picture in `source`, upright and at most `maxPixelDimension` on its long side.
    static func uprightImage(from source: CGImageSource, maxPixelDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ] as CFDictionary)
    }

    /// `image` as a file of `type`. Only the pixels are written: none of a source's metadata is carried over.
    static func data(for image: CGImage, as type: UTType, lossyQuality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: lossyQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}
