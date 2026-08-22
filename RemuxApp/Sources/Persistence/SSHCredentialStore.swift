import Foundation
import Security

struct SSHPrivateKeyCredential: Equatable, Codable, Sendable {
    var privateKeyPEM: String
    var passphrase: String?

    init(privateKeyPEM: String, passphrase: String? = nil) {
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
                    passphrase: try container.decodeIfPresent(String.self, forKey: .privateKeyPassphrase)
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
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
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
