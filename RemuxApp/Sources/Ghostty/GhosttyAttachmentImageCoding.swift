import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks and encodes attachment pictures with ImageIO, which reads a picture at the size asked for instead of
/// holding its full-size bitmap.
enum GhosttyAttachmentImageCoding {
    /// The primary picture in `source`, upright and at most `maxPixelDimension` on its long side, and never larger than
    /// it is: Image I/O enlarges a picture to the size asked for.
    static func uprightImage(from source: CGImageSource, maxPixelDimension: Int) -> CGImage? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let longSide = max(
            properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide > 0 ? min(maxPixelDimension, longSide) : maxPixelDimension
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
