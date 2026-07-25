import Foundation

enum FileProviderRemoteServiceError: Error, Equatable, Sendable {
    case invalidDomainIdentifier
    case serverNotFound
}

protocol FileProviderSFTPClientProviding: Sendable {
    func withClient<Value: Sendable>(
        server: SavedServer,
        authentication: ResolvedSSHAuth,
        operation: @Sendable (any RemuxSFTPReadOnlyClient) async throws -> Value
    ) async throws -> Value

    func closeIdleConnections(forServerID serverID: SavedServer.ID) async
}

protocol FileProviderRemoteServicing: Sendable {
    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem]
    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderRemoteItem
    func invalidate() async
}

struct FileProviderRemoteService: FileProviderRemoteServicing {
    private let domainIdentifier: String
    private let profiles: any ConnectionProfileRepository
    private let credentials: any SSHCredentialStore
    private let clientProvider: any FileProviderSFTPClientProviding
    private let safeLinkResolver = FileProviderSafeLinkResolver()

    init(
        domainIdentifier: String,
        profiles: any ConnectionProfileRepository,
        credentials: any SSHCredentialStore,
        clientProvider: any FileProviderSFTPClientProviding
    ) {
        self.domainIdentifier = domainIdentifier
        self.profiles = profiles
        self.credentials = credentials
        self.clientProvider = clientProvider
    }

    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem] {
        try await withClient { client in
            let canonicalHome = try await client.realPath(atPath: ".")
            let remoteDirectory = try directory.remotePath(beneath: canonicalHome)
            let entries = try await client.listDirectory(atPath: remoteDirectory)
            var items: [FileProviderRemoteItem] = []

            for entry in entries {
                guard let path = childPath(named: entry.name, beneath: directory) else {
                    continue
                }

                switch entry.metadata.type {
                case .other:
                    continue
                case .symbolicLink:
                    let remotePath = try path.remotePath(beneath: canonicalHome)
                    guard let canonicalTarget = try? await client.realPath(atPath: remotePath),
                          let relativeTarget = try? safeLinkResolver.resolve(
                              canonicalTarget,
                              home: canonicalHome
                          )
                    else {
                        continue
                    }
                    items.append(
                        try FileProviderRemoteItem(
                            path: path,
                            metadata: entry.metadata,
                            symlinkTargetRelativePath: relativeTarget
                        )
                    )
                case .regular, .directory:
                    items.append(
                        try FileProviderRemoteItem(path: path, metadata: entry.metadata)
                    )
                }
            }

            return items
        }
    }

    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem {
        try await withClient { client in
            let canonicalHome = try await client.realPath(atPath: ".")
            let remotePath = try path.remotePath(beneath: canonicalHome)
            let metadata = if path == .root {
                try await client.metadata(atPath: remotePath)
            } else {
                try await client.linkMetadata(atPath: remotePath)
            }

            switch metadata.type {
            case .regular, .directory:
                return try FileProviderRemoteItem(path: path, metadata: metadata)
            case .symbolicLink:
                do {
                    let canonicalTarget = try await client.realPath(atPath: remotePath)
                    let relativeTarget = try safeLinkResolver.resolve(
                        canonicalTarget,
                        home: canonicalHome
                    )
                    return try FileProviderRemoteItem(
                        path: path,
                        metadata: metadata,
                        symlinkTargetRelativePath: relativeTarget
                    )
                } catch {
                    throw RemuxSFTPClientError.noSuchFile(remotePath)
                }
            case .other:
                throw RemuxSFTPClientError.noSuchFile(remotePath)
            }
        }
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> FileProviderRemoteItem {
        try await withClient { client in
            try Task.checkCancellation()
            let canonicalHome = try await client.realPath(atPath: ".")
            let remotePath = try path.remotePath(beneath: canonicalHome)
            let metadata = try await client.linkMetadata(atPath: remotePath)
            guard metadata.type == .regular else {
                throw RemuxSFTPClientError.noSuchFile(remotePath)
            }
            try await client.downloadFile(
                atPath: remotePath,
                to: localURL,
                progress: progress
            )
            return try FileProviderRemoteItem(path: path, metadata: metadata)
        }
    }

    func invalidate() async {
        guard let serverID = UUID(uuidString: domainIdentifier) else {
            return
        }
        await clientProvider.closeIdleConnections(forServerID: serverID)
    }

    private func withClient<Value: Sendable>(
        _ operation: @Sendable (any RemuxSFTPReadOnlyClient) async throws -> Value
    ) async throws -> Value {
        let snapshot = try await profiles.loadSnapshot()
        guard let serverID = UUID(uuidString: domainIdentifier) else {
            throw FileProviderRemoteServiceError.invalidDomainIdentifier
        }
        guard let server = snapshot.servers.first(where: { $0.id == serverID }) else {
            throw FileProviderRemoteServiceError.serverNotFound
        }
        let authentication = try await SSHAuthResolver(credentialStore: credentials)
            .resolve(server: server, in: snapshot)
        return try await clientProvider.withClient(
            server: server,
            authentication: authentication,
            operation: operation
        )
    }

    private func childPath(
        named name: String,
        beneath directory: FileProviderRemotePath
    ) -> FileProviderRemotePath? {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0")
        else {
            return nil
        }
        let relative = directory.relative.isEmpty ? name : "\(directory.relative)/\(name)"
        return try? FileProviderRemotePath(relative: relative)
    }
}
