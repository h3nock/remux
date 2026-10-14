import Foundation

// The surface model of Herdr's `shell.surface.v1` codec (Herdr v0.9.3 `src/protocol/wire.rs`).
// Each type reads both encodings Herdr uses: bincode on the wire, and serde's JSON inside
// `endpoint.surface-reuse.v1`.

/// A packed cell colour: high byte 0 = named (0 is the default colour), 1 = indexed palette, 2 = RGB;
/// any other high byte means the default colour.
struct HerdrColor: Equatable, Sendable, Decodable {
    enum Value: Equatable, Sendable {
        case `default`
        /// ratatui's named colours 1...16: Black, Red, Green, Yellow, Blue, Magenta, Cyan, Gray,
        /// DarkGray, LightRed, LightGreen, LightYellow, LightBlue, LightMagenta, LightCyan, White.
        case named(UInt8)
        case indexed(UInt8)
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
    }

    let raw: UInt32

    init(raw: UInt32) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt32.self)
    }

    var value: Value {
        let low = UInt8(truncatingIfNeeded: raw)
        switch raw >> 24 {
        case 0:
            return low == 0 || low > 16 ? .default : .named(low)
        case 1:
            return .indexed(low)
        case 2:
            return .rgb(
                red: UInt8(truncatingIfNeeded: raw >> 16),
                green: UInt8(truncatingIfNeeded: raw >> 8),
                blue: low
            )
        default:
            return .default
        }
    }
}

struct HerdrCell: Equatable, Sendable, Decodable {
    /// One grapheme cluster. A wide grapheme sits in its first cell. The cell it covers is `""` in a
    /// patch; in a full surface it is usually `" "`, but `""` after a VS16 emoji or a voiced halfwidth
    /// kana.
    let symbol: String
    let fg: HerdrColor
    let bg: HerdrColor
    /// ratatui modifier bits (bold 1, dim 2, italic 4, underlined 8, slow blink 16, rapid blink 32,
    /// reversed 64, hidden 128, crossed out 256); bits 12-15 hold the underline style.
    let modifier: UInt16
    let skip: Bool
    /// Index into the frame's `hyperlinks`.
    let hyperlink: UInt32?

    init(symbol: String, fg: HerdrColor, bg: HerdrColor, modifier: UInt16, skip: Bool, hyperlink: UInt32?) {
        self.symbol = symbol
        self.fg = fg
        self.bg = bg
        self.modifier = modifier
        self.skip = skip
        self.hyperlink = hyperlink
    }

    init(wire reader: inout HerdrWireReader) throws {
        symbol = try reader.string()
        fg = HerdrColor(raw: try reader.u32())
        bg = HerdrColor(raw: try reader.u32())
        modifier = try reader.u16()
        skip = try reader.bool()
        hyperlink = try reader.optional { try $0.u32() }
    }
}

struct HerdrCursor: Equatable, Sendable, Decodable {
    let x: UInt16
    let y: UInt16
    let visible: Bool
    /// DECSCUSR parameter, 0-6.
    let shape: UInt8

    init(x: UInt16, y: UInt16, visible: Bool, shape: UInt8) {
        self.x = x
        self.y = y
        self.visible = visible
        self.shape = shape
    }

    init(wire reader: inout HerdrWireReader) throws {
        x = try reader.u16()
        y = try reader.u16()
        visible = try reader.bool()
        shape = try reader.u8()
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, visible, shape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(UInt16.self, forKey: .x)
        y = try container.decode(UInt16.self, forKey: .y)
        visible = try container.decode(Bool.self, forKey: .visible)
        // Herdr's JSON may omit `shape` (`#[serde(default)]`).
        shape = try container.decodeIfPresent(UInt8.self, forKey: .shape) ?? 0
    }
}

struct HerdrFrame: Equatable, Sendable, Decodable {
    /// Row-major; `width * height` cells, or none in a delta's metadata.
    var cells: [HerdrCell]
    let width: UInt16
    let height: UInt16
    var cursor: HerdrCursor?
    let hyperlinks: [String]
    /// Empty on shell surfaces; images travel in the surface's graphics scene.
    let graphics: [UInt8]

    init(
        cells: [HerdrCell],
        width: UInt16,
        height: UInt16,
        cursor: HerdrCursor?,
        hyperlinks: [String],
        graphics: [UInt8]
    ) {
        self.cells = cells
        self.width = width
        self.height = height
        self.cursor = cursor
        self.hyperlinks = hyperlinks
        self.graphics = graphics
    }

    init(wire reader: inout HerdrWireReader) throws {
        cells = try reader.array { try HerdrCell(wire: &$0) }
        width = try reader.u16()
        height = try reader.u16()
        cursor = try reader.optional { try HerdrCursor(wire: &$0) }
        hyperlinks = try reader.array { try $0.string() }
        graphics = try reader.byteArray()
    }
}

struct HerdrSurfaceRect: Equatable, Sendable, Decodable {
    let x: UInt16
    let y: UInt16
    let width: UInt16
    let height: UInt16

    init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(wire reader: inout HerdrWireReader) throws {
        x = try reader.u16()
        y = try reader.u16()
        width = try reader.u16()
        height = try reader.u16()
    }
}

struct HerdrScrollMetrics: Equatable, Sendable, Decodable {
    let offsetFromBottom: UInt64
    let maxOffsetFromBottom: UInt64
    /// The program's real row count.
    let viewportRows: UInt64

    init(wire reader: inout HerdrWireReader) throws {
        offsetFromBottom = try reader.u64()
        maxOffsetFromBottom = try reader.u64()
        viewportRows = try reader.u64()
    }

    private enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}

struct HerdrSurfacePane: Equatable, Sendable, Decodable {
    let paneID: String
    let contentRevision: UInt64
    /// The pane including Herdr's border, in surface cells.
    let rect: HerdrSurfaceRect
    /// The program's text area.
    let innerRect: HerdrSurfaceRect
    let scrollbarRect: HerdrSurfaceRect?
    let scroll: HerdrScrollMetrics?
    let focused: Bool
    /// Whether the pane's program asked for mouse reports.
    let mouseReporting: Bool
    let sgrPixelMouse: Bool
    let alternateScreenActive: Bool
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init(wire reader: inout HerdrWireReader) throws {
        paneID = try reader.string()
        contentRevision = try reader.u64()
        rect = try HerdrSurfaceRect(wire: &reader)
        innerRect = try HerdrSurfaceRect(wire: &reader)
        scrollbarRect = try reader.optional { try HerdrSurfaceRect(wire: &$0) }
        scroll = try reader.optional { try HerdrScrollMetrics(wire: &$0) }
        focused = try reader.bool()
        mouseReporting = try reader.bool()
        sgrPixelMouse = try reader.bool()
        alternateScreenActive = try reader.bool()
        pixelWidth = try reader.u32()
        pixelHeight = try reader.u32()
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case contentRevision = "content_revision"
        case rect
        case innerRect = "inner_rect"
        case scrollbarRect = "scrollbar_rect"
        case scroll
        case focused
        case mouseReporting = "mouse_reporting"
        case sgrPixelMouse = "sgr_pixel_mouse"
        case alternateScreenActive = "alternate_screen_active"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

struct HerdrSurfaceSplit: Equatable, Sendable, Decodable {
    enum Direction: String, Equatable, Sendable, Decodable {
        case horizontal = "Horizontal"
        case vertical = "Vertical"
    }

    let direction: Direction
    let pos: UInt16
    let area: HerdrSurfaceRect
    let hitRect: HerdrSurfaceRect
    let path: [Bool]

    init(wire reader: inout HerdrWireReader) throws {
        switch try reader.variant() {
        case 0: direction = .horizontal
        case 1: direction = .vertical
        case let index: throw HerdrWireError.invalidVariant(type: "SplitDirection", index: index)
        }
        pos = try reader.u16()
        area = try HerdrSurfaceRect(wire: &reader)
        hitRect = try HerdrSurfaceRect(wire: &reader)
        path = try reader.array { try $0.bool() }
    }

    private enum CodingKeys: String, CodingKey {
        case direction, pos, area
        case hitRect = "hit_rect"
        case path
    }
}

enum HerdrPopupSize: Equatable, Sendable, Decodable {
    case cells(UInt16)
    case percent(UInt8)

    init(wire reader: inout HerdrWireReader) throws {
        switch try reader.variant() {
        case 0: self = .cells(try reader.u16())
        case 1: self = .percent(try reader.u8())
        case let index: throw HerdrWireError.invalidVariant(type: "ClientShellPopupSize", index: index)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cells = "Cells"
        case percent = "Percent"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cells = try container.decodeIfPresent(UInt16.self, forKey: .cells) {
            self = .cells(cells)
        } else {
            self = .percent(try container.decode(UInt8.self, forKey: .percent))
        }
    }
}

struct HerdrPopupSurface: Equatable, Sendable, Decodable {
    let terminalID: String
    let title: String
    let width: HerdrPopupSize?
    let height: HerdrPopupSize?
    var frame: HerdrFrame
    let mouseReporting: Bool
    let sgrPixelMouse: Bool
    let pixelWidth: UInt32
    let pixelHeight: UInt32

    init(wire reader: inout HerdrWireReader) throws {
        terminalID = try reader.string()
        title = try reader.string()
        width = try reader.optional { try HerdrPopupSize(wire: &$0) }
        height = try reader.optional { try HerdrPopupSize(wire: &$0) }
        frame = try HerdrFrame(wire: &reader)
        mouseReporting = try reader.bool()
        sgrPixelMouse = try reader.bool()
        pixelWidth = try reader.u32()
        pixelHeight = try reader.u32()
    }

    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case title, width, height, frame
        case mouseReporting = "mouse_reporting"
        case sgrPixelMouse = "sgr_pixel_mouse"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

// MARK: - Graphics scene

enum HerdrGraphicsSource: Equatable, Sendable, Decodable {
    enum Target: Equatable, Sendable, Decodable {
        case pane(paneID: String)
        case popup(terminalID: String)

        private enum CodingKeys: String, CodingKey {
            case pane = "Pane"
            case popup = "Popup"
        }

        private struct PaneBody: Decodable {
            let paneID: String

            private enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
            }
        }

        private struct PopupBody: Decodable {
            let terminalID: String

            private enum CodingKeys: String, CodingKey {
                case terminalID = "terminal_id"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let pane = try container.decodeIfPresent(PaneBody.self, forKey: .pane) {
                self = .pane(paneID: pane.paneID)
            } else {
                self = .popup(terminalID: try container.decode(PopupBody.self, forKey: .popup).terminalID)
            }
        }
    }

    case terminal(target: Target, imageID: UInt32)
    case paneLayer(paneID: String, layerID: String)

    init(wire reader: inout HerdrWireReader) throws {
        switch try reader.variant() {
        case 0:
            let target: Target
            switch try reader.variant() {
            case 0: target = .pane(paneID: try reader.string())
            case 1: target = .popup(terminalID: try reader.string())
            case let index: throw HerdrWireError.invalidVariant(type: "SurfaceGraphicsTarget", index: index)
            }
            self = .terminal(target: target, imageID: try reader.u32())
        case 1:
            self = .paneLayer(paneID: try reader.string(), layerID: try reader.string())
        case let index:
            throw HerdrWireError.invalidVariant(type: "SurfaceGraphicsSource", index: index)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case terminal = "Terminal"
        case paneLayer = "PaneLayer"
    }

    private struct TerminalBody: Decodable {
        let target: Target
        let imageID: UInt32

        private enum CodingKeys: String, CodingKey {
            case target
            case imageID = "image_id"
        }
    }

    private struct PaneLayerBody: Decodable {
        let paneID: String
        let layerID: String

        private enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case layerID = "layer_id"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let terminal = try container.decodeIfPresent(TerminalBody.self, forKey: .terminal) {
            self = .terminal(target: terminal.target, imageID: terminal.imageID)
        } else {
            let layer = try container.decode(PaneLayerBody.self, forKey: .paneLayer)
            self = .paneLayer(paneID: layer.paneID, layerID: layer.layerID)
        }
    }
}

enum HerdrImageFormat: String, Equatable, Sendable, Decodable {
    case rgb = "Rgb"
    case rgba = "Rgba"
    case png = "Png"
}

struct HerdrGraphicsAssetKey: Equatable, Sendable, Decodable {
    let source: HerdrGraphicsSource
    let imageWidth: UInt32
    let imageHeight: UInt32
    let format: HerdrImageFormat
    let dataLength: UInt64
    let dataFingerprint: UInt64

    init(wire reader: inout HerdrWireReader) throws {
        source = try HerdrGraphicsSource(wire: &reader)
        imageWidth = try reader.u32()
        imageHeight = try reader.u32()
        switch try reader.variant() {
        case 0: format = .rgb
        case 1: format = .rgba
        case 2: format = .png
        case let index: throw HerdrWireError.invalidVariant(type: "SurfaceGraphicsFormat", index: index)
        }
        dataLength = try reader.u64()
        dataFingerprint = try reader.u64()
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case format
        case dataLength = "data_len"
        case dataFingerprint = "data_fingerprint"
    }
}

struct HerdrGraphicsAsset: Equatable, Sendable, Decodable {
    let key: HerdrGraphicsAssetKey
    let data: [UInt8]

    init(wire reader: inout HerdrWireReader) throws {
        key = try HerdrGraphicsAssetKey(wire: &reader)
        data = try reader.byteArray()
    }
}

struct HerdrGraphicsPlacement: Equatable, Sendable, Decodable {
    let asset: HerdrGraphicsAssetKey
    let logicalPlacementID: UInt32
    let x: UInt16
    let y: UInt16
    let cols: UInt32
    let rows: UInt32
    let sourceX: UInt32
    let sourceY: UInt32
    let sourceWidth: UInt32
    let sourceHeight: UInt32
    let xOffset: UInt32
    let yOffset: UInt32
    let z: Int32
    let scrollbackOffset: UInt32

    init(wire reader: inout HerdrWireReader) throws {
        asset = try HerdrGraphicsAssetKey(wire: &reader)
        logicalPlacementID = try reader.u32()
        x = try reader.u16()
        y = try reader.u16()
        cols = try reader.u32()
        rows = try reader.u32()
        sourceX = try reader.u32()
        sourceY = try reader.u32()
        sourceWidth = try reader.u32()
        sourceHeight = try reader.u32()
        xOffset = try reader.u32()
        yOffset = try reader.u32()
        z = try reader.i32()
        scrollbackOffset = try reader.u32()
    }

    private enum CodingKeys: String, CodingKey {
        case asset
        case logicalPlacementID = "logical_placement_id"
        case x, y, cols, rows
        case sourceX = "source_x"
        case sourceY = "source_y"
        case sourceWidth = "source_width"
        case sourceHeight = "source_height"
        case xOffset = "x_offset"
        case yOffset = "y_offset"
        case z
        case scrollbackOffset = "scrollback_offset"
    }
}

struct HerdrGraphicsScene: Equatable, Sendable, Decodable {
    /// Image bytes this connection doesn't have yet.
    let assets: [HerdrGraphicsAsset]
    let placements: [HerdrGraphicsPlacement]
    /// Images the client already has and should keep.
    let retainedAssets: [HerdrGraphicsAssetKey]

    init(wire reader: inout HerdrWireReader) throws {
        assets = try reader.array { try HerdrGraphicsAsset(wire: &$0) }
        placements = try reader.array { try HerdrGraphicsPlacement(wire: &$0) }
        retainedAssets = try reader.array { try HerdrGraphicsAssetKey(wire: &$0) }
    }

    private enum CodingKeys: String, CodingKey {
        case assets, placements
        case retainedAssets = "retained_assets"
    }
}

// MARK: - Surfaces and patches

/// The client's whole surface: the active tab, including Herdr's pane borders.
struct HerdrPaneSurfaceFrame: Equatable, Sendable, Decodable {
    let bootID: String
    /// The snapshot revision this surface was rendered against.
    let projectionRevision: UInt64
    /// Per connection; +1 for every surface message.
    var surfaceRevision: UInt64
    var frame: HerdrFrame
    var panes: [HerdrSurfacePane]
    let splits: [HerdrSurfaceSplit]
    var popup: HerdrPopupSurface?
    let graphics: HerdrGraphicsScene

    init(wire reader: inout HerdrWireReader) throws {
        bootID = try reader.string()
        projectionRevision = try reader.u64()
        surfaceRevision = try reader.u64()
        frame = try HerdrFrame(wire: &reader)
        panes = try reader.array { try HerdrSurfacePane(wire: &$0) }
        splits = try reader.array { try HerdrSurfaceSplit(wire: &$0) }
        popup = try reader.optional { try HerdrPopupSurface(wire: &$0) }
        graphics = try HerdrGraphicsScene(wire: &reader)
    }

    private enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case projectionRevision = "projection_revision"
        case surfaceRevision = "surface_revision"
        case frame, panes, splits, popup, graphics
    }
}

/// A span of cells written in place, starting at surface column `x` of row `y`.
struct HerdrPatchRow: Equatable, Sendable, Decodable {
    let x: UInt16
    let y: UInt16
    let cells: [HerdrCell]

    init(x: UInt16, y: UInt16, cells: [HerdrCell]) {
        self.x = x
        self.y = y
        self.cells = cells
    }

    init(wire reader: inout HerdrWireReader) throws {
        x = try reader.u16()
        y = try reader.u16()
        cells = try reader.array { try HerdrCell(wire: &$0) }
    }
}

struct HerdrPaneSurfacePatch: Equatable, Sendable, Decodable {
    let bootID: String
    let projectionRevision: UInt64
    let baseSurfaceRevision: UInt64
    let surfaceRevision: UInt64
    var rows: [HerdrPatchRow]
    /// New metadata for the panes whose content changed; other panes keep theirs.
    let panes: [HerdrSurfacePane]
    /// Replaces the frame cursor, `nil` included.
    let cursor: HerdrCursor?

    init(wire reader: inout HerdrWireReader) throws {
        bootID = try reader.string()
        projectionRevision = try reader.u64()
        baseSurfaceRevision = try reader.u64()
        surfaceRevision = try reader.u64()
        rows = try reader.array { try HerdrPatchRow(wire: &$0) }
        panes = try reader.array { try HerdrSurfacePane(wire: &$0) }
        cursor = try reader.optional { try HerdrCursor(wire: &$0) }
    }

    private enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case projectionRevision = "projection_revision"
        case baseSurfaceRevision = "base_surface_revision"
        case surfaceRevision = "surface_revision"
        case rows, panes, cursor
    }
}
