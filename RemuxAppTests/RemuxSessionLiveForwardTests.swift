import Foundation
import NIO
import XCTest

@testable import Remux

final class RemuxSessionLiveForwardTests: XCTestCase {
    private var group: EventLoopGroup { MultiThreadedEventLoopGroup.singleton }

    func testForwardBridgesRequestAndResponse() async throws {
        let server = try await LiveForwardTestServer.start(mode: .echo, group: group)
        defer { server.stop() }
        let listener = try await RemuxLiveForwardListener.start(
            opener: server.opener(group: group)
        )

        let client = try await LiveForwardTestClient.connect(
            port: listener.localPort,
            group: group
        )
        try await client.send(Data("hello-through-tunnel".utf8))
        try await waitFor("echoed response") {
            client.receivedData == Data("hello-through-tunnel".utf8)
        }

        try await listener.shutdown()
    }

    func testLargeTransferSurvivesBridgeBackpressure() async throws {
        let server = try await LiveForwardTestServer.start(mode: .echo, group: group)
        defer { server.stop() }
        let listener = try await RemuxLiveForwardListener.start(
            opener: server.opener(group: group)
        )
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

        let client = try await LiveForwardTestClient.connect(
            port: listener.localPort,
            group: group
        )
        try await client.send(payload)
        try await waitFor("large payload round trip", timeout: 30) {
            client.receivedData.count == payload.count
        }
        XCTAssertEqual(client.receivedData, payload)

        try await listener.shutdown()
    }

    func testHalfCloseDeliversRemoteResponseAfterLocalEOF() async throws {
        let server = try await LiveForwardTestServer.start(
            mode: .replyOnEOF,
            group: group
        )
        defer { server.stop() }
        let listener = try await RemuxLiveForwardListener.start(
            opener: server.opener(group: group)
        )

        let client = try await LiveForwardTestClient.connect(
            port: listener.localPort,
            group: group
        )
        try await client.send(Data("abc".utf8))
        try await client.send(Data("defg".utf8))
        try await client.closeOutput()
        try await waitFor("EOF-gated reply") {
            client.receivedData == Data("received:7".utf8)
        }
        try await waitFor("connection close after both halves") {
            client.isClosed
        }

        try await listener.shutdown()
    }

    func testShutdownClosesActiveConnectionsAndRefusesNew() async throws {
        let server = try await LiveForwardTestServer.start(mode: .echo, group: group)
        defer { server.stop() }
        let listener = try await RemuxLiveForwardListener.start(
            opener: server.opener(group: group)
        )
        let client = try await LiveForwardTestClient.connect(
            port: listener.localPort,
            group: group
        )
        try await client.send(Data("ping".utf8))
        try await waitFor("bridge established") {
            await listener.activeConnectionCount == 1
        }

        try await listener.shutdown()

        try await waitFor("active connection closed") { client.isClosed }
        let count = await listener.activeConnectionCount
        XCTAssertEqual(count, 0)
        do {
            _ = try await LiveForwardTestClient.connect(
                port: listener.localPort,
                group: group
            )
            XCTFail("listener should refuse connections after shutdown")
        } catch {}
    }

    func testPooledForwardHoldsItsClaimWhileOpenAndGivesItBackForReuse() async throws {
        let server = try await LiveForwardTestServer.start(mode: .echo, group: group)
        defer { server.stop() }
        let recorder = LiveForwardClaimRecorder()
        let provider = RemuxPooledLiveForwardProvider { [group] target in
            await recorder.claimed(target)
            return RemuxPooledLiveForwardProvider.Claim(
                opener: server.opener(group: group),
                release: { disposition in await recorder.released(disposition) }
            )
        }
        let target = try RemuxSSHDirectTCPIPTarget(host: "localhost", port: 3000)

        let handle = try await provider.openForward(to: target)
        let client = try await LiveForwardTestClient.connect(port: handle.localPort, group: group)
        try await client.send(Data("live".utf8))
        try await waitFor("echo through the pooled forward") {
            client.receivedData == Data("live".utf8)
        }
        let claimedTargets = await recorder.targets
        XCTAssertEqual(claimedTargets, [target])
        let releasesWhileOpen = await recorder.dispositions
        XCTAssertEqual(releasesWhileOpen, [], "An open forward keeps its claim on the connection.")

        try await handle.close()

        try await waitFor("close ends the bridged connection") { client.isClosed }
        let releasesAfterClose = await recorder.dispositions
        XCTAssertEqual(releasesAfterClose, [.reusable])
    }

    func testPooledForwardWhoseClaimFailsOpensNothing() async throws {
        enum ClaimFailure: Error { case unreachable }
        let provider = RemuxPooledLiveForwardProvider { _ in throw ClaimFailure.unreachable }

        do {
            _ = try await provider.openForward(to: try RemuxSSHDirectTCPIPTarget(host: "localhost", port: 3000))
            XCTFail("a forward without the connection should fail")
        } catch ClaimFailure.unreachable {}
    }

    private func waitFor(
        _ message: String,
        timeout: TimeInterval = 5,
        condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message, file: file, line: line)
    }
}

private final class LiveForwardTestServer: @unchecked Sendable {
    enum Mode {
        case echo
        case replyOnEOF
    }

    let serverChannel: Channel
    private let port: Int

    private init(serverChannel: Channel, port: Int) {
        self.serverChannel = serverChannel
        self.port = port
    }

    static func start(
        mode: Mode,
        group: EventLoopGroup
    ) async throws -> LiveForwardTestServer {
        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(LiveForwardTestServerHandler(mode: mode))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = serverChannel.localAddress?.port else {
            throw RemuxLiveForwardError.listenerAddressUnavailable
        }
        return LiveForwardTestServer(serverChannel: serverChannel, port: port)
    }

    func opener(group: EventLoopGroup) -> RemuxLiveForwardConnectionOpener {
        let port = port
        return RemuxLiveForwardConnectionOpener {
            try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port)
                .get()
        }
    }

    func stop() {
        serverChannel.close(promise: nil)
    }
}

private final class LiveForwardTestServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let mode: LiveForwardTestServer.Mode
    private var receivedByteCount = 0

    init(mode: LiveForwardTestServer.Mode) {
        self.mode = mode
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch mode {
        case .echo:
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        case .replyOnEOF:
            receivedByteCount += buffer.readableBytes
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event, case .replyOnEOF = mode {
            var buffer = context.channel.allocator.buffer(capacity: 24)
            buffer.writeString("received:\(receivedByteCount)")
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class LiveForwardTestClient: @unchecked Sendable {
    private let channel: Channel
    private let recorder: LiveForwardTestClientRecorder

    private init(channel: Channel, recorder: LiveForwardTestClientRecorder) {
        self.channel = channel
        self.recorder = recorder
    }

    static func connect(
        port: Int,
        group: EventLoopGroup
    ) async throws -> LiveForwardTestClient {
        let recorder = LiveForwardTestClientRecorder()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(recorder)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        return LiveForwardTestClient(channel: channel, recorder: recorder)
    }

    var receivedData: Data { recorder.receivedData }
    var isClosed: Bool { recorder.isClosed }

    func send(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
    }

    func closeOutput() async throws {
        try await channel.close(mode: .output)
    }
}

private final class LiveForwardTestClientRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var data = Data()
    private var closed = false

    var receivedData: Data { lock.withLock { data } }
    var isClosed: Bool { lock.withLock { closed } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.withLock { self.data.append(contentsOf: bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock { closed = true }
        context.fireChannelInactive()
    }
}

private actor LiveForwardClaimRecorder {
    private(set) var targets: [RemuxSSHDirectTCPIPTarget] = []
    private(set) var dispositions: [RemuxSSHRootLeaseDisposition] = []

    func claimed(_ target: RemuxSSHDirectTCPIPTarget) {
        targets.append(target)
    }

    func released(_ disposition: RemuxSSHRootLeaseDisposition) {
        dispositions.append(disposition)
    }
}
