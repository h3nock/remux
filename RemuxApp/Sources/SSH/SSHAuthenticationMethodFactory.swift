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
    /// This reads the key back from its reference; signing happens later, in the login, whose failures this
    /// doesn't see.
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
            throw SecureEnclaveSSHError.unavailableWhileLocked
        } catch {
            // Nothing here says the key is lost, so this isn't advice to replace it.
            throw SecureEnclaveSSHError.keyUnreadable
        }
        guard signingKey.publicKey.x963Representation == publicKey else {
            throw SecureEnclaveSSHError.keyUnusable
        }
        return signingKey
    }

    /// Whether the Secure Enclave refused to read the key back because the device is locked.
    private static func isUnavailableWhileLocked(_ error: any Error) -> Bool {
        if case CryptoKitError.underlyingCoreCryptoError(let code) = error {
            return code == errSecInteractionNotAllowed
        }
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == Int(errSecInteractionNotAllowed)
    }
}

/// The user's approvals of keys made on this device, one server at a time. Approving a server's key once with Face
/// ID, Touch ID or the passcode lets every later login to it sign without asking, however many connections Remux
/// opens and whether or not the user asked for them, while the user works with the server: locking the device,
/// leaving Remux and losing the network keep it. It ends when the user disconnects the server's last session or
/// removes the server, which their owners report with `revoke(serverID:)`, and when Remux quits, since nothing is
/// stored. While the device is locked the key itself can't sign, so a new login waits for it to be unlocked.
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
        /// Whether the key leaves the asking to Remux. One that asks for the user itself, on every use, can't log
        /// in without a prompt in the middle of the login, approved or not.
        let signsWithoutPrompt: Bool

        var isApproved: Bool {
            approvals.isApproved(scope)
        }

        /// Whether approving the server's key would let a new login to it start.
        var needsApproval: Bool {
            signsWithoutPrompt && !isApproved
        }

        /// What a new login to the server checks before it starts: a key that asks on every use needs replacing, one
        /// the user hasn't approved stops at the locked key, and one whose device is locked waits for it.
        func admitLogin() async throws {
            guard signsWithoutPrompt else { throw SecureEnclaveSSHError.keyUnusable }
            try await approvals.admit(scope)
        }
    }

    typealias Evaluate = @MainActor (LAContext, String) async throws -> Void

    /// One caller's wait for a server's prompt. It ends once: with the prompt's answer, or as soon as the caller is
    /// cancelled, so a caller that went away never carries on with what it asked for.
    private final class Waiter: @unchecked Sendable {
        private let lock = NIOLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            let finished: Result<Void, Error>? = lock.withLock {
                if result == nil { self.continuation = continuation }
                return result
            }
            if let finished { continuation.resume(with: finished) }
        }

        func finish(_ result: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                guard self.result == nil else { return nil }
                self.result = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }

    /// A server's prompt, and the callers still waiting for its answer. It's here only while someone waits: the last
    /// caller to leave, and the server's approvals ending, take it out, and only one still here can grant.
    private struct Pending {
        let id: UUID
        let request: Task<Void, Never>
        var waiters: [ObjectIdentifier: Waiter]
    }

    private let lock = NIOLock()
    private var approved: Set<Scope> = []
    private var pending: [Scope: Pending] = [:]
    /// The latest prompt: the device shows one at a time, so a server's prompt waits for the one before.
    private var lastPrompt: Task<Void, Never>?
    private let isActive: @MainActor () -> Bool
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private let evaluate: Evaluate

    init(
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        evaluate: @escaping Evaluate = { context, reason in
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
    ) {
        self.isActive = isActive
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.evaluate = evaluate
    }

    /// The check a login to `target` makes, when its key was made on this device.
    func check(for target: SessionTarget) -> Check? {
        guard case .privateKey(let credential) = target.sshAuth.credential,
              let key = credential.secureEnclaveKey else { return nil }
        return Check(
            approvals: self,
            scope: Scope(
                serverID: target.server.id,
                host: target.server.host,
                port: target.server.port,
                username: target.sshAuth.username,
                publicKey: key.publicKey
            ),
            signsWithoutPrompt: key.signsWithoutPrompt
        )
    }

    /// The check installing a key makes, when the key was made on this device. It covers the server the draft
    /// adds, so adding it and listing its sessions use the same approval.
    func check(for target: SSHPublicKeyInstallTarget) -> Check? {
        guard let key = target.privateKey.secureEnclaveKey else { return nil }
        return Check(
            approvals: self,
            scope: Scope(
                serverID: target.serverID,
                host: target.host,
                port: target.port,
                username: target.username,
                publicKey: key.publicKey
            ),
            signsWithoutPrompt: key.signsWithoutPrompt
        )
    }

    func isApproved(_ scope: Scope) -> Bool {
        lock.withLock { approved.contains(scope) }
    }

    /// Whether a new login to the server may start: the user approved it, and the device is unlocked, as the key
    /// needs. A locked device keeps the approval; the login just can't sign until it's unlocked.
    func admit(_ scope: Scope) async throws {
        guard isApproved(scope) else { throw SSHKeyApprovalError.required }
        guard await isProtectedDataAvailable() else { throw SecureEnclaveSSHError.unavailableWhileLocked }
        // The approval may have ended while the device was checked.
        guard isApproved(scope) else { throw SSHKeyApprovalError.required }
    }

    /// Whether `error` says only that nobody wanted the approval any more: the user or iOS dismissed the prompt,
    /// what asked for it went away, or the prompt couldn't come up then. Anything else is a failure worth saying.
    static func isCancellation(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            return true
        case let error as LAError:
            return [.userCancel, .systemCancel, .appCancel].contains(error.code)
        case let error as SSHKeyApprovalError:
            return error == .required
        default:
            return false
        }
    }

    /// Ends the server's approvals: the user disconnected its last session, or removed it. Its prompts still out
    /// grant nothing, and whoever waits for them hears that the key is locked; the next request asks again.
    func revoke(serverID: SavedServer.ID) {
        let retired: [Pending] = lock.withLock {
            approved = approved.filter { $0.serverID != serverID }
            let entries = pending.filter { $0.key.serverID == serverID }
            for scope in entries.keys {
                pending[scope] = nil
            }
            return Array(entries.values)
        }
        for entry in retired {
            entry.request.cancel()
            for waiter in entry.waiters.values {
                waiter.finish(.failure(SSHKeyApprovalError.required))
            }
        }
    }

    /// Asks the user to approve the server's key, unless they have. Requests for one server while its prompt is up
    /// share that prompt. A caller that's cancelled stops waiting at once, and leaves the prompt to the others; the
    /// last to leave takes the prompt away, or keeps it from coming up.
    @MainActor
    func approve(_ scope: Scope, serverName: String) async throws {
        try Task.checkCancellation()
        let waiter = Waiter()
        let isApproved: Bool = lock.withLock {
            if approved.contains(scope) { return true }
            if pending[scope] != nil {
                pending[scope]?.waiters[ObjectIdentifier(waiter)] = waiter
                return false
            }
            let id = UUID()
            let previous = lastPrompt
            let request = Task { @MainActor in
                await previous?.value
                do {
                    try await self.prompt(for: scope, reason: "Connect to \(serverName)", request: id)
                    self.grant(scope, request: id)
                } catch {
                    self.give(.failure(error), for: scope, request: id)
                }
            }
            pending[scope] = Pending(id: id, request: request, waiters: [ObjectIdentifier(waiter): waiter])
            lastPrompt = request
            return false
        }
        if isApproved { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter.install($0) }
        } onCancel: {
            self.leave(scope, waiter)
        }
        // Approved just as the caller went away: it doesn't carry on.
        try Task.checkCancellation()
    }

    /// Brings up the request's prompt, unless nobody waits for it any more.
    @MainActor
    private func prompt(for scope: Scope, reason: String, request id: UUID) async throws {
        guard isWaitedFor(scope, request: id) else { throw CancellationError() }
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
    }

    private func isWaitedFor(_ scope: Scope, request id: UUID) -> Bool {
        lock.withLock { pending[scope]?.id == id }
    }

    /// Grants what the user approved, if the request still has someone waiting for it: once the last caller left,
    /// or the server's approvals ended, it grants nothing.
    private func grant(_ scope: Scope, request id: UUID) {
        let waiters: [Waiter] = lock.withLock {
            guard let entry = pending[scope], entry.id == id, !entry.waiters.isEmpty else { return [] }
            approved.insert(scope)
            pending[scope] = nil
            return Array(entry.waiters.values)
        }
        for waiter in waiters {
            waiter.finish(.success(()))
        }
    }

    /// Gives a prompt's answer to the callers still waiting for it.
    private func give(_ answer: Result<Void, Error>, for scope: Scope, request id: UUID) {
        let waiters: [Waiter] = lock.withLock {
            guard let entry = pending[scope], entry.id == id else { return [] }
            pending[scope] = nil
            return Array(entry.waiters.values)
        }
        for waiter in waiters {
            waiter.finish(answer)
        }
    }

    /// The caller is out of the request before its wait ends, so a prompt answered meanwhile can't count it as
    /// still waiting.
    private func leave(_ scope: Scope, _ waiter: Waiter) {
        let abandoned: Task<Void, Never>? = lock.withLock {
            guard var entry = pending[scope],
                  entry.waiters.removeValue(forKey: ObjectIdentifier(waiter)) != nil else { return nil }
            guard entry.waiters.isEmpty else {
                pending[scope] = entry
                return nil
            }
            pending[scope] = nil
            return entry.request
        }
        waiter.finish(.failure(CancellationError()))
        abandoned?.cancel()
    }

    private final class ContextBox: @unchecked Sendable {
        let context: LAContext
        init(_ context: LAContext) { self.context = context }
    }
}
