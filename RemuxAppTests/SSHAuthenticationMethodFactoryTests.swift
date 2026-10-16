@preconcurrency import Citadel
import NIOCore
import NIOPosix
import CryptoKit
import NIOEmbedded
@preconcurrency import NIOSSH
import LocalAuthentication
import XCTest
@testable import Remux

final class SSHAuthenticationMethodFactoryTests: XCTestCase {
    @MainActor
    func testConcurrentUnlocksSharePromptAndCancellationDoesNotCancelOtherWaiter() async throws {
        enum Rejection: Error { case denied }
        let gate = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let started = expectation(description: "One authorization operation")
        started.assertForOverFulfill = true
        let secondEntered = expectation(description: "Second connection waiting")
        let coordinator = SecureEnclaveSSHUnlock(authorize: { _, _ in
            started.fulfill()
            try await gate.futureResult.get()
            throw Rejection.denied
        })
        let key = SecureEnclaveSSHKey(representation: Data([1]), publicKey: Data())
        let first = Task { try await coordinator.unlock(key) }
        await fulfillment(of: [started], timeout: 3)
        let second = Task {
            secondEntered.fulfill()
            return try await coordinator.unlock(key)
        }
        await fulfillment(of: [secondEntered], timeout: 3)
        first.cancel()
        gate.succeed(())
        do {
            _ = try await second.value
            XCTFail("Expected the authorization rejection")
        } catch Rejection.denied {
        }
        _ = await first.result
    }

    func testClosingConnectionCancelsEnclaveUnlock() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let closed = loop.makePromise(of: Void.self)
        let offer = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        let started = expectation(description: "Unlock started")
        let key = SecureEnclaveSSHKey(representation: Data([1]), publicKey: Data())
        let delegate = SecureEnclaveSSHAuthenticationDelegate(
            username: "test", key: key, connectionClosed: closed.futureResult,
            unlock: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
        )
        try await loop.submit {
            delegate.nextAuthenticationType(availableMethods: [.publicKey], nextChallengePromise: offer)
        }.get()
        await fulfillment(of: [started], timeout: 3)
        closed.succeed(())
        do {
            _ = try await offer.futureResult.get()
            XCTFail("A closed connection must not receive a signing key")
        } catch is CancellationError {
        }
    }

    func testEnclaveDoesNotPromptWhenServerRejectsPublicKeyMethod() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let offer = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        let delegate = SecureEnclaveSSHAuthenticationDelegate(
            username: "test", key: SecureEnclaveSSHKey(representation: Data([1]), publicKey: Data()),
            connectionClosed: nil,
            unlock: { _ in
                XCTFail("Must not prompt for an unsupported authentication method")
                throw CancellationError()
            }
        )
        try await loop.submit {
            delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: offer)
        }.get()
        do {
            _ = try await offer.futureResult.get()
            XCTFail("Expected unsupported method to fail")
        } catch SSHClientError.allAuthenticationOptionsFailed {
        }
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

final class SecureEnclaveSSHUserPresenceTests: XCTestCase {
    @MainActor
    func testSuccessUsesOnePasscodeCapableEvaluation() async throws {
        var policies: [LAPolicy] = []
        try await SecureEnclaveSSHUserPresence.authenticate { policies.append($0) }
        XCTAssertEqual(policies, [.deviceOwnerAuthentication])
    }

    @MainActor
    func testFailedEvaluationRetriesOnceUsingSamePolicy() async throws {
        var policies: [LAPolicy] = []
        try await SecureEnclaveSSHUserPresence.authenticate { policy in
            policies.append(policy)
            if policies.count == 1 { throw LAError(.authenticationFailed) }
        }
        XCTAssertEqual(policies, [.deviceOwnerAuthentication, .deviceOwnerAuthentication])
    }

    @MainActor
    func testRepeatedFailureStopsAfterOneRetry() async {
        var count = 0
        do {
            try await SecureEnclaveSSHUserPresence.authenticate { _ in
                count += 1
                throw LAError(.authenticationFailed)
            }
            XCTFail("Expected failed authentication")
        } catch {
            XCTAssertEqual((error as? LAError)?.code, .authenticationFailed)
        }
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testCancellationAndOtherErrorsNeverRestartAuthentication() async {
        for code: LAError.Code in [.userCancel, .systemCancel, .appCancel, .userFallback,
                                   .biometryLockout, .biometryNotAvailable, .passcodeNotSet] {
            var count = 0
            do {
                try await SecureEnclaveSSHUserPresence.authenticate { _ in
                    count += 1
                    throw LAError(code)
                }
                XCTFail("Expected authentication error")
            } catch {
                XCTAssertEqual((error as? LAError)?.code, code)
            }
            XCTAssertEqual(count, 1)
        }
    }
}
