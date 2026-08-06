import FileProvider
import Foundation

enum FileProviderBaseVersionValidation: Equatable, Sendable {
    case matches
    case conflict(current: FileProviderIdentifiedItem)
}

enum FileProviderMutationValidationError: Error, Equatable, Sendable {
    case unsupportedFileType
    case symbolicLinkMutation
    case invalidChildName
    case parentNotFound
    case rootMutation
    case directoryContents
    case directoryCycle
    case destinationOccupied
}

struct FileProviderMutationValidator: Sendable {
    func validateBaseVersion(
        requested: NSFileProviderItemVersion,
        current: FileProviderIdentifiedItem
    ) -> FileProviderBaseVersionValidation {
        let currentVersion = NSFileProviderItemVersion(
            contentVersion: current.remoteItem.contentVersion,
            metadataVersion: current.remoteItem.metadataVersion
        )
        return requested == currentVersion ? .matches : .conflict(current: current)
    }

    func validateMutation(of type: RemuxSFTPFileType) throws {
        switch type {
        case .directory, .regular:
            return
        case .symbolicLink:
            throw FileProviderMutationValidationError.symbolicLinkMutation
        case .other:
            throw FileProviderMutationValidationError.unsupportedFileType
        }
    }

    func validateDestination(
        _ destination: FileProviderRemotePath,
        occupiedPaths: some Sequence<FileProviderRemotePath>
    ) throws {
        for occupiedPath in occupiedPaths where pathsMatchIgnoringCase(destination, occupiedPath) {
            throw FileProviderMutationValidationError.destinationOccupied
        }
    }

    func validateChildName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0")
        else {
            throw FileProviderMutationValidationError.invalidChildName
        }
    }

    func validateParent(exists: Bool) throws {
        guard exists else {
            throw FileProviderMutationValidationError.parentNotFound
        }
    }

    func validateMutablePath(_ path: FileProviderRemotePath) throws {
        guard path != .root else {
            throw FileProviderMutationValidationError.rootMutation
        }
    }

    func validateContents(supplied: Bool, for type: RemuxSFTPFileType) throws {
        guard !(supplied && type == .directory) else {
            throw FileProviderMutationValidationError.directoryContents
        }
    }

    func validateMove(
        source: FileProviderRemotePath,
        destination: FileProviderRemotePath,
        sourceType: RemuxSFTPFileType
    ) throws {
        try validateMutation(of: sourceType)
        guard sourceType != .directory || !isDescendantOrSame(destination, of: source) else {
            throw FileProviderMutationValidationError.directoryCycle
        }
    }

    private func pathsMatchIgnoringCase(
        _ lhs: FileProviderRemotePath,
        _ rhs: FileProviderRemotePath
    ) -> Bool {
        lhs.relative.compare(
            rhs.relative,
            options: .caseInsensitive,
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedSame
    }

    private func isDescendantOrSame(
        _ candidate: FileProviderRemotePath,
        of ancestor: FileProviderRemotePath
    ) -> Bool {
        candidate == ancestor || candidate.relative.hasPrefix(ancestor.relative + "/")
    }
}
