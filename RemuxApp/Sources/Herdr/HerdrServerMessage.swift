import Foundation

/// A server message on Remux's endpoint connection (Herdr's `ServerMessage`; variant order is the tag).
enum HerdrServerMessage: Equatable, Sendable {
    case serverShutdown(reason: String?)
    case notify(HerdrNotify)
    /// Base64 of a program's OSC 52 payload.
    case clipboard(base64: String)
    case windowTitle(String?)
    case reloadSoundConfig
    case mouseCapture(enabled: Bool, sgrPixels: Bool)
    case terminalBell(count: UInt16)
    case paneSurface(HerdrPaneSurfaceFrame)
    case semanticNotification(HerdrSemanticNotification)
    case clientShellError(message: String)
    case keyboardReportAll(enabled: Bool)
    case responseChunk(HerdrResponseChunk)
    case paneSurfacePatch(HerdrPaneSurfacePatch)
    case control(kind: String, data: String)
    /// A type Herdr sends only to other kinds of client: 0 `Welcome` (the binary handshake reply, also
    /// an old server's answer to an endpoint hello), 1 `Terminal`, 2 `Graphics`, 10 `GraphicsFile`, 11
    /// `GraphicsTransmissionRetired` and 16 `DirectTerminalKeyboardProtocol`. An endpoint connection
    /// has no use for them, so the body is skipped.
    case unused(tag: UInt32)

    /// Decodes one payload (without its length prefix) and requires it to be consumed exactly.
    static func decode(_ payload: [UInt8]) throws -> HerdrServerMessage {
        var reader = HerdrWireReader(payload)
        let tag = try reader.variant()
        let message: HerdrServerMessage
        switch tag {
        case 0, 1, 2, 10, 11, 16:
            return .unused(tag: tag)
        case 12:
            throw HerdrWireError.unnegotiatedSnapshot
        case 3:
            message = .serverShutdown(reason: try reader.optional { try $0.string() })
        case 4:
            message = .notify(try HerdrNotify(wire: &reader))
        case 5:
            message = .clipboard(base64: try reader.string())
        case 6:
            message = .windowTitle(try reader.optional { try $0.string() })
        case 7:
            message = .reloadSoundConfig
        case 8:
            message = .mouseCapture(enabled: try reader.bool(), sgrPixels: try reader.bool())
        case 9:
            message = .terminalBell(count: try reader.u16())
        case 13:
            message = .paneSurface(try HerdrPaneSurfaceFrame(wire: &reader))
        case 14:
            message = .semanticNotification(try HerdrSemanticNotification(wire: &reader))
        case 15:
            message = .clientShellError(message: try reader.string())
        case 17:
            message = .keyboardReportAll(enabled: try reader.bool())
        case 18:
            message = .responseChunk(try HerdrResponseChunk(wire: &reader))
        case 19:
            message = .paneSurfacePatch(try HerdrPaneSurfacePatch(wire: &reader))
        case 20:
            message = .control(kind: try reader.string(), data: try reader.string())
        default:
            throw HerdrWireError.unknownMessage(tag: tag)
        }
        try reader.finish()
        return message
    }
}

struct HerdrNotify: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sound, toast, systemToast
    }

    let kind: Kind
    let message: String
    let body: String?

    init(wire reader: inout HerdrWireReader) throws {
        switch try reader.variant() {
        case 0: kind = .sound
        case 1: kind = .toast
        case 2: kind = .systemToast
        case let index: throw HerdrWireError.invalidVariant(type: "NotifyKind", index: index)
        }
        message = try reader.string()
        body = try reader.optional { try $0.string() }
    }
}

struct HerdrSemanticNotification: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case needsAttention, finished, updateInstalled, custom
    }

    enum Sound: Equatable, Sendable {
        case done, request
    }

    enum Position: Equatable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    let kind: Kind
    let title: String
    let body: String?
    let sound: Sound?
    let agent: String?
    let workspaceID: String?
    let tabID: String?
    let paneID: String?
    let position: Position?

    init(wire reader: inout HerdrWireReader) throws {
        switch try reader.variant() {
        case 0: kind = .needsAttention
        case 1: kind = .finished
        case 2: kind = .updateInstalled
        case 3: kind = .custom
        case let index: throw HerdrWireError.invalidVariant(type: "SemanticNotificationKind", index: index)
        }
        title = try reader.string()
        body = try reader.optional { try $0.string() }
        sound = try reader.optional { reader -> Sound in
            switch try reader.variant() {
            case 0: return .done
            case 1: return .request
            case let index: throw HerdrWireError.invalidVariant(type: "NotificationSound", index: index)
            }
        }
        agent = try reader.optional { try $0.string() }
        workspaceID = try reader.optional { try $0.string() }
        tabID = try reader.optional { try $0.string() }
        paneID = try reader.optional { try $0.string() }
        position = try reader.optional { reader -> Position in
            switch try reader.variant() {
            case 0: return .topLeft
            case 1: return .topRight
            case 2: return .bottomLeft
            case 3: return .bottomRight
            case let index: throw HerdrWireError.invalidVariant(type: "ToastPosition", index: index)
            }
        }
    }
}

/// One chunk of a command response; the JSON is the concatenation of every chunk's data up to the
/// final one.
struct HerdrResponseChunk: Equatable, Sendable {
    let bootID: String
    let requestID: String
    let isFinal: Bool
    let data: [UInt8]

    init(wire reader: inout HerdrWireReader) throws {
        bootID = try reader.string()
        requestID = try reader.string()
        isFinal = try reader.bool()
        data = try reader.byteArray()
    }
}

// MARK: - Named controls

enum HerdrControlKind {
    static let hello = "endpoint.hello.v1"
    static let welcome = "endpoint.welcome.v1"
    static let snapshot = "shell.snapshot.v1"
    static let surfaceReuse = "endpoint.surface-reuse.v1"
    static let surfaceDelta = "endpoint.surface-delta.v1"
    static let surfaceScroll = "endpoint.surface-scroll.v1"
    static let healthPing = "endpoint.health.ping.v1"
    static let healthPong = "endpoint.health.pong.v1"
}

enum HerdrEndpointControl: Equatable, Sendable {
    case welcome(HerdrWelcome)
    case snapshot(HerdrSnapshot)
    case surfaceReuse(HerdrSurfaceReuse)
    case surfaceDelta(HerdrSurfaceDelta)
    case surfaceScroll(HerdrSurfaceScroll)
    case healthPong(data: String)
    /// A kind Remux doesn't use: agent completions and agent view, the presentation fence's reply,
    /// and kinds added after generation 1. Herdr adds features as new kinds, so they are ignored.
    case ignored(kind: String)

    /// Parses a control. Invalid data in a kind Remux relies on, or any `shell.snapshot.*` kind other
    /// than v1 (an unnegotiated codec), is an error, as in Herdr's client, where these errors fail the
    /// connection.
    static func parse(kind: String, data: String) throws -> HerdrEndpointControl {
        do {
            switch kind {
            case HerdrControlKind.welcome:
                return .welcome(try JSONDecoder().decode(HerdrWelcome.self, from: Data(data.utf8)))
            case HerdrControlKind.snapshot:
                return .snapshot(try JSONDecoder().decode(HerdrSnapshot.self, from: Data(data.utf8)))
            case HerdrControlKind.surfaceReuse:
                return .surfaceReuse(try JSONDecoder().decode(HerdrSurfaceReuse.self, from: Data(data.utf8)))
            case HerdrControlKind.surfaceDelta:
                return .surfaceDelta(try HerdrSurfaceDelta(base64: data))
            case HerdrControlKind.surfaceScroll:
                return .surfaceScroll(try HerdrSurfaceScroll(base64: data))
            case HerdrControlKind.healthPong:
                return .healthPong(data: data)
            case _ where kind.hasPrefix("shell.snapshot."):
                throw HerdrWireError.invalidControl(kind: kind)
            default:
                return .ignored(kind: kind)
            }
        } catch {
            throw HerdrWireError.invalidControl(kind: kind)
        }
    }
}

/// `endpoint.welcome.v1`. A rejection carries `error` and empty lists, then the server closes the
/// connection. `methods` and `capabilities` default to empty, as Herdr declares them.
struct HerdrWelcome: Equatable, Sendable, Decodable {
    struct Rejection: Equatable, Sendable, Decodable {
        /// `unsupported_generation`, `no_common_core`, `invalid_surface` or `invalid_hello`.
        let code: String
        let message: String
    }

    let generation: UInt32
    let serverVersion: String
    let snapshotCodec: String
    let surfaceCodec: String
    let inputCodec: String
    let blobCodec: String
    let methods: [String]
    let capabilities: [String]
    let error: Rejection?

    private enum CodingKeys: String, CodingKey {
        case generation
        case serverVersion = "server_version"
        case snapshotCodec = "snapshot_codec"
        case surfaceCodec = "surface_codec"
        case inputCodec = "input_codec"
        case blobCodec = "blob_codec"
        case methods, capabilities, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(UInt32.self, forKey: .generation)
        serverVersion = try container.decode(String.self, forKey: .serverVersion)
        snapshotCodec = try container.decode(String.self, forKey: .snapshotCodec)
        surfaceCodec = try container.decode(String.self, forKey: .surfaceCodec)
        inputCodec = try container.decode(String.self, forKey: .inputCodec)
        blobCodec = try container.decode(String.self, forKey: .blobCodec)
        methods = try container.decodeIfPresent([String].self, forKey: .methods) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        error = try container.decodeIfPresent(Rejection.self, forKey: .error)
    }
}

/// `endpoint.surface-reuse.v1`: the next surface with an empty cell list; its cells are the baseline's.
struct HerdrSurfaceReuse: Equatable, Sendable, Decodable {
    let baseSurfaceRevision: UInt64
    let surface: HerdrPaneSurfaceFrame

    private enum CodingKeys: String, CodingKey {
        case baseSurfaceRevision = "base_surface_revision"
        case surface
    }
}

/// `endpoint.surface-delta.v1`: unpadded base64 of bincode. The surface carries metadata only; `rows`
/// and `popupCells` change the baseline's cells.
struct HerdrSurfaceDelta: Equatable, Sendable {
    enum PopupCells: Equatable, Sendable {
        case patch([HerdrPatchRow])
        case replace([HerdrCell])
    }

    let baseProjectionRevision: UInt64
    let baseSurfaceRevision: UInt64
    let surface: HerdrPaneSurfaceFrame
    let rows: [HerdrPatchRow]
    let popupCells: PopupCells?

    init(base64: String) throws {
        var reader = HerdrWireReader(try HerdrBase64.decodeUnpadded(base64))
        baseProjectionRevision = try reader.u64()
        baseSurfaceRevision = try reader.u64()
        surface = try HerdrPaneSurfaceFrame(wire: &reader)
        guard surface.frame.cells.isEmpty, surface.popup?.frame.cells.isEmpty ?? true else {
            throw HerdrWireError.invalidControl(kind: HerdrControlKind.surfaceDelta)
        }
        rows = try reader.array { try HerdrPatchRow(wire: &$0) }
        popupCells = try reader.optional { reader -> PopupCells in
            switch try reader.variant() {
            case 0: return .patch(try reader.array { try HerdrPatchRow(wire: &$0) })
            case 1: return .replace(try reader.array { try HerdrCell(wire: &$0) })
            case let index: throw HerdrWireError.invalidVariant(type: "SurfaceGridUpdate", index: index)
            }
        }
        try reader.finish()
    }
}

/// `endpoint.surface-scroll.v1`: unpadded base64 of a count, that many raw little-endian regions, and
/// one framed `PaneSurfacePatch`.
struct HerdrSurfaceScroll: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        let rect: HerdrSurfaceRect
        /// Rows move up by `shift` when positive, down when negative.
        let shift: Int16
    }

    let regions: [Region]
    let patch: HerdrPaneSurfacePatch

    init(base64: String) throws {
        let raw = try HerdrBase64.decodeUnpadded(base64)
        let invalid = HerdrWireError.invalidControl(kind: HerdrControlKind.surfaceScroll)
        guard let count = raw.first, (1...64).contains(count) else { throw invalid }
        let headerLength = 1 + Int(count) * 10
        guard raw.count >= headerLength + 4 else { throw invalid }
        func u16(at offset: Int) -> UInt16 {
            UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
        }
        regions = (0..<Int(count)).map { index in
            let base = 1 + index * 10
            return Region(
                rect: HerdrSurfaceRect(
                    x: u16(at: base),
                    y: u16(at: base + 2),
                    width: u16(at: base + 4),
                    height: u16(at: base + 6)
                ),
                shift: Int16(bitPattern: u16(at: base + 8))
            )
        }
        let patchLength = Int(
            UInt32(raw[headerLength])
                | UInt32(raw[headerLength + 1]) << 8
                | UInt32(raw[headerLength + 2]) << 16
                | UInt32(raw[headerLength + 3]) << 24
        )
        guard raw.count == headerLength + 4 + patchLength else { throw invalid }
        guard case .paneSurfacePatch(let patch) = try HerdrServerMessage.decode(
            Array(raw[(headerLength + 4)...])
        ) else {
            throw invalid
        }
        self.patch = patch
    }
}

enum HerdrBase64 {
    /// Herdr encodes with base64 STANDARD_NO_PAD.
    static func decodeUnpadded(_ text: String) throws -> [UInt8] {
        let invalid = HerdrWireError.invalidBase64
        guard !text.contains("=") else { throw invalid }
        let padding: String
        switch text.utf8.count % 4 {
        case 0: padding = ""
        case 2: padding = "=="
        case 3: padding = "="
        default: throw invalid
        }
        guard let data = Data(base64Encoded: text + padding) else { throw invalid }
        return Array(data)
    }
}
