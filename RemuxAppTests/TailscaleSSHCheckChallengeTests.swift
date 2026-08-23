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
        let challengeRecorder = TailscaleSSHCheckChallengeRecorder()
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .minutes(5),
            onTailscaleSSHCheck: { challenge in
                challengeRecorder.record(challenge)
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

        XCTAssertEqual(challengeRecorder.challenges.count, 1)
        XCTAssertNoThrow(try handler.authenticated.wait())
        XCTAssertNoThrow(try channel.finish())
    }

    func testHandshakeReportsVerificationTimeoutAfterChallenge() throws {
        let eventLoop = EmbeddedEventLoop()
        let handler = RemuxSSHRootHandshakeHandler(
            eventLoop: eventLoop,
            timeout: .seconds(1)
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
        XCTAssertNoThrow(try channel.finish())
    }
}

private final class TailscaleSSHCheckChallengeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChallenges: [TailscaleSSHCheckChallenge] = []

    var challenges: [TailscaleSSHCheckChallenge] {
        lock.withLock { recordedChallenges }
    }

    func record(_ challenge: TailscaleSSHCheckChallenge) {
        lock.withLock {
            recordedChallenges.append(challenge)
        }
    }
}
