@preconcurrency import Citadel
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import CryptoKit
import NIOEmbedded
@preconcurrency import NIOSSH
import LocalAuthentication
import XCTest
@testable import Remux

final class SSHAuthenticationMethodFactoryTests: XCTestCase {
    /// The login's timeout stops while the user approves the key and starts again after; closing the
    /// connection meanwhile ends the approval, which takes its prompt away, and offers no key. The prompt names
    /// the server.
    func testClosingTheConnectionDuringApprovalEndsItAndOffersNoKey() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let closed = loop.makePromise(of: Void.self)
        let offer = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        let started = expectation(description: "approval started")
        let events = NIOLockedValueBox<[String]>([])
        let delegate = SecureEnclaveSSHAuthenticationDelegate(
            username: "test",
            key: SecureEnclaveSSHKey(representation: Data([1]), publicKey: Data()),
            reason: "Connect to Mac mini",
            login: RemuxSSHLogin(
                closeFuture: closed.futureResult,
                approvalStarted: { events.withLockedValue { $0.append("started") } },
                approvalEnded: { events.withLockedValue { $0.append("ended") } }
            ),
            approve: { _, reason in
                XCTAssertEqual(reason, "Connect to Mac mini")
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                XCTFail("the approval outlived its connection")
                throw CancellationError()
            }
        )
        try await loop.submit {
            delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: offer)
        }.get()
        await fulfillment(of: [started], timeout: 3)
        closed.succeed(())
        do {
            _ = try await offer.futureResult.get()
            XCTFail("A closed connection must not receive a signing key")
        } catch is CancellationError {
        }
        XCTAssertEqual(events.withLockedValue { $0 }, ["started", "ended"])
    }

    func testNoneDelegateOffersNoneAuthenticationExactlyOnce() async throws {
        let eventLoop = EmbeddedEventLoop()
        let delegate = NoneSSHAuthenticationDelegate(username: "demo")
        let firstOffer = eventLoop.makePromise(
            of: NIOSSHUserAuthenticationOffer?.self
        )

        delegate.nextAuthenticationType(
            availableMethods: [],
            nextChallengePromise: firstOffer
        )

        let offer = try await firstOffer.futureResult.get()
        XCTAssertEqual(offer?.username, "demo")
        guard let offer, case .none = offer.offer else {
            return XCTFail("expected SSH none authentication")
        }

        let secondOffer = eventLoop.makePromise(
            of: NIOSSHUserAuthenticationOffer?.self
        )
        delegate.nextAuthenticationType(
            availableMethods: [],
            nextChallengePromise: secondOffer
        )

        do {
            _ = try await secondOffer.futureResult.get()
            XCTFail("expected the delegate to reject a second offer")
        } catch SSHClientError.allAuthenticationOptionsFailed {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

@MainActor
final class SecureEnclaveSSHApprovalTests: XCTestCase {
    private struct Signed: Error {}

    private let key = SecureEnclaveSSHKey(representation: Data([1]), publicKey: Data())

    /// iOS's prompt retries a face or finger it didn't recognize itself; Remux never brings up another.
    func testAFailedApprovalIsNotAskedAgain() async {
        var evaluations = 0
        do {
            _ = try await SecureEnclaveSSHApproval.approve(
                key,
                reason: "Connect to Mac mini",
                isActive: { true },
                evaluate: { _, _ in
                    evaluations += 1
                    throw LAError(.authenticationFailed)
                },
                signingKey: { _, _ in
                    XCTFail("signed without approval")
                    throw Signed()
                }
            )
            XCTFail("expected the failed approval")
        } catch {
            XCTAssertEqual((error as? LAError)?.code, .authenticationFailed)
        }
        XCTAssertEqual(evaluations, 1)
    }

    /// Signing on the connection's event loop, after the approval, can't bring up a second prompt.
    func testSigningAfterApprovalCannotPromptAgain() async {
        do {
            _ = try await SecureEnclaveSSHApproval.approve(
                key,
                reason: "Connect to Mac mini",
                isActive: { true },
                evaluate: { context, _ in
                    XCTAssertFalse(context.interactionNotAllowed)
                },
                signingKey: { _, context in
                    XCTAssertTrue(context.interactionNotAllowed)
                    throw Signed()
                }
            )
            XCTFail("expected the test's signing key")
        } catch {
            XCTAssertTrue(error is Signed, "\(error)")
        }
    }

    /// A prompt over another app, or while Remux leaves the screen, isn't one the user asked for.
    func testNoPromptWhileRemuxIsNotInFront() async {
        do {
            _ = try await SecureEnclaveSSHApproval.approve(
                key,
                reason: "Connect to Mac mini",
                isActive: { false },
                evaluate: { _, _ in XCTFail("prompted while Remux wasn't in front") },
                signingKey: { _, _ in throw Signed() }
            )
            XCTFail("expected the approval to wait for the user")
        } catch {
            XCTAssertEqual(error as? SSHKeyApprovalError, .required)
        }
    }

    /// The device shows one prompt at a time: a second server's approval waits for the first, and giving up
    /// on the first ends its prompt and lets the second go.
    func testApprovalsTakeTurnsAndGivingUpEndsTheirPrompt() async throws {
        let firstShown = expectation(description: "first prompt")
        let secondShown = expectation(description: "second prompt")
        var secondStarted = false
        let first = Task {
            try await SecureEnclaveSSHApproval.approve(
                key,
                reason: "Connect to Mac mini",
                isActive: { true },
                evaluate: { _, _ in
                    firstShown.fulfill()
                    try await Task.sleep(for: .seconds(60))
                },
                signingKey: { _, _ in throw Signed() }
            )
        }
        await fulfillment(of: [firstShown], timeout: 3)
        let second = Task {
            try await SecureEnclaveSSHApproval.approve(
                key,
                reason: "Connect to Build Host",
                isActive: { true },
                evaluate: { _, _ in
                    secondStarted = true
                    secondShown.fulfill()
                },
                signingKey: { _, _ in throw Signed() }
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(secondStarted, "two prompts at once")

        first.cancel()
        await fulfillment(of: [secondShown], timeout: 3)
        let firstResult = await first.result
        XCTAssertThrowsError(try firstResult.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let secondResult = await second.result
        XCTAssertThrowsError(try secondResult.get()) { XCTAssertTrue($0 is Signed, "\($0)") }
    }
}
