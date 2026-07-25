import FileProvider
import Foundation
import UniformTypeIdentifiers

final class RemuxFileProviderItem: NSObject, NSFileProviderItem {
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
}
