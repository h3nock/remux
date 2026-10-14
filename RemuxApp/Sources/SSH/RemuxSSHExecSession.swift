import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct RemuxSSHExecResult: Equatable, Sendable {
    let exitStatus: Int
    let stdout: Data
    let stderr: Data
}

enum RemuxSSHExecSessionError: Error, Equatable, LocalizedError {
    case requestFailed
    case missingExitStatus
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "The SSH server rejected the exec request."
        case .missingExitStatus:
            return "The SSH command closed without reporting an exit status."
        case .outputTooLarge:
            return "The SSH command produced more output than Remux can capture."
        }
    }
}

final class RemuxSSHExecConnection: @unchecked Sendable {
    private let sessionChannel: Channel
    private let isRootActive: @Sendable () -> Bool
    private let releaseRoot: @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    private let invalidateRoot: @Sendable () async -> Void
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var closeTask: Task<Void, Never>?

    init(
        sessionChannel: Channel,
        isRootActive: @escaping @Sendable () -> Bool = { true },
        releaseRoot: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void,
        invalidateRoot: @escaping @Sendable () async -> Void = {}
    ) {
        self.sessionChannel = sessionChannel
        self.isRootActive = isRootActive
        self.releaseRoot = releaseRoot
        self.invalidateRoot = invalidateRoot
    }

    var isActive: Bool {
        isRootActive() && sessionChannel.isActive
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await sessionChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    /// Asks for the next inbound data on a channel opened with `readsOnDemand`. The channel window
    /// refills only as data is delivered, so with no read pending the server stops once the current
    /// window is used.
    func requestRead() {
        sessionChannel.read()
    }

    /// Stops the SSH connection underneath from being handed out again, without waiting for this
    /// channel to close: for a path that went silent, where the channel close may never be answered.
    func invalidateRootForReuse() async {
        await invalidateRoot()
    }

    func finishInput() async throws {
        do {
            try await sessionChannel.close(mode: .output)
        } catch ChannelError.alreadyClosed {
            return
        }
    }

    func close(disposition: RemuxSSHRootLeaseDisposition) async {
        let task = closeLock.withLock { () -> Task<Void, Never> in
            if let closeTask = self.closeTask {
                return closeTask
            }
            let closeTask = Task { [sessionChannel, releaseRoot] in
                let rootDisposition: RemuxSSHRootLeaseDisposition
                do {
                    try await sessionChannel.close()
                    rootDisposition = disposition
                } catch ChannelError.alreadyClosed {
                    rootDisposition = disposition
                } catch {
                    NSLog("Remux SSH exec channel close failed: %@", String(describing: error))
                    rootDisposition = .invalidated
                }
                await releaseRoot(rootDisposition)
            }
            self.closeTask = closeTask
            return closeTask
        }
        await task.value
    }
}

private final class RemuxSSHExecCleanupOwner: @unchecked Sendable {
    private let cleanup: @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    private let lock = NIOLock()
    private var cleanupTask: Task<Void, Never>?

    init(
        cleanup: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    ) {
        self.cleanup = cleanup
    }

    func run(_ disposition: RemuxSSHRootLeaseDisposition) async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let cleanupTask = self.cleanupTask {
                return cleanupTask
            }
            let cleanupTask = Task { [cleanup] in
                await cleanup(disposition)
            }
            self.cleanupTask = cleanupTask
            return cleanupTask
        }
        await task.value
    }
}

final class RemuxSSHExecLifetimeOwner: @unchecked Sendable {
    private let rootCleanupOwner: RemuxSSHExecCleanupOwner
    private let invalidateRoot: @Sendable () async -> Void
    private let lock = NIOLock()
    private var connectionCleanupOwner: RemuxSSHExecCleanupOwner?
    private var isCancelled = false

    init(
        releaseRoot: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void,
        invalidateRoot: @escaping @Sendable () async -> Void = {}
    ) {
        rootCleanupOwner = RemuxSSHExecCleanupOwner(cleanup: releaseRoot)
        self.invalidateRoot = invalidateRoot
    }

    func makeConnection(
        sessionChannel: Channel,
        isRootActive: @escaping @Sendable () -> Bool = { true }
    ) -> RemuxSSHExecConnection {
        let connection = RemuxSSHExecConnection(
            sessionChannel: sessionChannel,
            isRootActive: isRootActive,
            releaseRoot: { [rootCleanupOwner] disposition in
                await rootCleanupOwner.run(disposition)
            },
            invalidateRoot: invalidateRoot
        )
        installConnectionCleanup { disposition in
            await connection.close(disposition: disposition)
        }
        return connection
    }

    func installConnectionCleanup(
        _ cleanup: @escaping @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    ) {
        let cleanupOwner = RemuxSSHExecCleanupOwner(cleanup: cleanup)
        let shouldInvalidate = lock.withLock {
            connectionCleanupOwner = cleanupOwner
            return isCancelled
        }
        if shouldInvalidate {
            Task {
                await cleanupOwner.run(.invalidated)
            }
        }
    }

    func cancel() {
        let connectionCleanupOwner = lock.withLock {
            isCancelled = true
            return self.connectionCleanupOwner
        }

        Task { [rootCleanupOwner] in
            if let connectionCleanupOwner {
                await connectionCleanupOwner.run(.invalidated)
            } else {
                await rootCleanupOwner.run(.invalidated)
            }
        }
    }

    func close(disposition: RemuxSSHRootLeaseDisposition) async {
        let cleanup = lock.withLock {
            (
                connectionCleanupOwner: connectionCleanupOwner,
                disposition: isCancelled ? .invalidated : disposition
            )
        }

        if let connectionCleanupOwner = cleanup.connectionCleanupOwner {
            await connectionCleanupOwner.run(cleanup.disposition)
        } else {
            await rootCleanupOwner.run(cleanup.disposition)
        }
    }
}

enum RemuxSSHExecSession {
    /// A raw pseudo-terminal (the `cfmakeraw` modes): no echo, line editing,
    /// signal characters, flow control, or byte translation, so the stream
    /// carries the same bytes as a plain exec channel. Unlike a plain exec
    /// channel, sshd hangs up the command when the channel or the connection
    /// goes away. The size is unused by the command.
    static let rawPseudoTerminalRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: false,
        term: "xterm-256color",
        terminalCharacterWidth: 80,
        terminalRowHeight: 24,
        terminalPixelWidth: 0,
        terminalPixelHeight: 0,
        terminalModes: SSHTerminalModes([
            .PARMRK: 0, .ISTRIP: 0, .INLCR: 0, .IGNCR: 0, .ICRNL: 0,
            .IXON: 0, .IXOFF: 0, .IXANY: 0,
            .OPOST: 0, .ONLCR: 0,
            .ECHO: 0, .ECHONL: 0, .ICANON: 0, .ISIG: 0, .IEXTEN: 0,
            .PARENB: 0, .CS8: 1,
        ])
    )

    /// Opens a long-lived exec channel. With `pseudoTerminal`, the command
    /// runs on `rawPseudoTerminalRequest`; a server that refuses the pty runs
    /// it on a plain channel, where stderr stays a separate stream. With
    /// `readsOnDemand`, data arrives only after `requestRead()`, which gives
    /// the reader SSH flow control.
    static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        pseudoTerminal: Bool,
        readsOnDemand: Bool = false,
        trace: RemuxTransportStartupTrace,
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws -> RemuxSSHExecConnection {
        let lifetime = makeLifetime(for: claimedRoot)
        return try await open(lifetime: lifetime) {
            try await open(
                using: claimedRoot,
                command: command,
                trace: trace,
                lifetime: lifetime,
                closeOnRemoteEOFAndExitStatus: false,
                pseudoTerminal: pseudoTerminal,
                readsOnDemand: readsOnDemand,
                onData: onData,
                onFinish: onFinish
            )
        }
    }

    static func open<Value: Sendable>(
        lifetime: RemuxSSHExecLifetimeOwner,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        return try await withTaskCancellationHandler {
            do {
                let connection = try await operation()
                try Task.checkCancellation()
                return connection
            } catch {
                await lifetime.close(disposition: .invalidated)
                throw error
            }
        } onCancel: {
            lifetime.cancel()
        }
    }

    private static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        trace: RemuxTransportStartupTrace,
        lifetime: RemuxSSHExecLifetimeOwner,
        closeOnRemoteEOFAndExitStatus: Bool,
        pseudoTerminal: Bool = false,
        readsOnDemand: Bool = false,
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws -> RemuxSSHExecConnection {
        do {
            // With reads on demand, NIOSSH still delivers channel requests, their replies and the exit
            // status at once; data, stderr and EOF are queued in arrival order and delivered only for a
            // read.
            let sessionChannel = try await claimedRoot.sshRoot.openSessionChannel(
                trace: trace,
                readsOnDemand: readsOnDemand
            )
            let openedConnection = lifetime.makeConnection(
                sessionChannel: sessionChannel,
                isRootActive: {
                    claimedRoot.sshRoot.rootChannel.isActive
                }
            )
            let handler = RemuxSSHExecChannelHandler(
                closeOnRemoteEOFAndExitStatus: closeOnRemoteEOFAndExitStatus,
                onData: onData,
                onFinish: onFinish
            )

            try await trace.stage("sessionChannel.handler.add") {
                try await sessionChannel.pipeline.addHandler(handler).get()
            }
            try await trace.stage(
                "exec.request",
                fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
            ) {
                try Task.checkCancellation()
                if pseudoTerminal {
                    try await sessionChannel.triggerUserOutboundEvent(rawPseudoTerminalRequest)
                }
                handler.expectExecReply()
                try await sessionChannel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExecRequest(
                        command: command,
                        wantReply: true
                    )
                )
            }
            return openedConnection
        } catch {
            await lifetime.close(disposition: .invalidated)
            throw error
        }
    }

    static func run(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        stdin: Data?,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHExecResult {
        let collector = RemuxSSHExecResultCollector()
        let lifetime = makeLifetime(for: claimedRoot)

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let openedConnection = try await open(
                    using: claimedRoot,
                    command: command,
                    trace: trace,
                    lifetime: lifetime,
                    closeOnRemoteEOFAndExitStatus: true,
                    onData: { type, data in
                        collector.receive(type: type, data: data)
                    },
                    onFinish: { exitStatus, error in
                        collector.finish(exitStatus: exitStatus, error: error)
                    }
                )
                try Task.checkCancellation()

                if let stdin {
                    try await openedConnection.write(stdin)
                }
                try Task.checkCancellation()
                try await openedConnection.finishInput()
                try Task.checkCancellation()

                let result = try await collector.value()
                try Task.checkCancellation()
                await lifetime.close(disposition: .reusable)
                return result
            } catch {
                await lifetime.close(disposition: .invalidated)
                throw error
            }
        } onCancel: {
            collector.cancel()
            lifetime.cancel()
        }
    }

    private static func makeLifetime(
        for claimedRoot: RemuxSSHClaimedRoot
    ) -> RemuxSSHExecLifetimeOwner {
        RemuxSSHExecLifetimeOwner(
            releaseRoot: { disposition in await claimedRoot.release(disposition) },
            invalidateRoot: { await claimedRoot.invalidateForReuse() }
        )
    }
}

final class RemuxSSHExecResultCollector: @unchecked Sendable {
    private static let maximumCapturedStreamBytes = 64 * 1024

    private struct Completion {
        let result: Result<RemuxSSHExecResult, Error>
        let continuation: CheckedContinuation<RemuxSSHExecResult, Error>?
    }

    private let lock = NIOLock()
    private var stdout = Data()
    private var stderr = Data()
    private var result: Result<RemuxSSHExecResult, Error>?
    private var continuation: CheckedContinuation<RemuxSSHExecResult, Error>?

    func receive(type: SSHChannelData.DataType, data: Data) {
        guard !data.isEmpty else { return }

        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }

            switch type {
            case .channel:
                guard stdout.count <= Self.maximumCapturedStreamBytes - data.count else {
                    let terminalResult: Result<RemuxSSHExecResult, Error> = .failure(
                        RemuxSSHExecSessionError.outputTooLarge
                    )
                    return Completion(
                        result: terminalResult,
                        continuation: finishLocked(terminalResult)
                    )
                }
                stdout.append(data)
            case .stdErr:
                guard stderr.count <= Self.maximumCapturedStreamBytes - data.count else {
                    let terminalResult: Result<RemuxSSHExecResult, Error> = .failure(
                        RemuxSSHExecSessionError.outputTooLarge
                    )
                    return Completion(
                        result: terminalResult,
                        continuation: finishLocked(terminalResult)
                    )
                }
                stderr.append(data)
            default:
                break
            }
            return nil
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    func finish(exitStatus: Int?, error: Error?) {
        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }

            let terminalResult: Result<RemuxSSHExecResult, Error>
            if let error {
                terminalResult = .failure(error)
            } else if let exitStatus {
                terminalResult = .success(
                    RemuxSSHExecResult(
                        exitStatus: exitStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            } else {
                terminalResult = .failure(RemuxSSHExecSessionError.missingExitStatus)
            }
            return Completion(
                result: terminalResult,
                continuation: finishLocked(terminalResult)
            )
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    func value() async throws -> RemuxSSHExecResult {
        try await withCheckedThrowingContinuation { continuation in
            let completedResult = lock.withLock { () -> Result<RemuxSSHExecResult, Error>? in
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            completedResult?.resume(continuation)
        }
    }

    private func complete(_ terminalResult: Result<RemuxSSHExecResult, Error>) {
        let completion = lock.withLock { () -> Completion? in
            guard result == nil else { return nil }
            return Completion(
                result: terminalResult,
                continuation: finishLocked(terminalResult)
            )
        }
        if let completion {
            completion.result.resume(completion.continuation)
        }
    }

    private func finishLocked(
        _ terminalResult: Result<RemuxSSHExecResult, Error>
    ) -> CheckedContinuation<RemuxSSHExecResult, Error>? {
        guard result == nil else { return nil }
        result = terminalResult
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

final class RemuxSSHExecChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let onData: @Sendable (SSHChannelData.DataType, Data) -> Void
    private let onFinish: @Sendable (Int?, Error?) -> Void
    private let closeOnRemoteEOFAndExitStatus: Bool
    private let lock = NIOLock()
    private var pendingExecReplies = 0
    private var exitStatus: Int?
    private var didReceiveRemoteEOF = false
    private var didFinish = false

    init(
        closeOnRemoteEOFAndExitStatus: Bool = true,
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) {
        self.closeOnRemoteEOFAndExitStatus = closeOnRemoteEOFAndExitStatus
        self.onData = onData
        self.onFinish = onFinish
    }

    func expectExecReply() {
        lock.withLock {
            pendingExecReplies += 1
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        ).whenFailure { [weak self] error in
            self?.finish(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            let completedExitStatus = lock.withLock { () -> Int? in
                exitStatus = Int(status.exitStatus)
                return takeFiniteCompletionIfReadyLocked()
            }
            completeFiniteCommandIfReady(
                exitStatus: completedExitStatus,
                context: context
            )
        case ChannelEvent.inputClosed:
            let completedExitStatus = lock.withLock { () -> Int? in
                didReceiveRemoteEOF = true
                return takeFiniteCompletionIfReadyLocked()
            }
            context.fireUserInboundEventTriggered(event)
            completeFiniteCommandIfReady(
                exitStatus: completedExitStatus,
                context: context
            )
        case is ChannelSuccessEvent:
            guard consumeExpectedExecReply() else {
                context.fireUserInboundEventTriggered(event)
                return
            }
        case is NIOSSH.ChannelFailureEvent:
            guard consumeExpectedExecReply() else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            finish(RemuxSSHExecSessionError.requestFailed)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty
        else {
            return
        }

        onData(channelData.type, Data(bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        let completion = lock.withLock { () -> (Int?, Error?)? in
            guard !didFinish else { return nil }
            didFinish = true
            return (exitStatus, error)
        }
        guard let completion else { return }
        onFinish(completion.0, completion.1)
    }

    private func takeFiniteCompletionIfReadyLocked() -> Int? {
        guard closeOnRemoteEOFAndExitStatus,
              didReceiveRemoteEOF,
              let exitStatus,
              !didFinish else {
            return nil
        }
        didFinish = true
        return exitStatus
    }

    private func completeFiniteCommandIfReady(
        exitStatus: Int?,
        context: ChannelHandlerContext
    ) {
        guard let exitStatus else { return }
        onFinish(exitStatus, nil)
        context.close(promise: nil)
    }

    private func consumeExpectedExecReply() -> Bool {
        lock.withLock {
            guard pendingExecReplies > 0 else { return false }
            pendingExecReplies -= 1
            return true
        }
    }
}

private extension Result where Success == RemuxSSHExecResult, Failure == Error {
    func resume(_ continuation: CheckedContinuation<Success, Failure>?) {
        guard let continuation else { return }
        switch self {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
