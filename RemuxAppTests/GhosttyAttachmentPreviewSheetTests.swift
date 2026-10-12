import SwiftUI
import UIKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyAttachmentPreviewSheetTests: XCTestCase {
    func testSiblingReadinessPreservesImageAndZoom() async throws {
        let data = imageData(size: CGSize(width: 16, height: 8))
        let selected = attachment(data: data)
        let sibling = GhosttyPendingAttachment(
            kind: .photo,
            title: "Photo 2",
            preparationState: .preparing
        )
        let harness = PreviewHarness()
        defer { harness.close() }
        await render([selected, sibling], in: harness)
        let preview = try XCTUnwrap(harness.preview)
        let scrollView = try XCTUnwrap(firstView(in: preview, matching: UIScrollView.self))
        let imageView = try XCTUnwrap(firstView(in: preview, matching: UIImageView.self))
        let image = try XCTUnwrap(imageView.image)
        scrollView.setZoomScale(2, animated: false)
        scrollView.contentOffset = CGPoint(x: 24, y: 18)
        let offset = scrollView.contentOffset

        await render([selected, attachment(id: sibling.id, data: data)], in: harness)

        XCTAssertTrue(harness.preview === preview)
        XCTAssertTrue(imageView.image === image)
        XCTAssertEqual(scrollView.zoomScale, 2)
        XCTAssertEqual(scrollView.contentOffset, offset)
    }

    func testChangingAttachmentOrImageResetsZoom() async throws {
        let selected = attachment(data: imageData(size: CGSize(width: 16, height: 8)))
        let replacementData = imageData(size: CGSize(width: 8, height: 16))
        let annotated = selected.updatingAnnotatedImage(
            fileURL: URL(fileURLWithPath: "/tmp/annotated.jpeg"),
            previewData: replacementData
        )
        let harness = PreviewHarness()
        defer { harness.close() }
        await render([selected], in: harness)

        for replacement in [annotated, attachment(data: replacementData)] {
            let preview = try XCTUnwrap(harness.preview)
            let scrollView = try XCTUnwrap(firstView(in: preview, matching: UIScrollView.self))
            let image = try XCTUnwrap(firstView(in: preview, matching: UIImageView.self)?.image)
            scrollView.setZoomScale(2, animated: false)

            await render([replacement], in: harness)

            let updatedPreview = try XCTUnwrap(harness.preview)
            let updatedScrollView = try XCTUnwrap(firstView(in: updatedPreview, matching: UIScrollView.self))
            let updatedImage = try XCTUnwrap(firstView(in: updatedPreview, matching: UIImageView.self)?.image)
            XCTAssertFalse(updatedImage === image)
            XCTAssertLessThan(updatedImage.size.width, updatedImage.size.height)
            XCTAssertEqual(updatedScrollView.zoomScale, 1)
        }
    }

    func testInvalidImageReplacesPreviewAndCanRecover() async throws {
        let selected = attachment(data: imageData(size: CGSize(width: 16, height: 8)))
        let harness = PreviewHarness()
        defer { harness.close() }
        await render([selected], in: harness)
        XCTAssertNotNil(harness.preview)

        await render([attachment(id: selected.id, data: Data([0x01, 0x02]))], in: harness)

        XCTAssertNil(harness.preview)

        await render([selected], in: harness)

        let preview = try XCTUnwrap(harness.preview)
        XCTAssertNotNil(firstView(in: preview, matching: UIImageView.self)?.image)
    }

    private func render(
        _ attachments: [GhosttyPendingAttachment],
        in harness: PreviewHarness
    ) async {
        let rendered = expectation(description: "Preview attachments updated")
        harness.host.rootView = AnyView(
            GhosttyAttachmentPreviewSheet(
                attachments: .constant(attachments),
                initiallySelectedAttachmentID: attachments[0].id
            )
            .onChange(of: attachments, initial: true) { _, _ in
                rendered.fulfill()
            }
        )
        harness.host.view.setNeedsLayout()
        harness.host.view.layoutIfNeeded()
        await fulfillment(of: [rendered], timeout: 1)
        harness.host.view.layoutIfNeeded()
        harness.preview?.layoutIfNeeded()
    }

    private func attachment(id: UUID = UUID(), data: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            id: id,
            kind: .photo,
            title: "Photo",
            payload: .file(URL(fileURLWithPath: "/tmp/photo.jpeg")),
            previewPayload: .imageData(data)
        )
    }

    private func imageData(size: CGSize) -> Data {
        UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

@MainActor
private final class PreviewHarness {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    var preview: GhosttyAttachmentInteractiveImageView? {
        firstView(in: host.view, matching: GhosttyAttachmentInteractiveImageView.self)
    }

    init() {
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func firstView<View: UIView>(in view: UIView, matching: View.Type) -> View? {
    if let match = view as? View {
        return match
    }
    for subview in view.subviews {
        if let match = firstView(in: subview, matching: matching) {
            return match
        }
    }
    return nil
}
