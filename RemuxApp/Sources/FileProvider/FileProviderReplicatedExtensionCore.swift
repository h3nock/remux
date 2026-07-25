import FileProvider
import Foundation

struct FileProviderFetchedContents: @unchecked Sendable {
    let localURL: URL
    let item: FileProviderItemProjection
}

final class FileProviderReplicatedExtensionCore: @unchecked Sendable {
    private let service: any FileProviderRemoteServicing
    private let rootDisplayName: String
    private let temporaryDirectoryURL: @Sendable () throws -> URL
    private let requests: FileProviderRequestController
    private let identifierCodec = FileProviderItemIdentifierCodec()

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
            operation: {
                let path = try self.identifierCodec.path(for: identifier)
                let temporaryDirectory = try self.temporaryDirectoryURL()
                let localURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)

                do {
                    let item = try await self.service.fetch(
                        path: path,
                        to: localURL,
                        progress: { _ in }
                    )
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

    func invalidate() {
        let service = service
        requests.invalidate {
            await service.invalidate()
        }
    }
}
