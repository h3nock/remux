import FileProvider
import Foundation

struct FileProviderCreateRequest: @unchecked Sendable {
    let templateIdentifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let type: RemuxSFTPFileType
    let fields: NSFileProviderItemFields
    let contentsURL: URL?
    let options: NSFileProviderCreateItemOptions
}

struct FileProviderModifyRequest: @unchecked Sendable {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let baseVersion: NSFileProviderItemVersion
    let changedFields: NSFileProviderItemFields
    let contentsURL: URL?
    let options: NSFileProviderModifyItemOptions
}

struct FileProviderDeleteRequest: @unchecked Sendable {
    let identifier: NSFileProviderItemIdentifier
    let baseVersion: NSFileProviderItemVersion
    let options: NSFileProviderDeleteItemOptions
}

struct FileProviderMutationFieldPartition: Equatable {
    let supported: NSFileProviderItemFields
    let stillPending: NSFileProviderItemFields

    init(changedFields: NSFileProviderItemFields) {
        let supportedFields: NSFileProviderItemFields = [
            .contents,
            .filename,
            .parentItemIdentifier,
        ]
        supported = changedFields.intersection(supportedFields)
        stillPending = changedFields.subtracting(supportedFields)
    }
}
