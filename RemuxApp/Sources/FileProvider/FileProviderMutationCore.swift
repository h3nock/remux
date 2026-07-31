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

enum FileProviderModifyMutationError: Error, Sendable {
    case conflict(current: FileProviderIdentifiedItem)
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

    func modify(
        request: FileProviderModifyRequest,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderMutationResult {
        let sourceIdentity = try FileProviderItemIdentifierCodec().identity(for: request.identifier)
        try validator.validateMutablePath(try await snapshots.path(for: request.identifier))
        let key = FileProviderMutationReplayKey.modify(
            identity: sourceIdentity,
            contentVersion: request.baseVersion.contentVersion,
            metadataVersion: request.baseVersion.metadataVersion,
            changedFields: UInt(request.changedFields.rawValue),
            parentIdentifier: request.parentIdentifier.rawValue,
            filename: request.filename
        )
        if let receipt = try await snapshots.receipt(for: key) {
            return try Self.replayedResult(from: receipt)
        }

        return try await coordinator.performMutation { [remote, snapshots, validator] in
            if let receipt = try await snapshots.receipt(for: key) {
                return try Self.replayedResult(from: receipt)
            }

            let partition = FileProviderMutationFieldPartition(
                changedFields: request.changedFields
            )
            let supportedMetadataFields = partition.supported.intersection([
                .filename,
                .parentItemIdentifier,
            ])
            let stillPendingFields = request.changedFields.subtracting(supportedMetadataFields)
            let sourcePath = try await snapshots.path(for: request.identifier)
            let sourceSnapshot = try await snapshots.item(for: request.identifier)

            return try await remote.withMutationAccess { access in
                let sourceRemote = try await access.item(at: sourcePath)
                let oldParentPath = sourceRemote.parent
                let oldParentRemote = try await access.item(at: oldParentPath)
                try validator.validateParent(exists: oldParentRemote.type == .directory)
                try validator.validateMutation(of: sourceRemote.type)

                let current = FileProviderIdentifiedItem(
                    identity: sourceIdentity,
                    parentIdentity: sourceSnapshot?.parentIdentity ?? .root,
                    remoteItem: sourceRemote
                )
                if case .conflict = validator.validateBaseVersion(
                    requested: request.baseVersion,
                    current: current
                ) {
                    throw FileProviderModifyMutationError.conflict(current: current)
                }
                guard !supportedMetadataFields.isEmpty else {
                    return FileProviderMutationResult(
                        item: current,
                        stillPendingFields: stillPendingFields,
                        shouldFetchContent: false
                    )
                }

                let newParentPath = try await snapshots.path(for: request.parentIdentifier)
                let newParentIdentity = try FileProviderItemIdentifierCodec().identity(
                    for: request.parentIdentifier
                )
                let newParentRemote = newParentPath == oldParentPath
                    ? oldParentRemote
                    : try await access.item(at: newParentPath)
                try validator.validateParent(exists: newParentRemote.type == .directory)

                let filename = request.changedFields.contains(.filename)
                    ? request.filename
                    : sourceRemote.name
                try validator.validateChildName(filename)
                let destination = try FileProviderRemotePath(
                    relative: newParentPath.relative.isEmpty
                        ? filename
                        : newParentPath.relative + "/" + filename
                )
                try validator.validateMove(
                    source: sourcePath,
                    destination: destination,
                    sourceType: sourceRemote.type
                )
                guard destination != sourcePath else {
                    return FileProviderMutationResult(
                        item: current,
                        stillPendingFields: stillPendingFields,
                        shouldFetchContent: false
                    )
                }

                let oldParentItems = try await access.list(directory: oldParentPath)
                let newParentItems = newParentPath == oldParentPath
                    ? oldParentItems
                    : try await access.list(directory: newParentPath)
                try validator.validateDestination(
                    destination,
                    occupiedPaths: newParentItems
                        .map(\.path)
                        .filter { $0 != sourcePath }
                )

                try await access.renameItem(from: sourcePath, to: destination)
                return try await finishCommittedMutation {
                    let movedRemote = try await access.item(at: destination)
                    let refreshedOldParentItems = try await access.list(directory: oldParentPath)
                    let refreshedDirectories: [FileProviderSnapshotLocalMutation.DirectoryRefresh]
                    if newParentPath == oldParentPath {
                        refreshedDirectories = [
                            .init(directory: oldParentPath, items: refreshedOldParentItems),
                        ]
                    } else {
                        let refreshedNewParentItems = try await access.list(directory: newParentPath)
                        refreshedDirectories = [
                            .init(directory: oldParentPath, items: refreshedOldParentItems),
                            .init(directory: newParentPath, items: refreshedNewParentItems),
                        ]
                    }
                    let moved = FileProviderIdentifiedItem(
                        identity: sourceIdentity,
                        parentIdentity: newParentIdentity,
                        remoteItem: movedRemote
                    )
                    _ = try await snapshots.commit(
                        localMutation: FileProviderSnapshotLocalMutation(
                            refreshedDirectories: refreshedDirectories,
                            relocations: [
                                .init(identity: sourceIdentity, from: sourcePath, to: destination),
                            ],
                            receipt: .item(key: key, item: moved)
                        )
                    )
                    return FileProviderMutationResult(
                        item: moved,
                        stillPendingFields: stillPendingFields,
                        shouldFetchContent: false
                    )
                }
            }
        }
    }

    private static func replayedResult(
        from receipt: FileProviderMutationReceipt
    ) throws -> FileProviderMutationResult {
        guard case .item(let key, let item) = receipt else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        let stillPendingFields: NSFileProviderItemFields
        switch key {
        case .modify(_, _, _, let changedFields, _, _):
            stillPendingFields = NSFileProviderItemFields(rawValue: changedFields)
                .subtracting([.filename, .parentItemIdentifier])
        case .create, .delete:
            stillPendingFields = []
        }
        return FileProviderMutationResult(
            item: item,
            stillPendingFields: stillPendingFields,
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
