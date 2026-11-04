@preconcurrency import Citadel
@preconcurrency import Crypto
import CryptoKit
import Foundation
import LocalAuthentication
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import UIKit

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

/// Offers a key made on this device once, then fails further offers.
final class SecureEnclaveSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let signingKey: SecureEnclave.P256.Signing.PrivateKey
    private var hasOffered = false

    init(username: String, signingKey: SecureEnclave.P256.Signing.PrivateKey) {
        self.username = username
        self.signingKey = signingKey
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
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: signingKey)))
        ))
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
            if let key = credential.secureEnclaveKey {
                return .custom(SecureEnclaveSSHAuthenticationDelegate(
                    username: username,
                    signingKey: try key.signingKey()
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

/// A login with a key made on this device that the user hasn't approved for the server. Only their own request
/// asks them to.
enum SSHKeyApprovalError: Error, Equatable, LocalizedError {
    case required

    var errorDescription: String? {
        "Unlock this server's key to connect."
    }
}

extension SecureEnclaveSSHKey {
    /// The key, to sign a login the user's approval of its server let start. It signs without asking: the
    /// approval was given to Remux, and signing on the connection's event loop must never bring up a prompt.
    func signingKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        // One that asks for the user itself, on every use, would ask in the middle of a login.
        guard signsWithoutPrompt else { throw SecureEnclaveSSHError.keyUnusable }
        let context = LAContext()
        context.interactionNotAllowed = true
        let signingKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            signingKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: representation,
                authenticationContext: context
            )
        } catch where Self.isUnavailableWhileLocked(error) {
            // The key works again once the device is unlocked and the server approved.
            throw SSHKeyApprovalError.required
        } catch {
            throw SecureEnclaveSSHError.keyUnusable
        }
        guard signingKey.publicKey.x963Representation == publicKey else {
            throw SecureEnclaveSSHError.keyUnusable
        }
        return signingKey
    }

    /// Whether the Secure Enclave refused the key because the device is locked, rather than because the key can't
    /// work here.
    private static func isUnavailableWhileLocked(_ error: any Error) -> Bool {
        if case CryptoKitError.underlyingCoreCryptoError(let code) = error {
            return code == errSecInteractionNotAllowed
        }
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == Int(errSecInteractionNotAllowed)
    }
}

/// The user's approvals of keys made on this device, one server at a time, for as long as Remux runs and the
/// device stays unlocked. Approving a server's key once with Face ID, Touch ID or the passcode lets every later
/// login to it sign without asking, however many connections Remux opens and whether or not the user asked for
/// them. Locking the device ends every approval, which iOS reports as protected data going away or, after a lock
/// Remux slept through, coming back; quitting ends them too, since nothing is stored.
final class SecureEnclaveSSHApprovals: @unchecked Sendable {
    /// What one approval covers: one server's address and account, with one key. Changing any of them needs a
    /// new approval.
    struct Scope: Hashable, Sendable {
        let serverID: SavedServer.ID
        let host: String
        let port: Int
        let username: String
        let publicKey: Data
    }

    /// One login's check of its server's approval.
    struct Check: Sendable {
        let approvals: SecureEnclaveSSHApprovals
        let scope: Scope

        var isApproved: Bool {
            approvals.isApproved(scope)
        }

        /// What a login to the server checks before it starts: one the user hasn't approved stops at the locked key.
        func requireApproval() throws {
            guard isApproved else { throw SSHKeyApprovalError.required }
        }
    }

    typealias Evaluate = @MainActor (LAContext, String) async throws -> Void

    private let lock = NIOLock()
    private var approved: Set<Scope> = []
    /// How many times every approval has ended, so a prompt answered after an end grants nothing.
    private var revocations = 0
    private var pending: [Scope: Task<Void, Error>] = [:]
    /// The latest prompt: the device shows one at a time, so a server's prompt waits for the one before.
    private var lastPrompt: Task<Void, Never>?
    private let isActive: @MainActor () -> Bool
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private let evaluate: Evaluate
    private let notificationCenter: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        evaluate: @escaping Evaluate = { context, reason in
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.isActive = isActive
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.evaluate = evaluate
        observers = [
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.revokeAll()
            }
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// The check a login to `target` makes, when its key was made on this device.
    func check(for target: SessionTarget) -> Check? {
        guard case .privateKey(let credential) = target.sshAuth.credential,
              let key = credential.secureEnclaveKey else { return nil }
        return Check(approvals: self, scope: Scope(
            serverID: target.server.id,
            host: target.server.host,
            port: target.server.port,
            username: target.sshAuth.username,
            publicKey: key.publicKey
        ))
    }

    /// The check installing a key makes, when the key was made on this device. It covers the server the draft
    /// adds, so adding it and listing its sessions use the same approval.
    func check(for target: SSHPublicKeyInstallTarget) -> Check? {
        guard let key = target.privateKey.secureEnclaveKey else { return nil }
        return Check(approvals: self, scope: Scope(
            serverID: target.serverID,
            host: target.host,
            port: target.port,
            username: target.username,
            publicKey: key.publicKey
        ))
    }

    func isApproved(_ scope: Scope) -> Bool {
        lock.withLock { approved.contains(scope) }
    }

    /// Asks the user to approve the server's key, unless they have. Requests for one server while its prompt is up
    /// share that prompt; a caller that stops waiting leaves it to the others.
    @MainActor
    func approve(_ scope: Scope, serverName: String) async throws {
        let request: Task<Void, Error>? = lock.withLock {
            if approved.contains(scope) { return nil }
            if let pending = pending[scope] { return pending }
            let revocation = revocations
            let previous = lastPrompt
            let request = Task { @MainActor in
                await previous?.value
                try await self.prompt(for: scope, reason: "Connect to \(serverName)", unlessRevokedAfter: revocation)
            }
            pending[scope] = request
            lastPrompt = Task { _ = await request.result }
            return request
        }
        guard let request else { return }
        defer {
            lock.withLock {
                if pending[scope] == request { pending[scope] = nil }
            }
        }
        try await request.value
    }

    @MainActor
    private func prompt(for scope: Scope, reason: String, unlessRevokedAfter revocation: Int) async throws {
        try Task.checkCancellation()
        // A prompt over another app, or while Remux leaves the screen, isn't one the user asked for; and a locked
        // device can't use the key.
        guard isActive(), isProtectedDataAvailable() else { throw SSHKeyApprovalError.required }
        let context = ContextBox(LAContext())
        defer { context.context.invalidate() }
        try await withTaskCancellationHandler {
            try await evaluate(context.context, reason)
        } onCancel: {
            Task { @MainActor in context.context.invalidate() }
        }
        let granted = lock.withLock {
            guard revocations == revocation else { return false }
            approved.insert(scope)
            return true
        }
        // The device locked while the prompt was up, which ended the approval it gave.
        guard granted else { throw SSHKeyApprovalError.required }
    }

    /// Ends every approval, then gives up the prompts still out, which can no longer grant one.
    private func revokeAll() {
        let requests = lock.withLock {
            approved.removeAll()
            revocations += 1
            return Array(pending.values)
        }
        requests.forEach { $0.cancel() }
    }

    private final class ContextBox: @unchecked Sendable {
        let context: LAContext
        init(_ context: LAContext) { self.context = context }
    }
}
