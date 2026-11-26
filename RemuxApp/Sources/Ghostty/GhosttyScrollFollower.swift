import Foundation

/// Where a mouse-reporting pane's viewport sits in what it shows, from the text of its rows alone, for one scroll
/// session.
///
/// The ledger remembers where pieces of text sit in the transcript and places each new copy of the viewport by the
/// pieces it shares with them. A piece is a nonblank row whose text occurs once in the copy. tmux forwards a repaint
/// in pieces and not every program marks its frames, so a copy can be half drawn:
/// - A piece is believed only after two copies in a row showed it where the content's movement says it should be,
///   so the stale half of a half-drawn copy teaches nothing false.
/// - A position is one the pieces agree on two to one, counting those that stayed; otherwise the copy is declined
///   and the next one decides.
/// - A piece that contradicts two placed copies in a row is dropped for the session: text that recurs in the
///   transcript, or chrome among the scrolling rows.
struct GhosttyScrollLedger {
    /// The transcript index of the viewport's first row. It grows as the content moves toward later rows.
    private(set) var offset = 0
    /// The first and last screen rows seen moving; rows outside it are chrome.
    private(set) var band: ClosedRange<Int>?

    private var place: [String: Int] = [:]
    private var pending: [String: Int] = [:]
    private var doubted: Set<String> = []
    private var banned: Set<String> = []
    private var started = false
    private var lastPieceCount = 0
    private var lastCopy: [String]?
    /// The last placed copy at another position than the current one, and that position.
    private var anchor: (copy: [String], offset: Int)?

    private static let minimumVotes = 2

    init(band: ClosedRange<Int>?) {
        self.band = band
    }

    /// A copy of the viewport as the ledger reads it, from its text as `GhosttyPaneRowsEvent` reports it: one string
    /// per row of a grid `gridRows` tall, trailing spaces dropped. The text leaves out rows at the end that hold
    /// nothing.
    static func rows(fromViewportText text: String, gridRows: Int) -> [String] {
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(gridRows).map { line in
            String(line[..<(line.lastIndex { $0 != " " }.map(line.index(after:)) ?? line.startIndex)])
        }
        rows.append(contentsOf: repeatElement("", count: max(gridRows - rows.count, 0)))
        return rows
    }

    /// Places a copy of the viewport, one string per grid row. True when its position is known: `offset` is then
    /// current, whether the content moved or not.
    mutating func locate(_ rows: [String]) -> Bool {
        let span = rowSpan(rows)
        if let lastCopy, lastCopy.count == rows.count, !span.isEmpty, lastCopy[span] == rows[span] {
            grow(rows)
            return true
        }
        let placed = place(rows)
        if placed {
            grow(rows)
            lastCopy = rows
        }
        return placed
    }

    /// Nothing in this copy is known: carry on from an assumed position.
    mutating func restart(_ rows: [String], offset: Int) {
        place = [:]
        pending = [:]
        doubted = []
        self.offset = offset
        for (row, piece) in pieces(rows) where !banned.contains(piece) {
            place[piece] = offset + row
        }
        lastPieceCount = place.count
        lastCopy = rows
        anchor = nil
    }

    private func rowSpan(_ rows: [String]) -> Range<Int> {
        let lower = max(band?.lowerBound ?? 0, 0)
        let upper = min(band?.upperBound ?? rows.count - 1, rows.count - 1)
        return lower <= upper ? lower..<(upper + 1) : 0..<0
    }

    private func pieces(_ rows: [String]) -> [(row: Int, piece: String)] {
        let span = rowSpan(rows)
        var counts: [String: Int] = [:]
        for row in span where !rows[row].isEmpty {
            counts[rows[row], default: 0] += 1
        }
        return span.compactMap { row in
            let text = rows[row]
            return !text.isEmpty && counts[text] == 1 ? (row, text) : nil
        }
    }

    private mutating func place(_ rows: [String]) -> Bool {
        let pieces = pieces(rows)
        guard started else {
            started = true
            for (row, piece) in pieces {
                place[piece] = row
            }
            lastPieceCount = pieces.count
            return true
        }

        // Votes in the order positions are first proposed, so a tie goes to the first, as it does in the design's
        // reference model.
        var order: [Int] = []
        var votes: [Int: Int] = [:]
        var rowsVoting: [Int: [Int]] = [:]
        for (row, piece) in pieces {
            guard let index = place[piece] else { continue }
            let position = index - row
            if votes[position] == nil { order.append(position) }
            votes[position, default: 0] += 1
            rowsVoting[position, default: []].append(row)
        }
        // Until this pane has been seen to scroll once, nothing says which rows are chrome, and chrome always votes
        // "didn't move": there, rows that moved decide alone. Afterwards chrome is outside the band and every piece
        // votes, so a copy that is only partly redrawn stays where the larger part says.
        let moved = order.filter { $0 != offset }
        let pool = band == nil && !moved.isEmpty ? moved : order
        guard !pool.isEmpty else { return false }
        var ranked = pool.enumerated().sorted { lhs, rhs in
            let lhsVotes = votes[lhs.element] ?? 0
            let rhsVotes = votes[rhs.element] ?? 0
            return lhsVotes != rhsVotes ? lhsVotes > rhsVotes : lhs.offset < rhs.offset
        }.map(\.element)
        let best = ranked.removeFirst()
        let bestVotes = votes[best] ?? 0
        let rivalVotes = ranked.first.flatMap { votes[$0] } ?? 0
        let needed = band == nil ? Self.minimumVotes : max(Self.minimumVotes, pieces.count / 8)
        guard bestVotes >= needed, bestVotes >= 2 * rivalVotes else { return false }

        if best == offset {
            // Too little is where it was: the content went further than the copies overlap, or something else was
            // drawn over it.
            guard bestVotes * 2 >= lastPieceCount else { return false }
        } else {
            // The rows that scroll: where the moved pieces are now, and where the last copy really showed them.
            let shift = best - offset
            let previous = lastCopy ?? []
            let now = rowsVoting[best] ?? []
            let before = now.map { $0 + shift }.filter { row in
                previous.indices.contains(row) && previous[row] == rows[row - shift]
            }
            let seen = now + before
            if let lower = seen.min(), let upper = seen.max() {
                band = band.map { min(lower, $0.lowerBound)...max(upper, $0.upperBound) } ?? lower...upper
            }
            anchor = (previous, offset)
            offset = best
        }

        // A piece that says otherwise twice in a row is not evidence. Once is forgiven: the stale half of a
        // half-drawn copy says otherwise once.
        var contrary: Set<String> = []
        for (row, piece) in pieces {
            if let index = place[piece], index - row != offset { contrary.insert(piece) }
        }
        for piece in contrary.intersection(doubted) {
            place[piece] = nil
            banned.insert(piece)
        }
        doubted = contrary.subtracting(banned)

        // Believe the pieces the last copy proposed that this one confirms; propose this copy's new ones.
        var proposed: [String: Int] = [:]
        for (row, piece) in pieces where place[piece] == nil && !banned.contains(piece) {
            let index = offset + row
            if pending[piece] == index {
                place[piece] = index
            } else {
                proposed[piece] = index
            }
        }
        pending = proposed
        lastPieceCount = pieces.count
        return true
    }

    /// The band takes in any row, in it or not, whose text the copy before the last move showed once, shifted by just
    /// as far as the content has moved since. A band learned from a half-drawn copy is only its redrawn rows; the
    /// next copy that shows the rest of them shifted widens it.
    private mutating func grow(_ rows: [String]) {
        guard let anchor else { return }
        let shift = offset - anchor.offset
        let counts = Self.counts(rows)
        let anchorCounts = Self.counts(anchor.copy)
        let slid = rows.indices.filter { row in
            let text = rows[row]
            return !text.isEmpty && counts[text] == 1 && anchorCounts[text] == 1
                && anchor.copy.indices.contains(row + shift) && anchor.copy[row + shift] == text
        }
        let rowsSlid = slid + slid.map { $0 + shift }
        guard let lower = rowsSlid.min(), let upper = rowsSlid.max() else { return }
        band = band.map { min(lower, $0.lowerBound)...max(upper, $0.upperBound) } ?? lower...upper
    }

    private static func counts(_ rows: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in rows { counts[text, default: 0] += 1 }
        return counts
    }
}

/// Follows a touch scroll over a program that reads the mouse by measuring what the program did.
///
/// The hidden scroll view's travel, in rows, is the target. The program decides what a wheel report does, and the
/// same reports move Claude Code between one and several rows each depending on a few milliseconds of timing, so the
/// follower reads the viewport, works out how far the content has moved, and sends the next reports from the
/// difference. One batch is out at a time: the next goes only once the last was seen to act or seen not to, so a
/// program that stalls, drops or multiplies reports can't make it send the same travel twice.
///
/// While the finger or the coast moves on, a batch to a program that has shown it moves a fixed number of rows per
/// report, however close together the reports come, is extended as the target moves: what is in flight is then what
/// one round trip carries, not one batch, and the content trails the scroll view by about one round trip. A program
/// gets a trial of two closely spaced sends first and full extensions only once the trial came in whole; it never
/// gets any again once an extended batch moved more than it was sent.
///
/// Travel is positive toward earlier rows, as a finger moving down the glass drags the transcript.
struct GhosttyScrollFollower {
    /// What the follower knows of the pane's program, kept between sessions while the pane stays on the
    /// mouse-report route.
    struct Memory {
        /// Rows per report of a batch sent to the program at rest, by batch size class (1, 2-3, 4-7, 8-15, and so
        /// on).
        var yields: [Int: Double] = [:]
        /// Time from a batch's receipt to its first movement, smoothed.
        var answer: TimeInterval?
        /// The screen rows last seen to scroll.
        var band: ClosedRange<Int>?
        /// Rows per report of the last batch, and when it finished.
        var recent: (rate: Double, at: TimeInterval)?
        /// Whether the program moves what the table says for reports a frame apart, as an extended batch sends them:
        /// nil until a batch extended by a trial of sends came in whole, then true; false for good once an extended
        /// batch moved more than it was sent.
        var pipe: Bool?
        /// Rows of travel the program has been sent and not shown, positive toward earlier rows, and until when they
        /// are taken to be on their way: a program can take reports and draw them only later, with more input.
        /// Movement their way is theirs first, they count as in flight, and nothing is learned while they are out.
        var held = 0
        var heldUntil: TimeInterval = 0

        /// Chrome keeps its place at the pane's edges, so on a resize the band keeps its margins.
        mutating func resize(fromRows old: Int, toRows new: Int) {
            guard let band, old != new else { return }
            let upper = new - 1 - (old - 1 - band.upperBound)
            self.band = upper >= band.lowerBound ? band.lowerBound...upper : nil
        }
    }

    /// A batch of wheel reports to send in one write, at `row` (1-based) of the pane's grid.
    struct Send: Equatable {
        let reports: Int
        /// Toward earlier rows (wheel up).
        let up: Bool
        let row: Int
    }

    enum Step: Equatable {
        /// No session: the container can stop watching the pane.
        case ended
        case live(Send?)
    }

    private struct Batch {
        /// Reports in all its sends.
        var reports: Int
        let up: Bool
        /// Rows per report expected when it was first sent.
        let rate: Double
        var expected: Double
        let row: Int
        /// Rows seen when it was sent, then as of its first receipt: what moved before that was not its doing.
        var start: Int
        let rested: Bool
        /// Known to be answered before its own answer comes (`tick`).
        let vouched: Bool
        /// Reports per send, in the order they went, and the receipts that came back for them.
        var sends: [Int]
        var receipts: [TimeInterval] = []
        var first: TimeInterval?
        var progress: TimeInterval?
        /// Whether it may still be extended.
        var open = true

        var receipt: TimeInterval? { receipts.first }
    }

    /// A batch that moved something is finished once nothing more has moved for two 60 Hz frames.
    static let settle: TimeInterval = 0.033
    /// How long to wait after a receipt for the first answer ever, before any has been timed.
    static let firstWait: TimeInterval = 0.25
    /// Never call a batch unanswered sooner than this after its receipt.
    static let minimumWait: TimeInterval = 0.08
    /// Without reports for this long, the program is taken to be at rest.
    static let rest: TimeInterval = 0.1
    static let maximumBatch = 64
    /// The largest batch sent to a program that is not at rest, and the largest send in an extension trial.
    static let smallBatch = 3
    /// Extension sends a program not yet proven gets: the fewest that show whether reports a frame apart move more
    /// than the same reports at rest.
    static let trialSends = 2
    /// An extension goes at most once per 60 Hz frame, less a quarter for display-link jitter.
    static let spacing: TimeInterval = 0.0125
    /// How long reports a program was sent and hasn't shown are still taken to be on their way.
    static let hold: TimeInterval = 1.0

    private(set) var memory: Memory
    let gridRows: Int

    private var ledger: GhosttyScrollLedger?
    private var batch: Batch?
    private var silent = 0
    private var answeredRow: Int?
    private var unplaced: (rows: [String], since: TimeInterval)?
    private var lastTarget: Double?
    private var heading = 0
    private var targetMoved: TimeInterval = 0
    private var lastSend: TimeInterval?
    private var forgiven: Double = 0
    private var caughtAt: Double?
    private var closing = 0
    private var unaskedAt: TimeInterval?
    /// The last answered batch, whose answer can still be arriving: its direction, and until when.
    private var tail: (up: Bool, until: TimeInterval)?

    init(gridRows: Int, memory: Memory = Memory()) {
        self.gridRows = gridRows
        self.memory = memory
    }

    var isLive: Bool { ledger != nil }

    /// Rows the content has moved since the session began, positive toward earlier rows.
    var seen: Int { -(ledger?.offset ?? 0) }

    /// One display frame. `target` is the scroll view's travel in rows since the session began, `active` whether a
    /// finger or a coast still moves it, `touchRow` the 1-based grid row where the gesture's touch began, and `rows`
    /// the viewport's current copy (needed to start a session).
    mutating func tick(target: Double, active: Bool, touchRow: Int, now: TimeInterval, rows: [String]?) -> Step {
        if ledger == nil {
            guard active, let rows else { return .ended }
            var started = GhosttyScrollLedger(band: memory.band)
            _ = started.locate(rows)
            ledger = started
        }
        if let lastTarget, target != lastTarget {
            heading = target > lastTarget ? 1 : -1
            targetMoved = now
        }
        lastTarget = target
        if memory.held != 0, now >= memory.heldUntil {
            // Not drawn in all this time: lost, at an edge or to the program.
            memory.held = 0
        }
        if batch != nil, !finishBatch(now: now) {
            return .live(active ? extend(target: target, now: now) : nil)
        }
        if let caughtAt {
            // Held reports are still on their way: they are part of where the content stops, not owed.
            forgiven = caughtAt - Double(memory.held) - Double(seen)
            self.caughtAt = nil
        }
        let error = target - forgiven - Double(memory.held) - Double(seen)
        let step = yield(reports: 1, now: now)
        if active {
            closing = 0
        } else if abs(error) < step || silent >= 2 || closing >= 2 {
            // At rest the follower finishes: it lands what one batch can, corrects once, and lets the rest go, so the
            // content never runs on after the scroll view has stopped.
            end()
            return .ended
        }
        let up = error > 0
        if active, heading != 0, (heading > 0) != up, now - targetMoved < Self.rest {
            // The content is ahead and the target is on its way to it.
            return .live(nil)
        }
        let reports = silent > 0 ? (abs(error) >= step ? 1 : 0) : batchSize(owed: abs(error), now: now)
        guard reports > 0 else { return .live(nil) }
        let row = reportRow(touched: touchRow)
        let rested = lastSend.map { now - $0 >= Self.rest } ?? true
        let rate = yield(reports: reports, now: now)
        // A batch is known to be answered before its own answer comes when it follows one answered at the same row,
        // the same way, without a pause; or, for a program proven to take extensions, when it goes to a row the
        // program has been seen to scroll.
        let continues = answeredRow == row && tail.map { $0.up == up && now - $0.until < Self.rest } == true
        let scrolls = memory.pipe == true && memory.band?.contains(row - 1) == true
        batch = Batch(
            reports: reports,
            up: up,
            rate: rate,
            expected: Double(reports) * rate,
            row: row,
            start: seen,
            rested: rested,
            vouched: silent == 0 && (continues || scrolls),
            sends: [reports]
        )
        lastSend = now
        if !active, silent == 0 { closing += 1 }
        return .live(Send(reports: reports, up: up, row: row))
    }

    /// The viewport changed.
    mutating func frame(_ rows: [String], now: TimeInterval) {
        guard ledger != nil else { return }
        let before = seen
        guard place(rows, now: now) else { return }
        let moved = unheld(since: before)
        if moved != 0, batch?.receipt != nil {
            batch?.progress = now
            if batch?.first == nil { batch?.first = now }
        } else if moved != 0 {
            unasked(rows: moved, now: now)
        }
    }

    /// One of the sends of the batch that is out reached the program, in the order they went, with the viewport's
    /// rows as of that moment (nil when they couldn't be read). Whatever moved before the first was not the batch's
    /// doing; what moved before a later one was the earlier sends' answer.
    mutating func receipt(rows: [String]?, now: TimeInterval) {
        guard ledger != nil, let current = batch, current.receipts.count < current.sends.count else { return }
        let before = seen
        var moved = 0
        if let rows, place(rows, now: now) { moved = unheld(since: before) }
        if current.receipts.isEmpty {
            if moved != 0 { unasked(rows: moved, now: now) }
            let position = seen
            batch?.start = position
        } else if moved != 0 {
            batch?.progress = now
            if batch?.first == nil { batch?.first = now }
        }
        batch?.receipts.append(now)
    }

    /// A touch stopped a coast. The content stops too: what the follower still owed is dropped once the batch that
    /// is out has landed.
    mutating func caught(target: Double) {
        guard ledger != nil else { return }
        caughtAt = target
    }

    /// Ends the session, sending nothing more. What was learned about the program is kept.
    mutating func end() {
        ledger = nil
        batch = nil
        silent = 0
        answeredRow = nil
        unplaced = nil
        lastTarget = nil
        heading = 0
        targetMoved = 0
        lastSend = nil
        forgiven = 0
        caughtAt = nil
        closing = 0
        unaskedAt = nil
        tail = nil
    }

    // MARK: One batch

    private mutating func place(_ rows: [String], now: TimeInterval) -> Bool {
        guard var current = ledger else { return false }
        let before = current.offset
        let placed = current.locate(rows)
        ledger = current
        guard placed else {
            unplaced = (rows, unplaced?.since ?? now)
            return false
        }
        unplaced = nil
        memory.band = current.band ?? memory.band
        return current.offset != before
    }

    /// Rows the content moved since `before` that aren't held reports landing; the batch's count leaves those out.
    private mutating func unheld(since before: Int) -> Int {
        var moved = seen - before
        guard memory.held != 0, moved * memory.held > 0 else { return moved }
        let paid = min(abs(moved), abs(memory.held)) * (moved > 0 ? 1 : -1)
        memory.held -= paid
        moved -= paid
        batch?.start += paid
        return moved
    }

    /// The content moved with no batch to account for it: the program's own doing, as a reply streaming in at the live
    /// edge, unless it is the last batch's answer still arriving. It counts toward the target, never past it: movement
    /// the follower didn't ask for must not become travel owed the other way. Nothing is learned for a second.
    private mutating func unasked(rows: Int, now: TimeInterval) {
        if let tail, now <= tail.until, (rows > 0) == tail.up { return }
        unaskedAt = now
        guard let lastTarget else { return }
        let moved = Double(rows)
        let error = lastTarget - forgiven - Double(memory.held) - Double(seen - rows)
        var toward = error * moved > 0 ? moved : 0
        toward = error > 0
            ? max(min(toward, error), -abs(error))
            : min(max(toward, error), abs(error))
        forgiven -= moved - toward
    }

    /// True once the batch that is out has finished, answered or not.
    private mutating func finishBatch(now: TimeInterval) -> Bool {
        guard let current = batch, current.receipts.count == current.sends.count, let receipt = current.receipt,
              let last = current.receipts.last
        else { return false }
        let extended = current.sends.count > 1
        let moved = (seen - current.start) * (current.up ? 1 : -1)
        let wait = answerWait() * pow(2, Double(max(silent - 1, 0)))
        if let unplaced, now - unplaced.since >= Self.settle {
            // The viewport changed past recognition and stayed that way: the batch moved further than the copies
            // overlap. Take it as having moved what was expected, and learn nothing from it.
            let reach = max(Int(current.expected), moved)
            ledger?.restart(unplaced.rows, offset: -(current.start + (current.up ? reach : -reach)))
            self.unplaced = nil
            silent = 0
            batch = nil
            return true
        }
        let quiet = silent > 0 ? wait : Self.settle
        // An answer can come in more than one repaint. A small batch is finished the moment it has moved what was
        // expected; a larger one, or one that did less, once nothing more has moved for `quiet` since its last
        // receipt or movement. What an extended batch, sent to a program proven to move what it is sent, hasn't
        // shown by then is held: on its way, not lost.
        let whole = moved >= Int(current.expected) && current.reports <= Self.smallBatch && silent == 0
        if whole || (moved > 0 && now - max(current.progress ?? last, last) >= quiet) {
            if extended {
                judge(moved: moved, now: now)
                let short = Int(current.expected) - moved
                if short > 0 {
                    let sign = current.up ? 1 : -1
                    memory.held = (memory.held * sign > 0 ? memory.held : 0) + short * sign
                    memory.heldUntil = now + Self.hold
                }
            } else if silent == 0, memory.held == 0, unaskedAt.map({ now - $0 >= 1 }) ?? true {
                let rate = max(1, Double(moved) / Double(current.reports))
                let sizeClass = Self.sizeClass(current.reports)
                // At rest a batch shows what its size does. Not at rest it can only have done as much or more, so it
                // may lower what the table holds, never raise it.
                memory.yields[sizeClass] = current.rested
                    ? rate
                    : min(rate, yield(reports: current.reports, now: nil))
                memory.recent = (rate, now)
                let took = (current.first ?? receipt) - receipt
                memory.answer = memory.answer.map { 0.75 * $0 + 0.25 * took } ?? took
            }
            answeredRow = current.row
            // A program can answer in more than one repaint, and a server can send them a frame apart: what moves the
            // same way within one settle is still this batch's answer, not movement nobody asked for.
            tail = (current.up, now + Self.settle)
            silent = 0
            batch = nil
            return true
        }
        if moved <= 0, now - last >= wait {
            silent += 1
            batch = nil
            return true
        }
        return false
    }

    /// How long after a receipt an answer may still be on its way.
    private func answerWait() -> TimeInterval {
        memory.answer.map { max(Self.minimumWait, 2 * $0) } ?? Self.firstWait
    }

    // MARK: Extending a batch

    /// The rows per report every size class tried has shown, when they all agree and more than one was tried.
    private var steadyRate: Double? {
        let rates = Set(memory.yields.values)
        return memory.yields.count >= 2 && rates.count == 1 ? rates.first : nil
    }

    /// Adds to the batch that is out what the target has moved on since, beyond what is already in flight, when the
    /// program is answering it as the table says. A program not yet seen to take reports a frame apart (`pipe` nil)
    /// gets a trial of a few sends; one that took more than it was sent never gets more (`pipe` false).
    private mutating func extend(target: Double, now: TimeInterval) -> Send? {
        guard let current = batch, current.open, memory.pipe != false, current.rate == steadyRate, silent == 0,
              unplaced == nil, caughtAt == nil, let lastSend, now - lastSend >= Self.spacing,
              current.first != nil || current.vouched
        else { return nil }
        let sign = current.up ? 1 : -1
        let moved = (seen - current.start) * sign
        guard agrees(moved: moved, now: now) else { return nil }
        let wait = answerWait()
        let due = current.rate * Double(zip(current.sends, current.receipts).reduce(0) { sum, sent in
            now - sent.1 >= wait ? sum + sent.0 : sum
        })
        if Double(moved) < due - current.rate {
            // Sends already in haven't shown: an edge, or the program stopped answering.
            batch?.open = false
            return nil
        }
        let owed = (target - forgiven - Double(memory.held) - Double(seen)) * Double(sign)
            - (current.expected - Double(moved))
        let reports: Int
        if memory.pipe == true {
            // Two sends the program reads together must still leave copies the ledger can place; and the table says
            // the program is steady only for the sizes it measured.
            let limit = Double(memory.band.map { $0.count } ?? gridRows / 2) / 2
            let measured = (1 << ((memory.yields.keys.max() ?? 0) + 1)) - 1
            reports = min(Int(owed / current.rate), max(1, Int(limit / 2 / current.rate)), measured)
        } else {
            // The trial sends as the pipe would at a flick's speed: a few reports a frame apart, which is what a
            // program that speeds up with closely spaced reports answers with more.
            reports = current.sends.count - 1 < Self.trialSends ? min(Int(owed / current.rate), Self.smallBatch) : 0
        }
        guard reports > 0 else { return nil }
        batch?.sends.append(reports)
        batch?.reports += reports
        batch?.expected += Double(reports) * current.rate
        self.lastSend = now
        return Send(reports: reports, up: current.up, row: current.row)
    }

    /// Whether an extended batch has moved what was sent, no more. False closes it, and when the program moved more
    /// than it was sent (and nothing unasked moved lately) it is never extended again.
    private mutating func agrees(moved: Int, now: TimeInterval) -> Bool {
        guard let current = batch, current.sends.count > 1, !current.receipts.isEmpty else { return true }
        let sent = current.rate * Double(current.sends.prefix(current.receipts.count).reduce(0, +))
        if Double(moved) > sent + current.rate {
            batch?.open = false
            if unaskedAt.map({ now - $0 >= 1 }) ?? true { memory.pipe = false }
            return false
        }
        return true
    }

    /// A finished extended batch. A trial proves the program only when it moved exactly what was sent, once nothing
    /// more moved, with nothing unasked moving lately: the evidence has to be clean to send ahead on it.
    private mutating func judge(moved: Int, now: TimeInterval) {
        guard agrees(moved: moved, now: now), let current = batch else { return }
        if memory.pipe == nil, current.sends.count - 1 >= Self.trialSends, moved == Int(current.expected),
           unaskedAt.map({ now - $0 >= 1 }) ?? true {
            memory.pipe = true
        }
    }

    /// The 1-based grid row reports go to: where the gesture's touch began, kept within the rows seen to scroll,
    /// until a batch is answered; from then on the row that was answered. A probe after an unanswered batch goes
    /// half as far from the top of those rows (of the pane, when none are known yet), a quarter at most: a
    /// transcript sits above its input box.
    private func reportRow(touched: Int) -> Int {
        if let answeredRow, silent == 0 { return answeredRow }
        let band = memory.band ?? 0...(gridRows - 1)
        let row = min(max(touched - 1, band.lowerBound), band.upperBound)
        return band.lowerBound + (row - band.lowerBound) / (1 << min(silent, 2)) + 1
    }

    // MARK: Sizing

    private static func sizeClass(_ reports: Int) -> Int {
        Int.bitWidth - max(reports, 1).leadingZeroBitCount - 1
    }

    /// Rows per report expected of a batch of `reports` sent now; nil: of one sent at rest.
    private func yield(reports: Int, now: TimeInterval?) -> Double {
        let sizeClass = Self.sizeClass(reports)
        var rate: Double
        if let known = memory.yields[sizeClass] {
            rate = known
        } else {
            // A size class never tried is taken to move twice as much per report as the class below it: a program
            // that speeds up with the rate of reports is met a class at a time, and a steady one costs one cautious
            // batch per class.
            let below = memory.yields.keys.filter { $0 < sizeClass }.max() ?? 0
            rate = (memory.yields[below] ?? 1) * pow(2, Double(sizeClass - below))
        }
        if let now, let recent = memory.recent, now - recent.at < Self.rest {
            // The program isn't at rest: it does at least what it just did.
            rate = max(rate, recent.rate)
        }
        return rate
    }

    /// The largest batch expected to move no more than is owed, and no more than can be recognised. The table
    /// describes the program at rest; one that has just been sent reports gets only the smallest batches, whose
    /// surprises are small.
    private func batchSize(owed: Double, now: TimeInterval) -> Int {
        let limit = Double(memory.band.map { $0.count } ?? gridRows / 2) / 2
        let rested = lastSend.map { now - $0 >= Self.rest } ?? true
        let largest = min(rested ? Self.maximumBatch : Self.smallBatch, Int(owed))
        guard largest > 0 else { return 0 }
        for reports in stride(from: largest, to: 0, by: -1) {
            let rows = Double(reports) * yield(reports: reports, now: now)
            if rows <= owed, rows <= limit || reports == 1 { return reports }
        }
        return 0
    }
}
