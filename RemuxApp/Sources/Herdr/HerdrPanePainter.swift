import Foundation

/// Turns part of a Herdr frame into VT bytes for a local terminal of exactly that part's size: a pane's
/// text area (`innerRect`) for that pane's producer, or a whole popup frame for the popup's.
///
/// Herdr's cells are copies of the cells of its own Ghostty terminals, which run grapheme clustering
/// (mode 2027). Each painted row is erased, then written left to right with every cell at its own
/// column, so the local Ghostty rebuilds every cell from its code points the way Herdr's built it:
/// - A cell's first code point above U+00FF is printed with clustering off, because with it on Ghostty
///   may join it to the cell on its left, which Herdr's grid keeps apart (Ghostty never joins at column 0
///   or for code points up to U+00FF). The rest of the cell is printed with clustering on, and lands in
///   that cell because the cells to its right are still erased.
/// - A wide grapheme writes the cell it covers itself. Herdr sends that cell as `""`, or in a full
///   surface usually as a default blank, so a cell that looks like an erased one is not written: written
///   over a covered cell it would erase the wide grapheme. The one exception is the cell after a VS15
///   grapheme: Ghostty prints such a grapheme's first code point wide before VS15 narrows it, which
///   leaves that cell styled.
///
/// Two cells Herdr's Ghostty can hold can't be printed: a covered cell styled apart from its wide
/// grapheme (printing gives it the grapheme's style), and a VS15 grapheme with a wide first code point
/// in the last column (Ghostty doesn't print a wide code point there with autowrap off).
///
/// Cells are encoded as Herdr's client encodes them (`protocol/render_ansi.rs`), which also writes a
/// cell's SGR only when it differs from the style in effect, and its CUP only when the cursor isn't
/// already there: right after an ASCII cell, which Ghostty prints into exactly one cell. A link carries
/// an id made from its URI: each cell is opened separately, and Ghostty makes every link opened without
/// an id a link of its own, so a long URL would otherwise be one link per cell.
///
/// The painted terminal needs autowrap off, as Herdr's client sets it on its terminal, so no cell spills
/// into the next row, and clustering on.
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
        var find: HerdrFindDecoration? = nil
    }

    /// Grapheme clustering (mode 2027), which Herdr's terminals have: Herdr lays out a cluster such as a
    /// joined emoji as one character, and writes it as one cell.
    static let graphemeClustering: [UInt8] = Array("\u{1B}[?2027h".utf8)

    /// Autowrap off and grapheme clustering on.
    static let terminalSetup: [UInt8] = graphemeClustering + Array("\u{1B}[?7l".utf8)

    /// The cursor the panes show: the frame's, unless a popup is open, which then has the only cursor,
    /// as Herdr's client composes them.
    static func paneCursor(of surface: HerdrPaneSurfaceFrame) -> HerdrCursor? {
        surface.popup == nil ? surface.frame.cursor : nil
    }

    /// For a new terminal, after a resize, and to recover a terminal: the modes, every row, then the
    /// cursor.
    static func repaint(_ next: Painted) -> [UInt8] {
        terminalSetup
            + rows(0..<Int(next.area.height), of: next.frame, area: next.area, find: next.find)
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
        return rows(changed, of: next.frame, area: next.area, find: next.find) + cursorBytes(shown)
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
        let decorationRows: Set<Int> = previous.find == next.find ? []
            : Set(previous.find?.rows.keys.map { $0 } ?? []).union(next.find?.rows.keys.map { $0 } ?? [])
        return (0..<height).filter { y in
            if decorationRows.contains(y) { return true }
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

    /// The listed rows of the area (0 is its top row), each erased and then written left to right, then
    /// SGR 0.
    static func rows(_ rows: some Sequence<Int>, of frame: HerdrFrame, area: HerdrSurfaceRect, find frameDecoration: HerdrFindDecoration? = nil) -> [UInt8] {
        let links = frame.hyperlinks.map(sanitizedLink)
        var bytes: [UInt8] = []
        for y in rows {
            appendCursorPosition(row: y, column: 0, to: &bytes)
            bytes += resetSGR
            bytes += eraseLine
            let start = (Int(area.y) + y) * Int(frame.width) + Int(area.x)
            var afterVS15 = false
            // The cursor's column when known, and the style in effect (SGR 0 sets the default one).
            var cursorColumn: Int? = 0
            let spans = frameDecoration?.rows[y] ?? []
            // Fill decoration before glyphs. Keep the original erased-cell skip rule below:
            // a full frame represents a wide glyph's covered cell as an ordinary blank.
            for span in spans {
                appendCursorPosition(row: y, column: span.start, to: &bytes)
                bytes += Array((span.selected ? "\u{1B}[48;2;255;225;65m" : "\u{1B}[48;2;107;96;45m").utf8)
                bytes += Array("\u{1B}[\(span.end - span.start + 1)X".utf8)
            }
            if !spans.isEmpty {
                bytes += resetSGR
                appendCursorPosition(row: y, column: 0, to: &bytes)
            }
            var spanIndex = 0
            var style: (fg: HerdrColor.Value, bg: HerdrColor.Value, modifier: UInt16) = (.default, .default, 0)
            for x in 0..<Int(area.width) {
                let original = frame.cells[start + x]
                var cell = original
                while spanIndex < spans.count, spans[spanIndex].end < x { spanIndex += 1 }
                if spanIndex < spans.count, spans[spanIndex].start <= x {
                    let active = spans[spanIndex].selected
                    cell = HerdrCell(symbol: cell.symbol,
                        fg: active ? HerdrColor(raw: 1) : cell.fg,
                        bg: HerdrColor(raw: active ? 0x02FFE141 : 0x026B602D),
                        modifier: cell.modifier & ~UInt16(64 | 128), skip: cell.skip, hyperlink: cell.hyperlink)
                }
                // A cell's text never controls the terminal. Herdr's cells come from Ghostty cells,
                // which never hold a control character.
                let symbol = withoutControlCharacters(cell.symbol)
                let link = cell.hyperlink.flatMap { Int($0) < links.count ? links[Int($0)] : nil }
                // A covered cell, a cell marked skip (Herdr's client never writes those), or one the
                // erased row already shows.
                if symbol.isEmpty || cell.skip || (link == nil && looksErased(symbol, original) && !afterVS15) {
                    afterVS15 = false
                    continue
                }
                afterVS15 = symbol.utf8.count > 1 && symbol.unicodeScalars.contains(variationSelector15)
                if cursorColumn != x {
                    appendCursorPosition(row: y, column: x, to: &bytes)
                }
                let cellStyle = (fg: cell.fg.value, bg: cell.bg.value, modifier: cell.modifier)
                if cellStyle != style {
                    appendSGR(cell, to: &bytes)
                    style = cellStyle
                }
                cursorColumn = symbol.utf8.count == 1 && x + 1 < Int(area.width) ? x + 1 : nil
                if let link {
                    bytes += osc8Prefix
                    bytes += linkID(link)
                    bytes.append(0x3B)
                    bytes += link
                    bytes += stringTerminator
                }
                appendSymbol(symbol, atColumn: x, to: &bytes)
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
        let sanitized = withoutControlCharacters(uri)
        return sanitized.isEmpty ? nil : Array(sanitized.utf8)
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
    /// EL 2: the whole row, blank with the default background after SGR 0.
    private static let eraseLine: [UInt8] = Array("\u{1B}[2K".utf8)
    private static let clusteringOff: [UInt8] = Array("\u{1B}[?2027l".utf8)
    private static let clusteringOn: [UInt8] = Array("\u{1B}[?2027h".utf8)
    private static let variationSelector15: Unicode.Scalar = "\u{FE0E}"
    private static let osc8Prefix: [UInt8] = Array("\u{1B}]8;".utf8)
    private static let stringTerminator: [UInt8] = [0x1B, 0x5C]
    /// ratatui's modifier bits before and after underline, with their SGR codes.
    private static let leadingModifiers: [(bit: UInt16, code: UInt8)] = [(1, 0x31), (2, 0x32), (4, 0x33)]
    private static let trailingModifiers: [(bit: UInt16, code: UInt8)] = [
        (16, 0x35), (32, 0x36), (64, 0x37), (128, 0x38), (256, 0x39),
    ]

    /// A blank in the default colours without modifiers: what an erased cell shows.
    private static func looksErased(_ symbol: String, _ cell: HerdrCell) -> Bool {
        symbol == " " && cell.fg.value == .default && cell.bg.value == .default && cell.modifier == 0
    }

    /// Unicode's control characters (general category Cc, fixed by Unicode's stability policy): C0, DEL
    /// and C1.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private static func withoutControlCharacters(_ text: String) -> String {
        // In UTF-8 a C0 or DEL is one byte below 0x20 or 0x7F, and a C1 is 0xC2 then 0x80-0x9F.
        var lead: UInt8 = 0
        let hasControl = text.utf8.contains { byte in
            defer { lead = byte }
            return byte < 0x20 || byte == 0x7F || (lead == 0xC2 && byte < 0xA0)
        }
        guard hasControl else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isControl($0) })
        return String(scalars)
    }

    /// The symbol, its first code point printed with clustering off where Ghostty could join it to the
    /// cell on the left.
    private static func appendSymbol(_ symbol: String, atColumn column: Int, to bytes: inout [UInt8]) {
        // A UTF-8 lead byte below 0xC4 starts a code point up to U+00FF.
        guard column > 0, let lead = symbol.utf8.first, lead >= 0xC4, let first = symbol.unicodeScalars.first else {
            bytes += symbol.utf8
            return
        }
        bytes += clusteringOff
        bytes += first.utf8
        bytes += clusteringOn
        bytes += symbol.utf8.dropFirst(first.utf8.count)
    }

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
