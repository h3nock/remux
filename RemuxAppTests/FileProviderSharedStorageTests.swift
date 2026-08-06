import Security
import XCTest
@testable import Remux

final class FileProviderSharedStorageTests: XCTestCase {
    func testSharedRootAppendsRemuxToResolvedContainer() throws {
        XCTAssertEqual(
            try ApplicationStorage.sharedRemuxRoot(
                appGroupIdentifier: "group.dev.remux",
                fileManager: .default,
                containerURL: { _ in URL(fileURLWithPath: "/shared") }
            ).path,
            "/shared/Remux"
        )
    }

    func testCredentialQueryIncludesExplicitAccessGroup() {
        let query = KeychainSSHCredentialStore.query(
            service: "dev.remux.ssh-credentials",
            accessGroup: "TEAM.dev.remux.shared",
            identityID: UUID(),
            returnData: false
        )

        XCTAssertEqual(query[kSecAttrAccessGroup] as? String, "TEAM.dev.remux.shared")
    }

    func testSharedConfigurationReadsExpandedAccessGroup() throws {
        XCTAssertEqual(
            try FileProviderSharedConfiguration.keychainAccessGroup(
                infoDictionary: ["RemuxSharedKeychainAccessGroup": "TEAM.dev.remux.shared"]
            ),
            "TEAM.dev.remux.shared"
        )
    }

    func testLiveCredentialStoresKeepApplicationSourceSeparateFromSharedDestination() async throws {
        let service = "dev.remux.tests.\(UUID().uuidString)"
        let stores = try RemuxAppDependencies.fileProviderCredentialStores(service: service)
        let identityID = UUID()

        try await stores.application.saveCredential(.password("application"), identityID: identityID)
        try await stores.shared.saveCredential(.password("shared"), identityID: identityID)

        let applicationCredential = try await stores.application.loadCredential(identityID: identityID)
        let sharedCredential = try await stores.shared.loadCredential(identityID: identityID)

        XCTAssertEqual(applicationCredential, .password("application"))
        XCTAssertEqual(sharedCredential, .password("shared"))

        try await stores.application.deleteCredential(identityID: identityID)
        try await stores.shared.deleteCredential(identityID: identityID)
    }
}
