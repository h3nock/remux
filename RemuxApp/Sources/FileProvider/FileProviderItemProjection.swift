import FileProvider
import Foundation
import UniformTypeIdentifiers

struct FileProviderItemProjection: @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let symlinkTargetPath: String?

    init(item: FileProviderIdentifiedItem, rootDisplayName: String) {
        let remoteItem = item.remoteItem
        self.itemIdentifier = item.itemIdentifier
        self.parentItemIdentifier = item.parentIdentity.itemIdentifier
        self.filename = remoteItem.path == .root ? rootDisplayName : remoteItem.name
        self.contentType = Self.contentType(for: remoteItem)
        self.documentSize = remoteItem.size.map(NSNumber.init(value:))
        self.contentModificationDate = remoteItem.modificationDate
        self.capabilities = Self.capabilities(for: remoteItem)
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: remoteItem.contentVersion,
            metadataVersion: remoteItem.metadataVersion
        )
        self.symlinkTargetPath = remoteItem.symlinkTargetRelativePath
    }

    private static func contentType(for item: FileProviderRemoteItem) -> UTType {
        switch item.type {
        case .directory:
            .folder
        case .regular:
            fileType(for: item.name)
        case .symbolicLink:
            .symbolicLink
        case .other:
            .data
        }
    }

    private static func capabilities(
        for item: FileProviderRemoteItem
    ) -> NSFileProviderItemCapabilities {
        switch item.type {
        case .directory where item.path == .root:
            [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems]
        case .directory:
            [
                .allowsReading, .allowsWriting, .allowsContentEnumerating,
                .allowsAddingSubItems, .allowsRenaming, .allowsReparenting,
                .allowsDeleting,
            ]
        case .regular:
            [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        case .symbolicLink, .other:
            [.allowsReading]
        }
    }

    private static func fileType(for filename: String) -> UTType {
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension)
        else {
            return .data
        }
        return type
    }
}
