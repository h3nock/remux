import Foundation
import UIKit
import UniformTypeIdentifiers

struct GhosttyAttachmentPasteboardSnapshot: Equatable {
    struct ImageProviderRequest {
        let provider: NSItemProvider
        let typeIdentifier: String
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

    @MainActor
    static func currentImagePreviewData(_ pasteboard: UIPasteboard = .general) async -> Data? {
        guard let request = imageProviderRequest(in: pasteboard) else {
            return nil
        }

        if let fileURL = await loadImageFileCopy(
            from: request.provider,
            typeIdentifier: request.typeIdentifier
        ) {
            defer {
                removeTemporaryImageFileCopy(fileURL)
            }

            return await GhosttyAttachmentImagePreviewData.makePreviewData(fromFileAt: fileURL)
        }

        guard let data = await loadImageData(
            from: request.provider,
            typeIdentifier: request.typeIdentifier
        ) else {
            return nil
        }

        return await GhosttyAttachmentImagePreviewData.makePreviewData(from: data)
    }

    @MainActor
    static func currentImageAttachment(_ pasteboard: UIPasteboard = .general) async -> GhosttyPendingAttachment? {
        guard let request = imageProviderRequest(in: pasteboard) else {
            return nil
        }

        return await imageAttachment(from: request)
    }

    @MainActor
    static func currentImageProviderRequest(
        _ pasteboard: UIPasteboard = .general
    ) -> ImageProviderRequest? {
        imageProviderRequest(in: pasteboard)
    }

    @MainActor
    static func imageAttachment(
        from request: ImageProviderRequest
    ) async -> GhosttyPendingAttachment? {
        if let fileURL = await loadImageFileCopy(
            from: request.provider,
            typeIdentifier: request.typeIdentifier
        ) {
            defer {
                removeTemporaryImageFileCopy(fileURL)
            }

            return await makeImageAttachment(fromFileAt: fileURL)
        }

        guard let data = await loadImageData(
            from: request.provider,
            typeIdentifier: request.typeIdentifier
        ) else {
            return nil
        }

        return await makeImageAttachment(
            from: data,
            contentType: UTType(request.typeIdentifier)
        )
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

    @MainActor
    private static func imageProviderRequest(in pasteboard: UIPasteboard) -> ImageProviderRequest? {
        for provider in pasteboard.itemProviders {
            guard let typeIdentifier = imageTypeIdentifier(for: provider) else {
                continue
            }

            return ImageProviderRequest(provider: provider, typeIdentifier: typeIdentifier)
        }

        return nil
    }

    private static func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        imagePasteboardTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }

    @MainActor
    private static func loadImageFileCopy(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: copyTemporaryImageFile(url, typeIdentifier: typeIdentifier))
            }
        }
    }

    @MainActor
    private static func loadImageData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private static func copyTemporaryImageFile(_ sourceURL: URL, typeIdentifier: String) -> URL? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RemuxPasteboardImage-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(
                "Image.\(fileExtension(for: sourceURL, typeIdentifier: typeIdentifier))"
            )
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }
    }

    private static func removeTemporaryImageFileCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func makeImageAttachment(fromFileAt fileURL: URL) async -> GhosttyPendingAttachment? {
        async let previewData = GhosttyAttachmentImagePreviewData.makePreviewData(fromFileAt: fileURL)

        do {
            let stagedURL = try await GhosttyAttachmentStagingStore.stageFileURL(fileURL)
            return await preparedImageAttachment(stagedURL: stagedURL, previewData: await previewData)
        } catch {
            return nil
        }
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

    private static func fileExtension(for url: URL, typeIdentifier: String) -> String {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathExtension.isEmpty {
            return pathExtension
        }

        return UTType(typeIdentifier)?.preferredFilenameExtension ?? "image"
    }

    private static var imagePasteboardTypes: [String] {
        [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            "public.heic",
            "public.image"
        ]
    }

}
