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

enum FileProviderDeleteMutationError: Error, Sendable {
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

                if request.type == .regular {
                    try validator.validateDestination(
                        temporary,
                        occupiedPaths: existing.map(\.path)
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
                        await cleanupTemporaryFile(temporary, using: access)
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

        return try await coordinator.performMutation { [remote, snapshots, validator, nonce, identity] in
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
            let changesContents = request.changedFields.contains(.contents)
            let supportedFields = changesContents
                ? supportedMetadataFields.union([.contents])
                : supportedMetadataFields
            let stillPendingFields = request.changedFields.subtracting(supportedFields)
            let sourcePath = try await snapshots.path(for: request.identifier)
            let sourceSnapshot = try await snapshots.item(for: request.identifier)

            return try await remote.withMutationAccess { access in
                let sourceRemote = try await access.item(at: sourcePath)
                let oldParentPath = sourceRemote.parent
                let oldParentRemote = try await access.item(at: oldParentPath)
                try validator.validateParent(exists: oldParentRemote.type == .directory)
                try validator.validateMutation(of: sourceRemote.type)
                try validator.validateContents(
                    supplied: changesContents,
                    for: sourceRemote.type
                )

                let current = FileProviderIdentifiedItem(
                    identity: sourceIdentity,
                    parentIdentity: sourceSnapshot?.parentIdentity ?? .root,
                    remoteItem: sourceRemote
                )
                if case .conflict = validator.validateBaseVersion(
                    requested: request.baseVersion,
                    current: current
                ) {
                    if Self.shouldFailOnConflict(request.options) {
                        throw FileProviderModifyMutationError.conflict(current: current)
                    }
                    return FileProviderMutationResult(
                        item: current,
                        stillPendingFields: stillPendingFields,
                        shouldFetchContent: changesContents
                    )
                }
                guard !supportedFields.isEmpty else {
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
                guard destination != sourcePath || changesContents else {
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

                var committed = false
                if changesContents {
                    let temporary = try FileProviderRemotePath(
                        relative: newParentPath.relative.isEmpty
                            ? ".remux-upload-\(nonce().uuidString.lowercased())"
                            : newParentPath.relative + "/.remux-upload-\(nonce().uuidString.lowercased())"
                    )
                    try validator.validateDestination(
                        temporary,
                        occupiedPaths: newParentItems.map(\.path)
                    )
                    do {
                        try await access.uploadFile(
                            from: try request.contentsURL ?? emptyFileURL(),
                            to: temporary,
                            progress: progress
                        )
                        try Task.checkCancellation()
                        try await access.renameItem(from: temporary, to: destination)
                        committed = true
                    } catch {
                        if !committed {
                            await cleanupTemporaryFile(temporary, using: access)
                        }
                        throw error
                    }
                } else {
                    try await access.renameItem(from: sourcePath, to: destination)
                    committed = true
                }

                let sourceRemovalFailed: Bool
                if changesContents && destination != sourcePath {
                    do {
                        try await access.removeFile(at: sourcePath)
                        sourceRemovalFailed = false
                    } catch {
                        sourceRemovalFailed = true
                    }
                } else {
                    sourceRemovalFailed = false
                }
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
                            identityReservations: sourceRemovalFailed
                                ? [.init(identity: .item(identity()), path: sourcePath)]
                                : [],
                            relocations: [
                                .init(identity: sourceIdentity, from: sourcePath, to: destination),
                            ],
                            receipt: .item(key: key, item: moved),
                            queuesWorkingSetSignal: sourceRemovalFailed
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

    func delete(request: FileProviderDeleteRequest) async throws {
        let sourceIdentity = try FileProviderItemIdentifierCodec().identity(for: request.identifier)
        if sourceIdentity == .root {
            throw FileProviderMutationValidationError.rootMutation
        }
        let key = FileProviderMutationReplayKey.delete(
            identity: sourceIdentity,
            contentVersion: request.baseVersion.contentVersion,
            metadataVersion: request.baseVersion.metadataVersion
        )
        if try await snapshots.receipt(for: key) != nil {
            return
        }

        try validator.validateMutablePath(try await snapshots.path(for: request.identifier))

        try await coordinator.performMutation { [remote, snapshots, validator] in
            if try await snapshots.receipt(for: key) != nil {
                return
            }

            let sourcePath = try await snapshots.path(for: request.identifier)
            try validator.validateMutablePath(sourcePath)
            guard let sourceSnapshot = try await snapshots.item(for: request.identifier) else {
                throw FileProviderSnapshotStoreError.itemIdentityNotFound
            }
            let parentPath = sourceSnapshot.remoteItem.parent

            return try await remote.withMutationAccess { access in
                let sourceRemote: FileProviderRemoteItem
                do {
                    sourceRemote = try await access.item(at: sourcePath)
                } catch RemuxSFTPClientError.noSuchFile {
                    return try await finishCommittedMutation {
                        let parentItems = try await access.list(directory: parentPath)
                        _ = try await snapshots.commit(
                            localMutation: FileProviderSnapshotLocalMutation(
                                refreshedDirectories: [
                                    .init(directory: parentPath, items: parentItems),
                                ],
                                deletedIdentities: [sourceIdentity],
                                receipt: .deleted(key: key),
                                queuesWorkingSetSignal: true
                            )
                        )
                    }
                }

                try validator.validateMutation(of: sourceRemote.type)
                let current = FileProviderIdentifiedItem(
                    identity: sourceIdentity,
                    parentIdentity: sourceSnapshot.parentIdentity,
                    remoteItem: sourceRemote
                )
                if case .conflict = validator.validateBaseVersion(
                    requested: request.baseVersion,
                    current: current
                ) {
                    throw FileProviderDeleteMutationError.conflict(current: current)
                }

                if sourceRemote.type == .directory {
                    let children = try await access.list(directory: sourcePath)
                    guard children.isEmpty else {
                        throw FileProviderErrorMapper.directoryNotEmpty
                    }
                    try await access.removeEmptyDirectory(at: sourcePath)
                } else {
                    try await access.removeFile(at: sourcePath)
                }

                return try await finishCommittedMutation {
                    let parentItems = try await access.list(directory: parentPath)
                    _ = try await snapshots.commit(
                        localMutation: FileProviderSnapshotLocalMutation(
                            refreshedDirectories: [
                                .init(directory: parentPath, items: parentItems),
                            ],
                            deletedIdentities: [sourceIdentity],
                            receipt: .deleted(key: key),
                            queuesWorkingSetSignal: true
                        )
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

    private static func shouldFailOnConflict(
        _ options: NSFileProviderModifyItemOptions
    ) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return options.contains(.failOnConflict)
    }
}

private func finishCommittedMutation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await Task.detached(operation: operation).value
}

private func cleanupTemporaryFile(
    _ temporary: FileProviderRemotePath,
    using access: any FileProviderRemoteMutationAccess
) async {
    _ = try? await Task.detached {
        try await access.removeFile(at: temporary)
    }.value
}

private func emptyFileURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: url)
    return url
}
