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
    static func make(
        username: String,
        credential: ResolvedSSHAuth.Credential,
        connectionClosed: EventLoopFuture<Void>? = nil
    ) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .none:
            return .custom(NoneSSHAuthenticationDelegate(username: username))
        case .privateKey(let credential):
            if let key = credential.secureEnclaveKey {
                return .custom(SecureEnclaveSSHAuthenticationDelegate(username: username, key: key, connectionClosed: connectionClosed))
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
        connectionClosed: EventLoopFuture<Void>? = nil
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
                credential: ResolvedSSHAuth.Credential.privateKey(privateKey),
                connectionClosed: connectionClosed
            )
        }
    }
}

/// Authentication is requested asynchronously before offering the signing key.
/// NIOSSH's synchronous signing operation then uses the authenticated context.
final class SecureEnclaveSSHAuthenticationDelegate:
    NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let key: SecureEnclaveSSHKey
    private let connectionClosed: EventLoopFuture<Void>?
    private let unlock: @MainActor @Sendable (SecureEnclaveSSHKey) async throws -> SecureEnclave.P256.Signing.PrivateKey
    // Accessed only on the SSH event loop.
    private var offered = false

    init(
        username: String,
        key: SecureEnclaveSSHKey,
        connectionClosed: EventLoopFuture<Void>?,
        unlock: @escaping @MainActor @Sendable (SecureEnclaveSSHKey) async throws -> SecureEnclave.P256.Signing.PrivateKey = {
            try await SecureEnclaveSSHUnlock.shared.unlock($0)
        }
    ) {
        self.unlock = unlock
        self.connectionClosed = connectionClosed
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        offered = true
        let task = Task { @MainActor [username, key, unlock] in
            do {
                let signingKey = try await unlock(key)
                try Task.checkCancellation()
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "",
                    offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: signingKey)))
                ))
            } catch {
                nextChallengePromise.fail(error)
            }
        }
        connectionClosed?.whenComplete { _ in task.cancel() }
    }
}

/// Simultaneous connection attempts for the same identity share one prompt.
/// The context is retained by the returned key only for this authentication;
/// the coordinator does not cache authorization after the operation completes.
@MainActor
final class SecureEnclaveSSHUnlock {
    static let shared = SecureEnclaveSSHUnlock()
    typealias Authorize = @MainActor @Sendable (SecureEnclaveSSHKey, LAContext) async throws -> SecureEnclave.P256.Signing.PrivateKey
    private let authorize: Authorize

    init(authorize: @escaping Authorize = SecureEnclaveSSHUnlock.authorizeKey) {
        self.authorize = authorize
    }

    static func authorizeKey(_ key: SecureEnclaveSSHKey, context: LAContext) async throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard UIApplication.shared.applicationState == .active else {
            throw SecureEnclaveSSHError.appNotActive
        }
        context.localizedFallbackTitle = "Enter Passcode"
        try await SecureEnclaveSSHUserPresence.authenticate { policy in
            guard try await context.evaluatePolicy(
                policy,
                localizedReason: "Unlock your Secure Enclave key to connect over SSH."
            ) else {
                throw LAError(.authenticationFailed)
            }
        }
        let signingKey = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: key.representation, authenticationContext: context
        )
        guard signingKey.publicKey.x963Representation == key.publicKey else {
            throw SecureEnclaveSSHError.publicKeyMismatch
        }
        return signingKey
    }

    private struct Pending {
        let id: UUID
        let context: LAContext
        let task: Task<SecureEnclave.P256.Signing.PrivateKey, Error>
        var waiters: Set<UUID>
    }
    private var pending: [Data: Pending] = [:]

    func unlock(_ key: SecureEnclaveSSHKey) async throws -> SecureEnclave.P256.Signing.PrivateKey {
        try Task.checkCancellation()
        let waiter = UUID()
        let entry: Pending
        if var existing = pending[key.representation] {
            existing.waiters.insert(waiter)
            entry = existing
        } else {
            let context = LAContext()
            context.localizedCancelTitle = "Cancel"
            let authorize = authorize
            let task = Task { @MainActor in
                try await authorize(key, context)
            }
            entry = Pending(id: UUID(), context: context, task: task, waiters: [waiter])
        }
        pending[key.representation] = entry
        let entryID = entry.id
        let operation = entry.task
        defer { release(key.representation, entryID: entryID, waiter: waiter, cancelled: false) }
        return try await withTaskCancellationHandler {
            let signingKey = try await operation.value
            try Task.checkCancellation()
            return signingKey
        } onCancel: {
            Task { @MainActor in
                self.release(key.representation, entryID: entryID, waiter: waiter, cancelled: true)
            }
        }
    }

    private func release(_ representation: Data, entryID: UUID, waiter: UUID, cancelled: Bool) {
        guard var entry = pending[representation], entry.id == entryID else { return }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty {
            pending[representation] = nil
            if cancelled {
                entry.context.invalidate()
                entry.task.cancel()
            }
        } else {
            pending[representation] = entry
        }
    }
}

/// Keep biometrics and passcode in one system evaluation so choosing passcode
/// does not restart Face ID. Retry a failed evaluation once; iOS owns scan counts.
@MainActor
enum SecureEnclaveSSHUserPresence {
    static func authenticate(evaluate: (LAPolicy) async throws -> Void) async throws {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                try await evaluate(.deviceOwnerAuthentication)
                try Task.checkCancellation()
                return
            } catch let error as LAError where error.code == .authenticationFailed && attempt == 0 {
                continue
            }
        }
    }
}
