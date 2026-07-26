import FileProvider
import Foundation

struct FileProviderFetchedContents: @unchecked Sendable {
    let localURL: URL
    let item: FileProviderItemProjection
}

protocol FileProviderEnumeratorInvalidating: AnyObject, Sendable {
    func invalidate()
    func waitUntilInvalidated() async
}

final class FileProviderReplicatedExtensionCore: @unchecked Sendable {
    private let service: any FileProviderRemoteServicing
    private let rootDisplayName: String
    private let snapshots: FileProviderSnapshotStore
    private let mutations: FileProviderMutationCore
    private let temporaryDirectoryURL: @Sendable () throws -> URL
    private let requests: FileProviderRequestController
    private let lifecycleLock = NSLock()
    private var enumerators: [
        ObjectIdentifier: FileProviderWeakEnumerator
    ] = [:]
    private var isInvalidated = false

    init(
        service: any FileProviderRemoteServicing,
        snapshots: FileProviderSnapshotStore,
        rootDisplayName: String,
        temporaryDirectoryURL: @escaping @Sendable () throws -> URL,
        coordinator: FileProviderDomainOperationCoordinator = FileProviderDomainOperationCoordinator(),
        requests: FileProviderRequestController = FileProviderRequestController()
    ) {
        self.service = service
        self.snapshots = snapshots
        self.mutations = FileProviderMutationCore(
            remote: service,
            snapshots: snapshots,
            coordinator: coordinator
        )
        self.rootDisplayName = rootDisplayName
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.requests = requests
    }

    func createItem(
        request: FileProviderCreateRequest,
        completion: @escaping @Sendable (
            Result<FileProviderMutationResult, NSError>
        ) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: mapMutationError,
            progressOperation: { progress in
                let result = try await self.mutations.create(request: request) { bytes in
                    progress.completedUnitCount = bytes
                }
                if progress.totalUnitCount <= 0 {
                    progress.totalUnitCount = max(progress.completedUnitCount, 1)
                }
                progress.completedUnitCount = progress.totalUnitCount
                return result
            },
            preserveResultAfterCancellation: true,
            completion: completion
        )
    }

    func modifyItem(
        request: FileProviderModifyRequest,
        completion: @escaping @Sendable (
            Result<FileProviderMutationResult, NSError>
        ) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: mapMutationError,
            progressOperation: { progress in
                let result = try await self.mutations.modify(request: request) { bytes in
                    progress.completedUnitCount = bytes
                }
                if progress.totalUnitCount <= 0 {
                    progress.totalUnitCount = max(progress.completedUnitCount, 1)
                }
                progress.completedUnitCount = progress.totalUnitCount
                return result
            },
            preserveResultAfterCancellation: true,
            completion: completion
        )
    }

    func deleteItem(
        request: FileProviderDeleteRequest,
        completion: @escaping @Sendable (Result<Void, NSError>) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: mapMutationError,
            progressOperation: { _ in
                try await self.mutations.delete(request: request)
            },
            preserveResultAfterCancellation: true,
            completion: completion
        )
    }

    func failedMutation(
        error: Error,
        completion: @escaping @Sendable (NSError) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: mapMutationError,
            operation: {
                throw error
            },
            completion: { result in
                guard case .failure(let error) = result else { return }
                completion(error)
            }
        )
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        completion: @escaping @Sendable (Result<FileProviderItemProjection, NSError>) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: {
                FileProviderErrorMapper.map($0, itemIdentifier: identifier)
            },
            operation: {
                let path = try await self.snapshots.path(for: identifier)
                let remoteItem = try await self.service.item(at: path)
                let item: FileProviderIdentifiedItem
                if identifier == .rootContainer {
                    item = FileProviderIdentifiedItem(
                        identity: .root,
                        parentIdentity: .root,
                        remoteItem: remoteItem
                    )
                } else if let identified = try await self.snapshots.item(for: identifier) {
                    item = FileProviderIdentifiedItem(
                        identity: identified.identity,
                        parentIdentity: identified.parentIdentity,
                        remoteItem: remoteItem
                    )
                } else {
                    throw FileProviderSnapshotStoreError.itemIdentityNotFound
                }
                return FileProviderItemProjection(
                    item: item,
                    rootDisplayName: self.rootDisplayName
                )
            },
            completion: completion
        )
    }

    func fetchContents(
        for identifier: NSFileProviderItemIdentifier,
        completion: @escaping @Sendable (Result<FileProviderFetchedContents, NSError>) -> Void
    ) -> Progress {
        requests.perform(
            errorMapper: {
                FileProviderErrorMapper.map($0, itemIdentifier: identifier)
            },
            progressOperation: { progress in
                let path = try await self.snapshots.path(for: identifier)
                let identified = try await self.snapshots.item(for: identifier)
                let temporaryDirectory = try self.temporaryDirectoryURL()
                let localURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)

                do {
                    let remoteItem = try await self.service.fetch(
                        path: path,
                        to: localURL,
                        progress: { remoteProgress in
                            progress.totalUnitCount = remoteProgress.totalByteCount
                            progress.completedUnitCount = remoteProgress.completedByteCount
                        }
                    )
                    if progress.totalUnitCount <= 0 {
                        progress.totalUnitCount = max(progress.completedUnitCount, 1)
                    }
                    progress.completedUnitCount = progress.totalUnitCount
                    return FileProviderFetchedContents(
                        localURL: localURL,
                        item: FileProviderItemProjection(
                            item: try self.identifiedItem(
                                identifier: identifier,
                                identified: identified,
                                remoteItem: remoteItem
                            ),
                            rootDisplayName: self.rootDisplayName
                        )
                    )
                } catch {
                    try? FileManager.default.removeItem(at: localURL)
                    throw error
                }
            },
            discardResult: { fetched in
                try? FileManager.default.removeItem(at: fetched.localURL)
            },
            completion: completion
        )
    }

    private func identifiedItem(
        identifier: NSFileProviderItemIdentifier,
        identified: FileProviderIdentifiedItem?,
        remoteItem: FileProviderRemoteItem
    ) throws -> FileProviderIdentifiedItem {
        if identifier == .rootContainer {
            return FileProviderIdentifiedItem(
                identity: .root,
                parentIdentity: .root,
                remoteItem: remoteItem
            )
        }
        guard let identified else {
            throw FileProviderSnapshotStoreError.itemIdentityNotFound
        }
        return FileProviderIdentifiedItem(
            identity: identified.identity,
            parentIdentity: identified.parentIdentity,
            remoteItem: remoteItem
        )
    }

    func registerEnumerator(
        _ enumerator: any FileProviderEnumeratorInvalidating
    ) -> Bool {
        let didRegister = lifecycleLock.withLock {
            enumerators = enumerators.filter { $0.value.value != nil }
            guard !isInvalidated else { return false }
            enumerators[ObjectIdentifier(enumerator)] = FileProviderWeakEnumerator(
                enumerator
            )
            return true
        }
        if !didRegister {
            enumerator.invalidate()
        }
        return didRegister
    }

    func invalidate() {
        let enumerators: [any FileProviderEnumeratorInvalidating]? =
            lifecycleLock.withLock {
                guard !isInvalidated else { return nil }
                isInvalidated = true
                let enumerators = self.enumerators.values.compactMap(\.value)
                self.enumerators.removeAll()
                return enumerators
            }
        guard let enumerators else { return }

        enumerators.forEach { $0.invalidate() }
        let service = service
        requests.invalidate {
            for enumerator in enumerators {
                await enumerator.waitUntilInvalidated()
            }
            await service.invalidate()
        }
    }

    private func mapMutationError(_ error: Error) -> NSError {
        if let createError = error as? FileProviderCreateMutationError {
            return switch createError {
            case .collision(let existing):
                FileProviderErrorMapper.filenameCollision(
                    existingItem: FileProviderSDKItem(
                        item: existing,
                        rootDisplayName: rootDisplayName
                    )
                )
            }
        }
        if let modifyError = error as? FileProviderModifyMutationError {
            return switch modifyError {
            case .conflict(let current):
                FileProviderErrorMapper.filenameCollision(
                    existingItem: FileProviderSDKItem(
                        item: current,
                        rootDisplayName: rootDisplayName
                    )
                )
            }
        }
        if let deleteError = error as? FileProviderDeleteMutationError {
            return switch deleteError {
            case .conflict(let current):
                FileProviderErrorMapper.deletionRejected(
                    updatedItem: FileProviderSDKItem(
                        item: current,
                        rootDisplayName: rootDisplayName
                    )
                )
            }
        }
        if error as? FileProviderMutationValidationError == .symbolicLinkMutation {
            return FileProviderErrorMapper.cannotSynchronize
        }
        return FileProviderErrorMapper.map(error)
    }
}

private final class FileProviderWeakEnumerator: @unchecked Sendable {
    weak var value: (any FileProviderEnumeratorInvalidating)?

    init(_ value: any FileProviderEnumeratorInvalidating) {
        self.value = value
    }
}
