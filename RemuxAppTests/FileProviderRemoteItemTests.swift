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

    func testIdentifierRoundTripsUnicodeAndRoot() throws {
        let path = try FileProviderRemotePath(relative: "資料/a b.txt")
        let identifier = codec.identifier(for: path)

        XCTAssertEqual(identifier.rawValue, "p:6LOH5paZL2EgYi50eHQ")
        XCTAssertEqual(try codec.path(for: identifier), path)
        XCTAssertEqual(codec.identifier(for: .root), .rootContainer)
        XCTAssertEqual(try codec.path(for: .rootContainer), .root)
    }

    func testIdentifierRejectsMalformedAndReservedRepresentations() throws {
        XCTAssertThrowsError(try codec.path(for: NSFileProviderItemIdentifier(rawValue: "docs/readme")))
        XCTAssertThrowsError(try codec.path(for: NSFileProviderItemIdentifier(rawValue: "p:not base64")))
        XCTAssertThrowsError(try codec.path(for: NSFileProviderItemIdentifier(rawValue: "p:Li4vZXNjYXBl")))
        XCTAssertThrowsError(try codec.path(for: NSFileProviderItemIdentifier(rawValue: "p:")))
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

    func testLinkResolverAcceptsOnlyCanonicalTargetsUnderHome() throws {
        XCTAssertEqual(try resolver.resolve("/home/me", home: "/home/me"), "")
        XCTAssertEqual(try resolver.resolve("/home/me/project", home: "/home/me"), "project")
        XCTAssertThrowsError(try resolver.resolve("/etc/passwd", home: "/home/me"))
        XCTAssertThrowsError(try resolver.resolve("/home/me2/project", home: "/home/me"))
        XCTAssertThrowsError(try resolver.resolve("/home/me/../etc/passwd", home: "/home/me"))
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
