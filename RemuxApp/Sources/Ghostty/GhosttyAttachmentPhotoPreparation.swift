import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// How a picture from the camera, the Photos picker, Files or a paste, or one marked up, is sent to a remote session,
/// and the making of one that is sent that way.
///
/// - A picture with more than one frame, an animated GIF, PNG or WebP or a HEICS sequence, is sent exactly as it is, at
///   any size and with any metadata it carries: Image I/O can't take metadata out of one without writing every frame
///   again, and can't write WebP at all.
/// - A PNG that fits stays a PNG unless it is solid and its JPEG is smaller. Upright, it keeps its image data as it is,
///   with only the chunks that draw it; turned by a rotation tag, it is written again upright.
/// - Every other still is rewritten, shrunk to `maxPixelDimension` when it is larger.
///
/// A rewrite is drawn from the upright pixels, so it carries none of the source's metadata, and is a JPEG, or a PNG when
/// it really has see-through pixels, which JPEG can't hold. No still goes with anything of where, when or with what it
/// was taken.
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
        /// Made from the pixels the preparation decoded (`GhosttyAttachmentImagePreviewData`).
        let previewData: Data
    }

    /// A photo just taken, as it is sent, with its preview.
    struct CapturedPhoto: Sendable {
        let jpegData: Data
        let previewData: Data
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
            ] as CFDictionary) else {
                throw PreparationError.unreadableImage
            }
            let preparation = try prepare(source) { try? Data(contentsOf: url) }
            switch preparation.sent {
            case .asItIs(let contentType):
                return PreparedPhoto(
                    url: try named(url, for: contentType),
                    contentType: contentType,
                    previewData: preparation.previewData
                )
            case .rewritten(let picture):
                return try replace(url, with: picture, previewData: preparation.previewData)
            }
        }
    }

    /// Prepares a pasted picture from its bytes, and stages only what is sent.
    static func preparePastedPicture(_ data: Data, title: String) async throws -> PreparedPhoto {
        try await Task.detached(priority: .userInitiated) {
            try preparePastedPictureSynchronously(data, title: title)
        }.value
    }

    static func preparePastedPictureSynchronously(_ data: Data, title: String) throws -> PreparedPhoto {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                throw PreparationError.unreadableImage
            }
            return try stage(try prepare(source) { data }, original: .data(data)) { contentType in
                GhosttyAttachmentStagingStore.imageFilename(title: title, contentTypes: [contentType])
            }
        }
    }

    /// Prepares a picture picked in Files, read while the app may open it, and stages only what is sent. The file
    /// itself is left as it is.
    static func preparePictureFile(_ file: GhosttySecurityScopedAttachmentFile) async throws -> PreparedPhoto {
        try await Task.detached(priority: .userInitiated) {
            try file.withAccessibleURL { url in
                try preparePictureFileSynchronously(at: url, filename: file.filename)
            }
        }.value
    }

    /// What is sent keeps the file's name, so it can be referred to by it. Only the extension changes, when the
    /// picture is sent in another format than the one its name gives.
    static func preparePictureFileSynchronously(at url: URL, filename: String) throws -> PreparedPhoto {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                throw PreparationError.unreadableImage
            }
            return try stage(
                try prepare(source) { try? Data(contentsOf: url) },
                original: .file(url)
            ) { contentType in
                sentFilename(for: filename, as: contentType)
            }
        }
    }

    /// `filename` as it is when its extension names `type`, otherwise with the extension `type` prefers.
    static func sentFilename(for filename: String, as type: UTType) -> String {
        let name = filename as NSString
        if UTType(filenameExtension: name.pathExtension)?.conforms(to: type) == true {
            return filename
        }
        let stem = name.deletingPathExtension.isEmpty ? "image" : name.deletingPathExtension
        return type.preferredFilenameExtension.map { "\(stem).\($0)" } ?? stem
    }

    /// Whether the file at `url` holds a picture Image I/O can read, judged by its contents, not its name.
    static func isPicture(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
            let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) else {
            return false
        }
        return type.conforms(to: .image) && CGImageSourceGetCount(source) > 0
    }

    /// Where a picture prepared from somewhere the app doesn't own comes from.
    private enum Original {
        case data(Data)
        /// Copied as it is, never read whole, when it is sent as it is: an animation can be large.
        case file(URL)
    }

    /// Stages what `preparation` sends, the picture as it is or its rewrite, under the name `filename` gives its
    /// format.
    private static func stage(
        _ preparation: Preparation,
        original: Original,
        filename: (UTType) -> String
    ) throws -> PreparedPhoto {
        let url: URL
        let contentType: UTType
        switch (preparation.sent, original) {
        case (.asItIs(let type), .data(let data)):
            url = try GhosttyAttachmentStagingStore.stageDataSynchronously(data, filename: filename(type))
            contentType = type
        case (.asItIs(let type), .file(let fileURL)):
            url = try GhosttyAttachmentStagingStore.stageFileURLSynchronously(fileURL, filename: filename(type))
            contentType = type
        case (.rewritten(let picture), _):
            url = try GhosttyAttachmentStagingStore.stageDataSynchronously(picture.data, filename: filename(picture.contentType))
            contentType = picture.contentType
        }
        return PreparedPhoto(url: url, contentType: contentType, previewData: preparation.previewData)
    }

    /// The staged file at `url`, renamed when its name doesn't give `type`'s extension, as a picture from the Photos
    /// picker can arrive without one or with another.
    private static func named(_ url: URL, for type: UTType) throws -> URL {
        let filename = sentFilename(for: url.lastPathComponent, as: type)
        guard filename != url.lastPathComponent else { return url }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(filename)
        try FileManager.default.moveItem(at: url, to: renamed)
        return renamed
    }

    /// What is sent for a picture, and its preview.
    private struct Preparation {
        enum Sent {
            case asItIs(UTType)
            case rewritten(EncodedPicture)
        }

        let sent: Sent
        let previewData: Data
    }

    /// How the picture in `source` is sent. `original` gives its file's bytes, read only for a PNG that may keep them.
    private static func prepare(_ source: CGImageSource, original: () -> Data?) throws -> Preparation {
        guard let sourceType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) else {
            throw PreparationError.unreadableImage
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PreparationError.unreadableImage
        }

        if isAnimated(source, type: sourceType) {
            guard let previewData = GhosttyAttachmentImagePreviewData.previewData(from: source) else {
                throw PreparationError.unreadableImage
            }
            return Preparation(sent: .asItIs(sourceType), previewData: previewData)
        }

        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        let sizeToSend = sentSize(for: pixelSize)
        guard let image = GhosttyAttachmentImageCoding.uprightImage(
            from: source,
            maxPixelDimension: Int(max(sizeToSend.width, sizeToSend.height))
        ) else {
            throw PreparationError.unreadableImage
        }
        guard let previewData = GhosttyAttachmentImagePreviewData.previewData(for: image) else {
            throw PreparationError.encodingFailed
        }
        let isSeeThrough = hasSeeThroughPixels(image)

        guard sizeToSend == pixelSize, sourceType.conforms(to: .png) else {
            guard let rewrite = encodedPicture(image, as: isSeeThrough ? .png : .jpeg) else {
                throw PreparationError.encodingFailed
            }
            return Preparation(sent: .rewritten(rewrite), previewData: previewData)
        }

        // Without its rotation tag an upright PNG draws the same; a turned one has to be written again upright.
        let isUpright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        let kept = isUpright ? original().flatMap(pngWithoutMetadata) : nil
        guard let png = kept.map({ EncodedPicture(data: $0, contentType: .png) })
            ?? encodedPicture(image, as: .png) else {
            throw PreparationError.encodingFailed
        }
        // The PNG is kept on a tie, and when its JPEG can't be made.
        if !isSeeThrough, let jpeg = encodedPicture(image, as: .jpeg), jpeg.data.count < png.data.count {
            return Preparation(sent: .rewritten(jpeg), previewData: previewData)
        }
        return Preparation(sent: .rewritten(png), previewData: previewData)
    }

    /// The PNG in `data` with only the chunks that draw it, each as it was; nil when `data` is not a whole PNG.
    static func pngWithoutMetadata(_ data: Data) -> Data? {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.starts(with: signature) else { return nil }

        var kept = signature
        var offset = data.startIndex + signature.count
        // A chunk is its data's length in 4 bytes, its type in 4, its data, and a 4-byte checksum.
        while data.endIndex - offset >= 12 {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard data.endIndex - offset - 12 >= length else { return nil }
            let end = offset + 12 + length
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            if pngDrawingChunks.contains(type) {
                kept.append(data[offset..<end])
            }
            if type == "IEND" {
                return kept
            }
            offset = end
        }
        return nil
    }

    /// The chunks that draw a PNG: its header, palette, image data and end, its transparency, colour and pixel
    /// density, and the frames of an animation. The rest, text, EXIF, XMP and time among them, describes it.
    private static let pngDrawingChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND",
        "tRNS", "bKGD", "cHRM", "gAMA", "iCCP", "sRGB", "sBIT", "cICP", "mDCv", "cLLi", "pHYs", "sPLT",
        "acTL", "fcTL", "fdAT"
    ]

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

    /// The JPEG to send for a photo just taken with the camera, and its preview.
    static func preparedCapturedPhotoSynchronously(_ photo: UIImage) throws -> CapturedPhoto {
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
                  ),
                  let previewData = GhosttyAttachmentImagePreviewData.previewData(for: image) else {
                throw PreparationError.encodingFailed
            }
            return CapturedPhoto(jpegData: data, previewData: previewData)
        }
    }

    private static func encodedPicture(_ image: CGImage, as type: UTType) -> EncodedPicture? {
        GhosttyAttachmentImageCoding.data(for: image, as: type, lossyQuality: jpegCompressionQuality)
            .map { EncodedPicture(data: $0, contentType: type) }
    }

    private static func replace(
        _ url: URL,
        with picture: EncodedPicture,
        previewData: Data
    ) throws -> PreparedPhoto {
        // The staged file goes first: its new name can differ from the old one by letter case only, which is the
        // same file where the file system ignores case.
        try FileManager.default.removeItem(at: url)
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent(sentFilename(for: url.lastPathComponent, as: picture.contentType))
        try picture.data.write(to: outputURL, options: .atomic)
        return PreparedPhoto(url: outputURL, contentType: picture.contentType, previewData: previewData)
    }

    /// The formats whose frames make an animation, an image sequence (HEICS) among them. In other formats, such as
    /// HEIC, further pictures are not frames, and the primary one is the picture.
    static let animationTypes: [UTType] = [.gif, .png, .webP, .heics]

    /// More than one frame in a format whose frames make an animation.
    static func isAnimated(_ source: CGImageSource, type: UTType) -> Bool {
        CGImageSourceGetCount(source) > 1 && animationTypes.contains { type.conforms(to: $0) }
    }
}
