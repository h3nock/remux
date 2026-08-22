import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHAuthenticationMethodFactoryTests: XCTestCase {
    func testNoneDelegateOffersNoneAuthenticationExactlyOnce() async throws {
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
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
        guard case .none = offer?.offer else {
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
