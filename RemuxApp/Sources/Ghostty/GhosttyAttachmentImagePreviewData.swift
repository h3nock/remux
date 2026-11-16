import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GhosttyAttachmentImagePreviewData {
    static let maxPixelDimension = 1_280
    private static let compressionQuality = 0.84

    /// From pixels already decoded for sending, so the picture is not decoded a second time.
    static func previewData(for image: CGImage) -> Data? {
        GhosttyAttachmentImageCoding.data(
            for: image,
            as: .jpeg,
            lossyQuality: compressionQuality,
            maxPixelDimension: maxPixelDimension
        )
    }

    static func makePreviewData(from data: Data) async -> Data? {
        await Task.detached(priority: .utility) {
            makePreviewDataSynchronously(from: data)
        }.value
    }

    static func makePreviewData(fromFileAt url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            makePreviewDataSynchronously(fromFileAt: url)
        }.value
    }

    static func makePreviewDataSynchronously(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        return makePreviewDataSynchronously(from: source)
    }

    static func makePreviewDataSynchronously(fromFileAt url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        return makePreviewDataSynchronously(from: source)
    }

    private static func makePreviewDataSynchronously(from source: CGImageSource) -> Data? {
        GhosttyAttachmentImageCoding
            .uprightImage(from: source, maxPixelDimension: maxPixelDimension)
            .flatMap { GhosttyAttachmentImageCoding.data(for: $0, as: .jpeg, lossyQuality: compressionQuality) }
    }
}
