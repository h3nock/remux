import FileProvider
import Foundation

final class RemuxFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let core: FileProviderEnumeratorCore
    private let rootDisplayName: String
    private let requests = FileProviderRequestController()
    private let polling: FileProviderPollingLoop

    init(
        core: FileProviderEnumeratorCore,
        rootDisplayName: String
    ) {
        self.core = core
        self.rootDisplayName = rootDisplayName
        self.polling = FileProviderPollingLoop {
            try await core.refreshAndSignalChanges()
        }
        super.init()
        polling.start()
    }

    func invalidate() {
        polling.invalidate()
        requests.invalidate()
    }

    func enumerateItems(
        for observer: any NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let observer = RemuxFileProviderUncheckedSendable(value: observer)
        let core = core
        let rootDisplayName = rootDisplayName
        _ = requests.perform(
            operation: {
                try await core.enumerateItems()
            },
            completion: { result in
                switch result {
                case .success(let enumeration):
                    observer.value.didEnumerate(
                        enumeration.items.map {
                            RemuxFileProviderItem(
                                projection: FileProviderItemProjection(
                                    remoteItem: $0,
                                    rootDisplayName: rootDisplayName
                                )
                            )
                        }
                    )
                    observer.value.finishEnumerating(upTo: enumeration.nextPage)
                case .failure(let error):
                    observer.value.finishEnumeratingWithError(error)
                }
            }
        )
    }

    func enumerateChanges(
        for observer: any NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        let observer = RemuxFileProviderUncheckedSendable(value: observer)
        let core = core
        let rootDisplayName = rootDisplayName
        _ = requests.perform(
            operation: {
                try await core.enumerateChanges(from: syncAnchor)
            },
            completion: { result in
                switch result {
                case .success(let changes):
                    observer.value.didUpdate(
                        changes.updated.map {
                            RemuxFileProviderItem(
                                projection: FileProviderItemProjection(
                                    remoteItem: $0,
                                    rootDisplayName: rootDisplayName
                                )
                            )
                        }
                    )
                    observer.value.didDeleteItems(withIdentifiers: changes.deleted)
                    observer.value.finishEnumeratingChanges(
                        upTo: changes.anchor,
                        moreComing: changes.moreComing
                    )
                case .failure(let error):
                    observer.value.finishEnumeratingWithError(error)
                }
            }
        )
    }

    func currentSyncAnchor(
        completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void
    ) {
        let core = core
        _ = requests.perform(
            operation: {
                try await core.currentSyncAnchor()
            },
            completion: { result in
                completionHandler(try? result.get())
            }
        )
    }
}

struct RemuxFileProviderManagerSignaler: FileProviderEnumeratorSignaling, @unchecked Sendable {
    let manager: NSFileProviderManager

    func temporaryDirectoryURL() throws -> URL {
        try manager.temporaryDirectoryURL()
    }

    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async {
        await withCheckedContinuation { continuation in
            manager.signalEnumerator(for: identifier) { _ in
                continuation.resume()
            }
        }
    }
}

private struct RemuxFileProviderUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
