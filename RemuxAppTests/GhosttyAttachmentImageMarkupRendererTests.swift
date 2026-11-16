import ImageIO
import PencilKit
import UIKit
import XCTest
@testable import Remux

final class GhosttyAttachmentImageMarkupRendererTests: XCTestCase {
    func testOutputFilenameUsesSelectedFormatExtension() {
        XCTAssertEqual(
            GhosttyAttachmentImageMarkupRenderer.outputFilename(
                for: "../Screenshot.jpeg",
                contentType: .jpeg
            ),
            "Screenshot-annotated.jpeg"
        )
        XCTAssertEqual(
            GhosttyAttachmentImageMarkupRenderer.outputFilename(
                for: "   ",
                contentType: .png
            ),
            "image-annotated.png"
        )
    }

    func testDocumentSizeCapsLargeImagesPreservingAspectRatio() {
        let size = GhosttyAttachmentImageMarkupRenderer.documentSize(
            for: CGSize(width: 4_032, height: 3_024)
        )

        XCTAssertEqual(size.width, 1_024, accuracy: 0.001)
        XCTAssertEqual(size.height, 768, accuracy: 0.001)
    }

    func testDocumentSizeDoesNotUpscaleSmallImages() {
        let size = GhosttyAttachmentImageMarkupRenderer.documentSize(
            for: CGSize(width: 320, height: 240)
        )

        XCTAssertEqual(size.width, 320, accuracy: 0.001)
        XCTAssertEqual(size.height, 240, accuracy: 0.001)
    }

    @MainActor
    func testAnAnnotatedSolidPictureIsWrittenAsJPEG() throws {
        let baseImage = try makeImage(width: 80, height: 60)
        let drawing = makeDrawing(color: .red)

        let result = try GhosttyAttachmentImageMarkupRenderer.renderData(
            baseImage: baseImage,
            drawing: drawing,
            documentSize: CGSize(width: 80, height: 60)
        )

        XCTAssertEqual(result.picture.contentType, .jpeg)
        XCTAssertTrue(result.picture.data.starts(with: Data([0xFF, 0xD8])))
        XCTAssertNotNil(UIImage(data: result.picture.data))
        XCTAssertNotNil(GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(from: result.picture.data))
    }

    @MainActor
    func testThePictureToMarkUpIsReadUprightAtTheSizeItIsSent() throws {
        let stored = try XCTUnwrap(try makeImage(width: 4_000, height: 3_000).cgImage)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-\(UUID().uuidString).jpeg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try XCTUnwrap(GhosttyAttachmentMarkupImageSource.file(url).loadImage())

        XCTAssertEqual(image.width, 1_500)
        XCTAssertEqual(image.height, 2_000)
    }

    @MainActor
    func testASmallPictureToMarkUpIsReadAtItsOwnSize() throws {
        let png = try XCTUnwrap(try makeImage(width: 400, height: 300).pngData())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try XCTUnwrap(GhosttyAttachmentMarkupImageSource.file(url).loadImage())

        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
    }

    func testAFileThatIsNotAPictureHasNothingToMarkUp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-\(UUID().uuidString).jpeg")
        try Data([0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(GhosttyAttachmentMarkupImageSource.file(url).loadImage())
        XCTAssertNil(GhosttyAttachmentMarkupImageSource.file(url.appendingPathExtension("missing")).loadImage())
    }

    @MainActor
    func testRenderDataPreservesWhiteInk() throws {
        let baseImage = try makeImage(width: 80, height: 60, fill: .black)
        let drawing = makeHorizontalDrawing(color: .white, width: 22)

        let output = try GhosttyAttachmentImageMarkupRenderer.renderData(
            baseImage: baseImage,
            drawing: drawing,
            documentSize: CGSize(width: 80, height: 60)
        ).picture.data

        let pixel = try brightestPixel(from: output, in: CGRect(x: 20, y: 20, width: 40, height: 20))
        XCTAssertGreaterThan(pixel.red, 0.82)
        XCTAssertGreaterThan(pixel.green, 0.82)
        XCTAssertGreaterThan(pixel.blue, 0.82)
        XCTAssertGreaterThan(pixel.alpha, 0.95)
    }

    @MainActor
    func testAnAnnotatedPictureWithSeeThroughPixelsIsWrittenAsPNGAndKeepsThem() throws {
        let baseImage = try makeTransparentImage(width: 80, height: 60)
        let drawing = makeHorizontalDrawing(color: .white, width: 12)

        let result = try GhosttyAttachmentImageMarkupRenderer.renderData(
            baseImage: baseImage,
            drawing: drawing,
            documentSize: CGSize(width: 80, height: 60)
        )
        let output = result.picture.data

        XCTAssertEqual(result.picture.contentType, .png)
        XCTAssertTrue(output.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertLessThan(try renderedPixel(from: output, x: 2, y: 2).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 2, y: 57).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 77, y: 2).alpha, 0.05)
        XCTAssertLessThan(try renderedPixel(from: output, x: 77, y: 57).alpha, 0.05)
    }

    @MainActor
    func testRenderDataScalesDocumentDrawingToImageSize() throws {
        let baseImage = try makeImage(width: 100, height: 100, fill: .black)
        let drawing = makeHorizontalDrawing(
            color: .white,
            width: 8,
            y: 25,
            startX: 10,
            endX: 40
        )

        let output = try GhosttyAttachmentImageMarkupRenderer.renderData(
            baseImage: baseImage,
            drawing: drawing,
            documentSize: CGSize(width: 50, height: 50)
        ).picture.data

        let pixel = try brightestPixel(from: output, in: CGRect(x: 25, y: 45, width: 55, height: 10))
        XCTAssertGreaterThan(pixel.red, 0.82)
        XCTAssertGreaterThan(pixel.green, 0.82)
        XCTAssertGreaterThan(pixel.blue, 0.82)
        XCTAssertGreaterThan(pixel.alpha, 0.95)
    }

    @MainActor
    func testRenderDataExportsCappedImageAndScalesDrawing() throws {
        let baseImage = try makeImage(width: 4_096, height: 3_072, fill: .black)
        let drawing = makeHorizontalDrawing(
            color: .white,
            width: 8,
            y: 384,
            startX: 128,
            endX: 896
        )

        let result = try GhosttyAttachmentImageMarkupRenderer.renderData(
            baseImage: baseImage,
            drawing: drawing,
            documentSize: CGSize(width: 1_024, height: 768)
        )
        let output = result.picture.data

        // Shrinking a solid picture leaves it solid.
        XCTAssertEqual(result.picture.contentType, .jpeg)
        let image = try XCTUnwrap(UIImage(data: output))
        XCTAssertEqual(image.size.width, 2_000, accuracy: 0.001)
        XCTAssertEqual(image.size.height, 1_500, accuracy: 0.001)

        let pixel = try brightestPixel(from: output, in: CGRect(x: 250, y: 744, width: 1_500, height: 12))
        XCTAssertGreaterThan(pixel.red, 0.82)
        XCTAssertGreaterThan(pixel.green, 0.82)
        XCTAssertGreaterThan(pixel.blue, 0.82)
        XCTAssertGreaterThan(pixel.alpha, 0.95)
    }

    @MainActor
    func testRenderDataRejectsInvalidDocumentSize() throws {
        XCTAssertThrowsError(
            try GhosttyAttachmentImageMarkupRenderer.renderData(
                baseImage: try makeImage(width: 80, height: 60),
                drawing: PKDrawing(),
                documentSize: .zero
            )
        ) { error in
            XCTAssertEqual(
                error as? GhosttyAttachmentImageMarkupRenderer.RenderError,
                .invalidDocumentSize
            )
        }
    }

    @MainActor
    private func makeImage(
        width: Int,
        height: Int,
        fill: UIColor = .white
    ) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            fill.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeTransparentImage(width: Int, height: Int) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func makeDrawing(color: UIColor, width: CGFloat = 6) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 10, y: 10),
                timeOffset: 0,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 70, y: 50),
                timeOffset: 0.1,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func makeHorizontalDrawing(
        color: UIColor,
        width: CGFloat,
        y: CGFloat = 30,
        startX: CGFloat = 20,
        endX: CGFloat = 60
    ) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: startX, y: y),
                timeOffset: 0,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: endX, y: y),
                timeOffset: 0.1,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func renderedPixel(from data: Data, x: Int, y: Int) throws -> RGBA {
        let pixels = try renderedPixels(from: data)
        XCTAssertGreaterThan(pixels.width, x)
        XCTAssertGreaterThan(pixels.height, y)

        return pixels.pixel(x: x, y: y)
    }

    private func brightestPixel(from data: Data, in rect: CGRect) throws -> RGBA {
        let pixels = try renderedPixels(from: data)
        let minX = max(Int(rect.minX.rounded(.down)), 0)
        let maxX = min(Int(rect.maxX.rounded(.up)), pixels.width)
        let minY = max(Int(rect.minY.rounded(.down)), 0)
        let maxY = min(Int(rect.maxY.rounded(.up)), pixels.height)

        var brightest = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let pixel = pixels.pixel(x: x, y: y)
                if pixel.brightness > brightest.brightness {
                    brightest = pixel
                }
            }
        }
        return brightest
    }

    private func renderedPixels(from data: Data) throws -> PixelBuffer {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let width = image.width
        let height = image.height

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(x: Int, y: Int) -> RGBA {
            let offset = ((y * width) + x) * 4
            return RGBA(
                red: CGFloat(bytes[offset]) / 255,
                green: CGFloat(bytes[offset + 1]) / 255,
                blue: CGFloat(bytes[offset + 2]) / 255,
                alpha: CGFloat(bytes[offset + 3]) / 255
            )
        }
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        var brightness: CGFloat {
            max(red, green, blue)
        }
    }
}
