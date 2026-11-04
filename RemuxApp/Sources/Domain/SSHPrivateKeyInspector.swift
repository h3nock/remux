import CryptoKit
import Foundation

enum SSHPrivateKeyType: String, Codable, Equatable, Sendable {
    case ed25519 = "ssh-ed25519"
    case rsa = "ssh-rsa"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"

    var displayName: String {
        switch self {
        case .ed25519:
            "ED25519"
        case .rsa:
            "RSA"
        case .ecdsaP256:
            "ECDSA P-256"
        case .ecdsaP384:
            "ECDSA P-384"
        case .ecdsaP521:
            "ECDSA P-521"
        }
    }

    var ecdsaCurveName: String? {
        switch self {
        case .ed25519, .rsa:
            nil
        case .ecdsaP256:
            "nistp256"
        case .ecdsaP384:
            "nistp384"
        case .ecdsaP521:
            "nistp521"
        }
    }

    var ecdsaPointByteCount: Int? {
        switch self {
        case .ed25519, .rsa:
            nil
        case .ecdsaP256:
            65
        case .ecdsaP384:
            97
        case .ecdsaP521:
            133
        }
    }
}

struct SSHPrivateKeyInspection: Equatable, Sendable {
    let keyType: SSHPrivateKeyType
    let publicFingerprint: String
    let publicKeyLine: String
    let normalizedPEM: String
    let isEncrypted: Bool
}

struct SSHGeneratedPrivateKey: Equatable, Sendable {
    let privateKeyPEM: String
    let publicKeyLine: String
    let publicFingerprint: String
}

enum SSHPrivateKeyInspectionError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLarge
    case invalidOpenSSHPrivateKey
    case unsupportedKeyType(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "Private key is required."
        case .tooLarge:
            "Private key file is too large."
        case .invalidOpenSSHPrivateKey:
            "Import an OpenSSH private key."
        case .unsupportedKeyType(let keyType):
            "Remux does not support \(keyType) private keys yet."
        }
    }
}

enum SSHPrivateKeyInspector {
    static let maxByteCount = 256 * 1024

    static func inspect(_ pem: String) throws -> SSHPrivateKeyInspection {
        let normalizedPEM = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPEM.isEmpty else {
            throw SSHPrivateKeyInspectionError.empty
        }

        guard normalizedPEM.utf8.count <= maxByteCount else {
            throw SSHPrivateKeyInspectionError.tooLarge
        }

        let payload = try openSSHPrivateKeyPayload(from: normalizedPEM)
        var reader = SSHPrivateKeyPayloadReader(data: payload)

        guard
            try reader.readBytes(count: "openssh-key-v1\0".utf8.count) == Data("openssh-key-v1\0".utf8)
        else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let cipherName = try reader.readSSHString()
        let kdfName = try reader.readSSHString()
        let kdfOptions = try reader.readSSHStringData()

        guard try reader.readUInt32() == 1 else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let publicKeyBlob = try reader.readSSHStringData()
        var publicKeyReader = SSHPrivateKeyPayloadReader(data: publicKeyBlob)
        let rawKeyType = try publicKeyReader.readSSHString()

        guard let keyType = SSHPrivateKeyType(rawValue: rawKeyType) else {
            throw SSHPrivateKeyInspectionError.unsupportedKeyType(rawKeyType)
        }
        try validatePublicKeyBlob(for: keyType, reader: &publicKeyReader)
        guard publicKeyReader.isAtEnd else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let privateKeyBlock = try reader.readSSHStringData()
        guard reader.isAtEnd else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        if cipherName == "none" {
            guard kdfName == "none", kdfOptions.isEmpty else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
            try validateUnencryptedPrivateKeyBlock(
                privateKeyBlock,
                keyType: keyType,
                publicKeyBlob: publicKeyBlob
            )
        } else {
            guard !privateKeyBlock.isEmpty else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        }

        return SSHPrivateKeyInspection(
            keyType: keyType,
            publicFingerprint: fingerprint(of: publicKeyBlob),
            publicKeyLine: "\(rawKeyType) \(publicKeyBlob.base64EncodedString())",
            normalizedPEM: normalizedPEM,
            isEncrypted: cipherName != "none"
        )
    }

    /// An ECDSA P-256 public key in X9.63 form, as the Secure Enclave makes one, with its private part held
    /// there: no PEM, and nothing to decrypt.
    static func inspectECDSAP256PublicKey(x963 publicKey: Data) -> SSHPrivateKeyInspection {
        let keyType = SSHPrivateKeyType.ecdsaP256.rawValue
        var blob = SSHPrivateKeyPayloadWriter()
        blob.writeSSHString(keyType)
        blob.writeSSHString("nistp256")
        blob.writeSSHString(publicKey)
        return SSHPrivateKeyInspection(
            keyType: .ecdsaP256,
            publicFingerprint: fingerprint(of: blob.data),
            publicKeyLine: "\(keyType) \(blob.data.base64EncodedString())",
            normalizedPEM: "",
            isEncrypted: false
        )
    }

    /// OpenSSH's SHA256 fingerprint of a public key's wire form.
    private static func fingerprint(of publicKeyBlob: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKeyBlob))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }

    private static func validatePublicKeyBlob(
        for keyType: SSHPrivateKeyType,
        reader: inout SSHPrivateKeyPayloadReader
    ) throws {
        switch keyType {
        case .ed25519:
            guard try reader.readSSHStringData().count == 32 else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        case .rsa:
            let exponent = try reader.readSSHStringData()
            let modulus = try reader.readSSHStringData()
            guard
                !exponent.isEmpty,
                !modulus.isEmpty
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard
                let expectedCurveName = keyType.ecdsaCurveName,
                let expectedPointByteCount = keyType.ecdsaPointByteCount,
                try reader.readSSHString() == expectedCurveName
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
            let point = try reader.readSSHStringData()
            guard point.count == expectedPointByteCount, point.first == 0x04 else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        }
    }

    private static func validateUnencryptedPrivateKeyBlock(
        _ data: Data,
        keyType: SSHPrivateKeyType,
        publicKeyBlob: Data
    ) throws {
        guard data.count.isMultiple(of: 8) else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        var reader = SSHPrivateKeyPayloadReader(data: data)
        var publicKeyReader = SSHPrivateKeyPayloadReader(data: publicKeyBlob)

        guard try publicKeyReader.readSSHString() == keyType.rawValue else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let firstCheck = try reader.readUInt32()
        guard try reader.readUInt32() == firstCheck else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        guard try reader.readSSHString() == keyType.rawValue else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        switch keyType {
        case .ed25519:
            let publicKey = try publicKeyReader.readSSHStringData()
            let privateBlockPublicKey = try reader.readSSHStringData()
            let privateMaterial = try reader.readSSHStringData()
            guard
                privateBlockPublicKey == publicKey,
                publicKey.count == 32,
                privateMaterial.count == 64,
                Data(privateMaterial.suffix(32)) == publicKey
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        case .rsa:
            let publicExponent = try publicKeyReader.readSSHStringData()
            let publicModulus = try publicKeyReader.readSSHStringData()
            let privateBlockModulus = try reader.readSSHStringData()
            let privateBlockExponent = try reader.readSSHStringData()
            guard
                privateBlockModulus == publicModulus,
                privateBlockExponent == publicExponent
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
            for _ in 0..<4 {
                let component = try reader.readSSHStringData()
                guard !component.isEmpty else {
                    throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
                }
            }
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard
                let expectedCurveName = keyType.ecdsaCurveName,
                let expectedPointByteCount = keyType.ecdsaPointByteCount,
                try publicKeyReader.readSSHString() == expectedCurveName,
                try reader.readSSHString() == expectedCurveName
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
            let publicPoint = try publicKeyReader.readSSHStringData()
            let point = try reader.readSSHStringData()
            let privateScalar = try reader.readSSHStringData()
            guard
                point == publicPoint,
                point.count == expectedPointByteCount,
                point.first == 0x04,
                !privateScalar.isEmpty
            else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        }

        _ = try reader.readSSHString()
        let padding = try reader.readRemainingBytes()
        guard padding.count <= 8 else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }
        for (index, byte) in padding.enumerated() {
            guard byte == UInt8(index + 1) else {
                throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
            }
        }

        guard publicKeyReader.isAtEnd else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }
    }

    static func generateEd25519(comment: String = "remux") -> SSHGeneratedPrivateKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let privateSeed = privateKey.rawRepresentation
        let keyType = SSHPrivateKeyType.ed25519.rawValue

        var publicBlob = SSHPrivateKeyPayloadWriter()
        publicBlob.writeSSHString(keyType)
        publicBlob.writeSSHString(publicKey)
        let publicKeyBlob = publicBlob.data

        let check = UInt32.random(in: UInt32.min...UInt32.max)
        var privateBlock = SSHPrivateKeyPayloadWriter()
        privateBlock.writeUInt32(check)
        privateBlock.writeUInt32(check)
        privateBlock.writeSSHString(keyType)
        privateBlock.writeSSHString(publicKey)
        privateBlock.writeSSHString(privateSeed + publicKey)
        privateBlock.writeSSHString(comment)
        privateBlock.writePadding(blockSize: 8)

        var payload = SSHPrivateKeyPayloadWriter()
        payload.writeBytes(Data("openssh-key-v1\0".utf8))
        payload.writeSSHString("none")
        payload.writeSSHString("none")
        payload.writeSSHString(Data())
        payload.writeUInt32(1)
        payload.writeSSHString(publicKeyBlob)
        payload.writeSSHString(privateBlock.data)

        let base64 = payload.data.base64EncodedString()
        let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.distance(from: start, to: base64.endIndex)))
            return String(base64[start..<end])
        }.joined(separator: "\n")
        let privateKeyPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrapped)
        -----END OPENSSH PRIVATE KEY-----
        """
        return SSHGeneratedPrivateKey(
            privateKeyPEM: privateKeyPEM,
            publicKeyLine: "\(keyType) \(publicKeyBlob.base64EncodedString())",
            publicFingerprint: fingerprint(of: publicKeyBlob)
        )
    }

    private static func openSSHPrivateKeyPayload(from pem: String) throws -> Data {
        let lines = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard
            lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
            lines.last == "-----END OPENSSH PRIVATE KEY-----"
        else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let base64 = lines.dropFirst().dropLast().joined()
        guard let payload = Data(base64Encoded: base64) else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        return payload
    }
}

private struct SSHPrivateKeyPayloadReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { result, byte in
            (result << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }

    mutating func readSSHString() throws -> String {
        let stringData = try readSSHStringData()
        guard let string = String(data: stringData, encoding: .utf8) else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }
        return string
    }

    mutating func readSSHStringData() throws -> Data {
        let length = Int(try readUInt32())
        return try readBytes(count: length)
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw SSHPrivateKeyInspectionError.invalidOpenSSHPrivateKey
        }

        let bytes = data[offset..<(offset + count)]
        offset += count
        return Data(bytes)
    }

    mutating func readRemainingBytes() throws -> Data {
        try readBytes(count: data.count - offset)
    }

    var isAtEnd: Bool {
        offset == data.count
    }
}

private struct SSHPrivateKeyPayloadWriter {
    private(set) var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func writeSSHString(_ string: String) {
        writeSSHString(Data(string.utf8))
    }

    mutating func writeSSHString(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writePadding(blockSize: Int) {
        var paddingByte: UInt8 = 1
        repeat {
            data.append(paddingByte)
            paddingByte &+= 1
        } while data.count % blockSize != 0
    }
}
