@preconcurrency import Crypto
import XCTest
import NIOSSH
@testable import Remux

final class SSHPrivateKeyInspectorTests: XCTestCase {
    // A software public key exercises metadata paths without accessing the SEP
    // or prompting on a simulator. The opaque representation is a test fixture.
    private func enclaveFixture() -> (SecureEnclaveSSHKey, P256.Signing.PrivateKey) {
        let softwareKey = P256.Signing.PrivateKey()
        return (SecureEnclaveSSHKey(
            representation: Data("opaque-test-reference".utf8),
            publicKey: softwareKey.publicKey.x963Representation
        ), softwareKey)
    }

    func testEnclavePublicKeyMatchesNIOSSHEncodingWithoutUnlocking() throws {
        let (key, softwareKey) = enclaveFixture()
        let inspection = try key.inspect()
        XCTAssertEqual(inspection.publicKeyLine, String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: softwareKey).publicKey))
        XCTAssertEqual(inspection.keyType, .ecdsaP256)
        XCTAssertEqual(inspection.normalizedPEM, "")
        XCTAssertFalse(inspection.isEncrypted)
    }

    func testEnclaveCredentialRoundTripsWithoutPEM() throws {
        let (key, _) = enclaveFixture()
        let credential = SSHCredential.privateKey(SSHPrivateKeyCredential(privateKeyPEM: "", secureEnclaveKey: key))
        let encoded = try JSONEncoder().encode(credential)
        XCTAssertEqual(try JSONDecoder().decode(SSHCredential.self, from: encoded), credential)
    }

    func testLegacyCredentialDecodesWithoutEnclaveReference() throws {
        let data = Data(#"{"kind":"privateKey","privateKeyPEM":"legacy","privateKeyPassphrase":"passphrase"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SSHCredential.self, from: data),
                       .privateKey(SSHPrivateKeyCredential(privateKeyPEM: "legacy", passphrase: "passphrase")))
    }

    func testEnclaveAuthRequiresUserPresenceAndUsesDistinctPoolIdentity() throws {
        let (key, _) = enclaveFixture()
        let auth = try ResolvedSSHAuth.privateKey(username: "test", credential:
            SSHPrivateKeyCredential(privateKeyPEM: "", secureEnclaveKey: key),
            identityID: UUID(), displayLabel: "test")
        XCTAssertTrue(auth.requiresInteractiveAuthentication)
        XCTAssertTrue(auth.authFingerprint.hasPrefix("secure-enclave:"))
        XCTAssertFalse(ResolvedSSHAuth.password(username: "test", password: "fixture", identityID: UUID(), displayLabel: "test").requiresInteractiveAuthentication)
    }

    func testEnclaveDraftSurvivesValidationAndEditingWithoutPEM() throws {
        let (key, _) = enclaveFixture()
        var draft = TmuxConnectionDraft()
        draft.host = "server.example.test"
        draft.username = "test"
        draft.displayName = "Test"
        draft.authenticationKind = .privateKey
        draft.secureEnclaveKey = key
        guard case .valid(let submission) = TmuxConnectionDraftValidator.validateServer(draft, existingServerID: nil) else {
            return XCTFail("Expected a valid Secure Enclave credential without PEM")
        }
        let credential = SSHPrivateKeyCredential(privateKeyPEM: "", secureEnclaveKey: key)
        XCTAssertEqual(submission.credential, .privateKey(credential))
        let identity = SSHIdentity(name: "Test", authenticationKind: .privateKey)
        let server = SavedServer(displayName: "Test", host: draft.host, username: draft.username, identityID: identity.id)
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "test")
        let edited = TmuxConnectionDraft(server: server, workspace: workspace, identity: identity, credential: .privateKey(credential))
        XCTAssertEqual(edited.secureEnclaveKey, key)
        XCTAssertTrue(edited.privateKeyPEM.isEmpty)
    }

    func testInspectsUnencryptedEd25519Key() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.ed25519Key)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:ut9xpxBjkrwDyq3o7dO0r/opPmzTsBSslfZtdaBGYWk")
        XCTAssertTrue(inspection.publicKeyLine.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(inspection.normalizedPEM, Self.ed25519Key)
    }

    func testInspectsEncryptedEd25519KeyWithoutPassphrase() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.encryptedEd25519Key)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:yEWIQVesP93YESnAgn/VLQP2EVeTWHpXrwGeFZs/doQ")
    }

    func testInspectsUnencryptedRSAKey() throws {
        let inspection = try SSHPrivateKeyInspector.inspect(Self.rsaKey)

        XCTAssertEqual(inspection.keyType, .rsa)
        XCTAssertEqual(inspection.publicFingerprint, "SHA256:Uws9SA2STf78Yr7GkJ9XeWMtf8zR+7/fQ5gkUnVTaP0")
        XCTAssertTrue(inspection.publicKeyLine.hasPrefix("ssh-rsa "))
    }

    func testInspectsUnencryptedECDSAKeys() throws {
        let p256 = try SSHPrivateKeyInspector.inspect(Self.ecdsaP256Key)
        XCTAssertEqual(p256.keyType, .ecdsaP256)
        XCTAssertEqual(p256.keyType.displayName, "ECDSA P-256")
        XCTAssertTrue(p256.publicKeyLine.hasPrefix("ecdsa-sha2-nistp256 "))
        XCTAssertTrue(p256.publicFingerprint.hasPrefix("SHA256:"))

        let p384 = try SSHPrivateKeyInspector.inspect(Self.ecdsaP384Key)
        XCTAssertEqual(p384.keyType, .ecdsaP384)
        XCTAssertEqual(p384.keyType.displayName, "ECDSA P-384")
        XCTAssertTrue(p384.publicKeyLine.hasPrefix("ecdsa-sha2-nistp384 "))
        XCTAssertTrue(p384.publicFingerprint.hasPrefix("SHA256:"))

        let p521 = try SSHPrivateKeyInspector.inspect(Self.ecdsaP521Key)
        XCTAssertEqual(p521.keyType, .ecdsaP521)
        XCTAssertEqual(p521.keyType.displayName, "ECDSA P-521")
        XCTAssertTrue(p521.publicKeyLine.hasPrefix("ecdsa-sha2-nistp521 "))
        XCTAssertTrue(p521.publicFingerprint.hasPrefix("SHA256:"))
    }

    func testGeneratesInspectableEd25519Key() throws {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "remux-test")
        let inspection = try SSHPrivateKeyInspector.inspect(generated.privateKeyPEM)

        XCTAssertEqual(inspection.keyType, .ed25519)
        XCTAssertEqual(inspection.publicKeyLine, generated.publicKeyLine)
        XCTAssertEqual(inspection.publicFingerprint, generated.publicFingerprint)
        XCTAssertTrue(generated.publicKeyLine.hasPrefix("ssh-ed25519 "))
    }

    func testGeneratedEd25519KeyLoadsThroughConnectionParser() throws {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "remux-test")
        let inspection = try SSHPrivateKeyInspector.inspect(generated.privateKeyPEM)

        let privateKey = try Curve25519.Signing.PrivateKey(
            sshEd25519: inspection.normalizedPEM,
            decryptionKey: nil
        )

        XCTAssertEqual(privateKey.publicKey.rawRepresentation.count, 32)
    }

    func testECDSAKeysLoadThroughConnectionParser() throws {
        let p256Inspection = try SSHPrivateKeyInspector.inspect(Self.ecdsaP256Key)
        let p256Key = try P256.Signing.PrivateKey(sshEcdsaP256: p256Inspection.normalizedPEM)
        XCTAssertEqual(p256Key.publicKey.x963Representation.count, 65)

        let p384Inspection = try SSHPrivateKeyInspector.inspect(Self.ecdsaP384Key)
        let p384Key = try P384.Signing.PrivateKey(sshEcdsaP384: p384Inspection.normalizedPEM)
        XCTAssertEqual(p384Key.publicKey.x963Representation.count, 97)

        let p521Inspection = try SSHPrivateKeyInspector.inspect(Self.ecdsaP521Key)
        let p521Key = try P521.Signing.PrivateKey(sshEcdsaP521: p521Inspection.normalizedPEM)
        XCTAssertEqual(p521Key.publicKey.x963Representation.count, 133)
    }

    func testRejectsEmptyKey() {
        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect("   \n")) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .empty)
        }
    }

    func testRejectsInvalidOpenSSHKey() {
        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect("not a key")) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testRejectsTruncatedPrivateKeyBlock() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "broken")
        let truncated = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            payload.removeLast(min(payload.count, 8))
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(truncated)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testRejectsTrailingTopLevelData() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "trailing")
        let trailing = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            payload.append(0)
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(trailing)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testRejectsOversizedUnencryptedPaddingWithoutTrapping() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "oversized-padding")
        let oversizedPadding = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            Self.mutatePrivateBlock(in: &payload) { block in
                block.append(contentsOf: repeatElement(UInt8(1), count: 256))
            }
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(oversizedPadding)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testAcceptsUnencryptedKeyWithoutPadding() throws {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "align")
        let noPadding = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            Self.mutatePrivateBlock(in: &payload) { block in
                var offset = 8
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                block.removeSubrange(offset..<block.count)
            }
        }

        let inspection = try SSHPrivateKeyInspector.inspect(noPadding)

        XCTAssertEqual(inspection.keyType, .ed25519)
    }

    func testRejectsUnalignedUnencryptedPrivateBlockWithoutPadding() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "unaligned")
        let unaligned = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            Self.mutatePrivateBlock(in: &payload) { block in
                var offset = 8
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                block.removeSubrange(offset..<block.count)
            }
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(unaligned)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testRejectsMismatchedPrivateBlockPublicKey() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "mismatched-public")
        let mismatched = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            Self.mutatePrivateBlock(in: &payload) { block in
                var offset = 8
                Self.skipSSHString(in: block, offset: &offset)
                offset += 4
                block[offset] ^= 0x01
            }
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(mismatched)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    func testRejectsMismatchedEd25519PrivateMaterialPublicKey() {
        let generated = SSHPrivateKeyInspector.generateEd25519(comment: "mismatched-private")
        let mismatched = Self.privateKeyPEM(generated.privateKeyPEM) { payload in
            Self.mutatePrivateBlock(in: &payload) { block in
                var offset = 8
                Self.skipSSHString(in: block, offset: &offset)
                Self.skipSSHString(in: block, offset: &offset)
                let privateMaterialLength = Int(Self.readUInt32(in: block, offset: offset))
                offset += 4
                block[offset + privateMaterialLength - 1] ^= 0x01
            }
        }

        XCTAssertThrowsError(try SSHPrivateKeyInspector.inspect(mismatched)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyInspectionError, .invalidOpenSSHPrivateKey)
        }
    }

    private static func privateKeyPEM(
        _ pem: String,
        mutate: (inout Data) -> Void
    ) -> String {
        let lines = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var payload = Data(base64Encoded: lines.dropFirst().dropLast().joined())!
        mutate(&payload)

        let base64 = payload.base64EncodedString()
        var wrappedLines: [String] = []
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            wrappedLines.append(String(base64[start..<end]))
            start = end
        }

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(wrappedLines.joined(separator: "\n"))
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private static func mutatePrivateBlock(
        in payload: inout Data,
        mutate: (inout Data) -> Void
    ) {
        var offset = "openssh-key-v1\0".utf8.count
        skipSSHString(in: payload, offset: &offset)
        skipSSHString(in: payload, offset: &offset)
        skipSSHString(in: payload, offset: &offset)
        offset += 4
        skipSSHString(in: payload, offset: &offset)

        let lengthOffset = offset
        let length = Int(readUInt32(in: payload, offset: offset))
        offset += 4
        let blockStart = offset
        let blockEnd = blockStart + length
        var privateBlock = payload.subdata(in: blockStart..<blockEnd)
        mutate(&privateBlock)

        var rebuilt = payload.subdata(in: 0..<lengthOffset)
        appendUInt32(UInt32(privateBlock.count), to: &rebuilt)
        rebuilt.append(privateBlock)
        rebuilt.append(payload.subdata(in: blockEnd..<payload.count))
        payload = rebuilt
    }

    private static func skipSSHString(in data: Data, offset: inout Int) {
        let length = Int(readUInt32(in: data, offset: offset))
        offset += 4 + length
    }

    private static func readUInt32(in data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { result, byte in
            (result << 8) | UInt32(byte)
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static let ed25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQAAAJhUdIMJVHSD
    CQAAAAtzc2gtZWQyNTUxOQAAACBrnioq6neTEO1xxGFen/fsHyajOA4is61ZfPpaD/dzkQ
    AAAEAuFkLHR6BO6DpN/zM9hdy3psHOh+8TxQMwJaNEWacIvmueKirqd5MQ7XHEYV6f9+wf
    JqM4DiKzrVl8+loP93ORAAAAEnJlbXV4LXRlc3QtZWQyNTUxOQECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let encryptedEd25519Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD87oA8AF
    9fpLEAQtTWMZZwAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuwDbwcjxPpUNPA
    PkZgyQ9jnCXaboZMHs+AWOqtGxO0AAAAoA9no2kroZ7q7MIpSQ6+Gs5N/KMrm/eFRfWf4K
    iLGRTczk+WQycDp1YidTw8kH9IwJle5ulywHf+5iLCVaolx8vYErJfKsJ1DRRx0qMzZObI
    AHd8pT6MnuDISadNzI+lZgn1dbCZ6/aWPVFO3pFpmREscRgolzFcvSOtLiT/5U1wWUhwPo
    KGvU4Tmf5I5hGQCbKhx4g4z7aJfILg2ErdGPQ=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let rsaKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAQEAvHwbXstzv7i97hp/QLB+mOdUFRdkx1t5qUNH10SprpeID3gLAWYB
    bJaRs9uTtVj4oChmmAV3nAJtSLQirDrgFrvGNsrk8rQUdvynWoN8g7VKeuIP27ZBCTN3pp
    nX3oneXDSDvk/Z/+qEp0GPxtJYfka8Ff2dtx63bgoF7j/okqunRoJKLRyXWGG4RcXSjC4T
    KRyDAdRe79eORz4Fc+3yWjbrifEvHR4GumNNcJrfpyU3AOpF1aRfIaQ+tpwMovta/V1y1p
    KXJ8Z337pXSgLVwPXolyjwyvzdCmohStkQSwJGiqfSUCyBeaobSNDl6F/66u1VowW/gwhT
    ysNVKQ6Y6QAAA8hwane2cGp3tgAAAAdzc2gtcnNhAAABAQC8fBtey3O/uL3uGn9AsH6Y51
    QVF2THW3mpQ0fXRKmul4gPeAsBZgFslpGz25O1WPigKGaYBXecAm1ItCKsOuAWu8Y2yuTy
    tBR2/Kdag3yDtUp64g/btkEJM3emmdfeid5cNIO+T9n/6oSnQY/G0lh+RrwV/Z23HrduCg
    XuP+iSq6dGgkotHJdYYbhFxdKMLhMpHIMB1F7v145HPgVz7fJaNuuJ8S8dHga6Y01wmt+n
    JTcA6kXVpF8hpD62nAyi+1r9XXLWkpcnxnffuldKAtXA9eiXKPDK/N0KaiFK2RBLAkaKp9
    JQLIF5qhtI0OXoX/rq7VWjBb+DCFPKw1UpDpjpAAAAAwEAAQAAAQAVjYN7tXwI4lEllvYS
    KZxwU5NzzfcCLN2ek0j1vq5AfqdaTXnEsStchWMn0+XyCLh1Z+lDXOyudECW3bJRS3IwZ0
    xlG5JOhnUInh9s5Dgqv2JC5vK1RwPsz2vRKypaEh3RIVgnPO5Kq0B7960/KPJhjikXwqZ0
    OBj1hkPjWH95teCGpC6WHJk5G820KmngVwqcR/TF4iQ4qddOl7O3U5jun2tzoq2Hpva2oW
    /OfS6DjaPp55kNg/SKYJTA/e0DZLeyIwaGx8ctmJYr9hsAhD6rclWZVTEVAMLR36Pofzej
    bYgLSn+PSNfrsLeY6tgr/jmKCV7EBE5g+9n+GSOgw/thAAAAgQCeDKd91bg5RJ38bdA/2f
    m3Cl8w2OK28oGrlaZVGnPcrS9QLvnRgqrB5HfGOSxgnsYwmrdiRmafK7k9wz0XjtPjhDRR
    L00qOCxtwSLrL+IWZtJPA06xkgxD46uTnTs4Qt3Vc8NRTjT1pJ3+YzuyPyJ/Z2EbHCnTQg
    FFce73mrBUKQAAAIEA+axWwVHCEde05ARuP8h2HMJHaAgoXirnjikOJ4kIfIUSU8VVp1VW
    eEcml96bVl/NIgDEI1LGn89OY9U+tZwietN1352FsnZwkJUqYJ8WvLZ/mXZdBgbo3tIkeR
    RAC93/paVW271i856Wza7AAQFp6fpSvWACBuf5BrK+UqVf1V0AAACBAMFC1Mr7Wxc99VvO
    SPN7VcCWbtxUggzVrJF9qmy+CF0XvoSrmPZzHM8YkdKcAfYoY6WEBpsg7WQZ7pU1CPaDEI
    Uy5fslboaiuQuwFBBnT1QDQQ0SoITS6MBvh0DFJVg76mR4vDLXGEmVo59CHxFZy7kR2GXu
    DfSvNOmwIetJ0+z9AAAADnJlbXV4LXRlc3QtcnNhAQIDBA==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ecdsaP256Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQR/G9rJovBSvdkd9XoGNURImI5vQP/2
    w7TQNb/b8hGI5oq844XjI7V4j8XDwjqlcNfeD7gqoHf8ekpmL4EUtzYaAAAAqFZzBpBWcw
    aQAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBH8b2smi8FK92R31
    egY1REiYjm9A//bDtNA1v9vyEYjmirzjheMjtXiPxcPCOqVw194PuCqgd/x6SmYvgRS3Nh
    oAAAAgPV1jW6vy45i2F3WBFirMPgiJU7FgIl4rJy264fkhPU4AAAALeW91QGV4YW1wbGUB
    AgMEBQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ecdsaP384Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
    1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQTbanVgBsim5t0MwvPHpmbupOibZFVU
    a9Teahi4S4YZsvEob0eX9wYSEA2VF6MNKCDM0wQFtm0tk/5vgG0vqSaqjefgXCsov7mFDx
    BW0Trg0YqULpUlRR9l9f12TyZm050AAADY3IaN69yGjesAAAATZWNkc2Etc2hhMi1uaXN0
    cDM4NAAAAAhuaXN0cDM4NAAAAGEE22p1YAbIpubdDMLzx6Zm7qTom2RVVGvU3moYuEuGGb
    LxKG9Hl/cGEhANlRejDSggzNMEBbZtLZP+b4BtL6kmqo3n4FwrKL+5hQ8QVtE64NGKlC6V
    JUUfZfX9dk8mZtOdAAAAMQDtslLX7WTAyAIiTxRVtOl9WXp/GKn9agJIJ0/qOpuRaYGLtk
    w3LPjfQfpJT1dh9CUAAAALeW91QGV4YW1wbGUBAgME
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ecdsaP521Key = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
    1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQAuwrbbKlzQliuu1AmBtr9N7xG1Qic
    MqizNJa5zWWnm9rvBvQwIl0u6NDmUMVTnLxscnk9hXARGaLnn2ufhGhrDWkBujkMnwfGy7
    f/eIIOmWwdoMh/fbam5qMtOgNIp5QO9I70QstcHF62ankrtmcgBZtdCBsvHAuIfL6IK2ts
    BgG7cvMAAAEQktYcEpLWHBIAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
    AAAIUEALsK22ypc0JYrrtQJgba/Te8RtUInDKoszSWuc1lp5va7wb0MCJdLujQ5lDFU5y8
    bHJ5PYVwERmi559rn4Roaw1pAbo5DJ8Hxsu3/3iCDplsHaDIf322puajLToDSKeUDvSO9E
    LLXBxetmp5K7ZnIAWbXQgbLxwLiHy+iCtrbAYBu3LzAAAAQgETL+ZErb1c9FwcOKtIuXgy
    pS4OdBd4Il5mUSzCwJ/PKWO0L+KRTthlNrwZTRxrdGIsjonmEEoIh9kLfGM3Tpa0YQAAAA
    t5b3VAZXhhbXBsZQECAwQFBgc=
    -----END OPENSSH PRIVATE KEY-----
    """
}
