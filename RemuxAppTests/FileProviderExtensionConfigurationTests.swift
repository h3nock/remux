import Foundation
import XCTest

final class FileProviderExtensionConfigurationTests: XCTestCase {
    func testExtensionDeclaresProviderAsReadOnly() throws {
        let extensionURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("RemuxFileProvider.appex")
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let extensionConfiguration = try XCTUnwrap(
            extensionBundle.infoDictionary?["NSExtension"] as? [String: Any]
        )

        XCTAssertEqual(
            extensionConfiguration["NSExtensionFileProviderReadOnly"] as? Bool,
            true
        )
    }
}
