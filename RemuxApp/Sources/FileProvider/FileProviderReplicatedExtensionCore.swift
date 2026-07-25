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
    private let temporaryDirectoryURL: @Sendable () throws -> URL
    private let requests: FileProviderRequestController
    private let identifierCodec = FileProviderItemIdentifierCodec()
    private let lifecycleLock = NSLock()
    private var enumerators: [
        ObjectIdentifier: FileProviderWeakEnumerator
    ] = [:]
    private var isInvalidated = false

    init(
        service: any FileProviderRemoteServicing,
        rootDisplayName: String,
        temporaryDirectoryURL: @escaping @Sendable () throws -> URL,
        requests: FileProviderRequestController = FileProviderRequestController()
    ) {
        self.service = service
        self.rootDisplayName = rootDisplayName
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.requests = requests
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
                let path = try self.identifierCodec.path(for: identifier)
                let item = try await self.service.item(at: path)
                return FileProviderItemProjection(
                    remoteItem: item,
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
                let path = try self.identifierCodec.path(for: identifier)
                let temporaryDirectory = try self.temporaryDirectoryURL()
                let localURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)

                do {
                    let item = try await self.service.fetch(
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
                            remoteItem: item,
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

    func rejectMutation(
        completion: (NSError) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completion(FileProviderReadOnlyMutationPolicy.rejection)
        progress.completedUnitCount = 1
        return progress
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
}

private final class FileProviderWeakEnumerator: @unchecked Sendable {
    weak var value: (any FileProviderEnumeratorInvalidating)?

    init(_ value: any FileProviderEnumeratorInvalidating) {
        self.value = value
    }
}
