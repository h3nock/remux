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

struct FileProviderCreateAlias: Sendable {
    let templateIdentifier: String
    let identity: FileProviderItemIdentity
}

struct FileProviderSnapshotLocalMutation: Sendable {
    struct DirectoryRefresh: Sendable {
        let directory: FileProviderRemotePath
        let items: [FileProviderRemoteItem]
    }

    struct IdentityRelocation: Sendable {
        let identity: FileProviderItemIdentity
        let from: FileProviderRemotePath
        let to: FileProviderRemotePath
    }

    struct IdentityReservation: Sendable {
        let identity: FileProviderItemIdentity
        let path: FileProviderRemotePath
    }

    let refreshedDirectories: [DirectoryRefresh]
    var identityReservations: [IdentityReservation] = []
    var relocations: [IdentityRelocation] = []
    var deletedIdentities: Set<FileProviderItemIdentity> = []
    var createAlias: FileProviderCreateAlias?
    var queuesWorkingSetSignal = false
}
