@preconcurrency import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

struct SSHTmuxControlConfiguration: Sendable {
    let host: String
    let port: Int
    let authenticationMethod: @Sendable () throws -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    let connectTimeout: TimeAmount
    let controlNoResponseTimeout: TimeAmount
    let sftpOperationTimeout: TimeAmount
    let tmuxExecutable: String
    let sessionName: String
    let initialViewport: TmuxControlViewport
    let traceFlowID: String?
    let sshRootKey: RemuxSSHRootKey?

    init(
        host: String,
        port: Int = 22,
        authenticationMethod: @escaping @Sendable () throws -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeout: TimeAmount = .seconds(30),
        controlNoResponseTimeout: TimeAmount = .seconds(15),
        sftpOperationTimeout: TimeAmount = .seconds(15),
        tmuxExecutable: String = "tmux",
        sessionName: String,
        initialViewport: TmuxControlViewport = .default,
        traceFlowID: String? = nil,
        sshRootKey: RemuxSSHRootKey? = nil
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeout = connectTimeout
        self.controlNoResponseTimeout = controlNoResponseTimeout
        self.sftpOperationTimeout = sftpOperationTimeout
        self.tmuxExecutable = tmuxExecutable
        self.sessionName = sessionName
        self.initialViewport = initialViewport
        self.traceFlowID = traceFlowID
        self.sshRootKey = sshRootKey
    }

    var sshRootConfiguration: RemuxSSHRootConfiguration {
        RemuxSSHRootConfiguration(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            connectTimeout: connectTimeout
        )
    }
}

struct SSHTmuxControlChannelCompletionState: Equatable, Sendable {
    private var didFinish = false
    private var exitStatus: Int?

    mutating func recordExitStatus(_ status: Int) {
        exitStatus = status
    }

    mutating func finish(
        _ error: Error?,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> Result<Void, Error>? {
        guard !didFinish else { return nil }
        didFinish = true

        if let error {
            return .failure(error)
        }

        if let exitStatus, exitStatus != 0 {
            return .failure(
                SSHTmuxControlTransportError.remoteExit(
                    exitStatus,
                    diagnostics: diagnostics
                )
            )
        }

        return .success(())
    }
}

final class SSHTmuxControlFirstOutputGate: @unchecked Sendable {
    private let lock = NIOLock()
    private let promise: EventLoopPromise<Void>
    private var isCompleted = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func succeed() {
        complete {
            promise.succeed(())
        }
    }

    func fail(_ error: Error) {
        complete {
            promise.fail(error)
        }
    }

    private func complete(_ body: () -> Void) {
        let shouldComplete = lock.withLock {
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }

        guard shouldComplete else { return }
        body()
    }
}

enum SSHTmuxControlTransportError: LocalizedError, Equatable, CustomStringConvertible {
    case remoteExit(Int, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case channelRequestFailed(SSHTmuxControlChannelRequestKind, diagnostics: SSHTmuxStartupDiagnostics? = nil)
    case unsupportedInboundChannel
    case alreadyStarted
    case closed
    case stalePreparedConnection
    case controlSessionNoResponse(TimeAmount)

    var description: String {
        switch self {
        case .remoteExit(let code, let diagnostics):
            return Self.describe(
                "remoteExit(\(code))",
                diagnostics: diagnostics
            )
        case .channelRequestFailed(let request, let diagnostics):
            return Self.describe(
                "SSH \(request.description) request failed",
                diagnostics: diagnostics
            )
        case .unsupportedInboundChannel:
            return "unsupportedInboundChannel"
        case .alreadyStarted:
            return "alreadyStarted"
        case .closed:
            return "closed"
        case .stalePreparedConnection:
            return "stalePreparedConnection"
        case .controlSessionNoResponse(let timeout):
            return "tmux control session produced no output within \(timeout)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .remoteExit(let code, _):
            return "The remote tmux control session exited with status \(code)."
        case .channelRequestFailed(let request, _):
            return "The SSH server rejected the \(request.description) request."
        case .unsupportedInboundChannel:
            return "Remux received an unexpected SSH channel type."
        case .alreadyStarted:
            return "The tmux control transport has already started."
        case .closed:
            return "The tmux control transport has already been closed."
        case .stalePreparedConnection:
            return "The prepared SSH root reservation is no longer valid."
        case .controlSessionNoResponse(let timeout):
            return "The remote tmux control session produced no output within \(timeout)."
        }
    }

    private static func describe(
        _ base: String,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> String {
        guard let diagnostics else { return base }
        return "\(base) \(diagnostics)"
    }
}

private extension TmuxControlTransportCloseDisposition {
    var sshRootLeaseDisposition: RemuxSSHRootLeaseDisposition {
        switch self {
        case .reusable:
            return .reusable
        case .invalidated:
            return .invalidated
        }
    }
}

actor SSHTmuxControlTransport: TmuxControlTransport, TmuxControlTransportLivenessChecking,
    TmuxControlTransportSFTPProviding, TmuxControlTransportLiveForwardProviding {
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>
    nonisolated let sessionSFTPClientProvider: RemuxSessionCitadelSFTPClientProvider
    nonisolated let sessionLiveForwardProvider: RemuxSessionLiveForwardProvider

    private let configuration: SSHTmuxControlConfiguration
    private let inboundStream: SSHTmuxControlInboundStream
    private let sshRootService: RemuxSSHRootService?
    private let sessionSFTPScope: RemuxSessionSFTPChildScope

    private var pendingWrites: [Data] = []
    private var inputAdapter: SSHTmuxControlInputAdapter?
    private var preparedRoot: RemuxSSHPreparedRoot?
    private var connection: SSHTmuxControlConnection?
    private var sessionSFTPDrainTask: Task<RemuxSFTPChildDrain, Never>?
    private var hasStarted = false
    private var isClosed = false

    init(
        configuration: SSHTmuxControlConfiguration,
        sshRootService: RemuxSSHRootService? = nil
    ) {
        self.configuration = configuration
        self.sshRootService = sshRootService
        let sessionSFTPScope = RemuxSessionSFTPChildScope()
        self.sessionSFTPScope = sessionSFTPScope
        self.sessionSFTPClientProvider = RemuxSessionCitadelSFTPClientProvider(
            scope: sessionSFTPScope,
            hostDescription: "\(configuration.host):\(configuration.port)",
            operationTimeout: configuration.sftpOperationTimeout
        )
        self.sessionLiveForwardProvider = RemuxSessionLiveForwardProvider(
            scope: sessionSFTPScope
        )
        let inboundStream = SSHTmuxControlInboundStream()
        self.inboundStream = inboundStream
        self.receivedBytes = inboundStream.receivedBytes
    }

    func prepare() async {
        guard !isClosed, preparedRoot == nil, connection == nil, !hasStarted else { return }

        preparedRoot = await makePreparedRoot()
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }
        guard !hasStarted else { throw SSHTmuxControlTransportError.alreadyStarted }
        hasStarted = true

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "transport.start begin host=\(configuration.host):\(configuration.port) session=\(configuration.sessionName)"
        )
        let preparedRoot: RemuxSSHPreparedRoot
        if let existingPreparedRoot = self.preparedRoot {
            preparedRoot = existingPreparedRoot
        } else {
            preparedRoot = await makePreparedRoot()
        }
        self.preparedRoot = preparedRoot
        let startupTrace = preparedRoot.trace
        var startedConnection: SSHTmuxControlConnection?
        let establishedConnection: SSHTmuxControlConnection
        let establishedInputAdapter: SSHTmuxControlInputAdapter
        do {
            let sshRoot = try await startupTrace.stage("sshRoot.ready") {
                try await preparedRoot.sshRoot()
            }
            self.preparedRoot = nil
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            let startupViewport = initialViewport ?? configuration.initialViewport
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.attach session=\(configuration.sessionName) viewport=\(GhosttyRuntimeTrace.viewportDescription(startupViewport)) initialProvided=\(initialViewport != nil)"
            )
            let claimedConnection = try await preparedRoot.claim(
                sshRoot,
                trace: startupTrace
            )
            guard !isClosed else {
                await claimedConnection.release(.reusable)
                throw SSHTmuxControlTransportError.closed
            }
            let remotePlatform: SSHTmuxRemotePlatform
            do {
                remotePlatform = try await SSHTmuxControlBootstrap.detectRemotePlatform(
                    using: claimedConnection.sshRoot,
                    trace: startupTrace
                )
            } catch {
                await claimedConnection.release(.reusable)
                throw error
            }
            guard !isClosed else {
                await claimedConnection.release(.reusable)
                throw SSHTmuxControlTransportError.closed
            }
            let startupOutputAdapter = SSHTmuxControlStartupOutputAdapter(
                platform: remotePlatform
            )
            let inputAdapter = SSHTmuxControlInputAdapter(platform: remotePlatform)
            establishedInputAdapter = inputAdapter
            establishedConnection = try await SSHTmuxControlBootstrap.openControlSession(
                using: claimedConnection,
                viewport: startupViewport,
                command: tmuxAttachCommand(
                    platform: remotePlatform,
                    viewport: startupViewport
                ),
                controlNoResponseTimeout: configuration.controlNoResponseTimeout,
                trace: startupTrace,
                onOutput: { [inboundStream, startupOutputAdapter] data in
                    if let adapted = startupOutputAdapter.adapt(data) {
                        inboundStream.yield(adapted)
                    }
                },
                onFinish: { [inboundStream] error in
                    inboundStream.finish(error)
                }
            )
            startedConnection = establishedConnection
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            try await sessionSFTPScope.activate(
                rootChannel: claimedConnection.sshRoot.rootChannel,
                invalidateRootForReuse: {
                    await claimedConnection.invalidateForReuse()
                }
            )
            await sessionLiveForwardProvider.activate(
                openerFactory: { [sshRoot = claimedConnection.sshRoot] target in
                    .directTCPIP(
                        sshRoot: sshRoot,
                        target: target,
                        originatorAddress: Self.liveForwardOriginatorAddress
                    )
                }
            )
            guard !isClosed else { throw SSHTmuxControlTransportError.closed }
            self.inputAdapter = inputAdapter
            connection = establishedConnection
            startedConnection = nil
        } catch {
            let transportError: any Error
            if Self.startWasInterruptedByClose(
                error,
                transportWasClosed: isClosed
            ) {
                transportError = SSHTmuxControlTransportError.closed
            } else {
                transportError = translateSSHRootError(error)
            }
            self.preparedRoot = nil
            self.connection = nil
            let childDrain = await drainSessionSFTPChildren()
            await startedConnection?.close(
                disposition: closeDispositionAfterStartFailure(transportError),
                childDrain: childDrain
            )
            throw transportError
        }

        let queuedWrites = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        startupTrace.event(
            "queuedWrites.begin",
            fields: ["count": "\(queuedWrites.count)"]
        )
        do {
            for data in queuedWrites {
                if let adapted = try establishedInputAdapter.adapt(data) {
                    try await establishedConnection.write(adapted)
                }
            }
        } catch {
            connection = nil
            let childDrain = await drainSessionSFTPChildren()
            await establishedConnection.close(
                disposition: .invalidated,
                childDrain: childDrain
            )
            throw error
        }
        startupTrace.event(
            "queuedWrites.end",
            fields: ["count": "\(queuedWrites.count)"]
        )
        startupTrace.event(
            "end",
            fields: ["queuedWrites": "\(queuedWrites.count)"]
        )
        GhosttyRuntimeTrace.latency(
            "transport.start end queuedWrites=\(queuedWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard !isClosed else { throw SSHTmuxControlTransportError.closed }

        let start = GhosttyRuntimeTrace.nowNanos()
        guard let connection else {
            pendingWrites.append(data)
            GhosttyRuntimeTrace.latency(
                "transport.send queued-before-start bytes=\(data.count) pending=\(pendingWrites.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start)) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
            )
            return
        }

        GhosttyRuntimeTrace.latency(
            "transport.send begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        let adapted: Data?
        if let inputAdapter {
            adapted = try inputAdapter.adapt(data)
        } else {
            adapted = data
        }
        guard let adapted else {
            GhosttyRuntimeTrace.latency(
                "transport.send buffered bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
            )
            return
        }
        try await connection.write(adapted)
        GhosttyRuntimeTrace.latency(
            "transport.send end bytes=\(adapted.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
    }

    func isControlChannelActive() async -> Bool {
        guard !isClosed, let connection else { return false }
        return connection.isControlChannelActive
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        let activeConnection = connection
        let pendingPreparedRoot = preparedRoot
        connection = nil
        inputAdapter = nil
        preparedRoot = nil
        isClosed = true
        let childDrain = await drainSessionSFTPChildren()
        if let activeConnection {
            await activeConnection.close(
                disposition: disposition,
                childDrain: childDrain
            )
        }
        if let pendingPreparedRoot {
            Task {
                await pendingPreparedRoot.cancelAndCleanup()
            }
        }
        inboundStream.finish(nil)
    }

    private func drainSessionSFTPChildren() async -> RemuxSFTPChildDrain {
        if let sessionSFTPDrainTask {
            return await sessionSFTPDrainTask.value
        }

        let scope = sessionSFTPScope
        let task = Task { await scope.close() }
        sessionSFTPDrainTask = task
        return await task.value
    }

    // The SSH wire format requires an IP-literal originator; the real
    // originator is always this device's loopback browser connection.
    private static let liveForwardOriginatorAddress = try! SocketAddress(
        ipAddress: "127.0.0.1",
        port: 0
    )

    nonisolated static func startWasInterruptedByClose(
        _ error: any Error,
        transportWasClosed: Bool
    ) -> Bool {
        guard transportWasClosed,
              let sftpError = error as? RemuxSFTPClientError
        else { return false }
        return sftpError == .sessionUnavailable
    }

    private func closeDispositionAfterStartFailure(_ error: any Error) -> TmuxControlTransportCloseDisposition {
        if let transportError = error as? SSHTmuxControlTransportError,
           transportError == .closed {
            return .reusable
        }

        return .invalidated
    }

    private func translateSSHRootError(_ error: any Error) -> any Error {
        guard let rootError = error as? RemuxSSHRootServiceError else {
            return error
        }

        switch rootError {
        case .unsupportedInboundChannel:
            return SSHTmuxControlTransportError.unsupportedInboundChannel
        case .closed:
            return SSHTmuxControlTransportError.closed
        case .stalePreparedRoot:
            return SSHTmuxControlTransportError.stalePreparedConnection
        }
    }

    private func makePreparedRoot() async -> RemuxSSHPreparedRoot {
        let configuration = self.configuration
        let startupTrace = RemuxTransportStartupTrace(flowID: configuration.traceFlowID)
        startupTrace.event(
            "begin",
            fields: [
                "host": configuration.host,
                "port": "\(configuration.port)",
                "session": configuration.sessionName,
            ]
        )

        if let sshRootService,
           let rootKey = configuration.sshRootKey {
            return await sshRootService.preparedRoot(
                for: rootKey,
                configuration: configuration.sshRootConfiguration,
                trace: startupTrace
            )
        }

        return RemuxSSHPreparedRoot.dedicated(
            configuration: configuration.sshRootConfiguration,
            trace: startupTrace
        )
    }

    private func tmuxAttachCommand(
        platform: SSHTmuxRemotePlatform,
        viewport: TmuxControlViewport
    ) -> String {
        SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            platform: platform,
            tmuxExecutable: configuration.tmuxExecutable,
            sessionName: configuration.sessionName,
            initialViewport: viewport
        )
    }
}

enum SSHTmuxControlInputAdapterError: Error, Equatable {
    case invalidUTF8
}

/// Adapt the small subset of upstream tmux control commands whose syntax is
/// different in Windows tmux.exe. Commands are newline-delimited and may be
/// split across SSH writes.
final class SSHTmuxControlInputAdapter: @unchecked Sendable {
    private let platform: SSHTmuxRemotePlatform
    private let lock = NIOLock()
    private var bufferedCommand = Data()

    init(platform: SSHTmuxRemotePlatform) {
        self.platform = platform
    }

    func adapt(_ data: Data) throws -> Data? {
        guard !data.isEmpty else { return nil }
        guard platform == .windows else { return data }

        return try lock.withLock {
            bufferedCommand.append(data)
            var output = Data()

            while let newline = bufferedCommand.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(bufferedCommand[..<newline])
                output.append(try adaptCommand(line))
                output.append(UInt8(ascii: "\n"))
                bufferedCommand.removeSubrange(...newline)
            }

            return output.isEmpty ? nil : output
        }
    }

    private func adaptCommand(_ data: Data) throws -> Data {
        guard let command = String(data: data, encoding: .utf8) else { return data }
        if let resized = Self.adaptRefreshClientSize(command) {
            return Data(resized.utf8)
        }
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 5,
              tokens[0] == "send-keys",
              tokens[1] == "-H",
              tokens[2] == "-t",
              tokens[3].first == "%",
              tokens[3].count > 1,
              tokens[3].dropFirst().allSatisfy(\.isNumber),
              tokens[4...].allSatisfy(Self.isHexByte)
        else {
            return data
        }

        var input = Data()
        for token in tokens[4...] {
            guard let byte = UInt8(token, radix: 16) else { return data }
            input.append(byte)
        }
        guard let text = String(data: input, encoding: .utf8) else {
            throw SSHTmuxControlInputAdapterError.invalidUTF8
        }
        let scalars = text.unicodeScalars
            .map { "0x" + String($0.value, radix: 16) }
            .joined(separator: " ")
        return Data("send-keys -t \(tokens[3]) \(scalars)".utf8)
    }

    /// Upstream tmux accepts both `COLSxROWS` and `COLS,ROWS`, while psmux's
    /// control-client resize parser currently accepts only the comma form.
    private static func adaptRefreshClientSize(_ command: String) -> String? {
        let prefix = "refresh-client -C "
        guard command.hasPrefix(prefix) else { return nil }

        let size = command.dropFirst(prefix.count)
        let components = size.split(separator: "x", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        return prefix + components.joined(separator: ",")
    }

    private static func isHexByte(_ token: Substring) -> Bool {
        token.count == 2 && token.allSatisfy(\.isHexDigit)
    }
}

/// Windows tmux.exe's `-CC` stream is wrapped in DCS 1000p. Ghostty expects a
/// plain control stream, so remove only that envelope on positively detected
/// Windows hosts.
final class SSHTmuxControlStartupOutputAdapter: @unchecked Sendable {
    private static let dcsOpener = Data([0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])

    private let platform: SSHTmuxRemotePlatform
    private let lock = NIOLock()
    private var bufferedPrefix = Data()
    private var startupResolved = false
    private var isDCSWrapped = false
    private var hasPendingEscape = false

    init(platform: SSHTmuxRemotePlatform) {
        self.platform = platform
    }

    func adapt(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard platform == .windows else { return data }

        return lock.withLock {
            if startupResolved {
                return isDCSWrapped ? removingDCSClosers(from: data) : data
            }

            bufferedPrefix.append(data)
            let comparedCount = min(bufferedPrefix.count, Self.dcsOpener.count)
            guard bufferedPrefix.prefix(comparedCount)
                    == Self.dcsOpener.prefix(comparedCount)
            else {
                startupResolved = true
                defer { bufferedPrefix.removeAll(keepingCapacity: false) }
                return bufferedPrefix
            }

            guard bufferedPrefix.count >= Self.dcsOpener.count else { return nil }

            startupResolved = true
            isDCSWrapped = true
            let output = Data(bufferedPrefix.dropFirst(Self.dcsOpener.count))
            bufferedPrefix.removeAll(keepingCapacity: false)
            return removingDCSClosers(from: output)
        }
    }

    private func removingDCSClosers(from data: Data) -> Data? {
        var output = Data()
        output.reserveCapacity(data.count + (hasPendingEscape ? 1 : 0))
        var iterator = data.makeIterator()

        if hasPendingEscape {
            hasPendingEscape = false
            guard let first = iterator.next() else {
                hasPendingEscape = true
                return nil
            }
            if first != UInt8(ascii: "\\") {
                output.append(UInt8(ascii: "\u{1b}"))
                output.append(first)
            }
        }

        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\u{1b}") else {
                output.append(byte)
                continue
            }
            guard let next = iterator.next() else {
                hasPendingEscape = true
                break
            }
            if next != UInt8(ascii: "\\") {
                output.append(byte)
                output.append(next)
            }
        }

        return output.isEmpty ? nil : output
    }
}

private final class SSHTmuxControlViewportTraceState: @unchecked Sendable {
    private let lock = NIOLock()
    private var viewport: TmuxControlViewport

    init(viewport: TmuxControlViewport) {
        self.viewport = viewport
    }

    func description() -> String {
        lock.withLock {
            GhosttyRuntimeTrace.viewportDescription(viewport)
        }
    }
}

private func traceControlByteChunk(
    _ data: Data,
    direction: String,
    source: String,
    viewportDescription: String
) {
    guard GhosttyRuntimeTrace.tmuxViewportEnabled, !data.isEmpty else { return }

    GhosttyRuntimeTrace.tmuxViewport(
        "io.chunk dir=\(direction) source=\(source) chunkBytes=\(data.count) viewport=\(viewportDescription) preview=\(GhosttyRuntimeTrace.preview(data, limit: 220))"
    )
}

private final class SSHTmuxControlConnection: @unchecked Sendable {
    private let claimedConnection: RemuxSSHClaimedRoot
    private let sessionChannel: Channel
    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let allocator = ByteBufferAllocator()
    private let closeLock = NIOLock()
    private var didClose = false

    init(
        claimedConnection: RemuxSSHClaimedRoot,
        sessionChannel: Channel,
        viewportTraceState: SSHTmuxControlViewportTraceState
    ) {
        self.claimedConnection = claimedConnection
        self.sessionChannel = sessionChannel
        self.viewportTraceState = viewportTraceState
    }

    var isControlChannelActive: Bool {
        claimedConnection.sshRoot.rootChannel.isActive && sessionChannel.isActive
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        traceControlByteChunk(
            data,
            direction: "tx",
            source: "ssh.writeAndFlush",
            viewportDescription: viewportTraceState.description()
        )
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush begin bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "ssh.writeAndFlush.begin",
            fields: [
                "bytes": "\(data.count)",
                "wall_ns": "\(GhosttyRuntimeTrace.wallNanos())",
            ],
            at: start
        )
        do {
            try await sessionChannel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            )
        } catch {
            GhosttyRuntimeTrace.flowEndIfActive(
                GhosttyRuntimeTrace.paneSwitchFlow,
                event: "ssh.writeAndFlush.failed",
                fields: [
                    "bytes": "\(data.count)",
                    "error": String(describing: error),
                ]
            )
            throw error
        }
        GhosttyRuntimeTrace.latency(
            "ssh.writeAndFlush end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
        )
        GhosttyRuntimeTrace.flowEventIfActive(
            GhosttyRuntimeTrace.paneSwitchFlow,
            event: "ssh.writeAndFlush.end",
            fields: [
                "bytes": "\(data.count)",
                "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
            ]
        )
    }

    func close(
        disposition: TmuxControlTransportCloseDisposition,
        childDrain: RemuxSFTPChildDrain
    ) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        let sessionChannelClosedCleanly: Bool
        do {
            try await sessionChannel.close()
            sessionChannelClosedCleanly = true
        } catch {
            sessionChannelClosedCleanly = false
            NSLog("Remux tmux control channel close failed: %@", String(describing: error))
        }

        let rootDisposition: RemuxSSHRootLeaseDisposition
        if childDrain == .dirty || !sessionChannelClosedCleanly {
            rootDisposition = .invalidated
        } else {
            rootDisposition = disposition.sshRootLeaseDisposition
        }
        await claimedConnection.release(rootDisposition)
    }
}

private final class SSHTmuxPreparedControlSession: @unchecked Sendable {
    let claimedConnection: RemuxSSHClaimedRoot
    let sessionChannel: Channel

    private let closeLock = NIOLock()
    private var didClose = false

    init(
        claimedConnection: RemuxSSHClaimedRoot,
        sessionChannel: Channel
    ) {
        self.claimedConnection = claimedConnection
        self.sessionChannel = sessionChannel
    }

    func close(disposition: RemuxSSHRootLeaseDisposition) async {
        let shouldClose = closeLock.withLock {
            guard !didClose else { return false }
            didClose = true
            return true
        }
        guard shouldClose else { return }

        let rootDisposition: RemuxSSHRootLeaseDisposition
        do {
            try await sessionChannel.close()
            rootDisposition = disposition
        } catch {
            NSLog("Remux prepared tmux channel close failed: %@", String(describing: error))
            rootDisposition = .invalidated
        }
        await claimedConnection.release(rootDisposition)
    }
}

private struct SSHTmuxRemoteCommandResult: Sendable {
    let exitStatus: Int?
    let stdout: Data
}

private struct SSHTmuxRemoteCommandTimedOut: Error {}

private enum SSHTmuxRemoteCommandRunner {
    static func run(
        command: String,
        using sshRoot: RemuxSSHRoot,
        timeout: TimeAmount,
        trace: RemuxTransportStartupTrace
    ) async throws -> SSHTmuxRemoteCommandResult {
        let channel = try await sshRoot.openSessionChannel(trace: trace)
        let promise = channel.eventLoop.makePromise(of: SSHTmuxRemoteCommandResult.self)
        let handler = SSHTmuxRemoteCommandHandler(promise: promise)

        do {
            try await channel.pipeline.addHandler(handler).get()
            let timeoutTask = channel.eventLoop.scheduleTask(deadline: .now() + timeout) {
                handler.fail(SSHTmuxRemoteCommandTimedOut())
            }
            defer { timeoutTask.cancel() }

            try await channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
            let result = try await promise.futureResult.get()
            try? await channel.close()
            return result
        } catch {
            try? await channel.close()
            throw error
        }
    }
}

private final class SSHTmuxRemoteCommandHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let promise: EventLoopPromise<SSHTmuxRemoteCommandResult>
    private var stdout = Data()
    private var exitStatus: Int?
    private var didComplete = false

    init(promise: EventLoopPromise<SSHTmuxRemoteCommandResult>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard channelData.type == .channel,
              case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes)
        else {
            return
        }
        stdout.append(contentsOf: bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = Int(status.exitStatus)
        case is NIOSSH.ChannelFailureEvent:
            fail(SSHTmuxControlTransportError.channelRequestFailed(.exec))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func fail(_ error: Error) {
        guard !didComplete else { return }
        didComplete = true
        promise.fail(error)
    }

    private func complete() {
        guard !didComplete else { return }
        didComplete = true
        promise.succeed(
            SSHTmuxRemoteCommandResult(exitStatus: exitStatus, stdout: stdout)
        )
    }
}

private enum SSHTmuxControlBootstrap {
    static func detectRemotePlatform(
        using sshRoot: RemuxSSHRoot,
        trace: RemuxTransportStartupTrace
    ) async throws -> SSHTmuxRemotePlatform {
        let result = try await trace.stage("remotePlatform.detect") {
            try await SSHTmuxRemoteCommandRunner.run(
                command: SSHTmuxRemotePlatformDetector.windowsProbeCommand,
                using: sshRoot,
                timeout: .seconds(3),
                trace: trace
            )
        }
        let platform = try SSHTmuxRemotePlatformDetector.platform(
            exitStatus: result.exitStatus,
            stdout: result.stdout
        )
        trace.event("remotePlatform.detected", fields: ["platform": platform.description])
        return platform
    }

    static func openSessionChannel(
        using sshRoot: RemuxSSHRoot,
        trace: RemuxTransportStartupTrace
    ) async throws -> Channel {
        try await sshRoot.openSessionChannel(trace: trace)
    }

    static func activateControlSession(
        using preparedSession: SSHTmuxPreparedControlSession,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: RemuxTransportStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let childChannel = preparedSession.sessionChannel
        let viewportTraceState = SSHTmuxControlViewportTraceState(viewport: viewport)
        let firstOutputPromise = childChannel.eventLoop.makePromise(of: Void.self)
        let firstOutputGate = SSHTmuxControlFirstOutputGate(promise: firstOutputPromise)
        let firstOutputTimeout = childChannel.eventLoop.scheduleTask(
            deadline: .now() + controlNoResponseTimeout
        ) { [firstOutputGate] in
            firstOutputGate.fail(
                SSHTmuxControlTransportError.controlSessionNoResponse(controlNoResponseTimeout)
            )
        }
        let handler = SSHTmuxControlChannelHandler(
            viewportTraceState: viewportTraceState,
            onFirstOutput: { [firstOutputGate] data in
                firstOutputGate.succeed()
                trace.event(
                    "firstOutput",
                    fields: [
                        "bytes": "\(data.count)",
                        "preview": GhosttyRuntimeTrace.preview(data, limit: 80),
                    ]
                )
            },
            onOutput: onOutput,
            onFinish: { [firstOutputGate] error in
                firstOutputGate.fail(
                    error ?? SSHTmuxControlTransportError.controlSessionNoResponse(
                        controlNoResponseTimeout
                    )
                )
                onFinish(error)
            }
        )

        try await trace.stage("sessionChannel.handler.add") {
            try await childChannel.pipeline.addHandler(handler).get()
        }

        // Deliberately NO pseudo-terminal: the control-mode protocol is a
        // plain byte stream pumped straight into Ghostty's session parser. A PTY
        // would force POSIX `tmux -CC` (which demands a tty and wraps the stream
        // in a DCS 1000p envelope Ghostty's parser must not see) and adds
        // echo and CRLF line-discipline hazards. `tmux -C` over a bare exec
        // channel emits exactly the verified wire contract. Windows tmux.exe
        // uses pipe-capable `-CC`; its DCS envelope is removed before Ghostty
        // sees it. TERM is exported by the POSIX command line.
        try await trace.stage(
            "exec.request",
            fields: ["commandBytes": "\(command.lengthOfBytes(using: .utf8))"]
        ) {
            GhosttyRuntimeTrace.tmuxViewport(
                "startup.exec.request viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) commandBytes=\(command.lengthOfBytes(using: .utf8)) preview=\(GhosttyRuntimeTrace.preview(Data(command.utf8), limit: 220))"
            )
            handler.expectReply(for: .exec)
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        }
        do {
            try await trace.stage(
                "controlSession.firstOutput",
                fields: ["timeout": "\(controlNoResponseTimeout)"]
            ) {
                try await firstOutputPromise.futureResult.get()
            }
            firstOutputTimeout.cancel()
        } catch {
            firstOutputTimeout.cancel()
            throw error
        }
        trace.event("bootstrap.connected")

        return SSHTmuxControlConnection(
            claimedConnection: preparedSession.claimedConnection,
            sessionChannel: childChannel,
            viewportTraceState: viewportTraceState
        )
    }

    static func openControlSession(
        using claimedConnection: RemuxSSHClaimedRoot,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: RemuxTransportStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        var preparedSession: SSHTmuxPreparedControlSession?
        do {
            let childChannel = try await openSessionChannel(
                using: claimedConnection.sshRoot,
                trace: trace
            )
            let session = SSHTmuxPreparedControlSession(
                claimedConnection: claimedConnection,
                sessionChannel: childChannel
            )
            preparedSession = session

            return try await activateControlSession(
                using: session,
                viewport: viewport,
                command: command,
                controlNoResponseTimeout: controlNoResponseTimeout,
                trace: trace,
                onOutput: onOutput,
                onFinish: onFinish
            )
        } catch {
            if let preparedSession {
                await preparedSession.close(disposition: .invalidated)
            } else {
                await claimedConnection.releaseAfterFailedStart()
            }
            throw error
        }
    }
}

private final class SSHTmuxControlChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let viewportTraceState: SSHTmuxControlViewportTraceState
    private let onFirstOutput: @Sendable (Data) -> Void
    private let onOutput: @Sendable (Data) -> Void
    private let onFinish: @Sendable (Error?) -> Void
    private let lock = NIOLock()
    private var channelDataRouter = SSHTmuxControlChannelDataRouter()
    private var completionState = SSHTmuxControlChannelCompletionState()
    private var requestReplyTracker = SSHTmuxControlChannelRequestReplyTracker()

    init(
        viewportTraceState: SSHTmuxControlViewportTraceState,
        onFirstOutput: @escaping @Sendable (Data) -> Void,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.viewportTraceState = viewportTraceState
        self.onFirstOutput = onFirstOutput
        self.onOutput = onOutput
        self.onFinish = onFinish
    }

    func expectReply(for request: SSHTmuxControlChannelRequestKind) {
        lock.withLock {
            requestReplyTracker.expectReply(for: request)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [weak self] error in
            self?.finish(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            lock.withLock {
                completionState.recordExitStatus(Int(status.exitStatus))
            }
        case is ChannelSuccessEvent:
            lock.withLock {
                _ = requestReplyTracker.acknowledgeSuccess()
            }
        case is NIOSSH.ChannelFailureEvent:
            let failure = lock.withLock {
                (
                    request: requestReplyTracker.acknowledgeFailure(),
                    diagnostics: channelDataRouter.diagnostics
                )
            }
            finish(
                SSHTmuxControlTransportError.channelRequestFailed(
                    failure.request,
                    diagnostics: failure.diagnostics
                )
            )
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = channelData.data else {
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        let data = Data(bytes)
        let route = lock.withLock {
            channelDataRouter.route(type: channelData.type, data: data)
        }
        switch route {
        case .stdout(let reportFirstOutput):
            handleStdout(data, reportFirstOutput: reportFirstOutput)
        case .stderr:
            handleStderr(data)
        case .extendedData(let typeDescription):
            handleExtendedData(data, typeDescription: typeDescription)
        }
    }

    private func handleStdout(_ data: Data, reportFirstOutput: Bool) {
        traceControlByteChunk(
            data,
            direction: "rx",
            source: "ssh.channelRead",
            viewportDescription: viewportTraceState.description()
        )
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
        if reportFirstOutput {
            onFirstOutput(data)
        }
        onOutput(data)
    }

    private func handleStderr(_ data: Data) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.stderr bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
    }

    private func handleExtendedData(_ data: Data, typeDescription: String) {
        GhosttyRuntimeTrace.latency(
            "ssh.channelRead.extended type=\(typeDescription) bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
        )
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
        let completion = lock.withLock { () -> Result<Void, Error>? in
            completionState.finish(error, diagnostics: channelDataRouter.diagnostics)
        }

        guard let completion else { return }

        switch completion {
        case .success:
            onFinish(nil)
        case .failure(let error):
            onFinish(error)
        }
    }
}
