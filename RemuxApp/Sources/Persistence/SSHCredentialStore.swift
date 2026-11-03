import Foundation
import Security
import CryptoKit
import LocalAuthentication

struct SSHPrivateKeyCredential: Equatable, Codable, Sendable {
    var privateKeyPEM: String
    var passphrase: String?
    var secureEnclaveKey: SecureEnclaveSSHKey?

    init(
        privateKeyPEM: String,
        passphrase: String? = nil,
        secureEnclaveKey: SecureEnclaveSSHKey? = nil
    ) {
        self.secureEnclaveKey = secureEnclaveKey
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
    }
}

enum SSHCredential: Equatable, Codable, Sendable {
    case password(String)
    case privateKey(SSHPrivateKeyCredential)

    var authenticationKind: SSHAuthenticationKind {
        switch self {
        case .password:
            .password
        case .privateKey:
            .privateKey
        }
    }

    private enum Kind: String, Codable {
        case password
        case privateKey
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case password
        case privateKeyPEM
        case privateKeyPassphrase
        case secureEnclaveKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .password:
            self = .password(try container.decode(String.self, forKey: .password))
        case .privateKey:
            self = .privateKey(
                SSHPrivateKeyCredential(
                    privateKeyPEM: try container.decode(String.self, forKey: .privateKeyPEM),
                    passphrase: try container.decodeIfPresent(String.self, forKey: .privateKeyPassphrase),
                    secureEnclaveKey: try container.decodeIfPresent(SecureEnclaveSSHKey.self, forKey: .secureEnclaveKey)
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .password(let password):
            try container.encode(Kind.password, forKey: .kind)
            try container.encode(password, forKey: .password)
        case .privateKey(let credential):
            try container.encode(Kind.privateKey, forKey: .kind)
            try container.encode(credential.privateKeyPEM, forKey: .privateKeyPEM)
            try container.encodeIfPresent(credential.passphrase, forKey: .privateKeyPassphrase)
            try container.encodeIfPresent(credential.secureEnclaveKey, forKey: .secureEnclaveKey)
        }
    }
}

protocol SSHCredentialStore: Sendable {
    func loadCredential(identityID: SSHIdentity.ID) async throws -> SSHCredential?
    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) async throws
    func deleteCredential(identityID: SSHIdentity.ID) async throws
}

enum KeychainSSHCredentialStoreError: LocalizedError, Sendable {
    case loadFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .loadFailed(let status):
            return "Remux could not load the saved SSH credential from Keychain (\(status))."
        case .saveFailed(let status):
            return "Remux could not save the SSH credential in Keychain (\(status))."
        case .deleteFailed(let status):
            return "Remux could not delete the saved SSH credential from Keychain (\(status))."
        case .invalidPayload:
            return "Remux received an invalid Keychain SSH credential payload."
        }
    }
}

actor KeychainSSHCredentialStore: SSHCredentialStore {
    static let defaultService = "dev.remux.ssh-credentials"

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = KeychainSSHCredentialStore.defaultService) {
        self.service = service
    }

    func loadCredential(identityID: SSHIdentity.ID) async throws -> SSHCredential? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(for: identityID, returnData: true) as CFDictionary,
            &item
        )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainSSHCredentialStoreError.loadFailed(status)
        }

        guard let data = item as? Data else {
            throw KeychainSSHCredentialStoreError.invalidPayload
        }

        do {
            return try decoder.decode(SSHCredential.self, from: data)
        } catch {
            throw KeychainSSHCredentialStoreError.invalidPayload
        }
    }

    func saveCredential(_ credential: SSHCredential, identityID: SSHIdentity.ID) async throws {
        let data = try encoder.encode(credential)
        let query = baseQuery(for: identityID, returnData: false)
        var attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        // A Secure Enclave key works only on the device that made it, so its reference stays here too. It
        // isn't secret, and iOS deletes passcode-bound items when the passcode is turned off, so it doesn't
        // need one.
        if case .privateKey(let key) = credential, key.secureEnclaveKey != nil {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSSHCredentialStoreError.saveFailed(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainSSHCredentialStoreError.saveFailed(updateStatus)
        }
    }

    func deleteCredential(identityID: SSHIdentity.ID) async throws {
        let status = SecItemDelete(baseQuery(for: identityID, returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSSHCredentialStoreError.deleteFailed(status)
        }
    }

    private func baseQuery(for identityID: SSHIdentity.ID, returnData: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identityID.uuidString,
        ]

        if returnData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }

        return query
    }
}

/// The representation is an opaque, device-bound encrypted key blob, never a
/// plaintext private key. Public metadata is available without authentication.
struct SecureEnclaveSSHKey: Codable, Equatable, Sendable {
    let representation: Data
    let publicKey: Data

    /// Whether this device can make such a key: one with a Secure Enclave.
    static let isSupported = SecureEnclave.isAvailable

    /// How this device approves the key, as the user knows it.
    static var approvalMethodName: String {
        biometryName ?? "your passcode"
    }

    /// The device's Face ID, Touch ID or Optic ID; without one, the passcode approves the key. Read once: the
    /// kind of sensor doesn't change while the app runs.
    static let biometryName: String? = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }()

    static func generate() throws -> Self {
        guard isSupported else {
            throw SecureEnclaveSSHError.unavailable
        }
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw SecureEnclaveSSHError.passcodeNotSet
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .userPresence], nil
        ), let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
            throw SecureEnclaveSSHError.unavailable
        }
        return Self(representation: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
    }

    func inspect() throws -> SSHPrivateKeyInspection {
        guard !representation.isEmpty else { throw SecureEnclaveSSHError.keyUnusable }
        _ = try P256.Signing.PublicKey(x963Representation: publicKey)
        return SSHPrivateKeyInspector.inspectECDSAP256PublicKey(x963: publicKey)
    }
}

enum SecureEnclaveSSHError: LocalizedError {
    /// The device has no Secure Enclave, or couldn't make the key.
    case unavailable
    case passcodeNotSet
    /// The saved key is no longer usable here: the passcode was turned off, or the key came from another device.
    case keyUnusable

    var errorDescription: String? {
        switch self {
        case .unavailable: "This device can't create this key."
        case .passcodeNotSet: "Set a passcode on this device to use this key."
        case .keyUnusable: "This key no longer works on this device. Add a new key in Edit Server."
        }
    }
}

extension SSHPrivateKeyCredential {
    func inspect() throws -> SSHPrivateKeyInspection {
        if let secureEnclaveKey { return try secureEnclaveKey.inspect() }
        return try SSHPrivateKeyInspector.inspect(privateKeyPEM)
    }
}
