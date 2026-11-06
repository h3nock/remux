import Foundation

/// `pane.selection.read`: the plain text between two cells of a pane, read by Herdr from the pane's
/// terminal, history included. Rows count from the top of the history, the viewport's top row being
/// `max_offset_from_bottom - offset_from_bottom`, as Herdr's client counts them (`selection.rs`); soft-
/// wrapped rows come back as one line.
///
/// As Herdr's client copies an explicit selection (`request_selection_copy` with `live`), no content
/// revision goes with a copy: rows counted from the top of the history stay with their lines as output
/// arrives, so Herdr reads the live terminal instead of refusing a copy over output that came after the
/// frame on screen. A read about the frame on screen names its content revision, which Herdr refuses once
/// the pane shows something else.
struct HerdrSelectionRead: Encodable, Sendable {
    struct Point: Encodable, Sendable {
        let row: UInt32
        let col: UInt16
    }

    let paneID: String
    let anchor: Point
    let cursor: Point
    let contentRevision: UInt64?

    /// `selection`'s cells in reading order, as Herdr's client sends them.
    init(paneID: String, selection: GhosttyHistorySelection, contentRevision: UInt64? = nil) {
        func point(_ cell: GhosttyTerminalCell) -> Point {
            Point(row: UInt32(clamping: cell.row), col: cell.column)
        }
        let (first, last) = selection.ordered
        self.paneID = paneID
        anchor = point(first)
        cursor = point(last)
        self.contentRevision = contentRevision
    }

    /// Reads the text from the reply `{"id", "result": {"type": "pane_selection", "pane_id", "text"}}`.
    static func text(fromReply reply: Data) throws -> String {
        struct Reply: Decodable {
            struct Result: Decodable {
                let text: String
            }

            let result: Result
        }
        return try JSONDecoder().decode(Reply.self, from: reply).result.text
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case anchor, cursor
        case contentRevision = "content_revision"
    }
}

/// Whether a selection made in a pane's frame goes on past a row edge it reaches. Herdr's frames don't say
/// where lines wrap, but Herdr reads a line's soft-wrapped rows back as one line, with trailing blanks
/// trimmed (`read_text_screen`), so its text for the two cells across the edge has a line break or a blank
/// there exactly when the selection's word stops at the edge.
struct HerdrRowEdgeRead: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        /// The previous row's last cell and the selection's first.
        case start
        /// The selection's last cell and the next row's first.
        case end
    }

    let side: Side
    let cells: GhosttyHistorySelection

    /// The reads for the row edges `selection` reaches in `content`'s frame, as `reachesRowEdge` finds them;
    /// none for an edge with nothing beyond it: the top of the history, or the last row the pane has.
    static func reads(for selection: GhosttyHistorySelection, in content: HerdrPaneContent) -> [HerdrRowEdgeRead] {
        guard content.columns > 0 else { return [] }
        let (first, last) = selection.ordered
        var reads: [HerdrRowEdgeRead] = []
        if first.column == 0, first.row > 0 {
            let before = GhosttyTerminalCell(row: first.row - 1, column: content.columns - 1)
            reads.append(HerdrRowEdgeRead(side: .start, cells: GhosttyHistorySelection(start: before, end: first)))
        }
        let isLastRow = content.offsetFromBottom == 0 && last.row + 1 >= content.top + UInt64(content.rows)
        if Int(last.column) + 2 >= Int(content.columns), !isLastRow {
            let after = GhosttyTerminalCell(row: last.row + 1, column: 0)
            reads.append(HerdrRowEdgeRead(side: .end, cells: GhosttyHistorySelection(start: last, end: after)))
        }
        return reads
    }

    /// Whether the line goes on across the edge, from Herdr's text for `cells`: no line break, and a character
    /// that isn't blank on the far side.
    func lineGoesOn(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        switch side {
        case .start: return text.first.map { !$0.isWhitespace } ?? false
        case .end: return text.count > 1 && text.last.map { !$0.isWhitespace } == true
        }
    }
}

/// What Herdr says of a selection that may go on past a row edge.
enum HerdrSelectionCompletion: Sendable {
    /// The plain-text web link at the cell pressed, which Herdr finds across wrapped rows.
    case link(HerdrResolvedLink)
    /// No web link there: other text, whole when its line stops at each row edge the selection reaches.
    case text(isWhole: Bool)
}

/// Herdr's visible link regions remain useful for selection even when the destination continues off screen.
struct HerdrResolvedLink {
    let selection: GhosttyHistorySelection
    let isComplete: Bool
}

/// `pane.link.resolve`: the cells of the plain-text link at a cell of a pane's viewport, which Herdr finds
/// across the pane's wrapped rows, as regions of rows of the viewport. As Herdr's client asks it, the
/// request names the content revision and viewport of the frame on screen, and Herdr refuses it once its
/// pane shows something else.
struct HerdrLinkResolve: Encodable, Sendable {
    let paneID: String
    let viewportRow: UInt16
    let col: UInt16
    let contentRevision: UInt64
    let offsetFromBottom: UInt64?
    private let content: HerdrPaneContent

    /// Asks about `cell`, a history cell of the pane whose terminal shows `content`; nil when the cell
    /// isn't on its viewport, or the content is one Herdr was still changing (an odd revision), which
    /// Herdr's client doesn't ask about either.
    init?(paneID: String, cell: GhosttyTerminalCell, content: HerdrPaneContent) {
        guard content.revision.isMultiple(of: 2), cell.row >= content.top,
              cell.row - content.top < UInt64(content.rows), cell.column < content.columns
        else { return nil }
        self.paneID = paneID
        viewportRow = UInt16(cell.row - content.top)
        col = cell.column
        contentRevision = content.revision
        offsetFromBottom = content.offsetFromBottom
        self.content = content
    }

    /// The link from the reply `{"id", "result": {"type": "pane_link_resolved", "regions"}}`, in history
    /// rows; nil when Herdr found none or returned invalid regions.
    /// `pane.link.resolve` clips its highlighting to the viewport; those regions alone must not turn
    /// a URL prefix into a browser destination.
    func link(fromReply reply: Data) throws -> HerdrResolvedLink? {
        struct Reply: Decodable {
            struct Result: Decodable {
                let regions: [Region]
            }

            let result: Result
        }
        struct Region: Decodable {
            let row: UInt16
            let startCol: UInt16
            let endCol: UInt16

            private enum CodingKeys: String, CodingKey {
                case row
                case startCol = "start_col"
                case endCol = "end_col"
            }
        }
        let regions = try JSONDecoder().decode(Reply.self, from: reply).result.regions
        guard regions.count <= Int(content.rows),
              regions.allSatisfy({ $0.row < content.rows && $0.startCol <= $0.endCol && $0.endCol < content.columns }),
              regions.contains(where: { $0.row == viewportRow && ($0.startCol...$0.endCol).contains(col) }),
              let first = regions.min(by: { ($0.row, $0.startCol) < ($1.row, $1.startCol) }),
              let last = regions.max(by: { ($0.row, $0.endCol) < ($1.row, $1.endCol) })
        else { return nil }
        // At the actual history/screen ends there is no hidden continuation. Otherwise an endpoint
        // at the viewport boundary is ambiguous. Herdr omits wide-wrap padding from its regions,
        // so the bottom endpoint may be one column short even though the URL continues below.
        let isComplete = !((content.top > 0 || content.offsetFromBottom == nil) && first.row == 0 && first.startCol == 0)
            && !(content.offsetFromBottom != 0 && last.row + 1 == content.rows
                && Int(last.endCol) + 2 >= Int(content.columns))
        return HerdrResolvedLink(
            selection: GhosttyHistorySelection(
                start: GhosttyTerminalCell(row: content.top + UInt64(first.row), column: first.startCol),
                end: GhosttyTerminalCell(row: content.top + UInt64(last.row), column: last.endCol)
            ),
            isComplete: isComplete
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case viewportRow = "viewport_row"
        case col
        case contentRevision = "content_revision"
        case offsetFromBottom = "offset_from_bottom"
    }
}
