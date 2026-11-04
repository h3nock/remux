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
    /// Whether the Secure Enclave signs with the key without asking the user. One that asks on every use would ask
    /// in the middle of a login, and can't change, so it's replaced.
    let signsWithoutPrompt: Bool

    init(representation: Data, publicKey: Data, signsWithoutPrompt: Bool = true) {
        self.representation = representation
        self.publicKey = publicKey
        self.signsWithoutPrompt = signsWithoutPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case representation
        case publicKey
        case signsWithoutPrompt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        representation = try container.decode(Data.self, forKey: .representation)
        publicKey = try container.decode(Data.self, forKey: .publicKey)
        // A saved key without the field asks on every use.
        signsWithoutPrompt = try container.decodeIfPresent(Bool.self, forKey: .signsWithoutPrompt) ?? false
    }

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
        // Usable only while the device is unlocked, and gone with its passcode; it signs without asking.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage], nil
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

    /// The key read back from its reference, to sign a login. Signing happens on the connection's event loop, which
    /// must never bring up a prompt, and later than this, so its failures aren't seen here.
    func signingKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
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

enum SecureEnclaveSSHError: LocalizedError {
    /// The device has no Secure Enclave, or couldn't make the key.
    case unavailable
    case passcodeNotSet
    /// The saved key can't sign here: it asks for the user on every use, or isn't the key its reference names.
    case keyUnusable
    /// The Secure Enclave didn't give the key back, for a reason it doesn't say.
    case keyUnreadable
    /// The key can't sign while the device is locked; it can once it's unlocked.
    case unavailableWhileLocked

    var errorDescription: String? {
        switch self {
        case .unavailable: "This device can't create this key."
        case .passcodeNotSet: "Set a passcode on this device to use this key."
        case .keyUnusable: "This key no longer works on this device. Add a new key in Edit Server."
        case .keyUnreadable: "Remux couldn't read this key on this device."
        case .unavailableWhileLocked: "The key can't be used while this device is locked."
        }
    }
}

extension SSHPrivateKeyCredential {
    func inspect() throws -> SSHPrivateKeyInspection {
        if let secureEnclaveKey { return try secureEnclaveKey.inspect() }
        return try SSHPrivateKeyInspector.inspect(privateKeyPEM)
    }
}
