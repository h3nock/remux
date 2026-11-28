@preconcurrency import Citadel
@preconcurrency import Crypto
import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Offers SSH's `none` authentication method once, then fails further offers.
/// Used for Tailscale SSH and other servers explicitly configured to accept
/// SSH `none` authentication without a password or private key.
final class NoneSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var hasOffered = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }

        hasOffered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
        )
    }
}

/// Offers a key made on this device as Citadel offers an imported one. Citadel's `.custom` method asks it once.
final class SecureEnclaveSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let signingKey: SecureEnclave.P256.Signing.PrivateKey

    init(username: String, signingKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.username = username
        self.signingKey = signingKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }

        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: signingKey)))
        ))
    }
}

/// Credentials read and decoded before a connection starts, so a key that can't be used fails as itself instead of as
/// a failed connection. Each SSH channel gets its own method from it: Citadel's methods use up their offers as the
/// server asks for them, so one can't serve two channels.
struct SSHPreparedAuthentication: Sendable {
    let makeMethod: @Sendable () -> SSHAuthenticationMethod
}

enum SSHAuthenticationMethodFactory {
    static func prepare(
        username: String,
        credential: ResolvedSSHAuth.Credential
    ) throws -> SSHPreparedAuthentication {
        switch credential {
        case .password(let password):
            return SSHPreparedAuthentication { .passwordBased(username: username, password: password) }
        case .none:
            return SSHPreparedAuthentication { .custom(NoneSSHAuthenticationDelegate(username: username)) }
        case .privateKey(let credential):
            if let key = credential.secureEnclaveKey {
                let signingKey = try key.signingKey()
                return SSHPreparedAuthentication {
                    .custom(SecureEnclaveSSHAuthenticationDelegate(username: username, signingKey: signingKey))
                }
            }
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let decryptionKey = credential.passphrase.map { Data($0.utf8) }
            switch inspection.keyType {
            case .ed25519:
                let privateKey = try Curve25519.Signing.PrivateKey(
                    sshEd25519: inspection.normalizedPEM,
                    decryptionKey: decryptionKey
                )
                return SSHPreparedAuthentication { .ed25519(username: username, privateKey: privateKey) }
            case .rsa:
                let privateKey = try Insecure.RSA.PrivateKey(
                    sshRsa: inspection.normalizedPEM,
                    decryptionKey: decryptionKey
                )
                return SSHPreparedAuthentication { .rsa(username: username, privateKey: privateKey) }
            case .ecdsaP256:
                let privateKey = try P256.Signing.PrivateKey(
                    sshEcdsaP256: inspection.normalizedPEM,
                    decryptionKey: decryptionKey
                )
                return SSHPreparedAuthentication { .p256(username: username, privateKey: privateKey) }
            case .ecdsaP384:
                let privateKey = try P384.Signing.PrivateKey(
                    sshEcdsaP384: inspection.normalizedPEM,
                    decryptionKey: decryptionKey
                )
                return SSHPreparedAuthentication { .p384(username: username, privateKey: privateKey) }
            case .ecdsaP521:
                let privateKey = try P521.Signing.PrivateKey(
                    sshEcdsaP521: inspection.normalizedPEM,
                    decryptionKey: decryptionKey
                )
                return SSHPreparedAuthentication { .p521(username: username, privateKey: privateKey) }
            }
        }
    }

    static func prepare(
        username: String,
        storedCredential: SSHCredential
    ) throws -> SSHPreparedAuthentication {
        switch storedCredential {
        case .password(let password):
            return try prepare(username: username, credential: .password(password))
        case .privateKey(let privateKey):
            return try prepare(username: username, credential: .privateKey(privateKey))
        }
    }
}
