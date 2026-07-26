import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderSDKItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let symlinkTargetPath: String?

    init(projection: FileProviderItemProjection) {
        self.itemIdentifier = projection.itemIdentifier
        self.parentItemIdentifier = projection.parentItemIdentifier
        self.filename = projection.filename
        self.contentType = projection.contentType
        self.documentSize = projection.documentSize
        self.contentModificationDate = projection.contentModificationDate
        self.capabilities = projection.capabilities
        self.itemVersion = projection.itemVersion
        self.symlinkTargetPath = projection.symlinkTargetPath
        super.init()
    }

    convenience init(item: FileProviderIdentifiedItem, rootDisplayName: String) {
        self.init(
            projection: FileProviderItemProjection(
                item: item,
                rootDisplayName: rootDisplayName
            )
        )
    }
}

enum FileProviderSDKRequestAdapter {
    static func createRequest(
        itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contentsURL: URL?,
        options: NSFileProviderCreateItemOptions
    ) throws -> FileProviderCreateRequest {
        FileProviderCreateRequest(
            templateIdentifier: itemTemplate.itemIdentifier,
            parentIdentifier: itemTemplate.parentItemIdentifier,
            filename: itemTemplate.filename,
            type: try fileType(for: itemTemplate.contentType ?? .data),
            fields: fields,
            contentsURL: contentsURL,
            options: options
        )
    }

    static func modifyRequest(
        item: NSFileProviderItem,
        baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contentsURL: URL?,
        options: NSFileProviderModifyItemOptions
    ) -> FileProviderModifyRequest {
        FileProviderModifyRequest(
            identifier: item.itemIdentifier,
            parentIdentifier: item.parentItemIdentifier,
            filename: item.filename,
            baseVersion: baseVersion,
            changedFields: changedFields,
            contentsURL: contentsURL,
            options: options
        )
    }

    static func deleteRequest(
        identifier: NSFileProviderItemIdentifier,
        baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions
    ) -> FileProviderDeleteRequest {
        FileProviderDeleteRequest(
            identifier: identifier,
            baseVersion: baseVersion,
            options: options
        )
    }

    private static func fileType(for contentType: UTType) throws -> RemuxSFTPFileType {
        if contentType == .folder {
            return .directory
        }
        if contentType == .symbolicLink {
            throw FileProviderMutationValidationError.symbolicLinkMutation
        }
        return .regular
    }
}
