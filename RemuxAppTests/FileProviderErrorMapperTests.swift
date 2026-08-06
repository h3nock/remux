@preconcurrency import Citadel
import FileProvider
import NIOCore
import XCTest

@testable import Remux

final class FileProviderErrorMapperTests: XCTestCase {
    func testErrorMapperUsesStableDomainsCodesAndRequestedItem() {
        let identifier = NSFileProviderItemIdentifier(rawValue: "p:cmVwb3J0LnR4dA")
        let cases: [(Error, String, Int)] = [
            (RemuxSFTPClientError.operationTimedOut, NSFileProviderErrorDomain, NSFileProviderError.serverUnreachable.rawValue),
            (RemuxSFTPClientError.sessionUnavailable, NSFileProviderErrorDomain, NSFileProviderError.serverUnreachable.rawValue),
            (URLError(.timedOut), NSFileProviderErrorDomain, NSFileProviderError.serverUnreachable.rawValue),
            (SSHAuthResolverError.missingCredential(UUID()), NSFileProviderErrorDomain, NSFileProviderError.notAuthenticated.rawValue),
            (TrustedHostStoreError.hostKeyTrustRequired(unknownTrustChallenge), NSFileProviderErrorDomain, NSFileProviderError.notAuthenticated.rawValue),
            (TrustedHostStoreError.staleHostKeyTrust(host: "server.example.test"), NSFileProviderErrorDomain, NSFileProviderError.notAuthenticated.rawValue),
            (RemuxSFTPClientError.noSuchFile("/private/report.txt"), NSFileProviderErrorDomain, NSFileProviderError.noSuchItem.rawValue),
            (FileProviderSnapshotStoreError.syncAnchorExpired, NSFileProviderErrorDomain, NSFileProviderError.syncAnchorExpired.rawValue),
        ]

        for (error, domain, code) in cases {
            let mapped = FileProviderErrorMapper.map(error, itemIdentifier: identifier)
            XCTAssertEqual(mapped.domain, domain)
            XCTAssertEqual(mapped.code, code)
        }

        let missing = FileProviderErrorMapper.map(
            RemuxSFTPClientError.noSuchFile("/private/report.txt"),
            itemIdentifier: identifier
        )
        XCTAssertEqual(missing.userInfo[NSFileProviderErrorItemKey] as? NSFileProviderItemIdentifier, identifier)
    }

    func testUnknownOpaqueIdentityMapsToRequestedNoSuchItem() {
        let identifier = NSFileProviderItemIdentifier(
            rawValue: "i:11111111-2222-3333-4444-555555555555"
        )

        let error = FileProviderErrorMapper.map(
            FileProviderSnapshotStoreError.itemIdentityNotFound,
            itemIdentifier: identifier
        )

        XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.noSuchItem.rawValue)
        XCTAssertEqual(
            error.userInfo[NSFileProviderErrorNonExistentItemIdentifierKey]
                as? NSFileProviderItemIdentifier,
            identifier
        )
    }

    func testErrorMapperSanitizesUnknownErrorsAndWritePolicy() {
        let sentinel = "password=super-secret-private-key-passphrase"
        let mapped = FileProviderErrorMapper.map(SecretError(sentinel))

        XCTAssertEqual(mapped.domain, NSCocoaErrorDomain)
        XCTAssertEqual(mapped.code, NSXPCConnectionReplyInvalid)
        XCTAssertTrue(mapped.userInfo.isEmpty)
        XCTAssertFalse(mapped.localizedDescription.contains(sentinel))
        XCTAssertFalse(String(reflecting: mapped).contains(sentinel))

        XCTAssertEqual(FileProviderErrorMapper.writePermission.domain, NSCocoaErrorDomain)
        XCTAssertEqual(FileProviderErrorMapper.writePermission.code, NSFileWriteNoPermissionError)
    }

    func testErrorMapperMapsWritePermissionAndSanitizesUnsupportedMutation() {
        let permissionDenied = FileProviderErrorMapper.map(
            RemuxSFTPClientError.permissionDenied
        )
        XCTAssertEqual(permissionDenied.domain, NSCocoaErrorDomain)
        XCTAssertEqual(permissionDenied.code, NSFileWriteNoPermissionError)

        let unsupportedMutation = FileProviderErrorMapper.map(
            RemuxSFTPClientError.unsupportedMutation
        )
        XCTAssertEqual(unsupportedMutation.domain, NSCocoaErrorDomain)
        XCTAssertEqual(unsupportedMutation.code, NSXPCConnectionReplyInvalid)
        XCTAssertTrue(unsupportedMutation.userInfo.isEmpty)
    }

    func testErrorMapperMapsChannelSessionFailuresToServerUnreachable() {
        let errors: [ChannelError] = [
            .connectTimeout(.seconds(1)),
            .eof,
            .ioOnClosedChannel,
            .alreadyClosed,
            .inputClosed,
            .outputClosed,
        ]

        for error in errors {
            let mapped = FileProviderErrorMapper.map(error)
            XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(mapped.code, NSFileProviderError.serverUnreachable.rawValue)
        }
    }

    func testErrorMapperMapsConfiguredCitadelAuthenticationFailuresToNotAuthenticated() {
        let errors: [SSHClientError] = [
            .allAuthenticationOptionsFailed,
            .unsupportedPasswordAuthentication,
            .unsupportedPrivateKeyAuthentication,
        ]

        for error in errors {
            let mapped = FileProviderErrorMapper.map(error)
            XCTAssertEqual(mapped.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(mapped.code, NSFileProviderError.notAuthenticated.rawValue)
        }
    }

    func testErrorMapperMapsCancellationWithoutLeakingImplementationDetails() {
        let mapped = FileProviderErrorMapper.map(CancellationError())

        XCTAssertEqual(mapped.domain, NSCocoaErrorDomain)
        XCTAssertEqual(mapped.code, NSUserCancelledError)
        XCTAssertTrue(mapped.userInfo.isEmpty)
    }

    func testMissingItemIdentifierDoesNotProduceKeylessNoSuchItem() {
        let mapped = FileProviderErrorMapper.map(
            RemuxSFTPClientError.noSuchFile("/private/report.txt")
        )

        XCTAssertEqual(mapped.domain, NSCocoaErrorDomain)
        XCTAssertEqual(mapped.code, NSXPCConnectionReplyInvalid)
        XCTAssertTrue(mapped.userInfo.isEmpty)
    }

    private var unknownTrustChallenge: SSHHostKeyTrustChallenge {
        SSHHostKeyTrustChallenge(
            kind: .unknown,
            serverID: UUID(),
            host: "server.example.test",
            trustedKeyType: nil,
            trustedOpenSSHPublicKey: nil,
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 public-key"
        )
    }
}

private struct SecretError: LocalizedError {
    let secret: String

    init(_ secret: String) {
        self.secret = secret
    }

    var errorDescription: String? {
        secret
    }
}
