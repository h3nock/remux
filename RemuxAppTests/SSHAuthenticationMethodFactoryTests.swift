@preconcurrency import Citadel
import CryptoKit
import Security
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
            XCTAssertThrowsError(try SSHAuthenticationMethodFactory.prepare(username: "test", credential: credential)) {
                XCTAssertEqual($0 as? SecureEnclaveSSHError, expected)
            }
        }
    }

    /// An imported key whose passphrase is wrong can't be read, which saving doesn't check. It's replaced like
    /// credentials the server turned down, since reconnecting would fail the same way.
    func testAKeyThatCantBeReadOffersUpdatingTheCredentials() {
        let credential = ResolvedSSHAuth.Credential.privateKey(SSHPrivateKeyCredential(
            privateKeyPEM: SSHPrivateKeyInspectorTests.encryptedEd25519Key,
            passphrase: "not the passphrase"
        ))

        XCTAssertThrowsError(try SSHAuthenticationMethodFactory.prepare(username: "test", credential: credential)) {
            XCTAssertTrue($0 is SSHPrivateKeyUnreadableError, "\($0)")
            let reason = GhosttyTerminalDisconnectReasonClassifier.transportStartFailure($0)
            XCTAssertEqual(reason.kind, .authentication)
            XCTAssertEqual(
                reason.message,
                "This private key couldn't be read with this passphrase, or isn't in a format Remux supports."
            )
        }
    }

    /// The Keychain refuses a read while the device is locked; that pauses a connection as a locked device key does,
    /// and any other failed read stays a failed read.
    func testACredentialReadWhileLockedIsTheLockedDeviceError() {
        XCTAssertEqual(
            KeychainSSHCredentialStore.loadError(errSecInteractionNotAllowed) as? SecureEnclaveSSHError,
            .unavailableWhileLocked
        )
        guard case .loadFailed(errSecAuthFailed)? = KeychainSSHCredentialStore.loadError(errSecAuthFailed)
            as? KeychainSSHCredentialStoreError else {
            return XCTFail("expected a failed read")
        }
    }

    /// A key that can't be used fails before any connection starts, so it reaches the user as itself. Prepared inside
    /// the connection instead, a server saved by name would report it as a connection that failed.
    func testAKeyThatCantBeUsedFailsAsItselfBeforeConnecting() async {
        let server = SavedServer(displayName: "named", host: "localhost", port: 1, username: "tester")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = RemuxSSHRootConfiguration(
            host: server.host,
            port: server.port,
            prepareAuthentication: { throw SecureEnclaveSSHError.keyUnusable },
            hostKeyValidator: TrustedHostStore(rootURL: directory).validator(for: server),
            connectTimeout: .seconds(2)
        )

        do {
            _ = try await RemuxSSHRootBootstrap.authenticate(
                using: configuration,
                trace: RemuxTransportStartupTrace(flowID: "prepare-before-connect-test")
            )
            XCTFail("expected the key's own error")
        } catch {
            XCTAssertEqual(error as? SecureEnclaveSSHError, .keyUnusable, "\(error)")
        }
    }
}
