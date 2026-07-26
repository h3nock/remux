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
                completion.value(FileProviderSDKItem(projection: projection), nil)
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
                    FileProviderSDKItem(projection: fetched.item),
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
        guard let setup else {
            return completedFailure {
                completionHandler(nil, [], false, initializationError)
            }
        }
        let completion = RemuxFileProviderExtensionUncheckedSendable(value: completionHandler)
        let rootDisplayName = domain.displayName
        do {
            let mutation = try FileProviderSDKRequestAdapter.createRequest(
                itemTemplate: itemTemplate,
                fields: fields,
                contentsURL: url,
                options: options
            )
            return setup.extensionCore.createItem(request: mutation) { result in
                switch result {
                case .success(let result):
                    completion.value(
                        FileProviderSDKItem(
                            item: result.item,
                            rootDisplayName: rootDisplayName
                        ),
                        result.stillPendingFields,
                        result.shouldFetchContent,
                        nil
                    )
                case .failure(let error):
                    completion.value(nil, [], false, error)
                }
            }
        } catch {
            return setup.extensionCore.failedMutation(error: error) { error in
                completion.value(nil, [], false, error)
            }
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
        guard let setup else {
            return completedFailure {
                completionHandler(nil, [], false, initializationError)
            }
        }
        let completion = RemuxFileProviderExtensionUncheckedSendable(value: completionHandler)
        let rootDisplayName = domain.displayName
        let mutation = FileProviderSDKRequestAdapter.modifyRequest(
            item: item,
            baseVersion: version,
            changedFields: changedFields,
            contentsURL: newContents,
            options: options
        )
        return setup.extensionCore.modifyItem(request: mutation) { result in
            switch result {
            case .success(let result):
                completion.value(
                    FileProviderSDKItem(
                        item: result.item,
                        rootDisplayName: rootDisplayName
                    ),
                    result.stillPendingFields,
                    result.shouldFetchContent,
                    nil
                )
            case .failure(let error):
                completion.value(nil, [], false, error)
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard let setup else {
            return completedFailure {
                completionHandler(initializationError)
            }
        }
        let completion = RemuxFileProviderExtensionUncheckedSendable(value: completionHandler)
        let mutation = FileProviderSDKRequestAdapter.deleteRequest(
            identifier: identifier,
            baseVersion: version,
            options: options
        )
        return setup.extensionCore.deleteItem(request: mutation) { result in
            completion.value(result.failureValue)
        }
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

        let scope: FileProviderEnumeratorScope
        if containerItemIdentifier == .workingSet {
            scope = .workingSet
        } else {
            do {
                scope = .directory(
                    try setup.snapshots.pathSynchronously(
                        for: containerItemIdentifier
                    )
                )
            } catch {
                throw FileProviderErrorMapper.map(
                    error,
                    itemIdentifier: containerItemIdentifier
                )
            }
        }

        let enumerator = RemuxFileProviderEnumerator(
            core: FileProviderEnumeratorCore(
                scope: scope,
                service: setup.service,
                snapshots: setup.snapshots,
                coordinator: setup.operationCoordinator,
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

    private func completedFailure(_ completion: () -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completion()
        progress.completedUnitCount = 1
        return progress
    }
}

private extension Result where Failure == NSError {
    var failureValue: NSError? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

private final class RemuxFileProviderExtensionSetup: @unchecked Sendable {
    let service: FileProviderRemoteService
    let snapshots: FileProviderSnapshotStore
    let operationCoordinator = FileProviderDomainOperationCoordinator()
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
            snapshots: snapshots,
            rootDisplayName: domain.displayName,
            temporaryDirectoryURL: {
                try signaler.temporaryDirectoryURL()
            },
            coordinator: operationCoordinator
        )
    }
}

private enum RemuxFileProviderExtensionInitializationError: Error {
    case managerUnavailable
}

private struct RemuxFileProviderExtensionUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
