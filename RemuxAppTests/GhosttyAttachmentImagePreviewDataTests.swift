import ImageIO
import UIKit
import XCTest
@testable import Remux

final class GhosttyAttachmentImagePreviewDataTests: XCTestCase {
    func testAPreviewIsShrunkToThePreviewSize() throws {
        let previewData = try XCTUnwrap(
            GhosttyAttachmentImagePreviewData.previewData(for: try makeImage(width: 1_600, height: 900))
        )

        XCTAssertEqual(try imagePixelSize(previewData), CGSize(width: 1_280, height: 720))
        XCTAssertTrue(previewData.starts(with: Data([0xFF, 0xD8])))
    }

    func testAPreviewIsNeverLargerThanThePicture() throws {
        let previewData = try XCTUnwrap(
            GhosttyAttachmentImagePreviewData.previewData(for: try makeImage(width: 400, height: 300))
        )

        XCTAssertEqual(try imagePixelSize(previewData), CGSize(width: 400, height: 300))
    }

    func testAPreviewFromAPictureFileIsShrunkToThePreviewSize() throws {
        let png = try XCTUnwrap(UIImage(cgImage: try makeImage(width: 1_600, height: 900)).pngData())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))

        let previewData = try XCTUnwrap(GhosttyAttachmentImagePreviewData.previewData(from: source))

        XCTAssertEqual(try imagePixelSize(previewData), CGSize(width: 1_280, height: 720))
    }

    func testBytesThatAreNotAPictureHaveNoPreview() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data([0x01, 0x02]) as CFData, nil))

        XCTAssertNil(GhosttyAttachmentImagePreviewData.previewData(from: source))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func imagePixelSize(_ data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? CGFloat),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? CGFloat)
        )
    }
}
