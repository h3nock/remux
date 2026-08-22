@preconcurrency import Citadel
@preconcurrency import Crypto
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

enum SSHAuthenticationMethodFactory {
    static func make(
        username: String,
        credential: ResolvedSSHAuth.Credential
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .none:
            return .custom(NoneSSHAuthenticationDelegate(username: username))
        case .privateKey(let credential):
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let decryptionKey = credential.passphrase.map { Data($0.utf8) }
            switch inspection.keyType {
            case .ed25519:
                return try .ed25519(
                    username: username,
                    privateKey: Curve25519.Signing.PrivateKey(
                        sshEd25519: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .rsa:
                return try .rsa(
                    username: username,
                    privateKey: Insecure.RSA.PrivateKey(
                        sshRsa: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP256:
                return try .p256(
                    username: username,
                    privateKey: P256.Signing.PrivateKey(
                        sshEcdsaP256: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP384:
                return try .p384(
                    username: username,
                    privateKey: P384.Signing.PrivateKey(
                        sshEcdsaP384: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP521:
                return try .p521(
                    username: username,
                    privateKey: P521.Signing.PrivateKey(
                        sshEcdsaP521: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            }
        }
    }

    static func make(
        username: String,
        storedCredential: SSHCredential
    ) throws -> SSHAuthenticationMethod {
        switch storedCredential {
        case .password(let password):
            return try make(
                username: username,
                credential: ResolvedSSHAuth.Credential.password(password)
            )
        case .privateKey(let privateKey):
            return try make(
                username: username,
                credential: ResolvedSSHAuth.Credential.privateKey(privateKey)
            )
        }
    }
}
