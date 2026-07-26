import Foundation
import XCTest

final class FileProviderExtensionConfigurationTests: XCTestCase {
    func testExtensionDeclaresWritableSerialUploadPipelines() throws {
        let extensionURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("RemuxFileProvider.appex")
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let configuration = try XCTUnwrap(
            extensionBundle.infoDictionary?["NSExtension"] as? [String: Any]
        )

        XCTAssertNil(configuration["NSExtensionFileProviderReadOnly"])
        XCTAssertEqual(
            configuration["NSExtensionFileProviderUploadPipelineDepth"] as? Int,
            1
        )
        XCTAssertEqual(
            configuration["NSExtensionFileProviderMetadataOnlyUploadPipelineDepth"] as? Int,
            1
        )
    }
}
