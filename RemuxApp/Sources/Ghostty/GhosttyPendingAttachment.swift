import Foundation
import UniformTypeIdentifiers

struct GhosttySecurityScopedAttachmentFile: Equatable, Sendable {
    enum AccessError: Error, Equatable, Sendable {
        case bookmarkResolutionFailed(String)
        case staleBookmark(String)
    }

    let bookmarkData: Data
    let originalURL: URL
    let filename: String
    let fileSize: Int64?

    init(
        bookmarkData: Data,
        originalURL: URL,
        filename: String,
        fileSize: Int64? = nil
    ) {
        self.bookmarkData = bookmarkData
        self.originalURL = originalURL
        self.filename = filename
        self.fileSize = fileSize
    }

    static func make(url: URL) throws -> GhosttySecurityScopedAttachmentFile {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .localizedNameKey,
        ])
        let filename = Self.displayFilename(
            localizedName: resourceValues?.localizedName,
            fallbackURL: url
        )
        let bookmarkData = try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return GhosttySecurityScopedAttachmentFile(
            bookmarkData: bookmarkData,
            originalURL: url,
            filename: filename,
            fileSize: resourceValues?.fileSize.map(Int64.init)
        )
    }

    func withAccessibleURL<ReturnValue>(
        _ operation: (URL) throws -> ReturnValue
    ) throws -> ReturnValue {
        let resolvedURL = try resolvedURL()
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        return try operation(resolvedURL)
    }

    func withAccessibleURL<ReturnValue: Sendable>(
        _ operation: (URL) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let resolvedURL = try resolvedURL()
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        return try await operation(resolvedURL)
    }

    func resolvedURL() throws -> URL {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw AccessError.bookmarkResolutionFailed(filename)
        }

        guard !isStale else {
            throw AccessError.staleBookmark(filename)
        }

        return resolvedURL
    }

    private static func displayFilename(
        localizedName: String?,
        fallbackURL: URL
    ) -> String {
        let localizedName = localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }

        let filename = fallbackURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "File" : filename
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(iOS)
        [.minimalBookmark]
        #else
        [.withSecurityScope]
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(iOS)
        []
        #else
        [.withSecurityScope]
        #endif
    }
}

enum GhosttyAttachmentPayload: Equatable, Sendable {
    case file(URL)
    case securityScopedFile(GhosttySecurityScopedAttachmentFile)
    case link(URL)
    case text(String)
}

enum GhosttyAttachmentPreviewPayload: Equatable, Sendable {
    case imageData(Data)
    case file(URL)
    case securityScopedFile(GhosttySecurityScopedAttachmentFile)
    case link(URL)
    case text(String)

    init(_ payload: GhosttyAttachmentPayload) {
        switch payload {
        case .file(let url):
            self = .file(url)
        case .securityScopedFile(let file):
            self = .securityScopedFile(file)
        case .link(let url):
            self = .link(url)
        case .text(let text):
            self = .text(text)
        }
    }
}

struct GhosttyPendingAttachment: Identifiable, Equatable, Sendable {
    enum PreparationState: Equatable, Sendable {
        case preparing
        case ready
        case failed
    }

    enum Kind: Equatable, Sendable {
        case photo
        case video
        case media
        case file
        case pasteboardImage
        case pasteboardLink
        case pasteboardText

        var systemName: String {
            switch self {
            case .photo, .pasteboardImage:
                "photo"
            case .video:
                "video"
            case .media:
                "photo.on.rectangle"
            case .file:
                "doc"
            case .pasteboardLink:
                "link"
            case .pasteboardText:
                "text.alignleft"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    let payload: GhosttyAttachmentPayload?
    let previewPayload: GhosttyAttachmentPreviewPayload?
    let preparationState: PreparationState

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String = "Attachment",
        payload: GhosttyAttachmentPayload? = nil,
        previewPayload: GhosttyAttachmentPreviewPayload? = nil,
        preparationState: PreparationState = .ready
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.payload = payload
        self.previewPayload = previewPayload ?? payload.map(GhosttyAttachmentPreviewPayload.init)
        self.preparationState = preparationState
    }

    var systemName: String {
        kind.systemName
    }

    var isPreviewable: Bool {
        previewPayload != nil
    }

    var supportsImageMarkup: Bool {
        switch kind {
        case .photo, .pasteboardImage:
            return imageMarkupFilename != nil
        case .file:
            guard let filename = imageMarkupFilename else { return false }
            return Self.isImageFilename(filename)
        case .video, .media, .pasteboardLink, .pasteboardText:
            return false
        }
    }

    var imageMarkupFilename: String? {
        switch payload {
        case .file(let url):
            let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return filename.isEmpty ? nil : filename
        case .securityScopedFile(let file):
            let filename = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            return filename.isEmpty ? nil : filename
        case .link, .text, nil:
            return nil
        }
    }

    /// `existingPhotoCount` is how many photos the draft already holds, so photos added in separate picks still
    /// get different names.
    static func mediaSelections(
        contentTypes: [[UTType]],
        existingPhotoCount: Int = 0
    ) -> [GhosttyPendingAttachment] {
        guard !contentTypes.isEmpty else { return [] }

        let shouldNumber = existingPhotoCount + contentTypes.count > 1
        return contentTypes.enumerated().compactMap { index, contentTypes in
            let kind = mediaKind(contentTypes)
            guard kind == .photo else { return nil }

            return GhosttyPendingAttachment(
                kind: kind,
                title: mediaTitle(kind, number: shouldNumber ? existingPhotoCount + index + 1 : nil),
                detail: "Preparing…",
                preparationState: .preparing
            )
        }
    }

    /// The draft's first photo is added unnumbered; once a second photo joins it, it becomes "Photo 1".
    func numberedAsFirstPhoto() -> GhosttyPendingAttachment {
        guard kind == .photo, title == Self.mediaTitle(.photo, number: nil) else { return self }
        return GhosttyPendingAttachment(
            id: id,
            kind: kind,
            title: Self.mediaTitle(.photo, number: 1),
            detail: detail,
            payload: payload,
            previewPayload: previewPayload,
            preparationState: preparationState
        )
    }

    static func file(url: URL) -> GhosttyPendingAttachment {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return GhosttyPendingAttachment(
            kind: .file,
            title: filename.isEmpty ? "File" : filename,
            detail: fileDetail(url),
            payload: .file(url)
        )
    }

    static func files(urls: [URL]) -> [GhosttyPendingAttachment] {
        urls.map(file(url:))
    }

    static func securityScopedFile(url: URL) throws -> GhosttyPendingAttachment {
        let file = try GhosttySecurityScopedAttachmentFile.make(url: url)
        return GhosttyPendingAttachment(
            kind: .file,
            title: file.filename,
            detail: fileDetail(filename: file.filename),
            payload: .securityScopedFile(file),
            previewPayload: .securityScopedFile(file)
        )
    }

    static func securityScopedFiles(urls: [URL]) throws -> [GhosttyPendingAttachment] {
        try urls.map(securityScopedFile(url:))
    }

    static func pasteboardImage(previewData: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasted image",
            detail: "Image",
            previewPayload: .imageData(previewData)
        )
    }

    static func pasteboardImage(fileURL: URL, previewData: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasted image",
            detail: "Image",
            payload: .file(fileURL),
            previewPayload: .imageData(previewData)
        )
    }

    static func photo(title: String, fileURL: URL, previewData: Data) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .photo,
            title: title,
            detail: "Image",
            payload: .file(fileURL),
            previewPayload: .imageData(previewData)
        )
    }

    static func photo(title: String, stagedFileURL: URL) async -> GhosttyPendingAttachment? {
        guard let previewData = await GhosttyAttachmentImagePreviewData.makePreviewData(
            fromFileAt: stagedFileURL
        ) else {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedFileURL])
            return nil
        }

        return photo(title: title, fileURL: stagedFileURL, previewData: previewData)
    }

    static func pasteboardImagePlaceholder() -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardImage,
            title: "Pasted image",
            detail: "Preparing…",
            preparationState: .preparing
        )
    }

    static func pasteboardLink(url: URL) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardLink,
            title: "Pasted link",
            detail: linkDetail(url),
            payload: .link(url)
        )
    }

    static func pasteboardText(_ text: String) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            kind: .pasteboardText,
            title: "Pasted text",
            detail: textDetail(text),
            payload: .text(text)
        )
    }

    func updating(
        payload: GhosttyAttachmentPayload? = nil,
        previewPayload: GhosttyAttachmentPreviewPayload? = nil,
        detail: String,
        preparationState: PreparationState? = nil
    ) -> GhosttyPendingAttachment {
        GhosttyPendingAttachment(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            payload: payload ?? self.payload,
            previewPayload: previewPayload ?? self.previewPayload,
            preparationState: preparationState ?? self.preparationState
        )
    }

    func updatingText(_ text: String) -> GhosttyPendingAttachment {
        updating(
            payload: .text(text),
            previewPayload: .text(text),
            detail: Self.textDetail(text)
        )
    }

    func updatingAnnotatedImage(fileURL: URL, previewData: Data) -> GhosttyPendingAttachment {
        updating(
            payload: .file(fileURL),
            previewPayload: .imageData(previewData),
            detail: "Annotated image"
        )
    }

    static func textDetail(_ text: String) -> String {
        let normalizedText = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedText, !normalizedText.isEmpty else {
            return "Text"
        }

        return normalizedText
    }

    private static func linkDetail(_ url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString
        }

        let path = url.path(percentEncoded: false)
        let query = url.query(percentEncoded: false).map { "?\($0)" } ?? ""
        let suffix = [path == "/" ? "" : path, query].joined()
        return suffix.isEmpty ? host : "\(host)\(suffix)"
    }

    private static func fileDetail(_ url: URL) -> String {
        fileDetail(filename: url.lastPathComponent)
    }

    private static func fileDetail(filename: String) -> String {
        let fileExtension = URL(fileURLWithPath: filename)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty else { return "File" }
        return "\(fileExtension.uppercased()) file"
    }

    private static func isImageFilename(_ filename: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: filename)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileExtension.isEmpty,
              let contentType = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return contentType.conforms(to: .image)
    }

    private static func mediaKind(_ contentTypes: [UTType]) -> Kind {
        if contentTypes.contains(where: { $0.conforms(to: .image) }) {
            return .photo
        }

        if contentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }) {
            return .video
        }

        return .media
    }

    private static func mediaTitle(_ kind: Kind, number: Int?) -> String {
        let title: String
        switch kind {
        case .photo:
            title = "Photo"
        case .video:
            title = "Video"
        default:
            title = "Media"
        }

        guard let number else { return title }
        return "\(title) \(number)"
    }
}
