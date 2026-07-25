import Foundation

struct FileProviderRemoteItem: Equatable, Codable, Sendable {
    let path: FileProviderRemotePath
    let parent: FileProviderRemotePath
    let name: String
    let type: RemuxSFTPFileType
    let size: UInt64?
    let permissions: UInt32?
    let modificationDate: Date?
    let symlinkTargetRelativePath: String?

    var contentVersion: Data {
        var data = Data()
        data.appendString(type.rawValue)
        data.appendOptional(size)
        data.appendOptional(modificationDate.map { Int64($0.timeIntervalSince1970) })
        return data
    }

    var metadataVersion: Data {
        var data = contentVersion
        data.appendString(path.relative)
        data.appendString(name)
        data.appendOptional(permissions)
        return data
    }

    init(
        path: FileProviderRemotePath,
        metadata: RemuxSFTPFileMetadata,
        symlinkTargetRelativePath: String? = nil
    ) throws {
        self.path = path
        self.parent = try Self.parent(of: path)
        self.name = path.relative.split(separator: "/").last.map(String.init) ?? ""
        self.type = metadata.type
        self.size = metadata.size
        self.permissions = metadata.permissions
        self.modificationDate = metadata.modificationDate
        self.symlinkTargetRelativePath = try symlinkTargetRelativePath.map {
            try FileProviderRemotePath(relative: $0).relative
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(FileProviderRemotePath.self, forKey: .path)
        let metadata = RemuxSFTPFileMetadata(
            size: try container.decodeIfPresent(UInt64.self, forKey: .size),
            permissions: try container.decodeIfPresent(UInt32.self, forKey: .permissions),
            modificationDate: try container.decodeIfPresent(Date.self, forKey: .modificationDate),
            type: try container.decode(RemuxSFTPFileType.self, forKey: .type)
        )
        self = try Self(
            path: path,
            metadata: metadata,
            symlinkTargetRelativePath: try container.decodeIfPresent(String.self, forKey: .symlinkTargetRelativePath)
        )
    }

    private static func parent(of path: FileProviderRemotePath) throws -> FileProviderRemotePath {
        guard let separator = path.relative.lastIndex(of: "/") else {
            return .root
        }
        return try FileProviderRemotePath(relative: String(path.relative[..<separator]))
    }
}

struct FileProviderSafeLinkResolver: Sendable {
    func resolve(_ canonicalTarget: String, home canonicalHome: String) throws -> String {
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalTarget)
        try FileProviderPathValidation.validateCanonicalAbsolute(canonicalHome)

        if canonicalHome == "/" {
            return String(canonicalTarget.dropFirst())
        }

        guard canonicalTarget == canonicalHome || canonicalTarget.hasPrefix(canonicalHome + "/") else {
            throw FileProviderRemotePathError.unsafeLinkTarget
        }
        guard canonicalTarget != canonicalHome else { return "" }
        return String(canonicalTarget.dropFirst(canonicalHome.count + 1))
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        appendInteger(UInt64(value.utf8.count))
        append(contentsOf: value.utf8)
    }

    mutating func appendOptional<T: FixedWidthInteger>(_ value: T?) {
        append(value == nil ? 0 : 1)
        if let value {
            appendInteger(value)
        }
    }

    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
