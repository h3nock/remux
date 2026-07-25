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

    init(remoteItem: FileProviderRemoteItem, rootDisplayName: String) {
        let identifierCodec = FileProviderItemIdentifierCodec()
        self.itemIdentifier = identifierCodec.identifier(for: remoteItem.path)
        self.parentItemIdentifier = identifierCodec.identifier(for: remoteItem.parent)
        self.filename = remoteItem.path == .root ? rootDisplayName : remoteItem.name
        self.contentType = Self.contentType(for: remoteItem)
        self.documentSize = remoteItem.size.map(NSNumber.init(value:))
        self.contentModificationDate = remoteItem.modificationDate
        self.capabilities = [.allowsReading]
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
