import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class TailscaleSSHCheckChallengeTests: XCTestCase {
    func testParsesVerificationURLFromTailscaleBanner() {
        let challenge = TailscaleSSHCheckChallenge.parse(
            from: "# Tailscale SSH requires an additional check.\n" +
                "# To authenticate, visit: https://login.tailscale.com/a/5fb81378394f\n"
        )

        XCTAssertEqual(
            challenge?.verificationURL.absoluteString,
            "https://login.tailscale.com/a/5fb81378394f"
        )
    }

    func testRejectsNonTailscaleAndInsecureURLs() {
        for banner in [
            "https://example.com/a/5fb81378394f",
            "http://login.tailscale.com/a/5fb81378394f",
            "https://login.tailscale.com.evil.example/a/5fb81378394f",
            "https://login.tailscale.com/login/5fb81378394f",
            "no verification URL",
        ] {
            XCTAssertNil(TailscaleSSHCheckChallenge.parse(from: banner), banner)
        }
    }

    func testHandshakePublishesChallengeOnceAndCompletesAfterAuthentication() throws {
        let eventRecorder = TailscaleSSHCheckEventRecorder()
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .minutes(5),
            onTailscaleSSHCheck: { event in
                eventRecorder.record(event)
            }
        )
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)
        let banner = NIOUserAuthBannerEvent(
            message: "Authenticate at https://login.tailscale.com/a/5fb81378394f",
            languageTag: "en"
        )

        channel.pipeline.fireUserInboundEventTriggered(banner)
        channel.pipeline.fireUserInboundEventTriggered(banner)
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())

        let events = eventRecorder.events
        XCTAssertEqual(events.count, 2)
        guard case .presented(let request) = events[0] else {
            return XCTFail("expected a presented event")
        }
        XCTAssertEqual(request.challenge.verificationURL.absoluteString, "https://login.tailscale.com/a/5fb81378394f")
        XCTAssertEqual(events[1], .finished(request.id))
        XCTAssertNoThrow(try handler.authenticated.wait())

        eventLoop.advanceTime(by: .minutes(5))
        XCTAssertEqual(eventRecorder.events, events, "completed handshakes must cancel their timeout")
        XCTAssertNoThrow(try channel.finish())
    }

    func testHandshakeReportsVerificationTimeoutAfterChallenge() throws {
        let eventRecorder = TailscaleSSHCheckEventRecorder()
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .seconds(1),
            onTailscaleSSHCheck: { event in
                eventRecorder.record(event)
            }
        )
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOUserAuthBannerEvent(
                message: "Authenticate at https://login.tailscale.com/a/5fb81378394f",
                languageTag: "en"
            )
        )
        eventLoop.advanceTime(by: .seconds(1))

        XCTAssertThrowsError(try handler.authenticated.wait()) { error in
            XCTAssertEqual(error as? TailscaleSSHCheckError, .verificationTimedOut)
        }
        let events = eventRecorder.events
        XCTAssertEqual(events.count, 2)
        guard case .presented(let request) = events[0] else {
            return XCTFail("expected a presented event")
        }
        XCTAssertEqual(events[1], .finished(request.id))
        XCTAssertNoThrow(try channel.finish())
    }

    func testHandshakeCancellationFinishesChallengeAndFailsAuthentication() throws {
        let eventRecorder = TailscaleSSHCheckEventRecorder()
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .minutes(5),
            onTailscaleSSHCheck: { event in
                eventRecorder.record(event)
            }
        )
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOUserAuthBannerEvent(
                message: "Authenticate at https://login.tailscale.com/a/5fb81378394f",
                languageTag: "en"
            )
        )
        guard case .presented(let request) = eventRecorder.events.first else {
            return XCTFail("expected a presented event")
        }

        request.cancel()
        eventLoop.run()

        XCTAssertThrowsError(try handler.authenticated.wait()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(eventRecorder.events, [.presented(request), .finished(request.id)])
        XCTAssertNoThrow(try channel.finish())
    }

    func testHandshakeDismissesChallengeWhenConnectionCloses() throws {
        let eventRecorder = TailscaleSSHCheckEventRecorder()
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .minutes(5),
            onTailscaleSSHCheck: { event in
                eventRecorder.record(event)
            }
        )
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)

        channel.pipeline.fireUserInboundEventTriggered(
            NIOUserAuthBannerEvent(
                message: "Authenticate at https://login.tailscale.com/a/5fb81378394f",
                languageTag: "en"
            )
        )
        channel.pipeline.fireChannelInactive()

        XCTAssertThrowsError(try handler.authenticated.wait())
        let events = eventRecorder.events
        XCTAssertEqual(events.count, 2)
        guard case .presented(let request) = events[0] else {
            return XCTFail("expected a presented event")
        }
        XCTAssertEqual(events[1], .finished(request.id))
        XCTAssertNoThrow(try channel.finish())
    }

    /// The login's timeout stops while the user approves the key on the device, so a slow approval isn't an
    /// unreachable server; the server then answers within the timeout, counted again from the approval.
    func testApprovingTheKeyStopsTheLoginsTimeoutUntilItEnds() {
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(eventLoop: eventLoop, timeout: .seconds(10))
        var result: Result<Void, Error>?
        handler.authenticated.whenComplete { result = $0 }

        eventLoop.advanceTime(by: .seconds(5))
        handler.approvalStarted()
        eventLoop.advanceTime(by: .seconds(120))
        XCTAssertNil(result, "the login timed out while the user approved the key")

        handler.approvalEnded()
        eventLoop.advanceTime(by: .seconds(9))
        XCTAssertNil(result)
        eventLoop.advanceTime(by: .seconds(1))
        guard case .failure(let error)? = result, case .connectTimeout? = error as? ChannelError else {
            return XCTFail("expected the login to time out after the approval, got \(String(describing: result))")
        }
    }

    /// A connection that closes while the device waits for approval, as when the server's grace period ends,
    /// says so rather than reporting a bare disconnect.
    func testAConnectionClosedDuringApprovalSaysSo() {
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(eventLoop: eventLoop, timeout: .seconds(10))
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)

        handler.approvalStarted()
        channel.pipeline.fireChannelInactive()

        XCTAssertThrowsError(try handler.authenticated.wait()) { error in
            XCTAssertEqual(error as? SSHKeyApprovalError, .interrupted)
        }
    }

    /// A failed key exchange mid-session reaches this handler long after authentication.
    func testErrorAfterAuthenticationClosesTheConnection() throws {
        struct KeyExchangeFailed: Error {}
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .minutes(5),
            onTailscaleSSHCheck: nil
        )
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)

        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        XCTAssertNoThrow(try handler.authenticated.wait())

        channel.pipeline.fireErrorCaught(KeyExchangeFailed())
        eventLoop.run()

        XCTAssertThrowsError(try channel.finish()) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }
    }

    func testInitialHostTrustErrorSurvivesTeardownBeforeBootstrapResumes() throws {
        for kind in [SSHHostKeyTrustChallenge.Kind.unknown, .changed] {
            let eventLoop = EmbeddedEventLoop()
            let channel = EmbeddedChannel(loop: eventLoop)
            let initialization = configureBootstrapChannel(channel)
            try channel.connect(to: SocketAddress(unixDomainSocketPath: "/remux-bootstrap-test")).wait()
            let challenge = SSHHostKeyTrustChallenge(
                kind: kind,
                serverID: UUID(),
                host: "bootstrap.test",
                trustedKeyType: kind == .changed ? "ssh-ed25519" : nil,
                trustedOpenSSHPublicKey: kind == .changed ? "ssh-ed25519 previous-key" : nil,
                receivedKeyType: "ssh-ed25519",
                receivedOpenSSHPublicKey: "ssh-ed25519 received-key"
            )

            channel.pipeline.fireErrorCaught(TrustedHostStoreError.hostKeyTrustRequired(challenge))
            eventLoop.run()
            XCTAssertFalse(channel.isActive)
            XCTAssertThrowsError(try channel.pipeline.handler(type: RemuxSSHRootHandshakeHandler.self).wait()) {
                XCTAssertEqual($0 as? ChannelPipelineError, .notFound)
            }

            // The caller resumes after the handler is gone, using the actual initializer result.
            let connection = try initialization.wait()
            XCTAssertTrue(connection.channel === channel)
            XCTAssertThrowsError(try connection.authenticated.wait()) { error in
                guard case TrustedHostStoreError.hostKeyTrustRequired(let received) = error else {
                    return XCTFail("Expected the original host-trust error, got \(error)")
                }
                XCTAssertEqual(received, challenge)
            }
            _ = try? channel.finish(acceptAlreadyClosed: true)
        }
    }

    func testEarlyAuthenticationErrorFinishesTailscaleChallengeOnce() throws {
        struct AuthenticationFailed: Error {}
        let recorder = TailscaleSSHCheckEventRecorder()
        let eventLoop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: eventLoop)
        let initialization = configureBootstrapChannel(channel) { recorder.record($0) }
        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/remux-bootstrap-test")).wait()
        channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(
            message: "Authenticate at https://login.tailscale.com/a/5fb81378394f",
            languageTag: "en"
        ))
        guard case .presented(let request) = recorder.events.first else {
            return XCTFail("Expected a Tailscale verification challenge")
        }

        channel.pipeline.fireErrorCaught(AuthenticationFailed())
        eventLoop.run()
        let connection = try initialization.wait()
        XCTAssertFalse(connection.channel.isActive)
        XCTAssertThrowsError(try connection.authenticated.wait()) { XCTAssertTrue($0 is AuthenticationFailed) }
        XCTAssertEqual(recorder.events, [.presented(request), .finished(request.id)])
        eventLoop.advanceTime(by: .minutes(5))
        XCTAssertEqual(recorder.events, [.presented(request), .finished(request.id)])
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    private func configureBootstrapChannel(
        _ channel: EmbeddedChannel,
        onTailscaleSSHCheck: (@Sendable (TailscaleSSHCheckEvent) -> Void)? = nil
    ) -> EventLoopFuture<(channel: Channel, authenticated: EventLoopFuture<Void>)> {
        let server = SavedServer(displayName: "bootstrap", host: "bootstrap.test", username: "tester")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trustedHosts = TrustedHostStore(rootURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RemuxSSHRootBootstrap.configureChannel(channel, using: RemuxSSHRootConfiguration(
            host: server.host,
            port: server.port,
            authenticationMethod: { _ in .passwordBased(username: "tester", password: "unused") },
            hostKeyValidator: trustedHosts.validator(for: server),
            connectTimeout: .seconds(10),
            onTailscaleSSHCheck: onTailscaleSSHCheck
        ))
    }
}

private final class TailscaleSSHCheckEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [TailscaleSSHCheckEvent] = []

    var events: [TailscaleSSHCheckEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: TailscaleSSHCheckEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
