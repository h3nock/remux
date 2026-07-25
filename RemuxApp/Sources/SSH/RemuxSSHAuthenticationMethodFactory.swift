@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation

enum RemuxSSHAuthenticationMethodFactory {
    static func make(for auth: ResolvedSSHAuth) throws -> SSHAuthenticationMethod {
        switch auth.credential {
        case .password(let password):
            return .passwordBased(username: auth.username, password: password)
        case .privateKey(let credential):
            let inspection = try SSHPrivateKeyInspector.inspect(credential.privateKeyPEM)
            let decryptionKey = credential.passphrase.map { Data($0.utf8) }
            switch inspection.keyType {
            case .ed25519:
                return try .ed25519(
                    username: auth.username,
                    privateKey: Curve25519.Signing.PrivateKey(
                        sshEd25519: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .rsa:
                return try .rsa(
                    username: auth.username,
                    privateKey: Insecure.RSA.PrivateKey(
                        sshRsa: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP256:
                return try .p256(
                    username: auth.username,
                    privateKey: P256.Signing.PrivateKey(
                        sshEcdsaP256: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP384:
                return try .p384(
                    username: auth.username,
                    privateKey: P384.Signing.PrivateKey(
                        sshEcdsaP384: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            case .ecdsaP521:
                return try .p521(
                    username: auth.username,
                    privateKey: P521.Signing.PrivateKey(
                        sshEcdsaP521: inspection.normalizedPEM,
                        decryptionKey: decryptionKey
                    )
                )
            }
        }
    }
}
