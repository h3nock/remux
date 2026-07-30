import FileProvider
import XCTest
@testable import Remux

final class FileProviderRemoteItemTests: XCTestCase {
    private let codec = FileProviderItemIdentifierCodec()
    private let resolver = FileProviderSafeLinkResolver()

    func testNormalizationRejectsTraversalAndAcceptsDotfiles() throws {
        XCTAssertEqual(try FileProviderRemotePath(relative: ".config/tool").relative, ".config/tool")
        XCTAssertThrowsError(try FileProviderRemotePath(relative: "/absolute"))
        XCTAssertThrowsError(try FileProviderRemotePath(relative: "../escape"))
        XCTAssertThrowsError(try FileProviderRemotePath(relative: "folder/../../escape"))
        XCTAssertThrowsError(try FileProviderRemotePath(relative: "folder\0name"))
    }

    func testNormalizationCollapsesHarmlessComponentsToOneIdentity() throws {
        let normalized = try FileProviderRemotePath(relative: "folder//./document.txt")

        XCTAssertEqual(normalized.relative, "folder/document.txt")
        XCTAssertEqual(try FileProviderRemotePath(relative: "folder/document.txt"), normalized)
        XCTAssertEqual(try FileProviderRemotePath(relative: "."), .root)
    }

    func testRemotePathAppendsOnlyNormalizedRelativePath() throws {
        XCTAssertEqual(try FileProviderRemotePath.root.remotePath(beneath: "/home/me"), "/home/me")
        XCTAssertEqual(
            try FileProviderRemotePath(relative: "資料/a b.txt").remotePath(beneath: "/home/me"),
            "/home/me/資料/a b.txt"
        )
    }

    func testOpaqueIdentifierRoundTripsIdentityWithoutExposingPath() throws {
        let identity = FileProviderItemIdentity.item(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let identifier = codec.identifier(for: identity)

        XCTAssertEqual(identifier.rawValue, "i:11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(try codec.identity(for: identifier), identity)
        XCTAssertFalse(identifier.rawValue.contains("report"))
        XCTAssertEqual(codec.identifier(for: .root), .rootContainer)
    }

    func testOpaqueIdentifierRejectsPathAndMalformedRepresentations() {
        XCTAssertThrowsError(
            try codec.identity(
                for: NSFileProviderItemIdentifier(rawValue: "p:cmVwb3J0LnR4dA")
            )
        )
        XCTAssertThrowsError(
            try codec.identity(
                for: NSFileProviderItemIdentifier(rawValue: "i:not-a-uuid")
            )
        )
    }

    func testItemDerivesRootAndNestedParents() throws {
        let root = try item(path: .root, type: .directory)
        let nested = try item(path: FileProviderRemotePath(relative: "folder/document.txt"))

        XCTAssertEqual(root.name, "")
        XCTAssertEqual(root.parent, .root)
        XCTAssertEqual(nested.name, "document.txt")
        XCTAssertEqual(nested.parent, try FileProviderRemotePath(relative: "folder"))
    }

    func testContentVersionChangesForOnlyDesignedFields() throws {
        let original = try item(size: 4, modificationDate: 100.9, permissions: 0o100644)

        XCTAssertNotEqual(original.contentVersion, try item(size: 5, modificationDate: 100.9, permissions: 0o100644).contentVersion)
        XCTAssertNotEqual(original.contentVersion, try item(type: .directory, size: 4, modificationDate: 100.9, permissions: 0o040644).contentVersion)
        XCTAssertNotEqual(original.contentVersion, try item(size: 4, modificationDate: 101, permissions: 0o100644).contentVersion)
        XCTAssertEqual(original.contentVersion, try item(size: 4, modificationDate: 100.1, permissions: 0o100600).contentVersion)
        XCTAssertEqual(
            original.contentVersion,
            try item(path: FileProviderRemotePath(relative: "renamed.txt"), size: 4, modificationDate: 100.1, permissions: 0o100644).contentVersion
        )
    }

    func testMetadataVersionChangesForMetadataFieldsButNotLinkTarget() throws {
        let original = try item(symlinkTargetRelativePath: "safe-target")

        XCTAssertNotEqual(original.metadataVersion, try item(permissions: 0o100600).metadataVersion)
        XCTAssertNotEqual(
            original.metadataVersion,
            try item(path: FileProviderRemotePath(relative: "renamed.txt")).metadataVersion
        )
        XCTAssertEqual(
            original.metadataVersion,
            try item(symlinkTargetRelativePath: "another-safe-target").metadataVersion
        )
    }

    func testMetadataVersionIsFixedSizeForLongUnicodeDeepPaths() throws {
        let component = String(repeating: "資料", count: 40)
        let path = try FileProviderRemotePath(
            relative: Array(repeating: component, count: 20).joined(separator: "/") + "/document.txt"
        )
        let original = try item(path: path)

        XCTAssertEqual(original.metadataVersion.count, 32)
        XCTAssertLessThanOrEqual(original.metadataVersion.count, 128)
        XCTAssertEqual(original.metadataVersion, try item(path: path).metadataVersion)
        XCTAssertNotEqual(original.metadataVersion, try item(path: path, permissions: 0o100600).metadataVersion)
    }

    func testLinkResolverProjectsTargetsRelativeToSymlinkParent() throws {
        XCTAssertEqual(
            try resolver.resolve(
                "/home/me/projects/target",
                home: "/home/me",
                for: FileProviderRemotePath(relative: "projects/link")
            ),
            "target"
        )
        XCTAssertEqual(
            try resolver.resolve(
                "/home/me/shared/target",
                home: "/home/me",
                for: FileProviderRemotePath(relative: "projects/link")
            ),
            "../shared/target"
        )
        XCTAssertEqual(
            try resolver.resolve(
                "/home/me",
                home: "/home/me",
                for: FileProviderRemotePath(relative: "link")
            ),
            "."
        )
        XCTAssertEqual(
            try resolver.resolve(
                "/home/me",
                home: "/home/me",
                for: FileProviderRemotePath(relative: "projects/link")
            ),
            ".."
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                "/home/me2/project",
                home: "/home/me",
                for: FileProviderRemotePath(relative: "projects/link")
            )
        )
    }

    func testItemRejectsUnsafeSymlinkTargetsAndAcceptsParentRelativeTarget() throws {
        let nestedLink = try FileProviderRemotePath(relative: "projects/link")

        XCTAssertEqual(
            try item(path: nestedLink, symlinkTargetRelativePath: "../shared/target").symlinkTargetRelativePath,
            "../shared/target"
        )
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "/etc/passwd"))
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "target\0name"))
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "./target"))
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "folder//target"))
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "folder/../target"))
        XCTAssertThrowsError(try item(path: nestedLink, symlinkTargetRelativePath: "../../escape"))
        XCTAssertThrowsError(
            try item(
                path: FileProviderRemotePath(relative: "link"),
                symlinkTargetRelativePath: "../escape"
            )
        )
    }

    func testItemDecodingRejectsUnsafeSymlinkTarget() throws {
        let source = try item(
            path: FileProviderRemotePath(relative: "projects/link"),
            symlinkTargetRelativePath: "../shared/target"
        )
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any]
        )
        payload["symlinkTargetRelativePath"] = "../../escape"
        let unsafePayload = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(FileProviderRemoteItem.self, from: unsafePayload))
    }

    func testCapabilitiesMatchWritableTypePolicy() throws {
        XCTAssertEqual(
            try projection(path: .root, type: .directory).capabilities,
            [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems]
        )
        XCTAssertEqual(
            try projection(path: "folder", type: .directory).capabilities,
            [
                .allowsReading, .allowsWriting, .allowsContentEnumerating,
                .allowsAddingSubItems, .allowsRenaming, .allowsReparenting,
                .allowsDeleting,
            ]
        )
        XCTAssertEqual(
            try projection(path: "file.txt", type: .regular).capabilities,
            [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        )
        XCTAssertEqual(
            try projection(path: "link", type: .symbolicLink).capabilities,
            [.allowsReading]
        )
        XCTAssertEqual(
            try projection(path: "socket", type: .other).capabilities,
            [.allowsReading]
        )
    }

    private func projection(
        path: String,
        type: RemuxSFTPFileType
    ) throws -> FileProviderItemProjection {
        try projection(path: FileProviderRemotePath(relative: path), type: type)
    }

    private func projection(
        path: FileProviderRemotePath,
        type: RemuxSFTPFileType
    ) throws -> FileProviderItemProjection {
        let remote = try item(path: path, type: type)
        return FileProviderItemProjection(
            item: FileProviderIdentifiedItem(
                identity: path == .root ? .root : .item(UUID()),
                parentIdentity: .root,
                remoteItem: remote
            ),
            rootDisplayName: "Fixture"
        )
    }

    private func item(
        path: FileProviderRemotePath? = nil,
        type: RemuxSFTPFileType = .regular,
        size: UInt64? = 4,
        modificationDate: TimeInterval? = 100,
        permissions: UInt32? = 0o100644,
        symlinkTargetRelativePath: String? = nil
    ) throws -> FileProviderRemoteItem {
        try FileProviderRemoteItem(
            path: try path ?? FileProviderRemotePath(relative: "document.txt"),
            metadata: RemuxSFTPFileMetadata(
                size: size,
                permissions: permissions,
                modificationDate: modificationDate.map(Date.init(timeIntervalSince1970:)),
                type: type
            ),
            symlinkTargetRelativePath: symlinkTargetRelativePath
        )
    }
}
