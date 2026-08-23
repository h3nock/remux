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
