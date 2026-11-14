import Foundation
import UIKit
import UniformTypeIdentifiers

struct GhosttyAttachmentPasteboardSnapshot: Equatable {
    /// A picture's bytes, read while its paste is handled: the pasteboard stops serving what was pasted soon after,
    /// so a read left for later can fail or come back empty.
    struct PastedImage {
        let data: Data
        let contentType: UTType?
    }

    let hasImages: Bool
    let hasURLs: Bool
    let hasStrings: Bool
    let imageData: Data?
    let url: URL?
    let string: String?

    init(
        hasImages: Bool,
        hasURLs: Bool,
        hasStrings: Bool,
        imageData: Data? = nil,
        url: URL? = nil,
        string: String? = nil
    ) {
        self.hasImages = hasImages
        self.hasURLs = hasURLs
        self.hasStrings = hasStrings
        self.imageData = imageData
        self.url = url
        self.string = string
    }

    static func current(_ pasteboard: UIPasteboard = .general) -> Self {
        GhosttyAttachmentPasteboardSnapshot(
            hasImages: pasteboard.hasImages,
            hasURLs: pasteboard.hasURLs,
            hasStrings: pasteboard.hasStrings,
            url: pasteboard.url,
            string: pasteboard.string
        )
    }

    /// The first picture on `pasteboard`, in whichever of its items holds one, read now. Call it from the paste itself.
    ///
    /// Within an item, a representation that can hold an animation is taken first, so an animated GIF offered along
    /// with a still PNG of its first frame keeps its frames; otherwise the item's own order is followed, which puts its
    /// original first.
    @MainActor
    static func currentImage(_ pasteboard: UIPasteboard = .general) -> PastedImage? {
        let canHoldAnimation = { (type: UTType) in [UTType.gif, .webP, .heics].contains { type.conforms(to: $0) } }
        for index in 0..<pasteboard.numberOfItems {
            let item = IndexSet(integer: index)
            let pictureTypes = (pasteboard.types(forItemSet: item)?.first ?? [])
                .compactMap(UTType.init)
                .filter { $0.conforms(to: .image) }
            for type in pictureTypes.filter(canHoldAnimation) + pictureTypes.filter({ !canHoldAnimation($0) }) {
                if let data = pasteboard.data(forPasteboardType: type.identifier, inItemSet: item)?.first, !data.isEmpty {
                    return PastedImage(data: data, contentType: type)
                }
            }
        }
        return nil
    }

    static func imageAttachment(from image: PastedImage) async -> GhosttyPendingAttachment? {
        await makeImageAttachment(from: image.data, contentType: image.contentType)
    }

    var pendingAttachments: [GhosttyPendingAttachment] {
        if let imageData {
            return [.pasteboardImage(previewData: imageData)]
        }

        if let pasteboardURL {
            return [.pasteboardLink(url: pasteboardURL)]
        }

        if let pasteboardText {
            return [.pasteboardText(pasteboardText)]
        }

        return []
    }

    var emptyPasteMessage: String {
        if string != nil && pasteboardText == nil && imageData == nil && pasteboardURL == nil {
            return "Clipboard text is empty."
        }

        if hasImages || hasURLs || hasStrings {
            return "Clipboard content could not be read."
        }

        return "Clipboard has no attachable content."
    }

    private var pasteboardText: String? {
        let normalizedText = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedText, !normalizedText.isEmpty else { return nil }
        return normalizedText
    }

    private var pasteboardURL: URL? {
        if let url, Self.isAttachableLink(url) {
            return url
        }

        guard let pasteboardText,
              let parsedURL = URL(string: pasteboardText),
              Self.isAttachableLink(parsedURL) else {
            return nil
        }

        return parsedURL
    }

    private static func isAttachableLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return false
        }

        return true
    }

    private static func makeImageAttachment(
        from data: Data,
        contentType: UTType?
    ) async -> GhosttyPendingAttachment? {
        async let previewData = GhosttyAttachmentImagePreviewData.makePreviewData(from: data)

        do {
            let stagedURL = try await GhosttyAttachmentStagingStore.stageImageData(
                data,
                title: "Pasted image",
                contentTypes: contentType.map { [$0] } ?? []
            )
            return await preparedImageAttachment(stagedURL: stagedURL, previewData: await previewData)
        } catch {
            return nil
        }
    }

    /// A pasted picture is sent the way a picked photo is.
    private static func preparedImageAttachment(
        stagedURL: URL,
        previewData: Data?
    ) async -> GhosttyPendingAttachment? {
        guard let previewData,
              let prepared = try? await GhosttyAttachmentPhotoPreparation.preparePhoto(at: stagedURL) else {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            return nil
        }

        return .pasteboardImage(fileURL: prepared.url, previewData: previewData)
    }


}
