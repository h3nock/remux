import ImageIO
import UIKit
import XCTest
@testable import Remux

final class GhosttyAttachmentImagePreviewDataTests: XCTestCase {
    func testPreviewDataDownsamplesLargeImage() throws {
        let sourceData = try makeJPEGData(width: 1_600, height: 900)

        let previewData = try XCTUnwrap(
            GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(from: sourceData)
        )
        let size = try XCTUnwrap(imagePixelSize(previewData))

        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(GhosttyAttachmentImagePreviewData.maxPixelDimension))
    }

    func testPreviewDataDownsamplesImageFile() throws {
        let sourceData = try makeJPEGData(width: 1_600, height: 900)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try sourceData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let previewData = try XCTUnwrap(
            GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(fromFileAt: sourceURL)
        )
        let size = try XCTUnwrap(imagePixelSize(previewData))

        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(GhosttyAttachmentImagePreviewData.maxPixelDimension))
    }

    func testAPreviewIsNeverLargerThanThePicture() throws {
        let sourceData = try makeJPEGData(width: 400, height: 300)
        let sourceSize = try XCTUnwrap(imagePixelSize(sourceData))
        XCTAssertLessThan(max(sourceSize.width, sourceSize.height), CGFloat(GhosttyAttachmentImagePreviewData.maxPixelDimension))

        let previewData = try XCTUnwrap(GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(from: sourceData))

        XCTAssertEqual(imagePixelSize(previewData), sourceSize)
    }

    func testInvalidImageDataReturnsNil() {
        XCTAssertNil(GhosttyAttachmentImagePreviewData.makePreviewDataSynchronously(from: Data([0x01, 0x02])))
    }

    private func makeJPEGData(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func imagePixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}
