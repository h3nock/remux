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
