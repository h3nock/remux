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

enum FileProviderMutationReplayKey: Hashable, Codable, Sendable {
    case create(templateIdentifier: String)
    case modify(
        identity: FileProviderItemIdentity,
        contentVersion: Data,
        metadataVersion: Data,
        changedFields: UInt,
        parentIdentifier: String,
        filename: String
    )
    case delete(
        identity: FileProviderItemIdentity,
        contentVersion: Data,
        metadataVersion: Data
    )
}

enum FileProviderMutationReceipt: Equatable, Codable, Sendable {
    case item(
        key: FileProviderMutationReplayKey,
        item: FileProviderIdentifiedItem
    )
    case deleted(
        key: FileProviderMutationReplayKey
    )

    var key: FileProviderMutationReplayKey {
        switch self {
        case .item(let key, _), .deleted(let key):
            return key
        }
    }
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
    var receipt: FileProviderMutationReceipt?
    var queuesWorkingSetSignal = false
}
