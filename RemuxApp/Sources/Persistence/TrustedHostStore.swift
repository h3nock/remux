@preconcurrency import Citadel
import Foundation
import NIO
@preconcurrency import NIOSSH

struct TrustedHostIdentity: Equatable, Codable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let keyType: String
    let openSSHPublicKey: String
    let trustedAt: Date
}

enum TrustedHostStoreError: LocalizedError, Sendable {
    case hostKeyTrustRequired(SSHHostKeyTrustChallenge)
    case staleHostKeyTrust(host: String)
    case invalidHostKey

    var errorDescription: String? {
        switch self {
        case .hostKeyTrustRequired(let challenge):
            switch challenge.kind {
            case .unknown:
                return "The SSH host key for \(challenge.host) is unknown. Remux refused the connection until you trust it."
            case .changed:
                return "The SSH host key for \(challenge.host) changed. Remux refused the connection."
            }
        case .staleHostKeyTrust(let host):
            return "The SSH host key trust state for \(host) changed. Try connecting again."
        case .invalidHostKey:
            return "Remux could not read the SSH host key."
        }
    }
}

final class TrustedHostStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL) {
        self.fileURL = rootURL.appendingPathComponent("trusted-hosts.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func validator(for server: SavedServer) -> SSHHostKeyValidator {
        SSHHostKeyValidator.custom(
            StoredHostKeyValidator(server: server, store: self)
        )
    }

    func identity(for serverID: SavedServer.ID) throws -> TrustedHostIdentity? {
        try lock.withLock {
            try loadLocked().first { $0.serverID == serverID }
        }
    }

    /// Restores a previously captured identity during snapshot rollback.
    ///
    /// This intentionally bypasses host-key challenge and trust-transition
    /// validation. Callers must not use it to establish new trust.
    func restoreIdentity(
        _ identity: TrustedHostIdentity?,
        for serverID: SavedServer.ID
    ) throws {
        try lock.withLock {
            var identities = try loadLocked()
            if let index = identities.firstIndex(where: { $0.serverID == serverID }) {
                if let identity {
                    identities[index] = identity
                } else {
                    identities.remove(at: index)
                }
            } else if let identity {
                identities.append(identity)
            }
            try saveLocked(identities)
        }
    }

    func deleteIdentity(for serverID: SavedServer.ID) throws {
        try lock.withLock {
            let identities = try loadLocked().filter { $0.serverID != serverID }
            try saveLocked(identities)
        }
    }

    func trustHostKey(_ challenge: SSHHostKeyTrustChallenge) throws {
        guard challenge.receivedKeyFingerprint != nil else {
            throw TrustedHostStoreError.invalidHostKey
        }

        try lock.withLock {
            var identities = try loadLocked()
            let trustedIdentity = Self.identity(challenge: challenge)

            if let index = identities.firstIndex(where: { $0.serverID == challenge.serverID }) {
                if identities[index].openSSHPublicKey == challenge.receivedOpenSSHPublicKey {
                    return
                }

                guard challenge.kind == .changed,
                      let trustedOpenSSHPublicKey = challenge.trustedOpenSSHPublicKey,
                      identities[index].openSSHPublicKey == trustedOpenSSHPublicKey else {
                    throw TrustedHostStoreError.staleHostKeyTrust(host: challenge.host)
                }

                identities[index] = trustedIdentity
                try saveLocked(identities)
                return
            }

            guard challenge.kind == .unknown else {
                throw TrustedHostStoreError.staleHostKeyTrust(host: challenge.host)
            }

            identities.append(trustedIdentity)
            try saveLocked(identities)
        }
    }

    fileprivate func validate(server: SavedServer, hostKey: NIOSSHPublicKey) throws {
        let identity = try Self.identity(server: server, hostKey: hostKey)

        try lock.withLock {
            let identities = try loadLocked()
            if let existing = identities.first(where: { $0.serverID == server.id }) {
                guard existing.openSSHPublicKey == identity.openSSHPublicKey else {
                    throw TrustedHostStoreError.hostKeyTrustRequired(
                        Self.challenge(kind: .changed, trusted: existing, received: identity)
                    )
                }
                return
            }

            throw TrustedHostStoreError.hostKeyTrustRequired(
                Self.challenge(kind: .unknown, trusted: nil, received: identity)
            )
        }
    }

    private func loadLocked() throws -> [TrustedHostIdentity] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([TrustedHostIdentity].self, from: data)
    }

    private func saveLocked(_ identities: [TrustedHostIdentity]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(identities)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func identity(
        server: SavedServer,
        hostKey: NIOSSHPublicKey
    ) throws -> TrustedHostIdentity {
        let openSSHPublicKey = String(openSSHPublicKey: hostKey)
        let keyType = openSSHPublicKey
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)

        guard let keyType else {
            throw TrustedHostStoreError.invalidHostKey
        }

        return TrustedHostIdentity(
            serverID: server.id,
            host: server.host,
            keyType: keyType,
            openSSHPublicKey: openSSHPublicKey,
            trustedAt: Date()
        )
    }

    private static func identity(challenge: SSHHostKeyTrustChallenge) -> TrustedHostIdentity {
        TrustedHostIdentity(
            serverID: challenge.serverID,
            host: challenge.host,
            keyType: challenge.receivedKeyType,
            openSSHPublicKey: challenge.receivedOpenSSHPublicKey,
            trustedAt: Date()
        )
    }

    private static func challenge(
        kind: SSHHostKeyTrustChallenge.Kind,
        trusted: TrustedHostIdentity?,
        received: TrustedHostIdentity
    ) -> SSHHostKeyTrustChallenge {
        SSHHostKeyTrustChallenge(
            kind: kind,
            serverID: received.serverID,
            host: received.host,
            trustedKeyType: trusted?.keyType,
            trustedOpenSSHPublicKey: trusted?.openSSHPublicKey,
            receivedKeyType: received.keyType,
            receivedOpenSSHPublicKey: received.openSSHPublicKey
        )
    }
}

private final class StoredHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let server: SavedServer
    private let store: TrustedHostStore

    init(server: SavedServer, store: TrustedHostStore) {
        self.server = server
        self.store = store
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        do {
            try store.validate(server: server, hostKey: hostKey)
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
