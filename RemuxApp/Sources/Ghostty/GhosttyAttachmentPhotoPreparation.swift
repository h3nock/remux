import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// How a picture from the camera, the Photos picker or a paste, or one marked up, is sent to a remote session, and the
/// making of one that is sent that way.
///
/// - A picture with more than one frame, an animated GIF, PNG or WebP, is sent exactly as it is: at any size, and with
///   any location it records, since it can't be written again without losing its frames.
/// - A still larger than `maxPixelDimension` is shrunk to it and rewritten.
/// - A still that fits is rewritten when it is in none of `keptTypes`. In one of them, it is kept when it really has
///   see-through pixels; a solid one is kept unless its rewrite is smaller. A rotation tag alone never forces a
///   rewrite.
/// - No still is sent with the location it records. A rewrite has none; a kept JPEG or PNG is copied without it, with
///   its pixels and rotation tag as they were; a still that can't be copied that way, such as a GIF or WebP, is sent
///   rewritten instead, even when that is larger.
///
/// A rewrite is upright, carries none of the source's metadata, and is a JPEG, or a PNG when it really has see-through
/// pixels, which JPEG can't hold.
enum GhosttyAttachmentPhotoPreparation {
    /// The longest side, in pixels, a picture is sent at.
    static let maxPixelDimension = 2_000
    /// The quality a picture is written at as JPEG.
    static let jpegCompressionQuality = 0.8

    /// The size, in pixels, at which a picture is sent.
    static func sentSize(for pixelSize: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return .zero
        }

        let scale = min(1, CGFloat(maxPixelDimension) / max(pixelSize.width, pixelSize.height))
        return CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded())
        )
    }

    struct PreparedPhoto: Equatable, Sendable {
        let url: URL
        let contentType: UTType
    }

    /// A picture's file contents and their format.
    struct EncodedPicture: Sendable {
        let data: Data
        let contentType: UTType
    }

    enum PreparationError: Error {
        case unreadableImage
        case encodingFailed
    }

    /// Prepares the staged photo at `url`. A photo that is not sent as it is replaces the staged file, in the same
    /// directory.
    static func preparePhoto(at url: URL) async throws -> PreparedPhoto {
        try await Task.detached(priority: .userInitiated) {
            try preparePhotoSynchronously(at: url)
        }.value
    }

    static func preparePhotoSynchronously(at url: URL) throws -> PreparedPhoto {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
                let sourceType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) else {
                throw PreparationError.unreadableImage
            }
            let index = CGImageSourceGetPrimaryImageIndex(source)
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw PreparationError.unreadableImage
            }

            if isAnimated(source, type: sourceType) {
                return PreparedPhoto(url: url, contentType: sourceType)
            }

            let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
            let sizeToSend = sentSize(for: pixelSize)
            guard let image = GhosttyAttachmentImageCoding.uprightImage(
                from: source,
                maxPixelDimension: Int(max(sizeToSend.width, sizeToSend.height))
            ) else {
                throw PreparationError.unreadableImage
            }
            let isSeeThrough = hasSeeThroughPixels(image)

            let original: KeptOriginal?
            if sizeToSend == pixelSize, keptTypes.contains(where: { sourceType.conforms(to: $0) }) {
                original = try keptOriginal(
                    at: url,
                    source: source,
                    index: index,
                    type: sourceType,
                    hasLocation: properties[kCGImagePropertyGPSDictionary] != nil
                )
            } else {
                original = nil
            }

            // Larger than the limit, in another format, or with a location that can't be taken out of it as it is.
            guard let original else {
                guard let rewrite = encodedPicture(image, as: isSeeThrough ? .png : .jpeg) else {
                    throw PreparationError.encodingFailed
                }
                return try replace(url, with: rewrite)
            }
            // The original is kept on a tie, and when its JPEG can't be made.
            if !isSeeThrough,
               let rewrite = encodedPicture(image, as: .jpeg),
               rewrite.data.count < original.byteCount {
                return try replace(url, with: rewrite)
            }
            switch original {
            case .file:
                return PreparedPhoto(url: url, contentType: sourceType)
            case .copy(let copy):
                return try replace(url, with: copy)
            }
        }
    }

    /// `image` written as a rewritten picture is: as PNG when it really has see-through pixels, as JPEG otherwise.
    static func rewrittenPicture(for image: CGImage) -> EncodedPicture? {
        encodedPicture(image, as: hasSeeThroughPixels(image) ? .png : .jpeg)
    }

    /// Whether any pixel of `image` is less than fully opaque. An image without an alpha channel has none; in one with
    /// it, which many solid pictures carry, every pixel is looked at.
    static func hasSeeThroughPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        // Unread pixels count as see-through, so a clear area never becomes a JPEG's background by mistake.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            return true
        }

        let bytes = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: bytesPerRow * height
        )
        for alphaOffset in stride(from: 3, to: bytes.count, by: 4) where bytes[alphaOffset] < UInt8.max {
            return true
        }
        return false
    }

    /// The JPEG to send for a photo just taken with the camera.
    static func jpegDataSynchronously(forCapturedPhoto photo: UIImage) throws -> Data {
        try autoreleasepool {
            let size = sentSize(
                for: CGSize(width: photo.size.width * photo.scale, height: photo.size.height * photo.scale)
            )
            guard size != .zero else {
                throw PreparationError.unreadableImage
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            // Drawing turns the picture by its recorded orientation, so the pixels come out upright.
            let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                photo.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let image = upright.cgImage,
                  let data = GhosttyAttachmentImageCoding.data(
                      for: image,
                      as: .jpeg,
                      lossyQuality: jpegCompressionQuality
                  ) else {
                throw PreparationError.encodingFailed
            }
            return data
        }
    }

    /// The original of a still that fits, as it would be sent.
    private enum KeptOriginal {
        /// The staged file itself.
        case file(byteCount: Int)
        /// A copy of it without the location it records.
        case copy(EncodedPicture)

        var byteCount: Int {
            switch self {
            case .file(let byteCount):
                return byteCount
            case .copy(let copy):
                return copy.data.count
            }
        }
    }

    /// Nil when the original records a location that can't be taken out of it as it is.
    private static func keptOriginal(
        at url: URL,
        source: CGImageSource,
        index: Int,
        type: UTType,
        hasLocation: Bool
    ) throws -> KeptOriginal? {
        guard hasLocation else {
            guard let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw PreparationError.unreadableImage
            }
            return .file(byteCount: byteCount)
        }
        return copyWithoutLocation(source, index: index, type: type).map(KeptOriginal.copy)
    }

    /// The JPEG or PNG in `source` without its location, its pixels and other metadata as they were. Nil for any other
    /// format, and when the copy still holds a location.
    private static func copyWithoutLocation(_ source: CGImageSource, index: Int, type: UTType) -> EncodedPicture? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }

        let didCopy: Bool
        if type.conforms(to: .jpeg) {
            // The metadata is written anew while the compressed pixels are copied as they are.
            guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
                  let kept = CGImageMetadataCreateMutableCopy(metadata) else {
                return nil
            }
            var locationPaths: [CFString] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
                if (CGImageMetadataTagCopyNamespace(tag) as String?) == (kCGImageMetadataNamespaceExif as String),
                   (CGImageMetadataTagCopyName(tag) as String?)?.hasPrefix("GPS") == true {
                    locationPaths.append(path)
                }
                return true
            }
            for path in locationPaths {
                CGImageMetadataRemoveTagWithPath(kept, nil, path)
            }
            didCopy = CGImageDestinationCopyImageSource(destination, source, [
                kCGImageDestinationMetadata: kept,
                kCGImageDestinationMergeMetadata: false
            ] as CFDictionary, nil)
        } else if type.conforms(to: .png) {
            // A metadata copy keeps part of a PNG's location; PNG being lossless, writing the picture again keeps
            // every pixel.
            CGImageDestinationAddImageFromSource(destination, source, index, [
                kCGImagePropertyGPSDictionary: kCFNull!
            ] as CFDictionary)
            didCopy = CGImageDestinationFinalize(destination)
        } else {
            return nil
        }

        guard didCopy,
              let copy = CGImageSourceCreateWithData(output, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  copy,
                  CGImageSourceGetPrimaryImageIndex(copy),
                  nil
              ) as? [CFString: Any],
              properties[kCGImagePropertyGPSDictionary] == nil else {
            return nil
        }
        return EncodedPicture(data: output as Data, contentType: type)
    }

    private static func encodedPicture(_ image: CGImage, as type: UTType) -> EncodedPicture? {
        GhosttyAttachmentImageCoding.data(for: image, as: type, lossyQuality: jpegCompressionQuality)
            .map { EncodedPicture(data: $0, contentType: type) }
    }

    private static func replace(_ url: URL, with picture: EncodedPicture) throws -> PreparedPhoto {
        // The staged file goes first: its new name can differ from the old one by letter case only, which is the
        // same file where the file system ignores case.
        try FileManager.default.removeItem(at: url)
        let outputURL = url.deletingPathExtension().appendingPathExtension(for: picture.contentType)
        try picture.data.write(to: outputURL, options: .atomic)
        return PreparedPhoto(url: outputURL, contentType: picture.contentType)
    }

    /// More than one frame in a format whose frames make an animation. In other formats, such as HEIC, further
    /// pictures are not frames, and the primary one is the picture.
    private static func isAnimated(_ source: CGImageSource, type: UTType) -> Bool {
        CGImageSourceGetCount(source) > 1 && [UTType.gif, .png, .webP].contains { type.conforms(to: $0) }
    }

    /// The formats a still that fits can be sent in as it is; one in any other, such as HEIC or TIFF, is rewritten.
    private static let keptTypes: [UTType] = [.jpeg, .png, .gif, .webP]
}
