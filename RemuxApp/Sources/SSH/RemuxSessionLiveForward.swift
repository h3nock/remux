import Foundation
import NIO
@preconcurrency import NIOSSH

/// Unwraps direct-TCPIP `SSHChannelData` into raw `ByteBuffer` traffic and
/// wraps writes back, opting the child channel into remote half-closure so
/// CHANNEL_EOF surfaces as input-closed instead of a full close.
final class RemuxSSHChannelStreamCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data,
              case .channel = channelData.type
        else {
            context.fireErrorCaught(RemuxLiveForwardError.unexpectedChannelData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}

enum RemuxLiveForwardError: Error, Equatable, Sendable {
    case unexpectedChannelData
    case listenerAddressUnavailable
}

/// One side of a bridged connection pair. Reads from its own channel are
/// written to the peer; peer overload pauses this side's reads; half-close
/// and full close propagate in both directions.
final class RemuxLiveForwardBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    private let onClosed: @Sendable () -> Void

    init(peer: Channel, onClosed: @escaping @Sendable () -> Void) {
        self.peer = peer
        self.onClosed = onClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // This channel's outbound buffer filling up must pause the peer's
        // reads, or the bridge buffers unboundedly between a fast producer
        // and a slow consumer.
        let writable = context.channel.isWritable
        let peer = peer
        peer.setOption(ChannelOptions.autoRead, value: writable).whenSuccess {
            if writable {
                peer.read()
            }
        }
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            peer.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer.close(promise: nil)
    }
}

/// Opens the remote leg of one bridged connection. Production wraps a
/// direct-TCPIP child channel on the authenticated SSH root; tests may
/// substitute any channel source. Opened channels must not auto-read until
/// the bridge attaches.
struct RemuxLiveForwardConnectionOpener: Sendable {
    let open: @Sendable () async throws -> Channel

    static func directTCPIP(
        sshRoot: RemuxSSHRoot,
        target: RemuxSSHDirectTCPIPTarget,
        originatorAddress: SocketAddress
    ) -> RemuxLiveForwardConnectionOpener {
        RemuxLiveForwardConnectionOpener {
            try await sshRoot.openDirectTCPIPChannel(
                to: target,
                originatorAddress: originatorAddress,
                trace: RemuxTransportStartupTrace(flowID: nil),
                channelInitializer: { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            RemuxSSHChannelStreamCodec()
                        )
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    return channel.setOption(
                        ChannelOptions.autoRead,
                        value: false
                    )
                }
            )
        }
    }
}

private final class RemuxLiveForwardAcceptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptHandler: (@Sendable (Channel) -> Void)?
    private var pending: [Channel] = []

    func install(_ handler: @escaping @Sendable (Channel) -> Void) {
        let queued: [Channel] = lock.withLock {
            acceptHandler = handler
            let queued = pending
            pending.removeAll()
            return queued
        }
        for channel in queued {
            handler(channel)
        }
    }

    func accept(_ channel: Channel) {
        let handler: (@Sendable (Channel) -> Void)? = lock.withLock {
            if let acceptHandler { return acceptHandler }
            pending.append(channel)
            return nil
        }
        handler?(channel)
    }
}

private final class RemuxLiveForwardAcceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let sink: RemuxLiveForwardAcceptSink

    init(sink: RemuxLiveForwardAcceptSink) {
        self.sink = sink
    }

    func channelActive(context: ChannelHandlerContext) {
        sink.accept(context.channel)
        context.fireChannelActive()
    }
}

/// A loopback-only listener bridging each accepted local TCP connection to
/// one remote channel from the opener.
actor RemuxLiveForwardListener {
    private struct Pair {
        let local: Channel
        let remote: Channel
    }

    nonisolated let localPort: Int
    private let serverChannel: Channel
    private let opener: RemuxLiveForwardConnectionOpener
    private var pairs: [UUID: Pair] = [:]
    private var isShutDown = false

    static func start(
        opener: RemuxLiveForwardConnectionOpener,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> RemuxLiveForwardListener {
        let sink = RemuxLiveForwardAcceptSink()
        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    RemuxLiveForwardAcceptHandler(sink: sink)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let localPort = serverChannel.localAddress?.port else {
            try await serverChannel.close()
            throw RemuxLiveForwardError.listenerAddressUnavailable
        }
        let listener = RemuxLiveForwardListener(
            serverChannel: serverChannel,
            localPort: localPort,
            opener: opener
        )
        sink.install { channel in
            Task { await listener.bridge(channel) }
        }
        return listener
    }

    private init(
        serverChannel: Channel,
        localPort: Int,
        opener: RemuxLiveForwardConnectionOpener
    ) {
        self.serverChannel = serverChannel
        self.localPort = localPort
        self.opener = opener
    }

    var activeConnectionCount: Int {
        pairs.count
    }

    /// Closes the listener and every bridged pair. Throws when a remote
    /// (SSH child) channel refuses to close, so callers can retire the
    /// shared root from reuse; local browser-side close failures are the
    /// normal churn of page lifecycle and never dirty the session.
    func shutdown() async throws {
        guard !isShutDown else { return }
        isShutDown = true
        do {
            try await serverChannel.close()
        } catch ChannelError.alreadyClosed {
        } catch {
            NSLog(
                "Remux live forward listener close failed: %@",
                String(describing: error)
            )
        }
        let active = pairs.values
        pairs.removeAll()
        var remoteCloseFailure: Error?
        for pair in active {
            pair.local.close(promise: nil)
            do {
                try await pair.remote.close()
            } catch ChannelError.alreadyClosed {
            } catch {
                remoteCloseFailure = error
            }
        }
        if let remoteCloseFailure {
            throw remoteCloseFailure
        }
    }

    private func bridge(_ local: Channel) async {
        guard !isShutDown else {
            local.close(promise: nil)
            return
        }
        let id = UUID()
        do {
            let remote = try await opener.open()
            guard !isShutDown else {
                local.close(promise: nil)
                remote.close(promise: nil)
                return
            }
            let onClosed: @Sendable () -> Void = { [weak self] in
                Task { await self?.removePair(id) }
            }
            try await local.pipeline.addHandler(
                RemuxLiveForwardBridgeHandler(peer: remote, onClosed: onClosed)
            ).get()
            try await remote.pipeline.addHandler(
                RemuxLiveForwardBridgeHandler(peer: local, onClosed: onClosed)
            ).get()
            pairs[id] = Pair(local: local, remote: remote)
            try await local.setOption(ChannelOptions.autoRead, value: true).get()
            local.read()
            try await remote.setOption(ChannelOptions.autoRead, value: true).get()
            remote.read()
        } catch {
            NSLog(
                "Remux live forward bridge setup failed: %@",
                String(describing: error)
            )
            local.close(promise: nil)
            removePair(id)
        }
    }

    private func removePair(_ id: UUID) {
        guard let pair = pairs.removeValue(forKey: id) else { return }
        pair.local.close(promise: nil)
        pair.remote.close(promise: nil)
    }
}

struct RemuxLiveForwardHandle: Sendable {
    let localPort: Int
    let close: @Sendable () async throws -> Void
}

/// Live-page forwards on the server's pooled SSH connection. A forward claims the connection, as one of its
/// consumers, while it listens, and each browser connection it accepts opens a direct-TCPIP channel on it.
/// Closing gives the connection back, out of reuse when a channel refused to close.
struct RemuxPooledLiveForwardProvider: Sendable {
    /// One claim of the connection for a forward: what opens a channel per browser connection, and how to give
    /// the connection back.
    struct Claim: Sendable {
        let opener: RemuxLiveForwardConnectionOpener
        let release: @Sendable (RemuxSSHRootLeaseDisposition) async -> Void
    }

    private let claim: @Sendable (RemuxSSHDirectTCPIPTarget) async throws -> Claim

    init(claim: @escaping @Sendable (RemuxSSHDirectTCPIPTarget) async throws -> Claim) {
        self.claim = claim
    }

    init(
        sshRootService: RemuxSSHRootService,
        rootKey: RemuxSSHRootKey,
        rootConfiguration: RemuxSSHRootConfiguration
    ) {
        self.init { target in
            let claimedRoot = try await sshRootService.claimRoot(
                for: rootKey,
                configuration: rootConfiguration,
                trace: RemuxTransportStartupTrace(flowID: nil)
            )
            return Claim(
                opener: .directTCPIP(
                    sshRoot: claimedRoot.sshRoot,
                    target: target,
                    originatorAddress: Self.originatorAddress
                ),
                release: { disposition in await claimedRoot.release(disposition) }
            )
        }
    }

    func openForward(
        to target: RemuxSSHDirectTCPIPTarget
    ) async throws -> RemuxLiveForwardHandle {
        let claim = try await claim(target)
        let listener: RemuxLiveForwardListener
        do {
            listener = try await RemuxLiveForwardListener.start(opener: claim.opener)
        } catch {
            // The listener is local: nothing was opened on the connection.
            await claim.release(.reusable)
            throw error
        }
        let teardown = RemuxSFTPLeaseTeardown(
            closeChild: { try await listener.shutdown() },
            releaseRoot: claim.release
        )
        return RemuxLiveForwardHandle(
            localPort: listener.localPort,
            close: { try await teardown.close() }
        )
    }

    // The SSH wire format requires an IP-literal originator; the real
    // originator is always this device's loopback browser connection.
    private static let originatorAddress = try! SocketAddress(
        ipAddress: "127.0.0.1",
        port: 0
    )
}
