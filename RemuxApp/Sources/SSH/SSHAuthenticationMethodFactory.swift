@preconcurrency import Citadel
@preconcurrency import Crypto
import Foundation
import CryptoKit
import LocalAuthentication
import UIKit
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
    /// `serverName` names the server in the prompt to approve a Secure Enclave key; `login` is the connection
    /// that key's approval waits on.
    static func make(
        username: String,
        credential: ResolvedSSHAuth.Credential,
        serverName: String,
        login: RemuxSSHLogin? = nil
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .none:
            return .custom(NoneSSHAuthenticationDelegate(username: username))
        case .privateKey(let credential):
            if let key = credential.secureEnclaveKey {
                return .custom(SecureEnclaveSSHAuthenticationDelegate(
                    username: username,
                    key: key,
                    reason: "Connect to \(serverName)",
                    login: login
                ))
            }
            let inspection = try credential.inspect()
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
        storedCredential: SSHCredential,
        serverName: String,
        login: RemuxSSHLogin? = nil
    ) throws -> SSHAuthenticationMethod {
        switch storedCredential {
        case .password(let password):
            return try make(
                username: username,
                credential: ResolvedSSHAuth.Credential.password(password),
                serverName: serverName
            )
        case .privateKey(let privateKey):
            return try make(
                username: username,
                credential: ResolvedSSHAuth.Credential.privateKey(privateKey),
                serverName: serverName,
                login: login
            )
        }
    }
}

/// Offers the Secure Enclave key once the user approves it on this device. The approval runs off the
/// connection's event loop; NIOSSH then signs with the approved key, which can't ask again.
final class SecureEnclaveSSHAuthenticationDelegate:
    NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    typealias Approve = @MainActor @Sendable (SecureEnclaveSSHKey, String) async throws
        -> SecureEnclave.P256.Signing.PrivateKey

    private let username: String
    private let key: SecureEnclaveSSHKey
    private let reason: String
    private let login: RemuxSSHLogin?
    private let approve: Approve

    init(
        username: String,
        key: SecureEnclaveSSHKey,
        reason: String,
        login: RemuxSSHLogin?,
        approve: @escaping Approve = { try await SecureEnclaveSSHApproval.approve($0, reason: $1) }
    ) {
        self.username = username
        self.key = key
        self.reason = reason
        self.login = login
        self.approve = approve
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        login?.approvalStarted()
        let task = Task { @MainActor [username, key, reason, login, approve] in
            let offer: Result<NIOSSHUserAuthenticationOffer?, Error>
            do {
                let signingKey = try await approve(key, reason)
                try Task.checkCancellation()
                offer = .success(NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: signingKey)))
                ))
            } catch {
                offer = .failure(error)
            }
            login?.approvalEnded()
            nextChallengePromise.completeWith(offer)
        }
        login?.closeFuture.whenComplete { _ in task.cancel() }
    }
}

/// The user's approval of a Secure Enclave key on this device, with Face ID, Touch ID or the passcode in one
/// system prompt, which retries a failed face or finger itself. The device shows one prompt at a time, so
/// approvals for different servers wait their turn. Cancelling the wait takes its prompt away.
@MainActor
enum SecureEnclaveSSHApproval {
    typealias Evaluate = @MainActor (LAContext, String) async throws -> Void
    typealias SigningKey = @MainActor (SecureEnclaveSSHKey, LAContext) throws
        -> SecureEnclave.P256.Signing.PrivateKey

    private static var previous: Task<Void, Never>?

    static func approve(
        _ key: SecureEnclaveSSHKey,
        reason: String
    ) async throws -> SecureEnclave.P256.Signing.PrivateKey {
        try await approve(
            key,
            reason: reason,
            isActive: { UIApplication.shared.applicationState == .active },
            evaluate: { context, reason in
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            },
            signingKey: signingKey
        )
    }

    static func approve(
        _ key: SecureEnclaveSSHKey,
        reason: String,
        isActive: @escaping @MainActor () -> Bool,
        evaluate: @escaping Evaluate,
        signingKey: @escaping SigningKey
    ) async throws -> SecureEnclave.P256.Signing.PrivateKey {
        let context = ContextBox(LAContext())
        let waitFor = previous
        let turn = Task { @MainActor () throws -> SecureEnclave.P256.Signing.PrivateKey in
            await waitFor?.value
            try Task.checkCancellation()
            // A prompt over another app, or while Remux is going away, isn't one the user asked for.
            guard isActive() else { throw SSHKeyApprovalError.required }
            try await evaluate(context.context, reason)
            // Signing on the connection's event loop must never bring up a second prompt.
            context.context.interactionNotAllowed = true
            return try signingKey(key, context.context)
        }
        previous = Task { _ = await turn.result }
        return try await withTaskCancellationHandler {
            try await turn.value
        } onCancel: {
            turn.cancel()
            Task { @MainActor in context.context.invalidate() }
        }
    }

    private static func signingKey(
        _ key: SecureEnclaveSSHKey,
        context: LAContext
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let signingKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            signingKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: key.representation,
                authenticationContext: context
            )
        } catch {
            throw SecureEnclaveSSHError.keyUnusable
        }
        guard signingKey.publicKey.x963Representation == key.publicKey else {
            throw SecureEnclaveSSHError.keyUnusable
        }
        return signingKey
    }

    private final class ContextBox: @unchecked Sendable {
        let context: LAContext
        init(_ context: LAContext) { self.context = context }
    }
}
