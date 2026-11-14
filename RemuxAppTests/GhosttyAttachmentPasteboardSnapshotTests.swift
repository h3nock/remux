import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Remux

final class GhosttyAttachmentPasteboardSnapshotTests: XCTestCase {
    func testImageDataWinsOverOtherPasteboardContent() {
        let imageData = Data([0x01, 0x02, 0x03])
        let url = URL(string: "https://example.com/image.png")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: true,
            hasURLs: true,
            hasStrings: true,
            imageData: imageData,
            url: url,
            string: "hello"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardImage)
        XCTAssertNil(snapshot.pendingAttachments.first?.payload)
        XCTAssertEqual(snapshot.pendingAttachments.first?.previewPayload, .imageData(imageData))
    }

    @MainActor
    func testCurrentImagePreviewDataLoadsImageThroughItemProvider() async throws {
        let pasteboard = UIPasteboard.withUniqueName()
        let imageData = try makeJPEGData(width: 1_600, height: 900)
        pasteboard.setData(imageData, forPasteboardType: UTType.jpeg.identifier)

        let loadedPreviewData = await GhosttyAttachmentPasteboardSnapshot.currentImagePreviewData(pasteboard)
        let previewData = try XCTUnwrap(loadedPreviewData)
        let size = try XCTUnwrap(imagePixelSize(previewData))

        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(GhosttyAttachmentImagePreviewData.maxPixelDimension))
    }

    @MainActor
    func testCurrentImageAttachmentStagesUploadFileAndPreviewData() async throws {
        let pasteboard = UIPasteboard.withUniqueName()
        let imageData = try makeJPEGData(width: 1_600, height: 900)
        pasteboard.setData(imageData, forPasteboardType: UTType.jpeg.identifier)

        let loadedAttachment = await GhosttyAttachmentPasteboardSnapshot.currentImageAttachment(pasteboard)
        let attachment = try XCTUnwrap(loadedAttachment)
        XCTAssertEqual(attachment.kind, .pasteboardImage)

        guard case .file(let stagedURL) = attachment.payload else {
            return XCTFail("Expected file-backed image payload")
        }
        defer {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }

        guard case .imageData(let previewData) = attachment.previewPayload else {
            return XCTFail("Expected image preview payload")
        }

        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertGreaterThan(try Data(contentsOf: stagedURL).count, 0)
        XCTAssertNotNil(attachment.transferSource)

        let size = try XCTUnwrap(imagePixelSize(previewData))
        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(GhosttyAttachmentImagePreviewData.maxPixelDimension))
    }

    @MainActor
    func testAPastedPhotoIsSentTheWayAPickedPhotoIs() async throws {
        let pasteboard = UIPasteboard.withUniqueName()
        // Points; the renderer multiplies by the screen's scale, so this is larger than the limit on every simulator.
        pasteboard.setData(try makeJPEGData(width: 1_200, height: 900), forPasteboardType: UTType.jpeg.identifier)

        let loadedAttachment = await GhosttyAttachmentPasteboardSnapshot.currentImageAttachment(pasteboard)
        guard case .file(let stagedURL) = try XCTUnwrap(loadedAttachment).payload else {
            return XCTFail("Expected file-backed image payload")
        }
        defer {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }

        let size = try XCTUnwrap(imagePixelSize(try Data(contentsOf: stagedURL)))
        XCTAssertEqual(size, CGSize(width: 2_000, height: 1_500))
    }

    func testURLWinsOverStringWhenBothAreReadable() {
        let url = URL(string: "https://example.com/image.png")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: true,
            hasStrings: true,
            url: url,
            string: "hello"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardLink)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .link(url))
    }

    func testPasteboardURLRejectsNonHTTPURL() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: true,
            hasStrings: false,
            url: URL(fileURLWithPath: "/tmp/remux/test.txt")
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
    }

    func testHTTPTextStagesLinkAttachment() {
        let url = URL(string: "https://example.com/path?q=remux")!
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: "https://example.com/path?q=remux"
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardLink)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .link(url))
    }

    func testTextURLRejectsCustomScheme() {
        let text = "remux://attach?id=1"
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: text
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardText)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .text(text))
    }

    func testPlainTextStagesTextAttachment() {
        let text = "hello terminal  \nsecond line"
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: text
        )

        XCTAssertEqual(snapshot.pendingAttachments.count, 1)
        XCTAssertEqual(snapshot.pendingAttachments.first?.kind, .pasteboardText)
        XCTAssertEqual(snapshot.pendingAttachments.first?.payload, .text(text))
    }

    func testUnreadableStringReportsUnreadablePaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
    }

    func testWhitespaceStringReportsEmptyPaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: true,
            string: " \n\t "
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard text is empty.")
    }

    func testUnreadableImageReportsUnreadablePaste() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: true,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard content could not be read.")
    }

    func testEmptyPasteboardReportsNothingToAttach() {
        let snapshot = GhosttyAttachmentPasteboardSnapshot(
            hasImages: false,
            hasURLs: false,
            hasStrings: false
        )

        XCTAssertTrue(snapshot.pendingAttachments.isEmpty)
        XCTAssertEqual(snapshot.emptyPasteMessage, "Clipboard has no attachable content.")
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
