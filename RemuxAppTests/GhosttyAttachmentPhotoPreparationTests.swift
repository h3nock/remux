import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Remux

final class GhosttyAttachmentPhotoPreparationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Larger than the limit

    func testALargeStillIsShrunkToTheLimitAsJPEGWhateverItsFormat() throws {
        let url = try write(try makeImage(width: 2_400, height: 1_800), as: .png, name: "saved.png")

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertEqual(facts.type, .jpeg)
        XCTAssertEqual(facts.width, 2_000)
        XCTAssertEqual(facts.height, 1_500)
        XCTAssertEqual(prepared.url.deletingLastPathComponent(), url.deletingLastPathComponent())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testAPhotoWhoseNewNameDiffersOnlyByLetterCaseIsStillThere() throws {
        let url = try write(try makeImage(width: 4_032, height: 3_024), as: .jpeg, name: "IMG_0001.JPEG")

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(try imageFacts(at: prepared.url).width, 2_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testALargeStillWithSeeThroughPixelsIsShrunkToTheLimitAsPNG() throws {
        let url = try write(try makeCutout(width: 2_400, height: 1_800), as: .png, name: "cutout.png")

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(prepared.contentType, .png)
        XCTAssertEqual(facts.type, .png)
        XCTAssertEqual(facts.width, 2_000)
        XCTAssertEqual(facts.height, 1_500)
        // The clear part stays clear: it doesn't become a background.
        XCTAssertEqual(try pixel(of: decodedImage(at: prepared.url), x: 1_900, y: 1_400).alpha, 0)
    }

    func testALargeStillStoredSidewaysIsSentUpright() throws {
        let url = try write(
            try makeImage(width: 2_400, height: 1_800),
            as: .jpeg,
            name: "sideways.jpg",
            properties: [kCGImagePropertyOrientation: 6]
        )

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(facts.width, 1_500)
        XCTAssertEqual(facts.height, 2_000)
        XCTAssertEqual(facts.orientation, 1)
        // The top-left of the stored picture is red; turned upright, red is at the top-right.
        let image = try decodedImage(at: prepared.url)
        XCTAssertTrue(try pixel(of: image, x: 1_400, y: 100).isMostlyRed)
        XCTAssertFalse(try pixel(of: image, x: 100, y: 100).isMostlyRed)
    }

    func testALargeAnimationIsSentAsItIs() throws {
        let url = try writeAnimation(frames: [
            try makeImage(width: 2_400, height: 100),
            try makeImage(width: 2_400, height: 100)
        ], name: "moving.gif")
        let original = try Data(contentsOf: url)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared, .init(url: url, contentType: .gif))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAnImageSequenceIsSentAsItIs() throws {
        let url = try writeAnimation(frames: [
            try makeImage(width: 2_400, height: 100),
            try makeImage(width: 2_400, height: 100)
        ], name: "moving.heics", type: .heics)
        let original = try Data(contentsOf: url)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared, .init(url: url, contentType: .heics))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // MARK: - Fits the limit

    func testAnAnimationThatFitsIsSentAsItIsEvenWhenAJPEGWouldBeSmaller() throws {
        let url = try writeAnimation(frames: try (1...3).map { frame in
            try makeNoisyImage(width: 400, height: 300, seed: UInt32(frame))
        }, name: "moving.gif")
        let original = try Data(contentsOf: url)
        XCTAssertLessThan(try jpegRewriteByteCount(of: url), original.count)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared, .init(url: url, contentType: .gif))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAStillThatFitsWithSeeThroughPixelsKeepsItsPixels() throws {
        // One pixel at half opacity is enough; the rest is solid noise, whose JPEG would be smaller.
        let url = try write(
            try makeNoisyImage(width: 400, height: 300, translucentPixel: (x: 200, y: 150)),
            as: .png,
            name: "nearly-solid.png"
        )
        let originalPixels = try storedPixels(at: url)
        XCTAssertLessThan(try jpegRewriteByteCount(of: url), try Data(contentsOf: url).count)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared, .init(url: url, contentType: .png))
        XCTAssertEqual(try storedPixels(at: prepared.url), originalPixels)
    }

    func testAStillThatFitsInAnotherFormatIsRewrittenAsJPEG() throws {
        let url = try write(try makeImage(width: 400, height: 300), as: .tiff, name: "scan.tiff")

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertEqual(facts.type, .jpeg)
        XCTAssertEqual(facts.width, 400)
        XCTAssertEqual(facts.height, 300)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAStillThatFitsIsSentAsJPEGWhenThatIsSmaller() throws {
        let url = try write(try makeNoisyImage(width: 400, height: 300), as: .png, name: "photo.png")
        let jpegByteCount = try jpegRewriteByteCount(of: url)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertEqual(try imageFacts(at: prepared.url).width, 400)
        XCTAssertEqual(try Data(contentsOf: prepared.url).count, jpegByteCount)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testAJPEGThatFitsIsRewrittenEvenWhenThatIsLarger() throws {
        let url = try write(
            try makeNoisyImage(width: 400, height: 300),
            as: .jpeg,
            name: "small.jpg",
            properties: [kCGImageDestinationLossyCompressionQuality: 0.3]
        )
        let jpegByteCount = try jpegRewriteByteCount(of: url)
        XCTAssertGreaterThan(jpegByteCount, try Data(contentsOf: url).count)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertEqual(try Data(contentsOf: prepared.url).count, jpegByteCount)
    }

    func testAStillIsComparedWithItsJPEGAsItWouldBeSent() throws {
        let url = try write(try makeCheckerboard(width: 400, height: 300), as: .png, name: "pattern.png")
        // Bytes after a PNG's end change nothing in the picture and are not sent; here they make the file larger
        // than its JPEG.
        let jpegByteCount = try jpegRewriteByteCount(of: url)
        var original = try Data(contentsOf: url)
        XCTAssertLessThan(original.count, jpegByteCount)
        original.append(Data(count: jpegByteCount - original.count + 1))
        try original.write(to: url)
        let originalPixels = try storedPixels(at: url)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared, .init(url: url, contentType: .png))
        XCTAssertLessThan(try Data(contentsOf: prepared.url).count, jpegByteCount)
        XCTAssertEqual(try storedPixels(at: prepared.url), originalPixels)
    }

    func testAPNGThatFitsTurnedByARotationTagIsSentUprightAsPNG() throws {
        let url = try write(
            try makeImage(width: 400, height: 300),
            as: .png,
            name: "sideways.png",
            properties: [kCGImagePropertyOrientation: 6]
        )
        XCTAssertLessThan(try Data(contentsOf: url).count, try jpegRewriteByteCount(of: url))

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(prepared.contentType, .png)
        XCTAssertEqual(facts.width, 300)
        XCTAssertEqual(facts.height, 400)
        XCTAssertEqual(facts.orientation, 1)
        // The top-left of the stored picture is red; turned upright, red is at the top-right.
        let image = try decodedImage(at: prepared.url)
        XCTAssertTrue(try pixel(of: image, x: 280, y: 20).isMostlyRed)
        XCTAssertFalse(try pixel(of: image, x: 20, y: 20).isMostlyRed)
    }

    // MARK: - Metadata

    func testAJPEGThatFitsGoesWithNothingButItsPicture() throws {
        let url = try write(
            try makeNoisyImage(width: 400, height: 300),
            as: .jpeg,
            name: "described.jpg",
            properties: Self.everythingAPhotoRecords.merging([kCGImagePropertyOrientation: 6]) { _, new in new }
        )
        var original = try Data(contentsOf: url)
        // Where a motion photo keeps its video, after the end of the picture.
        original.append(Data(Self.dataAfterThePicture.utf8))
        try original.write(to: url)
        XCTAssertTrue(try imageFacts(at: url).hasLocation)
        for text in Self.recordedText {
            XCTAssertNotNil(original.range(of: Data(text.utf8)), text)
        }

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let sent = try Data(contentsOf: prepared.url)
        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertFalse(facts.hasLocation)
        for text in Self.recordedText + [Self.dataAfterThePicture] {
            XCTAssertNil(sent.range(of: Data(text.utf8)), text)
        }
        XCTAssertEqual(sent.suffix(2), Data([0xFF, 0xD9]))
        // Upright instead of tagged.
        XCTAssertEqual(facts.width, 300)
        XCTAssertEqual(facts.height, 400)
        XCTAssertEqual(facts.orientation, 1)
    }

    func testAPNGThatFitsKeepsItsImageDataAndNothingThatDescribesIt() throws {
        let url = try write(
            try makeCheckerboard(width: 400, height: 300),
            as: .png,
            name: "described.png",
            properties: Self.everythingAPhotoRecords
        )
        let original = try Data(contentsOf: url)
        XCTAssertTrue(try imageFacts(at: url).hasLocation)
        XCTAssertTrue(Self.recordedText.contains { original.range(of: Data($0.utf8)) != nil })
        XCTAssertLessThan(original.count, try jpegRewriteByteCount(of: url))

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let sent = try Data(contentsOf: prepared.url)
        XCTAssertEqual(prepared, .init(url: url, contentType: .png))
        XCTAssertFalse(try imageFacts(at: prepared.url).hasLocation)
        for text in Self.recordedText {
            XCTAssertNil(sent.range(of: Data(text.utf8)), text)
        }
        // Every chunk that draws the picture goes as it was, and nothing else goes.
        let drawing: Set = [
            "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "bKGD", "cHRM", "gAMA", "iCCP", "sRGB", "sBIT", "cICP", "mDCv",
            "cLLi", "pHYs", "sPLT"
        ]
        XCTAssertEqual(try Self.pngChunks(sent), try Self.pngChunks(original).filter { drawing.contains($0.type) })
        XCTAssertTrue(try Self.pngChunks(sent).contains { $0.type == "IDAT" })
    }

    func testOnlyAWholePNGHasItsMetadataTakenOut() throws {
        let url = try write(try makeCheckerboard(width: 40, height: 30), as: .png, name: "whole.png")
        let whole = try Data(contentsOf: url)

        XCTAssertNotNil(GhosttyAttachmentPhotoPreparation.pngWithoutMetadata(whole))
        // Without its end chunk.
        XCTAssertNil(GhosttyAttachmentPhotoPreparation.pngWithoutMetadata(whole.dropLast(12)))
        XCTAssertNil(GhosttyAttachmentPhotoPreparation.pngWithoutMetadata(Data("not a picture".utf8)))
    }

    func testARewrittenPictureIsSentWithoutItsLocation() throws {
        let url = try write(
            try makeImage(width: 2_400, height: 1_800),
            as: .jpeg,
            name: "located.jpg",
            properties: [kCGImagePropertyGPSDictionary: Self.location]
        )
        XCTAssertTrue(try imageFacts(at: url).hasLocation)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        let facts = try imageFacts(at: prepared.url)
        XCTAssertEqual(facts.width, 2_000)
        XCTAssertFalse(facts.hasLocation)
    }

    // MARK: - See-through pixels

    func testASolidPictureWithAnAlphaChannelIsTreatedAsSolid() throws {
        let url = try write(
            try makeNoisyImage(width: 400, height: 300, hasAlphaChannel: true),
            as: .png,
            name: "solid-with-alpha.png"
        )
        XCTAssertTrue(try imageFacts(at: url).hasAlphaChannel)
        XCTAssertLessThan(try jpegRewriteByteCount(of: url), try Data(contentsOf: url).count)

        let prepared = try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url)

        XCTAssertEqual(prepared.contentType, .jpeg)
        XCTAssertEqual(try imageFacts(at: prepared.url).type, .jpeg)
    }

    // MARK: - Other

    func testAFileThatIsNotAPictureIsRefused() throws {
        let url = directory.appendingPathComponent("notes.jpg")
        try Data("not a picture".utf8).write(to: url)

        XCTAssertThrowsError(try GhosttyAttachmentPhotoPreparation.preparePhotoSynchronously(at: url))
    }

    func testAPictureIsSentNoLargerThanTheLimit() {
        XCTAssertEqual(
            GhosttyAttachmentPhotoPreparation.sentSize(for: CGSize(width: 4_032, height: 3_024)),
            CGSize(width: 2_000, height: 1_500)
        )
        XCTAssertEqual(
            GhosttyAttachmentPhotoPreparation.sentSize(for: CGSize(width: 320, height: 240)),
            CGSize(width: 320, height: 240)
        )
    }

    func testACameraPhotoHeldUprightIsSentUprightAtTheLimit() throws {
        // The camera stores a photo taken upright as a landscape picture marked "turn right".
        let stored = try makeImage(width: 4_032, height: 3_024)
        let photo = UIImage(cgImage: stored, scale: 1, orientation: .right)

        let data = try GhosttyAttachmentPhotoPreparation.jpegDataSynchronously(forCapturedPhoto: photo)

        let url = directory.appendingPathComponent("captured.jpeg")
        try data.write(to: url)
        let facts = try imageFacts(at: url)
        XCTAssertEqual(facts.type, .jpeg)
        XCTAssertEqual(facts.width, 1_500)
        XCTAssertEqual(facts.height, 2_000)
        XCTAssertEqual(facts.orientation, 1)
        let image = try decodedImage(at: url)
        XCTAssertTrue(try pixel(of: image, x: 1_400, y: 100).isMostlyRed)
        XCTAssertFalse(try pixel(of: image, x: 100, y: 100).isMostlyRed)
    }

    // MARK: - Helpers

    /// Where, when and with what a picture was taken, as a camera or a photo editor might record it.
    private static var everythingAPhotoRecords: [CFString: Any] {
        [
            kCGImagePropertyGPSDictionary: location,
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Addis Ababa",
                kCGImagePropertyIPTCCountryPrimaryLocationName: "Ethiopia"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "taken at home",
                kCGImagePropertyExifDateTimeOriginal: "2026:11:15 09:41:00",
                kCGImagePropertyExifBodySerialNumber: "SERIAL-0042"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Remux Test Maker",
                kCGImagePropertyTIFFModel: "Remux Test Camera"
            ]
        ]
    }

    /// The text `everythingAPhotoRecords` writes, looked for in a file's bytes.
    private static let recordedText = [
        "Addis Ababa", "Ethiopia", "taken at home", "2026:11:15 09:41:00", "SERIAL-0042", "Remux Test Maker",
        "Remux Test Camera"
    ]

    private static let dataAfterThePicture = "bytes after the end of the picture"

    private struct PNGChunk: Equatable {
        let type: String
        let data: Data
    }

    /// The chunks of the PNG `data`, read from its bytes.
    private static func pngChunks(_ data: Data) throws -> [PNGChunk] {
        var chunks: [PNGChunk] = []
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = try XCTUnwrap(String(data: data[offset + 4..<offset + 8], encoding: .ascii))
            chunks.append(PNGChunk(type: type, data: data[offset + 8..<offset + 8 + length]))
            offset += 12 + length
        }
        return chunks
    }

    private static var location: [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: 9.03,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 38.74,
            kCGImagePropertyGPSLongitudeRef: "E"
        ]
    }

    private struct ImageFacts {
        let type: UTType?
        let width: Int
        let height: Int
        let orientation: Int
        let hasLocation: Bool
        /// A place name or a comment, written apart from the GPS position.
        let hasPlaceOrComment: Bool
        let hasAlphaChannel: Bool
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var isMostlyRed: Bool {
            red > 180 && blue < 90
        }
    }

    /// Blue, with a red square a fifth of the picture's shorter side in its top-left corner.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            let side = CGFloat(min(width, height)) / 5
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// A red square in the top-left corner; everything else is clear.
    private func makeCutout(width: Int, height: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            let side = CGFloat(min(width, height)) / 5
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// Black and white pixels in turn: a fine pattern, like crisp text, which PNG holds in far fewer bytes than JPEG.
    private func makeCheckerboard(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: UInt8.max, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where (x + y) % 2 == 1 {
                let offset = (y * width + x) * 4
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes, alphaInfo: .noneSkipLast)
    }

    /// Solid pixels of colours that look random, the same ones for the same `seed`: a picture that compresses as
    /// badly as a detailed photo. `translucentPixel` is made half see-through.
    private func makeNoisyImage(
        width: Int,
        height: Int,
        seed: UInt32 = 1,
        hasAlphaChannel: Bool = false,
        translucentPixel: (x: Int, y: Int)? = nil
    ) throws -> CGImage {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 16)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 8)
            bytes[offset + 3] = UInt8.max
        }
        if let translucentPixel {
            // Premultiplied: the colour is scaled by the opacity.
            let offset = (translucentPixel.y * width + translucentPixel.x) * 4
            for channel in 0..<3 {
                bytes[offset + channel] /= 2
            }
            bytes[offset + 3] = 128
        }

        return try makeImage(
            width: width,
            height: height,
            bytes: bytes,
            alphaInfo: hasAlphaChannel || translucentPixel != nil ? .premultipliedLast : .noneSkipLast
        )
    }

    /// `bytes` holds 8-bit RGBA rows, the top one first.
    private func makeImage(width: Int, height: Int, bytes: [UInt8], alphaInfo: CGImageAlphaInfo) throws -> CGImage {
        try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)),
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func write(
        _ image: CGImage,
        as type: UTType,
        name: String,
        properties: [CFString: Any] = [:]
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writeAnimation(frames: [CGImage], name: String, type: UTType = .gif) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil)
        )
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))), frames.count)
        return url
    }

    /// The size of the JPEG the picture at `url` is compared with: its rewrite, upright at its own size.
    private func jpegRewriteByteCount(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let facts = try imageFacts(at: url)
        let image = try XCTUnwrap(GhosttyAttachmentImageCoding.uprightImage(
            from: source,
            maxPixelDimension: max(facts.width, facts.height)
        ))
        return try XCTUnwrap(GhosttyAttachmentImageCoding.data(
            for: image,
            as: .jpeg,
            lossyQuality: GhosttyAttachmentPhotoPreparation.jpegCompressionQuality
        )).count
    }

    private func imageFacts(at url: URL) throws -> ImageFacts {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return ImageFacts(
            type: (CGImageSourceGetType(source) as String?).flatMap(UTType.init),
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int),
            orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
            hasLocation: properties[kCGImagePropertyGPSDictionary] != nil,
            hasPlaceOrComment: properties[kCGImagePropertyIPTCDictionary] != nil
                || (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] != nil,
            hasAlphaChannel: properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        )
    }

    /// The picture as stored, without turning it by its rotation tag.
    private func decodedImage(at url: URL) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)),
            0,
            nil
        ))
    }

    /// Every pixel of the picture as stored, as 8-bit RGBA.
    private func storedPixels(at url: URL) throws -> [UInt8] {
        let image = try decodedImage(at: url)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// `y` counts from the top.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Core Graphics counts rows from the bottom.
        context.draw(
            image,
            in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
        )
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}
