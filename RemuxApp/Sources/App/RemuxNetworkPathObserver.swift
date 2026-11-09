import Foundation
import Network

/// The network path as the root model needs it: whether it is usable now. The observer calls back on usable changes.
protocol RemuxNetworkPathObserving: AnyObject, Sendable {
    var isUsable: Bool { get }
}

extension RemuxNetworkPathObserver: RemuxNetworkPathObserving {}

/// Watches the device's network path. `onUsablePathChange` runs when the path changes and is usable (Wi-Fi to
/// cellular, another Wi-Fi network, the network coming back): the moments an open SSH connection most often dies
/// without a word, since its address or route went away. A path that is not usable is left alone, so a short
/// outage doesn't end connections that would have survived it.
final class RemuxNetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var lastPath: NWPath?

    init(onUsablePathChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previous = self.lock.withLock { () -> NWPath? in
                defer { self.lastPath = path }
                return self.lastPath
            }
            // The first report is the path at start, not a change.
            guard let previous, previous != path, path.status == .satisfied else { return }
            onUsablePathChange()
        }
        monitor.start(queue: DispatchQueue(label: "dev.remux.network-path", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    /// Whether the last reported path was usable; true before the first report, so nothing waits on it.
    var isUsable: Bool {
        lock.withLock { lastPath.map { $0.status == .satisfied } ?? true }
    }
}
