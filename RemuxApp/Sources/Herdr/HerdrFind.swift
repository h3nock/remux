import Foundation

struct HerdrFindPoint: Codable, Equatable, Comparable, Sendable {
    let row: UInt32
    let col: UInt16
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.row, lhs.col) < (rhs.row, rhs.col) }
}

struct HerdrFindRange: Codable, Equatable, Sendable {
    let start: HerdrFindPoint
    let end: HerdrFindPoint
}

struct HerdrFindRequest: Encodable, Sendable {
    let pane_id: String
    let query: String
    let direction: String
    let cursor: HerdrFindPoint
    let content_revision: UInt64
    let previous: HerdrFindRange?
}

struct HerdrFindResult: Decodable, Sendable {
    let type: String
    let pane_id: String
    let content_revision: UInt64
    let matches: [HerdrFindRange]
    let total: Int
    let current: Int?
    let current_global: Int?

    var windowStart: Int { (current_global ?? 0) - (current ?? 0) }

    static func decode(_ data: Data, request: HerdrFindRequest, columns: UInt16) throws -> Self {
        struct Reply: Decodable { let result: HerdrFindResult }
        let value = try JSONDecoder().decode(Reply.self, from: data).result
        guard value.type == "pane_copy_search", value.pane_id == request.pane_id,
              value.content_revision == request.content_revision,
              value.content_revision.isMultiple(of: 2), value.total >= 0,
              value.matches.count <= 1024, value.matches.count <= value.total
        else { throw HerdrFindError.invalidReply }
        if value.total == 0 {
            guard value.matches.isEmpty, value.current == nil, value.current_global == nil
            else { throw HerdrFindError.invalidReply }
        } else {
            guard let current = value.current, value.matches.indices.contains(current),
                  let global = value.current_global, global >= current, global < value.total,
                  value.windowStart <= value.total - value.matches.count
            else { throw HerdrFindError.invalidReply }
        }
        var previous: HerdrFindRange?
        for range in value.matches {
            guard range.start <= range.end, range.start.col < columns, range.end.col < columns,
                  previous.map({ $0.end < range.start }) ?? true
            else { throw HerdrFindError.invalidReply }
            previous = range
        }
        return value
    }
}

enum HerdrFindError: Error { case invalidReply }

enum HerdrFindCommand: Sendable {
    case search(generation: UInt64, request: HerdrFindRequest?, content: HerdrPaneContent?)
    case reveal(generation: UInt64)
    var generation: UInt64 {
        switch self { case .search(let id, _, _), .reveal(let id): id }
    }
    var method: String {
        switch self { case .search: "pane.copy_search"; case .reveal: "pane.scroll" }
    }
}

/// One active query on one connection. History and matching remain server-owned.
struct HerdrFindState: Sendable {
    let paneID: String
    let bootID: String
    var generation: UInt64
    var query = ""
    var origin: HerdrFindPoint?
    var content: HerdrPaneContent?
    var result: HerdrFindResult?
    var desiredIndex: Int?
    var direction = 1
    var needsReveal = false
    var waitingRevision: UInt64?
    var waitsForQuiet = false
    var retryAvailable = true
    var isDue = false
    var presentation = TerminalFindPresentation()
    var decorationToken: UInt64 = 0

    var selected: Int? {
        guard let result, let desiredIndex else { return nil }
        let index = desiredIndex - result.windowStart
        return result.matches.indices.contains(index) ? index : nil
    }

    var selectedRange: HerdrFindRange? { selected.flatMap { result?.matches[$0] } }

    mutating func invalidate() {
        result = nil
        desiredIndex = nil
        decorationToken &+= 1
        presentation = TerminalFindPresentation(status: query.isEmpty ? "" : "Searching…")
    }

    mutating func showResult() {
        guard let result else { return }
        decorationToken &+= 1
        presentation = TerminalFindPresentation(
            status: result.total == 0 ? "0" : selected.map { "\(result.windowStart + $0 + 1) of \(result.total)" } ?? "Searching…",
            // Keep accepting desired steps while the next bounded window is fetched.
            canNavigate: result.total > 0
        )
    }

    func request(for content: HerdrPaneContent) -> HerdrFindRequest {
        let edge: HerdrFindRange? = result.flatMap { direction > 0 ? $0.matches.last : $0.matches.first }
        let anchor = origin ?? HerdrFindPoint(row: UInt32(clamping: content.top), col: 0)
        // Herdr searches strictly after the cursor. A fresh scan should include its
        // anchor; `previous` is reserved for stepping beyond a cached window.
        let before = anchor.col > 0 ? HerdrFindPoint(row: anchor.row, col: anchor.col - 1)
            : anchor.row > 0 ? HerdrFindPoint(row: anchor.row - 1, col: content.columns - 1) : anchor
        return HerdrFindRequest(
            pane_id: paneID, query: query, direction: edge != nil && direction < 0 ? "backward" : "forward",
            cursor: edge.map { direction > 0 ? $0.end : $0.start }
                ?? before,
            content_revision: content.revision, previous: edge
        )
    }
}

/// Derived viewport decoration; source cells and native user selection are unchanged.
struct HerdrFindDecoration: Equatable, Sendable {
    struct Span: Sendable {
        let start: Int
        let end: Int
        let selected: Bool
    }
    let generation: UInt64
    let token: UInt64
    let top: UInt64
    let rows: [Int: [Span]]

    init?(find: HerdrFindState?, content: HerdrPaneContent?) {
        guard let find, let content, let result = find.result,
              result.content_revision == content.revision else { return nil }
        generation = find.generation; token = find.decorationToken; top = content.top
        let bottom = content.top + UInt64(content.rows)
        var rows: [Int: [Span]] = [:]
        for (index, match) in result.matches.enumerated() {
            if UInt64(match.start.row) >= bottom { break }
            guard UInt64(match.end.row) >= top else { continue }
            for row in max(top, UInt64(match.start.row))..<min(bottom, UInt64(match.end.row) + 1) {
                rows[Int(row - top), default: []].append(Span(
                    start: row == UInt64(match.start.row) ? Int(match.start.col) : 0,
                    end: row == UInt64(match.end.row) ? Int(match.end.col) : Int(content.columns) - 1,
                    selected: index == find.selected
                ))
            }
        }
        self.rows = rows
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.token == rhs.token && lhs.top == rhs.top
    }
}

/// Ordered with the session's other operations, including any input queued before Find opens.
enum HerdrFindIntent: Sendable {
    case begin(String)
    case query(String)
    case navigate(Int)
    case end
    case resumeInput
}

extension HerdrInputEvent {
    var isHistoryWheel: Bool {
        guard case .mouse(let mouse) = self else { return false }
        return switch mouse.kind { case .scrollUp, .scrollDown: true; default: false }
    }
}
