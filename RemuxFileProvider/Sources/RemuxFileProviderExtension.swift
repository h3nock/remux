import FileProvider
import Foundation

final class RemuxFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let setup: RemuxFileProviderExtensionSetup?
    private let initializationError: NSError?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain

        do {
            self.setup = try RemuxFileProviderExtensionSetup(domain: domain)
            self.initializationError = nil
        } catch {
            self.setup = nil
            self.initializationError = FileProviderErrorMapper.map(error)
        }

        super.init()
    }

    func invalidate() {
        setup?.extensionCore.invalidate()
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let setup else {
            return completedFailure {
                completionHandler(nil, initializationError)
            }
        }
        let completion = RemuxFileProviderExtensionUncheckedSendable(value: completionHandler)
        return setup.extensionCore.item(for: identifier) { result in
            switch result {
            case .success(let projection):
                completion.value(RemuxFileProviderItem(projection: projection), nil)
            case .failure(let error):
                completion.value(nil, error)
            }
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let setup else {
            return completedFailure {
                completionHandler(nil, nil, initializationError)
            }
        }
        let completion = RemuxFileProviderExtensionUncheckedSendable(value: completionHandler)
        return setup.extensionCore.fetchContents(for: itemIdentifier) { result in
            switch result {
            case .success(let fetched):
                completion.value(
                    fetched.localURL,
                    RemuxFileProviderItem(projection: fetched.item),
                    nil
                )
            case .failure(let error):
                completion.value(nil, nil, error)
            }
        }
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        rejectMutation { error in
            completionHandler(nil, [], false, error)
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        rejectMutation { error in
            completionHandler(nil, [], false, error)
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        rejectMutation(completionHandler)
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        guard let setup else {
            throw initializationError ?? FileProviderErrorMapper.map(
                RemuxFileProviderExtensionInitializationError.managerUnavailable
            )
        }

        let path: FileProviderRemotePath
        if containerItemIdentifier == .workingSet {
            path = .root
        } else {
            do {
                path = try FileProviderItemIdentifierCodec()
                    .path(for: containerItemIdentifier)
            } catch {
                throw FileProviderErrorMapper.map(
                    error,
                    itemIdentifier: containerItemIdentifier
                )
            }
        }

        let enumerator = RemuxFileProviderEnumerator(
            core: FileProviderEnumeratorCore(
                directory: path,
                service: setup.service,
                snapshots: setup.snapshots,
                coordinator: setup.pollingCoordinator,
                signaler: setup.signaler
            ),
            rootDisplayName: domain.displayName
        )
        guard setup.extensionCore.registerEnumerator(enumerator) else {
            throw FileProviderErrorMapper.map(
                CancellationError(),
                itemIdentifier: containerItemIdentifier
            )
        }
        enumerator.start()
        return enumerator
    }

    private func rejectMutation(
        _ completion: (NSError) -> Void
    ) -> Progress {
        if let setup {
            return setup.extensionCore.rejectMutation(completion: completion)
        }
        return completedFailure {
            completion(FileProviderReadOnlyMutationPolicy.rejection)
        }
    }

    private func completedFailure(_ completion: () -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completion()
        progress.completedUnitCount = 1
        return progress
    }
}

private final class RemuxFileProviderExtensionSetup: @unchecked Sendable {
    let service: FileProviderRemoteService
    let snapshots: FileProviderSnapshotStore
    let pollingCoordinator = FileProviderPollingCoordinator()
    let signaler: RemuxFileProviderManagerSignaler
    let extensionCore: FileProviderReplicatedExtensionCore

    init(domain: NSFileProviderDomain) throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw RemuxFileProviderExtensionInitializationError.managerUnavailable
        }

        let sharedRoot = try ApplicationStorage.sharedRemuxRoot()
        let accessGroup = try FileProviderSharedConfiguration.keychainAccessGroup()
        let profiles = FileBackedConnectionProfileRepository(rootURL: sharedRoot)
        let credentials = KeychainSSHCredentialStore(accessGroup: accessGroup)
        let trustedHosts = TrustedHostStore(rootURL: sharedRoot)
        let service = FileProviderRemoteService(
            domainIdentifier: domain.identifier.rawValue,
            profiles: profiles,
            credentials: credentials,
            clientProvider: FileProviderCitadelSFTPClientProvider(
                sshRootService: RemuxSSHRootService(),
                trustedHosts: trustedHosts
            )
        )

        self.service = service
        self.snapshots = FileProviderSnapshotStore(
            rootURL: sharedRoot
                .appendingPathComponent("file-provider-snapshots", isDirectory: true)
                .appendingPathComponent(domain.identifier.rawValue, isDirectory: true)
        )
        let signaler = RemuxFileProviderManagerSignaler(manager: manager)
        self.signaler = signaler
        self.extensionCore = FileProviderReplicatedExtensionCore(
            service: service,
            rootDisplayName: domain.displayName,
            temporaryDirectoryURL: {
                try signaler.temporaryDirectoryURL()
            }
        )
    }
}

private enum RemuxFileProviderExtensionInitializationError: Error {
    case managerUnavailable
}

private struct RemuxFileProviderExtensionUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
