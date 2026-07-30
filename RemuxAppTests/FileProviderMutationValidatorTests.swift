import FileProvider
import XCTest
@testable import Remux

final class FileProviderMutationValidatorTests: XCTestCase {
    private let validator = FileProviderMutationValidator()

    func testValidatorRejectsRemoteVersionConflictWithoutChangingRemote() throws {
        let requestedItem = try identifiedItem(size: 1)
        let currentItem = try identifiedItem(size: 2)

        let result = validator.validateBaseVersion(
            requested: version(for: requestedItem),
            current: currentItem
        )

        XCTAssertEqual(result, .conflict(current: currentItem))
    }

    func testValidatorAcceptsMatchingRemoteVersion() throws {
        let item = try identifiedItem(size: 1)

        XCTAssertEqual(
            validator.validateBaseVersion(requested: version(for: item), current: item),
            .matches
        )
    }

    func testValidatorRejectsOccupiedDestinationsRegardlessOfCase() throws {
        let destination = try FileProviderRemotePath(relative: "folder/Report.txt")

        XCTAssertThrowsError(
            try validator.validateDestination(destination, occupiedPaths: [destination])
        ) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .destinationOccupied)
        }
        XCTAssertThrowsError(
            try validator.validateDestination(
                try FileProviderRemotePath(relative: "folder/report.txt"),
                occupiedPaths: [destination]
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .destinationOccupied)
        }
    }

    func testValidatorRejectsUnsupportedSpecialFileAndAllSymlinkMutations() throws {
        XCTAssertThrowsError(try validator.validateMutation(of: .other)) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .unsupportedFileType)
        }
        XCTAssertThrowsError(try validator.validateMutation(of: .symbolicLink)) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .symbolicLinkMutation)
        }
    }

    func testValidatorRejectsInvalidChildNameAndMissingParent() throws {
        XCTAssertThrowsError(try validator.validateChildName("..")) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .invalidChildName)
        }
        XCTAssertThrowsError(try validator.validateParent(exists: false)) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .parentNotFound)
        }
    }

    func testValidatorRejectsRootMutationAndDirectoryContents() throws {
        XCTAssertThrowsError(try validator.validateMutablePath(.root)) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .rootMutation)
        }
        XCTAssertThrowsError(try validator.validateContents(supplied: true, for: .directory)) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .directoryContents)
        }
    }

    func testValidatorRejectsDirectoryMoveIntoDescendant() throws {
        XCTAssertThrowsError(
            try validator.validateMove(
                source: FileProviderRemotePath(relative: "folder"),
                destination: FileProviderRemotePath(relative: "folder/child/folder"),
                sourceType: .directory
            )
        ) { error in
            XCTAssertEqual(error as? FileProviderMutationValidationError, .directoryCycle)
        }
    }

    private func identifiedItem(
        path: String = "report.txt",
        size: UInt64
    ) throws -> FileProviderIdentifiedItem {
        FileProviderIdentifiedItem(
            identity: .item(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!),
            parentIdentity: .root,
            remoteItem: try FileProviderRemoteItem(
                path: FileProviderRemotePath(relative: path),
                metadata: RemuxSFTPFileMetadata(
                    size: size,
                    permissions: 0o100644,
                    modificationDate: Date(timeIntervalSince1970: TimeInterval(size)),
                    type: .regular
                )
            )
        )
    }

    private func version(
        for item: FileProviderIdentifiedItem
    ) -> NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: item.remoteItem.contentVersion,
            metadataVersion: item.remoteItem.metadataVersion
        )
    }
}
