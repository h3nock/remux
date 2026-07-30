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
}
