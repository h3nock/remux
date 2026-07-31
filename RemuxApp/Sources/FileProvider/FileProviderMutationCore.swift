import FileProvider
import Foundation

struct FileProviderMutationResult: Sendable {
    let item: FileProviderIdentifiedItem
    let stillPendingFields: NSFileProviderItemFields
    let shouldFetchContent: Bool
}

enum FileProviderCreateMutationError: Error, Sendable {
    case collision(existing: FileProviderIdentifiedItem)
}

actor FileProviderMutationCore {
    private let remote: any FileProviderRemoteServicing
    private let snapshots: FileProviderSnapshotStore
    private let coordinator: FileProviderDomainOperationCoordinator
    private let validator: FileProviderMutationValidator
    private let nonce: @Sendable () -> UUID
    private let identity: @Sendable () -> UUID

    init(
        remote: any FileProviderRemoteServicing,
        snapshots: FileProviderSnapshotStore,
        coordinator: FileProviderDomainOperationCoordinator,
        validator: FileProviderMutationValidator = FileProviderMutationValidator(),
        nonce: @escaping @Sendable () -> UUID = UUID.init,
        identity: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.remote = remote
        self.snapshots = snapshots
        self.coordinator = coordinator
        self.validator = validator
        self.nonce = nonce
        self.identity = identity
    }

    func create(
        request: FileProviderCreateRequest,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderMutationResult {
        let key = FileProviderMutationReplayKey.create(
            templateIdentifier: request.templateIdentifier.rawValue
        )
        if let receipt = try await snapshots.receipt(for: key) {
            return try Self.replayedResult(from: receipt)
        }

        return try await coordinator.performMutation { [remote, snapshots, validator, nonce, identity] in
            if let receipt = try await snapshots.receipt(for: key) {
                return try Self.replayedResult(from: receipt)
            }
            try validator.validateMutation(of: request.type)
            try validator.validateChildName(request.filename)
            try validator.validateContents(
                supplied: request.contentsURL != nil,
                for: request.type
            )

            let parentPath = try await snapshots.path(for: request.parentIdentifier)
            let parentIdentity = try FileProviderItemIdentifierCodec().identity(
                for: request.parentIdentifier
            )
            let destination = try FileProviderRemotePath(
                relative: parentPath.relative.isEmpty
                    ? request.filename
                    : parentPath.relative + "/" + request.filename
            )
            let temporary = try FileProviderRemotePath(
                relative: parentPath.relative.isEmpty
                    ? ".remux-upload-\(nonce().uuidString.lowercased())"
                    : parentPath.relative + "/.remux-upload-\(nonce().uuidString.lowercased())"
            )
            let reservedIdentity = FileProviderItemIdentity.item(identity())

            return try await remote.withMutationAccess { access in
                let parent = try await access.item(at: parentPath)
                try validator.validateParent(exists: parent.type == .directory)
                let existing = try await access.list(directory: parentPath)
                do {
                    try validator.validateDestination(
                        destination,
                        occupiedPaths: existing.map(\.path)
                    )
                } catch FileProviderMutationValidationError.destinationOccupied {
                    guard let remoteItem = existing.first(where: { $0.path == destination }) else {
                        throw FileProviderMutationValidationError.destinationOccupied
                    }
                    let snapshotsItems = try await snapshots.items(directory: parentPath)
                    let existingIdentity = snapshotsItems
                        .first { $0.remoteItem.path == destination }?.identity ?? .item(identity())
                    throw FileProviderCreateMutationError.collision(
                        existing: FileProviderIdentifiedItem(
                            identity: existingIdentity,
                            parentIdentity: parentIdentity,
                            remoteItem: remoteItem
                        )
                    )
                }

                var renamed = false
                do {
                    switch request.type {
                    case .directory:
                        try Task.checkCancellation()
                        try await access.createDirectory(at: destination)
                    case .regular:
                        let localURL = try request.contentsURL ?? emptyFileURL()
                        try await access.uploadFile(
                            from: localURL,
                            to: temporary,
                            progress: progress
                        )
                        try Task.checkCancellation()
                        try await access.renameItem(from: temporary, to: destination)
                        renamed = true
                    case .symbolicLink, .other:
                        throw FileProviderMutationValidationError.unsupportedFileType
                    }
                } catch {
                    if request.type == .regular, !renamed {
                        try? await access.removeFile(at: temporary)
                    }
                    throw error
                }

                return try await finishCommittedMutation {
                    let item = try await access.item(at: destination)
                    let parentItems = try await access.list(directory: parentPath)
                    let identified = FileProviderIdentifiedItem(
                        identity: reservedIdentity,
                        parentIdentity: parentIdentity,
                        remoteItem: item
                    )
                    _ = try await snapshots.commit(
                        localMutation: FileProviderSnapshotLocalMutation(
                            refreshedDirectories: [
                                .init(directory: parentPath, items: parentItems),
                            ],
                            identityReservations: [
                                .init(identity: reservedIdentity, path: destination),
                            ],
                            receipt: .item(key: key, item: identified),
                            queuesWorkingSetSignal: true
                        )
                    )
                    return FileProviderMutationResult(
                        item: identified,
                        stillPendingFields: request.fields.subtracting([
                            .contents,
                            .filename,
                            .parentItemIdentifier,
                        ]),
                        shouldFetchContent: false
                    )
                }
            }
        }
    }

    private static func replayedResult(
        from receipt: FileProviderMutationReceipt
    ) throws -> FileProviderMutationResult {
        guard case .item(_, let item) = receipt else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        return FileProviderMutationResult(
            item: item,
            stillPendingFields: [],
            shouldFetchContent: false
        )
    }
}

private func finishCommittedMutation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await Task.detached(operation: operation).value
}

private func emptyFileURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: url)
    return url
}
