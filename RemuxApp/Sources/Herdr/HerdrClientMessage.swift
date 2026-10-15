import Foundation

/// The client messages Remux sends (Herdr's `ClientMessage`; variant order is the tag).
enum HerdrClientMessage: Equatable, Sendable {
    /// Must be the first message.
    case hello(HerdrHello)
    case shellResize(HerdrSurfaceGeometry)
    case paneInput(paneID: String, events: [HerdrInputEvent])
    case popupInput(terminalID: String, events: [HerdrInputEvent])
    /// `request` is the JSON `{"id", "method", "params"}`.
    case endpointRequest(bootID: String, request: String)
    case hostTheme(HerdrHostThemeUpdate)
    case focus(Bool)
    case healthPing(data: String)
    case detach

    /// An endpoint command; `bootID` must be the current snapshot's.
    static func endpointRequest<Params: Encodable>(
        bootID: String,
        id: String,
        method: String,
        params: Params
    ) throws -> HerdrClientMessage {
        let request = HerdrEndpointRequest(id: id, method: method, params: params)
        let json = try JSONEncoder().encode(request)
        return .endpointRequest(bootID: bootID, request: String(decoding: json, as: UTF8.self))
    }

    var frame: [UInt8] {
        HerdrWire.frame(payload)
    }

    var payload: [UInt8] {
        var writer = HerdrWireWriter()
        switch self {
        case .hello(let hello):
            writer.variant(20)
            writer.string(HerdrControlKind.hello)
            writer.string(hello.json)
        case .shellResize(let geometry):
            writer.variant(12)
            writer.u32(geometry.cellWidthPx)
            writer.u32(geometry.cellHeightPx)
            writer.u16(geometry.cols)
            writer.u16(geometry.rows)
            // pixel_mouse: off, as in Remux's hello. A resize with it on would switch the server to
            // pixel mouse reports for this client.
            writer.bool(false)
        case .paneInput(let paneID, let events):
            writer.variant(13)
            writer.string(paneID)
            writer.array(events) { $1.write(to: &$0) }
        case .popupInput(let terminalID, let events):
            writer.variant(14)
            writer.string(terminalID)
            writer.array(events) { $1.write(to: &$0) }
        case .endpointRequest(let bootID, let request):
            writer.variant(15)
            writer.string(bootID)
            writer.string(request)
        case .hostTheme(let update):
            writer.variant(17)
            update.write(to: &writer)
        case .focus(let focused):
            writer.variant(18)
            writer.bool(focused)
        case .healthPing(let data):
            writer.variant(20)
            writer.string(HerdrControlKind.healthPing)
            writer.string(data)
        case .detach:
            writer.variant(4)
        }
        return writer.bytes
    }
}

/// Remux's `endpoint.hello.v1`: every surface encoding, the four v1 codecs, and no pixel mouse, direct
/// graphics, endpoint keybindings or client mouse capture. Cell size 0 means unknown.
struct HerdrHello: Equatable, Sendable, Encodable {
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
    let cols: UInt16
    let rows: UInt16
    let surfaceActive: Bool

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Only strings, integers, booleans and arrays: encoding cannot fail.
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case surfaceSize = "surface_size"
        case pixelMouse = "pixel_mouse"
        case directGraphics = "direct_graphics"
        case endpointKeybindings = "endpoint_keybindings"
        case mouseCapture = "mouse_capture"
        case surfaceActive = "surface_active"
        case surfaceReuse = "surface_reuse"
        case surfaceDelta = "surface_delta"
        case surfaceScroll = "surface_scroll"
        case snapshotCodecs = "snapshot_codecs"
        case surfaceCodecs = "surface_codecs"
        case inputCodecs = "input_codecs"
        case blobCodecs = "blob_codecs"
    }

    private enum SizeKeys: String, CodingKey {
        case cols, rows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1 as UInt32, forKey: .generation)
        try container.encode(cellWidthPx, forKey: .cellWidthPx)
        try container.encode(cellHeightPx, forKey: .cellHeightPx)
        var size = container.nestedContainer(keyedBy: SizeKeys.self, forKey: .surfaceSize)
        try size.encode(cols, forKey: .cols)
        try size.encode(rows, forKey: .rows)
        try container.encode(false, forKey: .pixelMouse)
        try container.encode(false, forKey: .directGraphics)
        try container.encode(false, forKey: .endpointKeybindings)
        try container.encode(false, forKey: .mouseCapture)
        try container.encode(surfaceActive, forKey: .surfaceActive)
        try container.encode(true, forKey: .surfaceReuse)
        try container.encode(true, forKey: .surfaceDelta)
        try container.encode(true, forKey: .surfaceScroll)
        try container.encode([HerdrControlKind.snapshot], forKey: .snapshotCodecs)
        try container.encode(["shell.surface.v1"], forKey: .surfaceCodecs)
        try container.encode(["shell.input.semantic.v1"], forKey: .inputCodecs)
        try container.encode(["shell.blob.v1"], forKey: .blobCodecs)
    }
}

struct HerdrSurfaceGeometry: Equatable, Sendable {
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
    let cols: UInt16
    let rows: UInt16
}

private struct HerdrEndpointRequest<Params: Encodable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

// MARK: - Semantic input (`shell.input.semantic.v1`)

enum HerdrInputEvent: Equatable, Sendable {
    case key(HerdrKeyEvent)
    /// Written to the program as is.
    case text(String)
    case mouse(HerdrMouseEvent)
    /// Bracketed when the program enabled bracketed paste.
    case paste(String)

    func write(to writer: inout HerdrWireWriter) {
        switch self {
        case .key(let key):
            writer.variant(0)
            key.write(to: &writer)
        case .text(let text):
            writer.variant(1)
            writer.string(text)
        case .mouse(let mouse):
            writer.variant(2)
            mouse.write(to: &writer)
        case .paste(let text):
            writer.variant(3)
            writer.string(text)
        }
    }
}

enum HerdrKeyCode: Equatable, Sendable {
    case backspace, enter, left, right, up, down, home, end, pageUp, pageDown
    case tab, backTab, delete, insert, escape
    /// serde `char`: exactly one Unicode scalar. A multi-scalar grapheme goes as `.text`.
    case character(Unicode.Scalar)
    case function(UInt8)
    case null
}

/// crossterm 0.29 `KeyModifiers` bits.
struct HerdrKeyModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let shift = HerdrKeyModifiers(rawValue: 1)
    static let control = HerdrKeyModifiers(rawValue: 2)
    static let alt = HerdrKeyModifiers(rawValue: 4)
    static let `super` = HerdrKeyModifiers(rawValue: 8)
    static let hyper = HerdrKeyModifiers(rawValue: 16)
    static let meta = HerdrKeyModifiers(rawValue: 32)
}

struct HerdrKeyEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case press, `repeat`, release
    }

    let code: HerdrKeyCode
    let modifiers: HerdrKeyModifiers
    let kind: Kind
    let repeatCount: UInt16
    let shiftedCodepoint: UInt32?
    /// The exact bytes the key produces. Herdr writes them in place of the key's own encoding, with its
    /// modifiers ignored, except for a release, a legacy Super or Ctrl+Shift+letter chord, or a key
    /// with `tracksRelease` going to a pane that reports every key. So it is the text only for keys
    /// that type it; control chords leave it nil.
    let generatedText: String?
    /// Herdr holds the press until its release and releases it itself if the surface deactivates.
    let tracksRelease: Bool
    let physicalKeyID: UInt32?

    init(
        code: HerdrKeyCode,
        modifiers: HerdrKeyModifiers = [],
        kind: Kind = .press,
        repeatCount: UInt16 = 1,
        shiftedCodepoint: UInt32? = nil,
        generatedText: String? = nil,
        tracksRelease: Bool = false,
        physicalKeyID: UInt32? = nil
    ) {
        self.code = code
        self.modifiers = modifiers
        self.kind = kind
        self.repeatCount = repeatCount
        self.shiftedCodepoint = shiftedCodepoint
        self.generatedText = generatedText
        self.tracksRelease = tracksRelease
        self.physicalKeyID = physicalKeyID
    }

    func write(to writer: inout HerdrWireWriter) {
        switch code {
        case .backspace: writer.variant(0)
        case .enter: writer.variant(1)
        case .left: writer.variant(2)
        case .right: writer.variant(3)
        case .up: writer.variant(4)
        case .down: writer.variant(5)
        case .home: writer.variant(6)
        case .end: writer.variant(7)
        case .pageUp: writer.variant(8)
        case .pageDown: writer.variant(9)
        case .tab: writer.variant(10)
        case .backTab: writer.variant(11)
        case .delete: writer.variant(12)
        case .insert: writer.variant(13)
        case .escape: writer.variant(14)
        case .character(let character):
            writer.variant(15)
            writer.character(character)
        case .function(let number):
            writer.variant(16)
            writer.u8(number)
        case .null: writer.variant(17)
        }
        writer.u8(modifiers.rawValue)
        switch kind {
        case .press: writer.variant(0)
        case .repeat: writer.variant(1)
        case .release: writer.variant(2)
        }
        writer.u16(repeatCount)
        writer.optional(shiftedCodepoint) { $0.u32($1) }
        writer.optional(generatedText) { $0.string($1) }
        writer.bool(tracksRelease)
        writer.optional(physicalKeyID) { $0.u32($1) }
        // windows_record: Windows console input only.
        writer.optional(nil as UInt8?) { $0.u8($1) }
    }
}

struct HerdrMouseEvent: Equatable, Sendable {
    enum Button: UInt32, Equatable, Sendable {
        case left = 0, right, middle
    }

    enum Kind: Equatable, Sendable {
        case down(Button), up(Button), drag(Button)
        case moved, scrollUp, scrollDown, scrollLeft, scrollRight
    }

    let kind: Kind
    /// The cell, relative to the pane's text area. Remux's hello turns pixel mouse off, so positions
    /// are always cells and no pixel geometry is sent.
    let column: UInt16
    let row: UInt16
    let modifiers: HerdrKeyModifiers
    /// Wheel lines; Herdr uses it only to scroll host history. Program wheel routes send one report
    /// or arrow key per event.
    let lines: UInt16

    init(
        kind: Kind,
        column: UInt16,
        row: UInt16,
        modifiers: HerdrKeyModifiers = [],
        lines: UInt16 = 1
    ) {
        self.kind = kind
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.lines = lines
    }

    func write(to writer: inout HerdrWireWriter) {
        switch kind {
        case .down(let button):
            writer.variant(0)
            writer.variant(button.rawValue)
        case .up(let button):
            writer.variant(1)
            writer.variant(button.rawValue)
        case .drag(let button):
            writer.variant(2)
            writer.variant(button.rawValue)
        case .moved: writer.variant(3)
        case .scrollUp: writer.variant(4)
        case .scrollDown: writer.variant(5)
        case .scrollLeft: writer.variant(6)
        case .scrollRight: writer.variant(7)
        }
        // MousePosition::Cell, then no pixel geometry.
        writer.variant(0)
        writer.u16(column)
        writer.u16(row)
        writer.optional(nil as UInt8?) { $0.u8($1) }
        writer.u8(modifiers.rawValue)
        writer.u16(lines)
    }
}

// MARK: - Host theme

struct HerdrRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// The phone's terminal colours, reported so Herdr answers programs' colour queries and resolves
/// default colours with them.
enum HerdrHostThemeUpdate: Equatable, Sendable {
    enum DefaultColorKind: Equatable, Sendable {
        case foreground, background
    }

    enum Appearance: Equatable, Sendable {
        case dark, light
    }

    case defaultColor(DefaultColorKind, HerdrRGB)
    /// Colours by palette index. One entry per index keeps the update within the 256 entries Herdr
    /// accepts; more closes the connection.
    case paletteColors([UInt8: HerdrRGB])
    case appearance(Appearance)

    func write(to writer: inout HerdrWireWriter) {
        func rgb(_ color: HerdrRGB) {
            writer.u8(color.red)
            writer.u8(color.green)
            writer.u8(color.blue)
        }
        switch self {
        case .defaultColor(let kind, let color):
            writer.variant(0)
            writer.variant(kind == .foreground ? 0 : 1)
            rgb(color)
        case .paletteColors(let colors):
            writer.variant(1)
            writer.u64(UInt64(colors.count))
            for (index, color) in colors.sorted(by: { $0.key < $1.key }) {
                writer.u8(index)
                rgb(color)
            }
        case .appearance(let appearance):
            writer.variant(2)
            writer.variant(appearance == .dark ? 0 : 1)
        }
    }
}
