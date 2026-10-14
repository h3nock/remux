import Foundation

/// Turns part of a Herdr frame into VT bytes for a local terminal of exactly that part's size: a pane's
/// text area (`innerRect`) for that pane's producer, or a whole popup frame for the popup's.
///
/// Each painted row is repainted whole, right to left, with every cell placed at its own column. A wide
/// grapheme painted after its right neighbour covers that column, and `""` covered cells aren't written,
/// so wide characters, emoji and combining marks land where Herdr's grid has them without a width table.
/// Cells are encoded as Herdr's client encodes them (`protocol/render_ansi.rs`). A link carries an id
/// made from its URI: each cell is opened separately, and Ghostty makes every link opened without an id
/// a link of its own, so a long URL would otherwise be one link per cell.
///
/// The painted terminal needs autowrap off, as Herdr's client sets it on its terminal, or a wide
/// grapheme in the last column wraps into the next row. It also needs grapheme clustering (mode 2027)
/// on, as Herdr's own pane terminals run it, or ZWJ sequences, flags and VS16 emoji split across cells.
///
/// A paint that places cells ends with the cursor, because placing cells moves the terminal's cursor.
/// Feed each paint in one producer call, so the renderer never draws a half-painted area. The area must
/// lie inside the frame, which `HerdrPresentation` checks for every surface it accepts.
enum HerdrPanePainter {
    /// What a terminal shows: part of a frame and the cursor it was given.
    struct Painted: Equatable, Sendable {
        let frame: HerdrFrame
        let area: HerdrSurfaceRect
        /// In frame coordinates: `paneCursor(of:)` for a pane, the popup frame's cursor for a popup.
        let cursor: HerdrCursor?
    }

    /// Autowrap off and grapheme clustering (mode 2027) on.
    static let terminalSetup: [UInt8] = Array("\u{1B}[?2027h\u{1B}[?7l".utf8)

    /// The cursor the panes show: the frame's, unless a popup is open, which then has the only cursor,
    /// as Herdr's client composes them.
    static func paneCursor(of surface: HerdrPaneSurfaceFrame) -> HerdrCursor? {
        surface.popup == nil ? surface.frame.cursor : nil
    }

    /// For a new terminal, after a resize, and to recover a terminal: the modes, every row, then the
    /// cursor.
    static func repaint(_ next: Painted) -> [UInt8] {
        terminalSetup
            + rows(0..<Int(next.area.height), of: next.frame, area: next.area)
            + cursorBytes(cursor(next.cursor, in: next.area))
    }

    /// For a terminal that shows `previous`: the rows that look different, then the cursor; only the
    /// cursor when nothing else changed; nothing when nothing did. Herdr's client also writes only what
    /// changed since the last frame. An area of another size is repainted: its terminal is resized
    /// first.
    static func update(from previous: Painted, to next: Painted) -> [UInt8] {
        guard let changed = changedRows(from: previous, to: next) else { return repaint(next) }
        let shown = cursor(next.cursor, in: next.area)
        if changed.isEmpty {
            return shown == cursor(previous.cursor, in: previous.area) ? [] : cursorBytes(shown)
        }
        return rows(changed, of: next.frame, area: next.area) + cursorBytes(shown)
    }

    /// The area's rows (0 is its top row) whose cells look different, compared as Herdr's client
    /// compares them: symbol, colours, modifiers and the link's sanitized URI, not `skip`. nil for
    /// areas of different sizes, which are repainted.
    static func changedRows(from previous: Painted, to next: Painted) -> [Int]? {
        let width = Int(next.area.width)
        let height = Int(next.area.height)
        guard Int(previous.area.width) == width, Int(previous.area.height) == height else {
            return nil
        }
        let oldLinks = previous.frame.hyperlinks.map(sanitizedLink)
        let newLinks = next.frame.hyperlinks.map(sanitizedLink)
        func link(_ cell: HerdrCell, _ links: [[UInt8]?]) -> [UInt8]? {
            cell.hyperlink.flatMap { Int($0) < links.count ? links[Int($0)] : nil }
        }
        return (0..<height).filter { y in
            let oldStart = (Int(previous.area.y) + y) * Int(previous.frame.width) + Int(previous.area.x)
            let newStart = (Int(next.area.y) + y) * Int(next.frame.width) + Int(next.area.x)
            for x in 0..<width {
                let old = previous.frame.cells[oldStart + x]
                let new = next.frame.cells[newStart + x]
                if old.symbol != new.symbol || old.fg != new.fg || old.bg != new.bg || old.modifier != new.modifier
                    || link(old, oldLinks) != link(new, newLinks) {
                    return true
                }
            }
            return false
        }
    }

    /// The listed rows of the area (0 is its top row), each right to left, then SGR 0.
    static func rows(_ rows: some Sequence<Int>, of frame: HerdrFrame, area: HerdrSurfaceRect) -> [UInt8] {
        let links = frame.hyperlinks.map(sanitizedLink)
        var bytes: [UInt8] = []
        for y in rows {
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            for x in stride(from: Int(area.width) - 1, through: 0, by: -1) {
                let cell = frame.cells[start + x]
                // Herdr's client never writes a cell marked skip.
                if cell.symbol.isEmpty || cell.skip { continue }
                let link = cell.hyperlink.flatMap { Int($0) < links.count ? links[Int($0)] : nil }
                appendCursorPosition(row: y, column: x, to: &bytes)
                appendSGR(cell, to: &bytes)
                if let link {
                    bytes += osc8Prefix
                    bytes += linkID(link)
                    bytes.append(0x3B)
                    bytes += link
                    bytes += stringTerminator
                }
                bytes += cell.symbol.utf8
                if link != nil {
                    bytes += osc8Prefix
                    bytes.append(0x3B)
                    bytes += stringTerminator
                }
            }
        }
        bytes += resetSGR
        return bytes
    }

    /// The cursor in area coordinates, shown or hidden, or nil when it lies outside the area (another
    /// pane's cursor, or none of the panes').
    static func cursor(_ cursor: HerdrCursor?, in area: HerdrSurfaceRect) -> HerdrCursor? {
        guard let cursor,
              cursor.x >= area.x, Int(cursor.x) < Int(area.x) + Int(area.width),
              cursor.y >= area.y, Int(cursor.y) < Int(area.y) + Int(area.height)
        else {
            return nil
        }
        return HerdrCursor(x: cursor.x - area.x, y: cursor.y - area.y, visible: cursor.visible, shape: cursor.shape)
    }

    /// As Herdr's client writes it: placed first, even when hidden, then shaped (DECSCUSR) and shown,
    /// or hidden. A cursor outside the area is hidden where it is.
    static func cursorBytes(_ cursor: HerdrCursor?) -> [UInt8] {
        guard let cursor else { return Array("\u{1B}[?25l".utf8) }
        var bytes: [UInt8] = []
        appendCursorPosition(row: Int(cursor.y), column: Int(cursor.x), to: &bytes)
        if cursor.visible {
            bytes += Array("\u{1B}[\(cursor.shape) q\u{1B}[?25h".utf8)
        } else {
            bytes += Array("\u{1B}[?25l".utf8)
        }
        return bytes
    }

    /// Herdr's client drops every control character from a link and treats an empty result as no link.
    static func sanitizedLink(_ uri: String) -> [UInt8]? {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: uri.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return scalars.isEmpty ? nil : Array(String(scalars).utf8)
    }

    /// `id=` and 16 hex digits of the URI's 64-bit FNV-1a hash, so every cell of a link, in every
    /// paint, opens the same link.
    static func linkID(_ uri: [UInt8]) -> [UInt8] {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in uri {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Array("id=\(String(hash, radix: 16).leftPadded(to: 16))".utf8)
    }

    // MARK: - Encoding

    private static let resetSGR: [UInt8] = Array("\u{1B}[0m".utf8)
    private static let osc8Prefix: [UInt8] = Array("\u{1B}]8;".utf8)
    private static let stringTerminator: [UInt8] = [0x1B, 0x5C]
    /// ratatui's modifier bits before and after underline, with their SGR codes.
    private static let leadingModifiers: [(bit: UInt16, code: UInt8)] = [(1, 0x31), (2, 0x32), (4, 0x33)]
    private static let trailingModifiers: [(bit: UInt16, code: UInt8)] = [
        (16, 0x35), (32, 0x36), (64, 0x37), (128, 0x38), (256, 0x39),
    ]

    /// CUP, 1-based.
    private static func appendCursorPosition(row: Int, column: Int, to bytes: inout [UInt8]) {
        bytes += [0x1B, 0x5B]
        appendDecimal(row + 1, to: &bytes)
        bytes.append(0x3B)
        appendDecimal(column + 1, to: &bytes)
        bytes.append(0x48)
    }

    /// Herdr's `build_sgr`: reset, the modifiers, then foreground and background.
    private static func appendSGR(_ cell: HerdrCell, to bytes: inout [UInt8]) {
        bytes += [0x1B, 0x5B, 0x30]
        let modifier = cell.modifier
        for (bit, code) in leadingModifiers where modifier & bit != 0 {
            bytes += [0x3B, code]
        }
        if modifier & 8 != 0 {
            bytes.append(0x3B)
            switch (modifier >> 12) & 0xF {
            case 2: bytes += "4:2".utf8
            case 3: bytes += "4:3".utf8
            case 4: bytes += "4:4".utf8
            case 5: bytes += "4:5".utf8
            default: bytes.append(0x34)
            }
        }
        for (bit, code) in trailingModifiers where modifier & bit != 0 {
            bytes += [0x3B, code]
        }
        bytes.append(0x3B)
        appendColor(cell.fg, foreground: true, to: &bytes)
        bytes.append(0x3B)
        appendColor(cell.bg, foreground: false, to: &bytes)
        bytes.append(0x6D)
    }

    private static func appendColor(_ color: HerdrColor, foreground: Bool, to bytes: inout [UInt8]) {
        switch color.value {
        case .default:
            bytes += (foreground ? "39" : "49").utf8
        case .named(let index):
            // Black through Gray are 30-37, DarkGray through White 90-97; backgrounds add 10.
            let code = index <= 8 ? 29 + Int(index) : 81 + Int(index)
            appendDecimal(foreground ? code : code + 10, to: &bytes)
        case .indexed(let index):
            bytes += (foreground ? "38;5;" : "48;5;").utf8
            appendDecimal(Int(index), to: &bytes)
        case .rgb(let red, let green, let blue):
            bytes += (foreground ? "38;2;" : "48;2;").utf8
            appendDecimal(Int(red), to: &bytes)
            bytes.append(0x3B)
            appendDecimal(Int(green), to: &bytes)
            bytes.append(0x3B)
            appendDecimal(Int(blue), to: &bytes)
        }
    }

    private static func appendDecimal(_ value: Int, to bytes: inout [UInt8]) {
        if value >= 10 {
            appendDecimal(value / 10, to: &bytes)
        }
        bytes.append(0x30 + UInt8(value % 10))
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
