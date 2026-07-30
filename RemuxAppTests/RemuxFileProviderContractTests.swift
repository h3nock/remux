@preconcurrency import Citadel
import FileProvider
import Foundation
import NIOEmbedded
@preconcurrency import NIOSSH
import UniformTypeIdentifiers
import XCTest
@testable import Remux

final class RemuxFileProviderContractTests: XCTestCase {

    func testSharedAuthenticationFactoryPreservesPasswordCredentials() throws {
        let authentication = ResolvedSSHAuth.password(
            username: "reader",
            password: "test-password",
            identityID: UUID(),
            displayLabel: "Fixture"
        )

        let credential: SSHCredential
        switch authentication.credential {
        case .password(let password):
            credential = .password(password)
        case .privateKey(let privateKey):
            credential = .privateKey(privateKey)
        }

        let method = try SSHAuthenticationMethodFactory.make(
            username: authentication.username,
            credential: credential
        )
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        method.nextAuthenticationType(
            availableMethods: [.password],
            nextChallengePromise: promise
        )
        let offer = try XCTUnwrap(promise.futureResult.wait())

        XCTAssertEqual(offer.username, "reader")
        guard case .password(let password) = offer.offer else {
            XCTFail("Expected password authentication")
            return
        }
        XCTAssertEqual(password.password, "test-password")
    }

    func testSSHRootKeyCanBeBuiltWithoutATmuxConnectionTarget() {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Fixture",
            host: "reader.example.test",
            port: 2222,
            username: "saved-user",
            identityID: identityID
        )
        let authentication = ResolvedSSHAuth.password(
            username: "resolved-user",
            password: "test-password",
            identityID: identityID,
            displayLabel: "Fixture"
        )

        let key = RemuxSSHRootKey(server: server, auth: authentication)

        XCTAssertEqual(key.serverID, server.id)
        XCTAssertEqual(key.host, "reader.example.test")
        XCTAssertEqual(key.port, 2222)
        XCTAssertEqual(key.username, "resolved-user")
    }
}
