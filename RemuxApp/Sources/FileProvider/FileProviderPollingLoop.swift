import Foundation

protocol FileProviderPollingClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousFileProviderPollingClock: FileProviderPollingClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

final class FileProviderPollingLoop: @unchecked Sendable {
    private static let interval: Duration = .seconds(5)

    private let clock: any FileProviderPollingClock
    private let refresh: @Sendable () async throws -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isInvalidated = false

    init(
        clock: any FileProviderPollingClock = ContinuousFileProviderPollingClock(),
        refresh: @escaping @Sendable () async throws -> Void
    ) {
        self.clock = clock
        self.refresh = refresh
    }

    func start() {
        let clock = clock
        let refresh = refresh
        lock.withLock {
            guard task == nil, !isInvalidated else { return }
            task = Task {
                while !Task.isCancelled {
                    do {
                        try await clock.sleep(for: Self.interval)
                    } catch is CancellationError {
                        return
                    } catch {
                        continue
                    }

                    do {
                        try await refresh()
                    } catch is CancellationError {
                        return
                    } catch {
                    }
                }
            }
        }
    }

    func invalidate() {
        let task = lock.withLock {
            isInvalidated = true
            return self.task
        }
        task?.cancel()
    }

    func waitUntilInvalidated() async {
        let task = lock.withLock {
            self.task
        }
        await task?.value
    }

    deinit {
        task?.cancel()
    }
}
