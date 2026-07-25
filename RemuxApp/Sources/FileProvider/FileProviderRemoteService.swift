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
            let canonicalDirectory = try await canonicalDirectory(
                for: directory,
                client: client,
                home: canonicalHome
            )
            let entries = try await client.listDirectory(atPath: canonicalDirectory)
            var items: [FileProviderRemoteItem] = []

            for entry in entries {
                guard let path = childPath(named: entry.name, beneath: directory) else {
                    continue
                }

                switch entry.metadata.type {
                case .other:
                    continue
                case .symbolicLink:
                    let canonicalEntry = try append(
                        component: entry.name,
                        to: canonicalDirectory
                    )
                    guard let canonicalTarget = try? await client.realPath(atPath: canonicalEntry),
                          let relativeTarget = try? safeLinkResolver.resolve(
                              canonicalTarget,
                              home: canonicalHome,
                              for: path
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
            let entry = if path == .root {
                canonicalHome
            } else {
                try await canonicalEntry(
                    for: path,
                    client: client,
                    home: canonicalHome
                )
            }
            let metadata = if path == .root {
                try await client.metadata(atPath: entry)
            } else {
                try await client.linkMetadata(atPath: entry)
            }

            switch metadata.type {
            case .regular, .directory:
                return try FileProviderRemoteItem(path: path, metadata: metadata)
            case .symbolicLink:
                do {
                    let canonicalTarget = try await client.realPath(atPath: entry)
                    let relativeTarget = try safeLinkResolver.resolve(
                        canonicalTarget,
                        home: canonicalHome,
                        for: path
                    )
                    return try FileProviderRemoteItem(
                        path: path,
                        metadata: metadata,
                        symlinkTargetRelativePath: relativeTarget
                    )
                } catch {
                    throw RemuxSFTPClientError.noSuchFile(path.relative)
                }
            case .other:
                throw RemuxSFTPClientError.noSuchFile(path.relative)
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
            let entry = try await canonicalEntry(
                for: path,
                client: client,
                home: canonicalHome
            )
            let metadata = try await client.linkMetadata(atPath: entry)
            guard metadata.type == .regular else {
                throw RemuxSFTPClientError.noSuchFile(path.relative)
            }
            let canonicalEntry = try await client.realPath(atPath: entry)
            try safeLinkResolver.ensureContained(
                canonicalEntry,
                home: canonicalHome
            )
            try await client.downloadFile(
                atPath: canonicalEntry,
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

    private func canonicalDirectory(
        for directory: FileProviderRemotePath,
        client: any RemuxSFTPReadOnlyClient,
        home canonicalHome: String
    ) async throws -> String {
        let requestedDirectory = try directory.remotePath(
            beneath: canonicalHome
        )
        guard directory != .root else {
            return requestedDirectory
        }

        let canonicalDirectory = try await client.realPath(
            atPath: requestedDirectory
        )
        try safeLinkResolver.ensureContained(
            canonicalDirectory,
            home: canonicalHome
        )
        return canonicalDirectory
    }

    private func canonicalEntry(
        for path: FileProviderRemotePath,
        client: any RemuxSFTPReadOnlyClient,
        home canonicalHome: String
    ) async throws -> String {
        guard path != .root,
              let name = path.relative.split(separator: "/").last.map(String.init)
        else {
            return canonicalHome
        }

        let parentRelative = (path.relative as NSString)
            .deletingLastPathComponent
        let parent = try FileProviderRemotePath(relative: parentRelative)
        let canonicalParent = try await canonicalDirectory(
            for: parent,
            client: client,
            home: canonicalHome
        )
        return try append(component: name, to: canonicalParent)
    }

    private func append(
        component: String,
        to canonicalDirectory: String
    ) throws -> String {
        try FileProviderPathValidation.validateCanonicalAbsolute(
            canonicalDirectory
        )
        guard isValidChildName(component) else {
            throw FileProviderRemotePathError.invalidRelativePath
        }
        guard canonicalDirectory != "/" else {
            return "/\(component)"
        }
        return "\(canonicalDirectory)/\(component)"
    }

    private func childPath(
        named name: String,
        beneath directory: FileProviderRemotePath
    ) -> FileProviderRemotePath? {
        guard isValidChildName(name) else {
            return nil
        }
        let relative = directory.relative.isEmpty ? name : "\(directory.relative)/\(name)"
        return try? FileProviderRemotePath(relative: relative)
    }

    private func isValidChildName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }
}
