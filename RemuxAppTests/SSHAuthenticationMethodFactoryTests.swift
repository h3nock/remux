@preconcurrency import Citadel
import CryptoKit
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHAuthenticationMethodFactoryTests: XCTestCase {
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

    /// A key made on this device that asks for the user itself on every use would ask in the middle of a login, so
    /// it needs replacing. One the Secure Enclave doesn't give back, as none is in the simulator, says only that,
    /// not that it's lost.
    func testADeviceKeyThatCantSignHereSaysWhy() {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let cases: [(SecureEnclaveSSHKey, SecureEnclaveSSHError)] = [
            (SecureEnclaveSSHKey(representation: Data([1]), publicKey: publicKey, signsWithoutPrompt: false), .keyUnusable),
            (SecureEnclaveSSHKey(representation: Data([1]), publicKey: publicKey), .keyUnreadable),
        ]
        for (key, expected) in cases {
            let credential = ResolvedSSHAuth.Credential.privateKey(
                SSHPrivateKeyCredential(privateKeyPEM: "", secureEnclaveKey: key)
            )
            XCTAssertThrowsError(try SSHAuthenticationMethodFactory.make(username: "test", credential: credential)) {
                XCTAssertEqual($0 as? SecureEnclaveSSHError, expected)
            }
        }
    }
}
