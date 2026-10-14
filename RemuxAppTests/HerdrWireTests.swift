import Foundation
import XCTest
@testable import Remux

/// HerdrWire against byte streams recorded from real Herdr v0.9.3 servers (`Fixtures/HerdrWire`).
final class HerdrWireTests: XCTestCase {
    // MARK: - Recorded streams

    func testDecodesEveryRecordedServerMessage() throws {
        let fixtures = try Self.goldenFixtures()
        XCTAssertEqual(fixtures.count, 23)
        var checked = 0
        for fixture in fixtures {
            var splitter = HerdrFrameSplitter()
            splitter.append(fixture.serverStream)
            var offset = 0
            for entry in fixture.golden.server {
                let payload = try XCTUnwrap(try splitter.nextPayload(), fixture.name)
                XCTAssertEqual(offset, entry.offset, fixture.name)
                XCTAssertEqual(payload.count, entry.length, fixture.name)
                offset += 4 + payload.count
                let message = try HerdrServerMessage.decode(payload)
                try Self.assert(message, matches: entry, in: "\(fixture.name) @\(entry.offset)")
                checked += 1
            }
            XCTAssertNil(try splitter.nextPayload(), fixture.name)
        }
        XCTAssertEqual(checked, 259)
    }

    func testEncodesEveryRecordedClientMessage() throws {
        var checked = 0
        var notSentByRemux = 0
        for fixture in try Self.goldenFixtures() {
            for entry in fixture.golden.clientMessages ?? [] {
                let context = "\(fixture.name) @\(entry.offset)"
                switch entry.message {
                case .binary(let message):
                    XCTAssertEqual(Self.hex(message.frame), entry.hex, context)
                case .hello(let hello):
                    let recorded = try Self.controlData(fromHex: entry.hex, kind: HerdrControlKind.hello)
                    try Self.assertSameJSON(hello.json, recorded, context)
                case .request(let bootID, let request):
                    let message = HerdrClientMessage.endpointRequest(bootID: bootID, request: request)
                    var reader = HerdrWireReader(Array(message.payload))
                    XCTAssertEqual(try reader.variant(), 15, context)
                    XCTAssertEqual(try reader.string(), bootID, context)
                    let recorded = Self.bytes(fromHex: entry.hex)
                    var recordedReader = HerdrWireReader(Array(recorded.dropFirst(4)))
                    _ = try recordedReader.variant()
                    XCTAssertEqual(try recordedReader.string(), bootID, context)
                    try Self.assertSameJSON(try reader.string(), try recordedReader.string(), context)
                case .notSentByRemux:
                    notSentByRemux += 1
                    continue
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 47)
        // Six hellos with options Remux doesn't use (no or only some encodings, generation 2, a missing
        // codec, zero columns, invalid JSON), the presentation fence, an unknown control, and Detach (a
        // closed stream ends the client the same way; `HerdrConnection.close()`).
        XCTAssertEqual(notSentByRemux, 9)
    }

    func testDecodesTheRecordedWelcomeAndSnapshot() throws {
        let fixture = try XCTUnwrap(try Self.goldenFixtures().first { $0.name == "herdr-04-patch-and-delta-A" })
        let controls = try fixture.golden.server.compactMap { entry -> HerdrEndpointControl? in
            guard entry.tag == 20, case .string(let kind) = entry.fields?["kind"],
                  case .string(let data) = entry.fields?["data"]
            else { return nil }
            return try HerdrEndpointControl.parse(kind: kind, data: data)
        }

        guard case .welcome(let welcome) = controls.first else { return XCTFail("no welcome first") }
        XCTAssertEqual(welcome.generation, 1)
        XCTAssertEqual(welcome.serverVersion, "0.9.3")
        XCTAssertEqual(welcome.methods.count, 40)
        XCTAssertTrue(welcome.methods.contains("client_shell.surface.set"))
        XCTAssertTrue(welcome.capabilities.contains("surface_scroll"))
        XCTAssertNil(welcome.error)

        let snapshots = controls.compactMap { control -> HerdrSnapshot? in
            if case .snapshot(let snapshot) = control { return snapshot }
            return nil
        }
        let split = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(split.panes.map(\.paneID), ["w1:p1", "w1:p2"])
        XCTAssertEqual(split.tabs.map(\.tabID), ["w1:t1"])
        XCTAssertEqual(split.focusedTabID, "w1:t1")
        XCTAssertEqual(Set(snapshots.map(\.bootID)).count, 1)
        XCTAssertEqual(snapshots.map(\.revision), snapshots.map(\.revision).sorted())
    }

    func testDecodesRecordedRejections() throws {
        let codes = try Self.goldenFixtures()
            .filter { $0.name.hasPrefix("herdr-03-handshake-rejections") }
            .map { fixture -> String in
                let entry = try XCTUnwrap(fixture.golden.server.first)
                guard case .string(let data) = entry.fields?["data"],
                      case .welcome(let welcome) = try HerdrEndpointControl.parse(
                          kind: HerdrControlKind.welcome,
                          data: data
                      )
                else { throw XCTSkip("not a welcome") }
                XCTAssertTrue(welcome.methods.isEmpty)
                return try XCTUnwrap(welcome.error).code
            }
        XCTAssertEqual(
            Set(codes),
            ["invalid_hello", "unsupported_generation", "no_common_core", "invalid_surface"]
        )
    }

    // MARK: - Message types for other kinds of client

    /// As Herdr's client: a binary snapshot and a tag outside generation 1 are errors; the types Herdr
    /// sends only to other kinds of client are skipped, whatever their body.
    func testMessageTypesForOtherClientsAreSkippedAndABinarySnapshotFails() throws {
        for tag: UInt8 in [0, 1, 2, 10, 11, 16] {
            XCTAssertEqual(try HerdrServerMessage.decode([tag, 7, 7]), .unused(tag: UInt32(tag)))
        }
        XCTAssertThrowsError(try HerdrServerMessage.decode([12])) { error in
            XCTAssertEqual(error as? HerdrWireError, .unnegotiatedSnapshot)
        }
        XCTAssertThrowsError(try HerdrServerMessage.decode([21])) { error in
            XCTAssertEqual(error as? HerdrWireError, .unknownMessage(tag: 21))
        }
    }
    // MARK: - Strict decoding

    func testRejectsTrailingAndCorruptBytes() {
        XCTAssertEqual(try HerdrServerMessage.decode([9, 1]), .terminalBell(count: 1))
        XCTAssertThrowsError(try HerdrServerMessage.decode([9, 1, 0])) { error in
            XCTAssertEqual(error as? HerdrWireError, .trailingBytes(1))
        }
        XCTAssertThrowsError(try HerdrServerMessage.decode([8, 2, 0])) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidBool(2))
        }
        XCTAssertThrowsError(try HerdrServerMessage.decode([9])) { error in
            XCTAssertEqual(error as? HerdrWireError, .truncated)
        }
        // A u16 never uses the u32 marker.
        XCTAssertThrowsError(try HerdrServerMessage.decode([9, 252, 1, 0, 0, 0])) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidVarint(252))
        }
        // A string length beyond the payload.
        XCTAssertThrowsError(try HerdrServerMessage.decode([15, 200, 65])) { error in
            XCTAssertEqual(error as? HerdrWireError, .lengthOutOfRange(200))
        }
    }

    func testVarintsRoundTripAtEveryWidth() throws {
        let values: [UInt64] = [0, 250, 251, 65_535, 65_536, UInt64(UInt32.max), UInt64(UInt32.max) + 1, .max]
        var writer = HerdrWireWriter()
        values.forEach { writer.u64($0) }
        writer.u32(0)
        var reader = HerdrWireReader(writer.bytes)
        for value in values {
            XCTAssertEqual(try reader.u64(), value)
        }
        XCTAssertEqual(try reader.u32(), 0)
        try reader.finish()
        XCTAssertEqual(Array(writer.bytes.prefix(4)), [0, 250, 251, 251])
    }

    func testSplitterWaitsForWholeFramesAndRefusesOversizedOnes() throws {
        var splitter = HerdrFrameSplitter()
        let frame = HerdrWire.frame([9, 1])
        splitter.append(frame.prefix(3))
        XCTAssertNil(try splitter.nextPayload())
        splitter.append(frame.dropFirst(3))
        XCTAssertEqual(try splitter.nextPayload(), [9, 1])
        XCTAssertNil(try splitter.nextPayload())

        var oversized = HerdrFrameSplitter()
        let length = UInt32(HerdrWire.maxPayloadSize + 1)
        oversized.append([UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)])
        XCTAssertThrowsError(try oversized.nextPayload()) { error in
            XCTAssertEqual(error as? HerdrWireError, .payloadTooLarge(HerdrWire.maxPayloadSize + 1))
            // The cap is Herdr's own largest frame, so only corrupt data exceeds it.
            XCTAssertTrue(error.localizedDescription.contains("corrupted"))
        }
    }

    // MARK: - Named controls

    func testControlKindsRemuxDoesNotUseAreIgnored() throws {
        XCTAssertEqual(try HerdrEndpointControl.parse(kind: "endpoint.future.v9", data: "{"), .ignored(kind: "endpoint.future.v9"))
        XCTAssertEqual(
            try HerdrEndpointControl.parse(kind: "endpoint.agent-completions.v1", data: "not json"),
            .ignored(kind: "endpoint.agent-completions.v1")
        )
        XCTAssertEqual(
            try HerdrEndpointControl.parse(kind: "endpoint.presentation.ready.v1", data: "token"),
            .ignored(kind: "endpoint.presentation.ready.v1")
        )
        XCTAssertEqual(try HerdrEndpointControl.parse(kind: HerdrControlKind.healthPong, data: ""), .healthPong(data: ""))
    }

    func testInvalidRequiredControlsAndUnnegotiatedSnapshotCodecsFail() {
        for (kind, data) in [
            (HerdrControlKind.snapshot, "{}"),
            ("shell.snapshot.v2", "{}"),
            (HerdrControlKind.surfaceDelta, "@@@"),
            (HerdrControlKind.surfaceScroll, ""),
            (HerdrControlKind.welcome, "[]"),
        ] {
            XCTAssertThrowsError(try HerdrEndpointControl.parse(kind: kind, data: data)) { error in
                XCTAssertEqual(error as? HerdrWireError, .invalidControl(kind: kind), kind)
            }
        }
    }

    func testDeltaMetadataMustNotCarryCells() throws {
        // A minimal delta whose metadata surface carries one cell.
        var writer = HerdrWireWriter()
        writer.u64(1)
        writer.u64(1)
        writer.string("boot")
        writer.u64(1)
        writer.u64(2)
        writer.array([0]) { writer, _ in
            writer.string("x")
            writer.u32(0)
            writer.u32(0)
            writer.u16(0)
            writer.bool(false)
            writer.optional(nil as UInt32?) { $0.u32($1) }
        }
        writer.u16(1)
        writer.u16(1)
        writer.optional(nil as UInt8?) { $0.u8($1) }
        writer.array([String]()) { $0.string($1) }
        writer.byteArray([])
        [0, 0].forEach { _ in writer.array([UInt8]()) { $0.u8($1) } }
        writer.optional(nil as UInt8?) { $0.u8($1) }
        [0, 0, 0].forEach { _ in writer.array([UInt8]()) { $0.u8($1) } }
        writer.array([UInt8]()) { $0.u8($1) }
        writer.optional(nil as UInt8?) { $0.u8($1) }
        let data = Data(writer.bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try HerdrSurfaceDelta(base64: data)) { error in
            XCTAssertEqual(error as? HerdrWireError, .invalidControl(kind: HerdrControlKind.surfaceDelta))
        }
    }

    // MARK: - Client messages without a recording

    func testHostThemeUpdatesEncodeAsHerdrDeclaresThem() {
        XCTAssertEqual(HerdrClientMessage.hostTheme(.appearance(.dark)).payload, [17, 2, 0])
        XCTAssertEqual(HerdrClientMessage.hostTheme(.appearance(.light)).payload, [17, 2, 1])
        XCTAssertEqual(
            HerdrClientMessage.hostTheme(.defaultColor(.background, HerdrRGB(red: 1, green: 2, blue: 3))).payload,
            [17, 0, 1, 1, 2, 3]
        )
        XCTAssertEqual(
            HerdrClientMessage.hostTheme(.paletteColors([
                4: HerdrRGB(red: 5, green: 6, blue: 7),
                1: HerdrRGB(red: 2, green: 3, blue: 4),
            ])).payload,
            [17, 1, 2, 1, 2, 3, 4, 4, 5, 6, 7]
        )
    }

    /// Herdr declares `methods` and `capabilities` with serde defaults.
    func testAWelcomeWithoutMethodsOrCapabilitiesDecodes() throws {
        let json = #"{"generation":1,"server_version":"0.9.3","snapshot_codec":"shell.snapshot.v1","surface_codec":"shell.surface.v1","input_codec":"shell.input.semantic.v1","blob_codec":"shell.blob.v1"}"#
        guard case .welcome(let welcome) = try HerdrEndpointControl.parse(kind: HerdrControlKind.welcome, data: json) else {
            return XCTFail("not a welcome")
        }
        XCTAssertEqual(welcome.methods, [])
        XCTAssertEqual(welcome.capabilities, [])
        XCTAssertNil(welcome.error)
    }

    func testRemuxHelloRequestsEveryEncodingAndNoHostFeatures() throws {
        let hello = HerdrHello(cellWidthPx: 9, cellHeightPx: 18, cols: 80, rows: 24, surfaceActive: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.json.utf8)) as? [String: Any])
        XCTAssertEqual(object["generation"] as? Int, 1)
        for key in ["surface_reuse", "surface_delta", "surface_scroll", "surface_active"] {
            XCTAssertEqual(object[key] as? Bool, true, key)
        }
        for key in ["pixel_mouse", "direct_graphics", "endpoint_keybindings", "mouse_capture"] {
            XCTAssertEqual(object[key] as? Bool, false, key)
        }
        XCTAssertEqual(object["snapshot_codecs"] as? [String], ["shell.snapshot.v1"])
        XCTAssertEqual(object["surface_codecs"] as? [String], ["shell.surface.v1"])
        XCTAssertEqual(object["input_codecs"] as? [String], ["shell.input.semantic.v1"])
        XCTAssertEqual(object["blob_codecs"] as? [String], ["shell.blob.v1"])
    }

    func testColorsUnpackAsHerdrPacksThem() {
        XCTAssertEqual(HerdrColor(raw: 0).value, .default)
        XCTAssertEqual(HerdrColor(raw: 2).value, .named(2))
        XCTAssertEqual(HerdrColor(raw: 0x0100_00D0).value, .indexed(208))
        XCTAssertEqual(HerdrColor(raw: 0x0212_3456).value, .rgb(red: 0x12, green: 0x34, blue: 0x56))
        XCTAssertEqual(HerdrColor(raw: 0x0300_0001).value, .default)
    }
}

// MARK: - Golden fixtures

extension HerdrWireTests {
    struct GoldenFixture {
        let name: String
        let serverStream: [UInt8]
        let golden: GoldenFile
    }

    struct GoldenFile: Decodable {
        struct Negotiated: Decodable {
            let delta: Bool
            let scroll: Bool
        }

        /// The reference presentation's committed surface after the whole recording.
        struct Final: Decodable {
            let cells: String?
            let surface_revision: UInt64?
            let rejected_patches: Int
        }

        let server: [GoldenServerEntry]
        let clientMessages: [GoldenClientEntry]?
        /// The surface encodings the recording's hello asked for; absent for picked messages.
        let negotiated: Negotiated?
        let final: Final?

        private enum CodingKeys: String, CodingKey {
            case server
            case clientMessages = "client_messages"
            case negotiated
            case final
        }
    }

    /// What the reference decoder made of a surface message, as SHA-256 digests.
    struct GoldenDecoded: Decodable {
        let kind: String
        let projection_revision: UInt64?
        let surface_revision: UInt64
        let cells: String?
        let popup_cells: String?
        let rows: String?
    }

    enum GoldenScalar: Decodable, Equatable {
        case string(String)
        case integer(Int64)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let integer = try? container.decode(Int64.self) {
                self = .integer(integer)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    struct GoldenDelta: Decodable {
        let base_projection_revision: UInt64
        let base_surface_revision: UInt64
        let surface: HerdrPaneSurfaceFrame
        let rows: [HerdrPatchRow]
        let popup_cells: GoldenPopupCells?
    }

    struct GoldenPopupCells: Decodable {
        let Patch: [HerdrPatchRow]?
        let Replace: [HerdrCell]?
    }

    struct GoldenScroll: Decodable {
        struct Region: Decodable {
            let x: UInt16
            let y: UInt16
            let width: UInt16
            let height: UInt16
            let shift: Int16
        }

        let regions: [Region]
        let patch: HerdrPaneSurfacePatch
    }

    struct GoldenServerEntry: Decodable {
        let offset: Int
        let length: Int
        let tag: UInt32
        let surface: HerdrPaneSurfaceFrame?
        let patch: HerdrPaneSurfacePatch?
        let fields: [String: GoldenScalar]?
        let delta: GoldenDelta?
        let scroll: GoldenScroll?
        let reuse: HerdrSurfaceReuse?
        let decoded: GoldenDecoded?

        private enum CodingKeys: String, CodingKey {
            case offset, length, tag, message, delta, scroll, reuse, decoded
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offset = try container.decode(Int.self, forKey: .offset)
            length = try container.decode(Int.self, forKey: .length)
            tag = try container.decode(UInt32.self, forKey: .tag)
            surface = tag == 13 ? try container.decode(HerdrPaneSurfaceFrame.self, forKey: .message) : nil
            patch = tag == 19 ? try container.decode(HerdrPaneSurfacePatch.self, forKey: .message) : nil
            fields = tag == 13 || tag == 19
                ? nil
                : try container.decode([String: GoldenScalar].self, forKey: .message)
            delta = try container.decodeIfPresent(GoldenDelta.self, forKey: .delta)
            scroll = try container.decodeIfPresent(GoldenScroll.self, forKey: .scroll)
            reuse = try container.decodeIfPresent(HerdrSurfaceReuse.self, forKey: .reuse)
            decoded = try container.decodeIfPresent(GoldenDecoded.self, forKey: .decoded)
        }
    }

    enum GoldenClientMessage {
        case binary(HerdrClientMessage)
        case hello(HerdrHello)
        case request(bootID: String, request: String)
        case notSentByRemux
    }

    struct GoldenClientEntry: Decodable {
        let offset: Int
        let hex: String
        let message: GoldenClientMessage

        private enum CodingKeys: String, CodingKey {
            case offset, hex, message
        }

        private enum MessageKeys: String, CodingKey {
            case tag, kind, data, focused, target, events
            case bootID = "boot_id"
            case request
            case cellWidthPx = "cell_width_px"
            case cellHeightPx = "cell_height_px"
            case surfaceSize = "surface_size"
            case pixelMouse = "pixel_mouse"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offset = try container.decode(Int.self, forKey: .offset)
            hex = try container.decode(String.self, forKey: .hex)
            let fields = try container.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
            switch try fields.decode(UInt32.self, forKey: .tag) {
            case 12:
                let size = try fields.decode(GoldenSize.self, forKey: .surfaceSize)
                // Remux never turns pixel mouse on.
                message = try fields.decode(Bool.self, forKey: .pixelMouse)
                    ? .notSentByRemux
                    : .binary(.shellResize(HerdrSurfaceGeometry(
                        cellWidthPx: try fields.decode(UInt32.self, forKey: .cellWidthPx),
                        cellHeightPx: try fields.decode(UInt32.self, forKey: .cellHeightPx),
                        cols: size.cols,
                        rows: size.rows
                    )))
            case 13:
                message = .binary(.paneInput(
                    paneID: try fields.decode(String.self, forKey: .target),
                    events: try fields.decode([GoldenInputEvent].self, forKey: .events).map(\.event)
                ))
            case 14:
                message = .binary(.popupInput(
                    terminalID: try fields.decode(String.self, forKey: .target),
                    events: try fields.decode([GoldenInputEvent].self, forKey: .events).map(\.event)
                ))
            case 15:
                let request = try fields.decode(GoldenJSON.self, forKey: .request)
                message = .request(
                    bootID: try fields.decode(String.self, forKey: .bootID),
                    request: request.text
                )
            case 18:
                message = .binary(.focus(try fields.decode(Bool.self, forKey: .focused)))
            case 20:
                switch try fields.decode(String.self, forKey: .kind) {
                case HerdrControlKind.hello:
                    // Remux's hello for the recorded size, when the recording used Remux's options. The
                    // rejection fixtures include one that is deliberately not JSON.
                    message = (try? fields.decode(GoldenHello.self, forKey: .data))?.remuxHello.map { .hello($0) }
                        ?? .notSentByRemux
                case HerdrControlKind.healthPing:
                    message = (try? fields.decode(String.self, forKey: .data))
                        .map { .binary(.healthPing(data: $0)) } ?? .notSentByRemux
                default:
                    message = .notSentByRemux
                }
            default:
                message = .notSentByRemux
            }
        }
    }

    struct GoldenSize: Decodable {
        let cols: UInt16
        let rows: UInt16
    }

    /// A recorded hello; Remux sends it only with every encoding, the v1 codecs and no host features.
    struct GoldenHello: Decodable {
        let generation: UInt32
        let cell_width_px: UInt32
        let cell_height_px: UInt32
        let surface_size: GoldenSize
        let pixel_mouse: Bool
        let direct_graphics: Bool
        let endpoint_keybindings: Bool
        let mouse_capture: Bool
        let surface_active: Bool
        let surface_reuse: Bool?
        let surface_delta: Bool?
        let surface_scroll: Bool?
        let snapshot_codecs: [String]?
        let surface_codecs: [String]?
        let input_codecs: [String]?
        let blob_codecs: [String]?

        var remuxHello: HerdrHello? {
            guard generation == 1, !pixel_mouse, !direct_graphics, !endpoint_keybindings, !mouse_capture,
                  surface_reuse == true, surface_delta == true, surface_scroll == true,
                  snapshot_codecs == ["shell.snapshot.v1"], surface_codecs == ["shell.surface.v1"],
                  input_codecs == ["shell.input.semantic.v1"], blob_codecs == ["shell.blob.v1"]
            else {
                return nil
            }
            return HerdrHello(
                cellWidthPx: cell_width_px,
                cellHeightPx: cell_height_px,
                cols: surface_size.cols,
                rows: surface_size.rows,
                surfaceActive: surface_active
            )
        }
    }

    /// Any JSON value, kept as compact text.
    struct GoldenJSON: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(AnyJSON.self)
            let data = try JSONSerialization.data(withJSONObject: value.object, options: [.sortedKeys, .fragmentsAllowed])
            text = String(decoding: data, as: UTF8.self)
        }
    }

    struct AnyJSON: Decodable {
        let object: Any

        init(from decoder: Decoder) throws {
            if var array = try? decoder.unkeyedContainer() {
                var values = [Any]()
                while !array.isAtEnd {
                    values.append(try array.decode(AnyJSON.self).object)
                }
                object = values
            } else if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
                var values = [String: Any]()
                for key in keyed.allKeys {
                    values[key.stringValue] = try keyed.decode(AnyJSON.self, forKey: key).object
                }
                object = values
            } else {
                let single = try decoder.singleValueContainer()
                if single.decodeNil() {
                    object = NSNull()
                } else if let bool = try? single.decode(Bool.self) {
                    object = bool
                } else if let integer = try? single.decode(Int64.self) {
                    object = integer
                } else if let double = try? single.decode(Double.self) {
                    object = double
                } else {
                    object = try single.decode(String.self)
                }
            }
        }
    }

    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    struct GoldenInputEvent: Decodable {
        let event: HerdrInputEvent

        private enum Keys: String, CodingKey {
            case key = "Key"
            case text = "TextCommit"
            case mouse = "Mouse"
            case paste = "Paste"
        }

        private struct Key: Decodable {
            let code: String
            let char: String?
            let f: UInt8?
            let modifiers: UInt8
            let kind: String
            let repeat_count: UInt16
            let shifted_codepoint: UInt32?
            let generated_text: String?
            let tracks_release: Bool
            let physical_key_id: UInt32?
        }

        private struct Mouse: Decodable {
            let kind: GoldenMouseKind
            let position: GoldenMousePosition
            let modifiers: UInt8
            let lines: UInt16
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let key = try container.decodeIfPresent(Key.self, forKey: .key) {
                let codes: [String: HerdrKeyCode] = [
                    "Backspace": .backspace, "Enter": .enter, "Left": .left, "Right": .right, "Up": .up,
                    "Down": .down, "Home": .home, "End": .end, "PageUp": .pageUp, "PageDown": .pageDown,
                    "Tab": .tab, "BackTab": .backTab, "Delete": .delete, "Insert": .insert, "Esc": .escape,
                    "Null": .null,
                ]
                let code: HerdrKeyCode
                switch key.code {
                case "Char":
                    let scalars = try XCTUnwrap(key.char).unicodeScalars
                    XCTAssertEqual(scalars.count, 1)
                    code = .character(try XCTUnwrap(scalars.first))
                case "F": code = .function(try XCTUnwrap(key.f))
                default: code = try XCTUnwrap(codes[key.code], key.code)
                }
                let kinds: [String: HerdrKeyEvent.Kind] = ["Press": .press, "Repeat": .repeat, "Release": .release]
                event = .key(HerdrKeyEvent(
                    code: code,
                    modifiers: HerdrKeyModifiers(rawValue: key.modifiers),
                    kind: try XCTUnwrap(kinds[key.kind]),
                    repeatCount: key.repeat_count,
                    shiftedCodepoint: key.shifted_codepoint,
                    generatedText: key.generated_text,
                    tracksRelease: key.tracks_release,
                    physicalKeyID: key.physical_key_id
                ))
            } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                event = .text(text)
            } else if let paste = try container.decodeIfPresent(String.self, forKey: .paste) {
                event = .paste(paste)
            } else {
                let mouse = try container.decode(Mouse.self, forKey: .mouse)
                event = .mouse(HerdrMouseEvent(
                    kind: mouse.kind.kind,
                    column: mouse.position.Cell.column,
                    row: mouse.position.Cell.row,
                    modifiers: HerdrKeyModifiers(rawValue: mouse.modifiers),
                    lines: mouse.lines
                ))
            }
        }
    }

    struct GoldenMouseKind: Decodable {
        let kind: HerdrMouseEvent.Kind

        init(from decoder: Decoder) throws {
            let buttons: [String: HerdrMouseEvent.Button] = ["Left": .left, "Right": .right, "Middle": .middle]
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                let kinds: [String: HerdrMouseEvent.Kind] = [
                    "Moved": .moved, "ScrollUp": .scrollUp, "ScrollDown": .scrollDown,
                    "ScrollLeft": .scrollLeft, "ScrollRight": .scrollRight,
                ]
                kind = try XCTUnwrap(kinds[name], name)
            } else {
                let pressed = try decoder.singleValueContainer().decode([String: String].self)
                let (name, button) = try XCTUnwrap(pressed.first)
                let value = try XCTUnwrap(buttons[button])
                switch name {
                case "Down": kind = .down(value)
                case "Up": kind = .up(value)
                default: kind = .drag(value)
                }
            }
        }
    }

    /// A recorded `MousePosition`; every recording uses cells, as Remux does.
    struct GoldenMousePosition: Decodable {
        struct CellPosition: Decodable {
            let column: UInt16
            let row: UInt16
        }

        let Cell: CellPosition
    }

    static func goldenFixtures() throws -> [GoldenFixture] {
        let bundle = Bundle(for: HerdrWireTests.self)
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".expected.json") && $0.lastPathComponent.hasPrefix("herdr-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            let name = String(url.lastPathComponent.dropLast(".expected.json".count))
            let stream = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("\(name).s2c.bin"))
            return GoldenFixture(
                name: name,
                serverStream: Array(stream),
                golden: try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
            )
        }
    }

    static func assert(_ message: HerdrServerMessage, matches entry: GoldenServerEntry, in context: String) throws {
        let fields = entry.fields ?? [:]
        func string(_ key: String) -> String? {
            if case .string(let value) = fields[key] { return value }
            return nil
        }
        func integer(_ key: String) -> Int64? {
            if case .integer(let value) = fields[key] { return value }
            return nil
        }
        func bool(_ key: String) -> Bool? {
            if case .bool(let value) = fields[key] { return value }
            return nil
        }
        switch (entry.tag, message) {
        case (3, .serverShutdown(let reason)):
            XCTAssertEqual(reason, string("reason"), context)
        case (5, .clipboard(let data)):
            XCTAssertEqual(data, string("data"), context)
        case (6, .windowTitle(let title)):
            XCTAssertEqual(title, string("title"), context)
        case (7, .reloadSoundConfig):
            break
        case (8, .mouseCapture(let enabled, let sgrPixels)):
            XCTAssertEqual(enabled, bool("enabled"), context)
            XCTAssertEqual(sgrPixels, bool("sgr_pixels"), context)
        case (9, .terminalBell(let count)):
            XCTAssertEqual(Int64(count), integer("count"), context)
        case (13, .paneSurface(let surface)):
            XCTAssertEqual(surface, entry.surface, context)
        case (14, .semanticNotification(let notification)):
            XCTAssertEqual(notification.title, string("title"), context)
            XCTAssertEqual(notification.body, string("body"), context)
            XCTAssertEqual("\(notification.kind)".lowercased(), string("kind")?.lowercased(), context)
            XCTAssertEqual(notification.paneID, string("pane_id"), context)
            XCTAssertEqual(notification.workspaceID, string("workspace_id"), context)
            XCTAssertEqual(notification.tabID, string("tab_id"), context)
            XCTAssertEqual(notification.agent, string("agent"), context)
            XCTAssertEqual(notification.position.map { "\($0)".lowercased() }, string("position")?.lowercased(), context)
        case (15, .clientShellError(let text)):
            XCTAssertEqual(text, string("message"), context)
        case (17, .keyboardReportAll(let enabled)):
            XCTAssertEqual(enabled, bool("enabled"), context)
        case (18, .responseChunk(let chunk)):
            XCTAssertEqual(chunk.bootID, string("boot_id"), context)
            XCTAssertEqual(chunk.requestID, string("request_id"), context)
            XCTAssertEqual(chunk.isFinal, bool("final_chunk"), context)
            XCTAssertEqual(Data(chunk.data).base64EncodedString(), string("data"), context)
        case (19, .paneSurfacePatch(let patch)):
            XCTAssertEqual(patch, entry.patch, context)
        case (20, .control(let kind, let data)):
            XCTAssertEqual(kind, string("kind"), context)
            XCTAssertEqual(data, string("data"), context)
            let control = try HerdrEndpointControl.parse(kind: kind, data: data)
            switch control {
            case .surfaceDelta(let delta):
                let expected = try XCTUnwrap(entry.delta, context)
                XCTAssertEqual(delta.baseProjectionRevision, expected.base_projection_revision, context)
                XCTAssertEqual(delta.baseSurfaceRevision, expected.base_surface_revision, context)
                XCTAssertEqual(delta.surface, expected.surface, context)
                XCTAssertEqual(delta.rows, expected.rows, context)
                switch (delta.popupCells, expected.popup_cells) {
                case (nil, nil): break
                case (.patch(let rows), let golden?): XCTAssertEqual(rows, golden.Patch, context)
                case (.replace(let cells), let golden?): XCTAssertEqual(cells, golden.Replace, context)
                default: XCTFail("popup cells differ: \(context)")
                }
            case .surfaceScroll(let scroll):
                let expected = try XCTUnwrap(entry.scroll, context)
                XCTAssertEqual(scroll.patch, expected.patch, context)
                XCTAssertEqual(
                    scroll.regions,
                    expected.regions.map {
                        HerdrSurfaceScroll.Region(
                            rect: HerdrSurfaceRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                            shift: $0.shift
                        )
                    },
                    context
                )
            case .surfaceReuse(let reuse):
                XCTAssertEqual(reuse, entry.reuse, context)
                XCTAssertTrue(reuse.surface.frame.cells.isEmpty, context)
            case .welcome, .snapshot, .healthPong, .ignored:
                break
            }
        default:
            XCTFail("tag \(entry.tag) decoded as \(message): \(context)")
        }
    }

    static func controlData(fromHex hex: String, kind: String) throws -> String {
        var reader = HerdrWireReader(Array(bytes(fromHex: hex).dropFirst(4)))
        XCTAssertEqual(try reader.variant(), 20)
        XCTAssertEqual(try reader.string(), kind)
        return try reader.string()
    }

    static func assertSameJSON(_ lhs: String, _ rhs: String, _ context: String) throws {
        let left = try JSONSerialization.jsonObject(with: Data(lhs.utf8), options: .fragmentsAllowed)
        let right = try JSONSerialization.jsonObject(with: Data(rhs.utf8), options: .fragmentsAllowed)
        XCTAssertEqual(left as? NSObject, right as? NSObject, context)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> [UInt8] {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
