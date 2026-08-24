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
    let authenticationTimeout: TimeAmount?
    let onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)?
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
        authenticationTimeout: TimeAmount? = nil,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil,
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
        self.authenticationTimeout = authenticationTimeout
        self.onTailscaleSSHCheck = onTailscaleSSHCheck
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
            connectTimeout: connectTimeout,
            authenticationTimeout: authenticationTimeout,
            onTailscaleSSHCheck: onTailscaleSSHCheck
        )
    }
}

final class SSHTmuxControlChannelCompletionState: @unchecked Sendable {
    private let lock = NIOLock()
    private var didFinish = false
    private var exitStatus: Int?

    func recordExitStatus(_ status: Int) {
        lock.withLock {
            exitStatus = status
        }
    }

    func finish(
        _ error: Error?,
        diagnostics: SSHTmuxStartupDiagnostics?
    ) -> Result<Void, Error>? {
        lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true

            if let execError = error as? RemuxSSHExecSessionError,
               execError == .requestFailed {
                return .failure(
                    SSHTmuxControlTransportError.channelRequestFailed(
                        .exec,
                        diagnostics: diagnostics
                    )
                )
            }

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
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
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
            establishedConnection = try await SSHTmuxControlBootstrap.openControlSession(
                using: claimedConnection,
                viewport: startupViewport,
                command: tmuxAttachCommand(viewport: startupViewport),
                controlNoResponseTimeout: configuration.controlNoResponseTimeout,
                trace: startupTrace,
                onOutput: { [inboundStream] data in
                    inboundStream.yield(data)
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
                try await establishedConnection.write(data)
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
        try await connection.write(data)
        GhosttyRuntimeTrace.latency(
            "transport.send end bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: start))"
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

    private func tmuxAttachCommand(viewport: TmuxControlViewport) -> String {
        SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: configuration.tmuxExecutable,
            sessionName: configuration.sessionName,
            initialViewport: viewport
        )
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
    private let execConnection: RemuxSSHExecConnection
    private let viewportTraceState: SSHTmuxControlViewportTraceState

    init(
        execConnection: RemuxSSHExecConnection,
        viewportTraceState: SSHTmuxControlViewportTraceState
    ) {
        self.execConnection = execConnection
        self.viewportTraceState = viewportTraceState
    }

    var isControlChannelActive: Bool {
        execConnection.isActive
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        traceControlByteChunk(
            data,
            direction: "tx",
            source: "ssh.writeAndFlush",
            viewportDescription: viewportTraceState.description()
        )
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
            try await execConnection.write(data)
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
        let rootDisposition: RemuxSSHRootLeaseDisposition
        if childDrain == .dirty {
            rootDisposition = .invalidated
        } else {
            rootDisposition = disposition.sshRootLeaseDisposition
        }
        await execConnection.close(disposition: rootDisposition)
    }
}

private enum SSHTmuxControlBootstrap {
    static func activateControlSession(
        using claimedConnection: RemuxSSHClaimedRoot,
        viewport: TmuxControlViewport,
        command: String,
        controlNoResponseTimeout: TimeAmount,
        trace: RemuxTransportStartupTrace,
        onOutput: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> SSHTmuxControlConnection {
        let viewportTraceState = SSHTmuxControlViewportTraceState(viewport: viewport)
        let firstOutputPromise = claimedConnection.sshRoot.rootChannel.eventLoop.makePromise(
            of: Void.self
        )
        let firstOutputGate = SSHTmuxControlFirstOutputGate(promise: firstOutputPromise)
        let router = SSHTmuxControlChannelDataRouter()
        let completionState = SSHTmuxControlChannelCompletionState()

        GhosttyRuntimeTrace.tmuxViewport(
            "startup.exec.request viewport=\(GhosttyRuntimeTrace.viewportDescription(viewport)) commandBytes=\(command.lengthOfBytes(using: .utf8)) preview=\(GhosttyRuntimeTrace.preview(Data(command.utf8), limit: 220))"
        )

        // Deliberately NO pseudo-terminal: the control-mode protocol is a
        // plain byte stream pumped straight into Ghostty's session parser. A PTY
        // would force `tmux -CC` (which demands a tty and wraps the stream
        // in a DCS 1000p envelope Ghostty's parser must not see) and adds
        // echo and CRLF line-discipline hazards. `tmux -C` over a bare exec
        // channel emits exactly the verified wire contract; TERM is exported
        // by the remote command line and the client size is owned by the
        // session's refresh-client reporting.
        let execConnection = try await RemuxSSHExecSession.open(
            using: claimedConnection,
            command: command,
            trace: trace,
            onData: { type, data in
                switch router.route(type: type, data: data) {
                case .stdout(let reportFirstOutput):
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
                        firstOutputGate.succeed()
                        trace.event(
                            "firstOutput",
                            fields: [
                                "bytes": "\(data.count)",
                                "preview": GhosttyRuntimeTrace.preview(data, limit: 80),
                            ]
                        )
                    }
                    onOutput(data)
                case .stderr:
                    GhosttyRuntimeTrace.latency(
                        "ssh.channelRead.stderr bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
                    )
                case .extendedData:
                    GhosttyRuntimeTrace.latency(
                        "ssh.channelRead.extended type=\(type.description) bytes=\(data.count) preview=\(GhosttyRuntimeTrace.preview(data, limit: 160))"
                    )
                }
            },
            onFinish: { exitStatus, error in
                if let exitStatus {
                    completionState.recordExitStatus(exitStatus)
                }
                guard let completion = completionState.finish(
                    error,
                    diagnostics: router.diagnostics
                ) else {
                    return
                }
                let failure = completion.failure
                firstOutputGate.fail(
                    failure ?? SSHTmuxControlTransportError.controlSessionNoResponse(
                        controlNoResponseTimeout
                    )
                )
                onFinish(failure)
            }
        )

        let firstOutputTimeout = claimedConnection.sshRoot.rootChannel.eventLoop.scheduleTask(
            deadline: .now() + controlNoResponseTimeout
        ) { [firstOutputGate] in
            firstOutputGate.fail(
                SSHTmuxControlTransportError.controlSessionNoResponse(controlNoResponseTimeout)
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
            await execConnection.close(disposition: .invalidated)
            throw error
        }
        trace.event("bootstrap.connected")

        return SSHTmuxControlConnection(
            execConnection: execConnection,
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
        try await activateControlSession(
            using: claimedConnection,
            viewport: viewport,
            command: command,
            controlNoResponseTimeout: controlNoResponseTimeout,
            trace: trace,
            onOutput: onOutput,
            onFinish: onFinish
        )
    }
}
