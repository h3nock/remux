import Foundation
import UniformTypeIdentifiers

enum GhosttyAttachmentStagingStoreError: Error, Equatable {
    case urlOutsideStagingRoot(URL)
}

enum GhosttyAttachmentStagingStore {
    static let directoryName = "RemuxAttachmentStaging"

    static func stageFiles(_ urls: [URL]) async throws -> [GhosttyPendingAttachment] {
        try await Task.detached(priority: .utility) {
            try stageFilesSynchronously(urls)
        }.value
    }

    static func stageFilesSynchronously(_ urls: [URL]) throws -> [GhosttyPendingAttachment] {
        var attachments: [GhosttyPendingAttachment] = []

        do {
            for url in urls {
                attachments.append(try stageFileSynchronously(url))
            }

            return attachments
        } catch {
            cleanupSynchronously(attachments.compactMap(\.stagedFileURL))
            throw error
        }
    }

    static func stageFileSynchronously(_ sourceURL: URL) throws -> GhosttyPendingAttachment {
        let stagedURL = try stageFileURLSynchronously(sourceURL)
        return .file(url: stagedURL)
    }

    static func stageFileURL(_ sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageFileURLSynchronously(sourceURL)
        }.value
    }

    static func stageFileURL(_ sourceURL: URL, filename: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageFileURLSynchronously(sourceURL, filename: filename)
        }.value
    }

    static func stageFileURLSynchronously(_ sourceURL: URL) throws -> URL {
        try stageFileURLSynchronously(sourceURL, filename: sourceURL.lastPathComponent)
    }

    static func stageFileURLSynchronously(_ sourceURL: URL, filename: String) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(stagedFilename(for: filename))
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return destination
    }

    static func renameStagedFile(_ stagedURL: URL, filename: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try renameStagedFileSynchronously(stagedURL, filename: filename)
        }.value
    }

    static func renameStagedFileSynchronously(_ stagedURL: URL, filename: String) throws -> URL {
        let fileManager = FileManager.default
        let root = stagingRoot(fileManager: fileManager)
        guard isStagedURL(stagedURL, root: root) else {
            throw GhosttyAttachmentStagingStoreError.urlOutsideStagingRoot(stagedURL)
        }

        let destination = stagedURL
            .deletingLastPathComponent()
            .appendingPathComponent(stagedFilename(for: filename))

        guard destination != stagedURL else {
            return stagedURL
        }

        do {
            try fileManager.moveItem(at: stagedURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: stagedURL.deletingLastPathComponent())
            throw error
        }

        return destination
    }

    static func stageData(_ data: Data, filename: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageDataSynchronously(data, filename: filename)
        }.value
    }

    static func stageDataSynchronously(_ data: Data, filename: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(stagedFilename(for: filename))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return destination
    }

    static func stageImageDataSynchronously(
        _ data: Data,
        title: String,
        contentTypes: [UTType]
    ) throws -> URL {
        try stageDataSynchronously(
            data,
            filename: imageFilename(title: title, contentTypes: contentTypes)
        )
    }

    static func cleanup(_ attachments: [GhosttyPendingAttachment]) {
        let urls = attachments.compactMap(\.stagedFileURL)
        guard !urls.isEmpty else { return }

        Task.detached(priority: .utility) {
            cleanupSynchronously(urls)
        }
    }

    static func cleanupSynchronously(_ urls: [URL]) {
        let fileManager = FileManager.default
        let root = stagingRoot(fileManager: fileManager)

        for url in urls {
            guard isStagedURL(url, root: root) else { continue }
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }
    }

    static func stagingRoot(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func imageFilename(
        title: String,
        contentTypes: [UTType],
        uniqueID: UUID? = nil
    ) -> String {
        var stem = filenameStem(from: title)
        if let uniqueID {
            stem += "-\(uniqueID.uuidString.prefix(8).lowercased())"
        }

        guard let fileExtension = contentTypes
            .lazy
            .compactMap(\.preferredFilenameExtension)
            .first else {
            return stem
        }
        return "\(stem).\(fileExtension)"
    }

    private static func stagingDirectory(fileManager: FileManager) -> URL {
        stagingRoot(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func filenameStem(from title: String) -> String {
        let characters = title
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let stem = String(characters)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return stem.isEmpty ? "image" : stem
    }

    private static func stagedFilename(for sourceURL: URL) -> String {
        stagedFilename(for: sourceURL.lastPathComponent)
    }

    private static func stagedFilename(for filename: String) -> String {
        let component = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { character in
                character == "/" || character == "\\"
            }
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let component,
              !component.isEmpty,
              component != ".",
              component != ".." else {
            return "Attachment"
        }

        return component
    }

    private static func isStagedURL(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let parentPath = url
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        return parentPath.hasPrefix(rootPath + "/")
    }
}

private extension GhosttyPendingAttachment {
    var stagedFileURL: URL? {
        guard case .file(let url) = payload else { return nil }
        return url
    }
}
