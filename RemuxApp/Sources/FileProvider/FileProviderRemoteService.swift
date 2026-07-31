import Foundation

enum FileProviderRemoteServiceError: Error, Equatable, Sendable {
    case invalidDomainIdentifier
    case serverNotFound
}

protocol FileProviderSFTPClientProviding: Sendable {
    func withClient<Value: Sendable>(
        server: SavedServer,
        authentication: ResolvedSSHAuth,
        operation: @Sendable (any RemuxSFTPFileProviderClient) async throws -> Value
    ) async throws -> Value

    func closeIdleConnections(forServerID serverID: SavedServer.ID) async
}

struct FileProviderRemoteFetchProgress: Equatable, Sendable {
    let totalByteCount: Int64
    let completedByteCount: Int64
}

protocol FileProviderRemoteMutationAccess: Sendable {
    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem]
    func createDirectory(at path: FileProviderRemotePath) async throws
    func uploadFile(
        from localURL: URL,
        to path: FileProviderRemotePath,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws
    func renameItem(
        from source: FileProviderRemotePath,
        to destination: FileProviderRemotePath
    ) async throws
    func removeFile(at path: FileProviderRemotePath) async throws
    func removeEmptyDirectory(at path: FileProviderRemotePath) async throws
}

protocol FileProviderRemoteServicing: Sendable {
    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem
    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem]
    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem
    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) async throws -> Value
    func invalidate() async
}

struct FileProviderRemoteService: FileProviderRemoteServicing {
    private let domainIdentifier: String
    private let profiles: any ConnectionProfileRepository
    private let credentials: any SSHCredentialStore
    private let clientProvider: any FileProviderSFTPClientProviding

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
        try await withAccess { access in
            try await access.list(directory: directory)
        }
    }

    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem {
        try await withAccess { access in
            try await access.item(at: path)
        }
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        try await withAccess { access in
            try await access.fetch(path: path, to: localURL, progress: progress)
        }
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) async throws -> Value {
        try await withAccess { access in
            try await operation(access)
        }
    }

    func invalidate() async {
        guard let serverID = UUID(uuidString: domainIdentifier) else {
            return
        }
        await clientProvider.closeIdleConnections(forServerID: serverID)
    }

    private func withAccess<Value: Sendable>(
        _ operation: @Sendable (
            FileProviderSFTPOperation
        ) async throws -> Value
    ) async throws -> Value {
        try await withClient { client in
            try Task.checkCancellation()
            let canonicalHome = try await client.realPath(atPath: ".")
            let access = try FileProviderSFTPOperation(
                client: client,
                canonicalHome: canonicalHome
            )
            return try await operation(access)
        }
    }

    private func withClient<Value: Sendable>(
        _ operation: @Sendable (any RemuxSFTPFileProviderClient) async throws -> Value
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
}

private struct FileProviderSFTPOperation: FileProviderRemoteMutationAccess {
    private let client: any RemuxSFTPFileProviderClient
    private let canonicalHome: String
    private let safeLinkResolver = FileProviderSafeLinkResolver()

    init(
        client: any RemuxSFTPFileProviderClient,
        canonicalHome: String
    ) throws {
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalHome)
        self.client = client
        self.canonicalHome = canonicalHome
    }

    func item(at path: FileProviderRemotePath) async throws -> FileProviderRemoteItem {
        try Task.checkCancellation()
        let entry = try await existingPath(for: path)
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

    func list(directory: FileProviderRemotePath) async throws -> [FileProviderRemoteItem] {
        try Task.checkCancellation()
        let canonicalDirectory = try await canonicalDirectory(for: directory)
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
                items.append(try FileProviderRemoteItem(path: path, metadata: entry.metadata))
            }
        }

        return items
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        try Task.checkCancellation()
        let entry = try await existingPath(for: path)
        let metadata = try await client.linkMetadata(atPath: entry)
        guard metadata.type == .regular else {
            throw RemuxSFTPClientError.noSuchFile(path.relative)
        }
        let totalByteCount = metadata.size.map(Int64.init(clamping:)) ?? -1
        await progress(
            FileProviderRemoteFetchProgress(
                totalByteCount: totalByteCount,
                completedByteCount: 0
            )
        )
        let canonicalEntry = try await client.realPath(atPath: entry)
        try safeLinkResolver.ensureContained(
            canonicalEntry,
            home: canonicalHome
        )
        try await client.downloadFile(
            atPath: canonicalEntry,
            to: localURL,
            progress: { completedByteCount in
                await progress(
                    FileProviderRemoteFetchProgress(
                        totalByteCount: totalByteCount,
                        completedByteCount: completedByteCount
                    )
                )
            }
        )
        return try FileProviderRemoteItem(path: path, metadata: metadata)
    }

    func createDirectory(at path: FileProviderRemotePath) async throws {
        try Task.checkCancellation()
        let destination = try await destinationPath(for: path)
        try Task.checkCancellation()
        try await client.createDirectory(atPath: destination)
    }

    func uploadFile(
        from localURL: URL,
        to path: FileProviderRemotePath,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let destination = try await destinationPath(for: path)
        try Task.checkCancellation()
        try await client.uploadFile(
            from: localURL,
            to: destination,
            progress: progress
        )
    }

    func renameItem(
        from source: FileProviderRemotePath,
        to destination: FileProviderRemotePath
    ) async throws {
        try Task.checkCancellation()
        let sourcePath = try await mutationSourcePath(for: source)
        let destinationPath = try await destinationPath(for: destination)
        try Task.checkCancellation()
        try await client.renameItem(
            from: sourcePath,
            to: destinationPath
        )
    }

    func removeFile(at path: FileProviderRemotePath) async throws {
        try Task.checkCancellation()
        let sourcePath = try await mutationSourcePath(for: path)
        try Task.checkCancellation()
        try await client.removeFile(atPath: sourcePath)
    }

    func removeEmptyDirectory(at path: FileProviderRemotePath) async throws {
        try Task.checkCancellation()
        let sourcePath = try await mutationSourcePath(for: path)
        try Task.checkCancellation()
        try await client.removeEmptyDirectory(atPath: sourcePath)
    }

    private func destinationPath(for path: FileProviderRemotePath) async throws -> String {
        guard path != .root,
              let name = path.relative.split(separator: "/").last.map(String.init)
        else {
            throw FileProviderRemotePathError.invalidRelativePath
        }
        let parent = try FileProviderRemotePath(
            relative: (path.relative as NSString).deletingLastPathComponent
        )
        return try append(component: name, to: try await canonicalDirectory(for: parent))
    }

    private func mutationSourcePath(for path: FileProviderRemotePath) async throws -> String {
        guard path != .root else {
            throw FileProviderRemotePathError.invalidRelativePath
        }
        let entry = try await existingPath(for: path)
        let metadata = try await client.linkMetadata(atPath: entry)
        guard metadata.type != .symbolicLink, metadata.type != .other else {
            throw RemuxSFTPClientError.noSuchFile(path.relative)
        }
        return entry
    }

    private func existingPath(for path: FileProviderRemotePath) async throws -> String {
        guard path != .root,
              let name = path.relative.split(separator: "/").last.map(String.init)
        else {
            return canonicalHome
        }
        let parent = try FileProviderRemotePath(
            relative: (path.relative as NSString).deletingLastPathComponent
        )
        return try append(component: name, to: try await canonicalDirectory(for: parent))
    }

    private func canonicalDirectory(for directory: FileProviderRemotePath) async throws -> String {
        guard directory != .root else { return canonicalHome }
        let requested = try directory.remotePath(beneath: canonicalHome)
        let canonical = try await client.realPath(atPath: requested)
        try safeLinkResolver.ensureContained(canonical, home: canonicalHome)
        return canonical
    }

    private func append(component: String, to directory: String) throws -> String {
        try FileProviderPathValidation.validateCanonicalAbsolute(directory)
        guard isValidChildName(component) else {
            throw FileProviderRemotePathError.invalidRelativePath
        }
        return directory == "/" ? "/\(component)" : "\(directory)/\(component)"
    }

    private func childPath(
        named name: String,
        beneath directory: FileProviderRemotePath
    ) -> FileProviderRemotePath? {
        guard isValidChildName(name) else { return nil }
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
