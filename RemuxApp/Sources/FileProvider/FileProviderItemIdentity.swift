import FileProvider
import Foundation

enum FileProviderItemIdentity: Hashable, Codable, Sendable {
    case root
    case item(UUID)

    var itemIdentifier: NSFileProviderItemIdentifier {
        FileProviderItemIdentifierCodec().identifier(for: self)
    }
}

struct FileProviderIdentifiedItem: Equatable, Codable, Sendable {
    let identity: FileProviderItemIdentity
    let parentIdentity: FileProviderItemIdentity
    let remoteItem: FileProviderRemoteItem

    var itemIdentifier: NSFileProviderItemIdentifier {
        identity.itemIdentifier
    }
}
