import XCTest
import UniformTypeIdentifiers
@testable import Remux

final class GhosttyAttachmentStagingStoreTests: XCTestCase {
    func testStageFileCopiesIntoRemuxStagingDirectory() throws {
        let sourceURL = try makeSourceFile(named: "notes.txt", data: Data("hello".utf8))

        let attachment = try GhosttyAttachmentStagingStore.stageFileSynchronously(sourceURL)
        guard case .file(let stagedURL) = attachment.payload else {
            return XCTFail("Expected staged file payload")
        }

        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data("hello".utf8))

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testStageFileURLCopiesIntoRemuxStagingDirectory() throws {
        let sourceURL = try makeSourceFile(named: "image.jpeg", data: Data([0x01, 0x02]))

        let stagedURL = try GhosttyAttachmentStagingStore.stageFileURLSynchronously(sourceURL)

        XCTAssertNotEqual(stagedURL, sourceURL)
        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(stagedURL.lastPathComponent, "image.jpeg")
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data([0x01, 0x02]))

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testStageFileURLCanUseProvidedFilename() throws {
        let sourceURL = try makeSourceFile(named: "provider-temp-file", data: Data([0x01, 0x02]))

        let stagedURL = try GhosttyAttachmentStagingStore.stageFileURLSynchronously(
            sourceURL,
            filename: "../screenshot.jpeg"
        )

        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(stagedURL.lastPathComponent, "screenshot.jpeg")
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data([0x01, 0x02]))

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
    }

    func testCleanupIgnoresFilesOutsideStagingDirectory() throws {
        let sourceURL = try makeSourceFile(named: "keep.txt", data: Data("keep".utf8))

        GhosttyAttachmentStagingStore.cleanupSynchronously([sourceURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCleanupRejectsSiblingDirectoryWithMatchingPrefix() throws {
        let root = GhosttyAttachmentStagingStore.stagingRoot()
        let siblingDirectory = URL(fileURLWithPath: root.path + "-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: siblingDirectory)
        }

        let siblingURL = siblingDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: siblingURL)

        GhosttyAttachmentStagingStore.cleanupSynchronously([siblingURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testCleanupRejectsDirectRootChild() throws {
        let root = GhosttyAttachmentStagingStore.stagingRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let directChildURL = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: directChildURL)

        GhosttyAttachmentStagingStore.cleanupSynchronously([directChildURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: directChildURL.path))
    }

    func testStageDataWritesIntoRemuxStagingDirectory() throws {
        let data = Data([0x01, 0x02, 0x03])

        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            data,
            filename: "image.png"
        )

        XCTAssertTrue(stagedURL.path.hasPrefix(GhosttyAttachmentStagingStore.stagingRoot().path))
        XCTAssertEqual(stagedURL.lastPathComponent, "image.png")
        XCTAssertEqual(try Data(contentsOf: stagedURL), data)

        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testStageDataUsesSafeFallbackFilename() throws {
        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            Data(),
            filename: " ../image.png "
        )

        XCTAssertEqual(stagedURL.lastPathComponent, "image.png")
        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
    }

    func testStageDataFallsBackForEmptyAndDotFilenames() throws {
        let filenames = ["", "   ", ".", "..", "////"]

        for filename in filenames {
            let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
                Data(),
                filename: filename
            )

            XCTAssertEqual(stagedURL.lastPathComponent, "Attachment")
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }
    }

    func testStageImageDataUsesPredictableFilename() throws {
        let stagedURL = try GhosttyAttachmentStagingStore.stageImageDataSynchronously(
            Data([0x01]),
            title: "Photo 1",
            contentTypes: [.jpeg]
        )

        XCTAssertEqual(stagedURL.lastPathComponent, "photo-1.jpeg")
        XCTAssertEqual(try Data(contentsOf: stagedURL), Data([0x01]))
        GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
    }

    func testImageFilenameCanIncludeUniqueID() {
        let uniqueID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

        XCTAssertEqual(
            GhosttyAttachmentStagingStore.imageFilename(
                title: "Photo 1",
                contentTypes: [.jpeg],
                uniqueID: uniqueID
            ),
            "photo-1-aaaaaaaa.jpeg"
        )
    }

    func testImageFilenameFallsBackForBlankTitleAndUnknownExtension() {
        XCTAssertEqual(
            GhosttyAttachmentStagingStore.imageFilename(title: "  ", contentTypes: []),
            "image"
        )
    }

    func testStageFilesCleansPartialCopiesWhenLaterCopyFails() throws {
        let sourceURL = try makeSourceFile(named: "first.txt", data: Data("first".utf8))
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("missing.txt")
        let stagingChildrenBefore = try stagingChildren()

        XCTAssertThrowsError(
            try GhosttyAttachmentStagingStore.stageFilesSynchronously([sourceURL, missingURL])
        )

        XCTAssertEqual(try stagingChildren(), stagingChildrenBefore)
    }

    private func makeSourceFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func stagingChildren() throws -> Set<String> {
        let root = GhosttyAttachmentStagingStore.stagingRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return Set(urls.map(\.lastPathComponent))
    }
}
