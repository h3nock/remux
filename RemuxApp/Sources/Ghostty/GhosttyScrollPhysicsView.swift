import QuartzCore
import UIKit

enum GhosttyScrollTuning {
    /// Wheel steps per row of finger travel on the forwarded routes. At 1 a
    /// program that scrolls one row per step moves with the finger; what a
    /// step scrolls is the program's choice.
    static let routeForwardedDefaultGain: CGFloat = 1

    /// Gain from finger travel to wheel steps on the forwarded routes.
    /// `REMUX_SCROLL_PRECISE_GAIN` overrides for on-device feel experiments
    /// (clamped; same read-once pattern as the REMUX_TRACE_* flags).
    static let routeForwardedGain: CGFloat = {
        let fallback = routeForwardedDefaultGain
        guard
            let raw = ProcessInfo.processInfo.environment["REMUX_SCROLL_PRECISE_GAIN"],
            let value = Double(raw), value.isFinite
        else {
            return fallback
        }
        let clamped = CGFloat(min(max(value, 0.5), 4))
        NSLog("Remux scrollTuning preciseGain=%.2f (env override)", clamped)
        return clamped
    }()
}

/// Scroll physics driver for route-forwarded scrolling.
///
/// A hit-test transparent UIScrollView with a large virtual content area.
/// Its pan gesture and native deceleration produce contentOffset changes that
/// the container converts into precise scroll events, including the momentum
/// tail after the finger lifts. It renders nothing; the container hosts its
/// pan gesture recognizer.
final class GhosttyScrollPhysicsView: UIScrollView {
    /// Virtual travel available on each side of the centered offset. A fling
    /// that reached an edge would bounce back and send steps the finger never
    /// asked for. UIKit coasts about the release speed times half a second
    /// (its 0.998-per-millisecond decay), so this covers any flick by far.
    private static let virtualTravelEachWay: CGFloat = 100_000

    /// Touches pass through to the surface view; this view only exists
    /// so UIKit scroll physics run.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    var centeredContentOffsetY: CGFloat {
        max(0, (contentSize.height - bounds.height) / 2)
    }

    func synchronizeVirtualContent() {
        let size = CGSize(
            width: max(bounds.width, 1),
            height: max(bounds.height, 1) + 2 * Self.virtualTravelEachWay
        )
        guard contentSize != size else { return }
        contentSize = size
    }
}

/// Detects when a deceleration has slowed below the cell-quantization
/// floor. Native scrolling coasts to sub-pixel speeds, but forwarded
/// scrolling emits whole cells: below a couple of cells per second the
/// tail degenerates into isolated ticks hundreds of milliseconds apart
/// — perceived as jitter, not motion. Velocity is smoothed with an
/// exponential moving average so a single short frame cannot trigger
/// a premature stop.
struct GhosttyScrollTailCutoff {
    /// Smoothed speed below which the coast is pure noise, in cells
    /// per second. Discrete whole-cell steps read as motion at ~6+
    /// ticks/s; slower than that the tail is stutter, not glide.
    static let minimumCellsPerSecond: Double = 6

    private let smoothing: Double
    private var smoothedSpeed: Double?
    private var lastSampleTime: TimeInterval?

    init(smoothing: Double = 0.3) {
        self.smoothing = min(max(smoothing, 0.01), 1)
    }

    /// Feed one offset delta (points) observed at `now`; returns true
    /// when the smoothed speed has fallen below the floor.
    mutating func shouldStop(
        delta: Double,
        at now: TimeInterval,
        cellHeightPoints: Double
    ) -> Bool {
        defer { lastSampleTime = now }
        guard let lastSampleTime else { return false }
        let dt = now - lastSampleTime
        guard dt > 0, cellHeightPoints > 0 else { return false }

        let speed = abs(delta) / dt
        let smoothed = (smoothedSpeed ?? speed) * (1 - smoothing) + speed * smoothing
        smoothedSpeed = smoothed
        return smoothed < Self.minimumCellsPerSecond * cellHeightPoints
    }

    mutating func reset() {
        smoothedSpeed = nil
        lastSampleTime = nil
    }
}

/// Token-bucket cap on route-forwarded scroll throughput, in gesture
/// translation units (points). A violent fling decelerates from very
/// high velocity; without a cap one gesture could enqueue an unbounded
/// stream of wheel reports, each of which costs the remote TUI a full
/// repaint. Excess delta is dropped, not deferred: flicks saturate at
/// the cap instead of stretching the scroll out in time.
struct GhosttyScrollDeltaBudget {
    /// Burst window. A longer window lets a hard flick emit dozens of
    /// one-line ticks at once before steady-rate pacing starts; 0.08 s
    /// limits that to a few lines without noticeable start latency.
    static let defaultBurstSeconds: Double = 0.08

    private(set) var unitsPerSecond: Double
    private let burstSeconds: Double
    private var available: Double
    private var lastRefill: TimeInterval?

    init(unitsPerSecond: Double, burstSeconds: Double = Self.defaultBurstSeconds) {
        self.unitsPerSecond = max(unitsPerSecond, 0)
        self.burstSeconds = max(burstSeconds, 0)
        self.available = self.unitsPerSecond * self.burstSeconds
        self.lastRefill = nil
    }

    /// Clamp a signed delta against the remaining budget, refilled by
    /// the time elapsed since the previous call.
    mutating func clamp(_ delta: Double, at now: TimeInterval) -> Double {
        let capacity = unitsPerSecond * burstSeconds
        if let lastRefill {
            let elapsed = max(0, now - lastRefill)
            available = min(available + elapsed * unitsPerSecond, capacity)
        }
        lastRefill = now

        guard delta != 0, available > 0 else { return 0 }
        let magnitude = min(abs(delta), available)
        available -= magnitude
        return delta < 0 ? -magnitude : magnitude
    }

    /// Re-arm for a new gesture with a freshly computed rate (the cap
    /// depends on the surface's cell height, which can change).
    mutating func rearm(unitsPerSecond: Double) {
        self.unitsPerSecond = max(unitsPerSecond, 0)
        self.available = self.unitsPerSecond * burstSeconds
        self.lastRefill = nil
    }
}

/// How far a program moved what it draws, read from two copies of the viewport's rows.
enum GhosttyViewportShift: Equatable {
    /// Every row is the same.
    case unchanged
    /// Rows moved down by this many rows (negative: up).
    case moved(Int)
    /// Some rows were redrawn where they are and nothing moved (a spinner, a clock).
    case redrawn
    /// The copies differ in a way that can't be read yet: a frame the program has half repainted, or content
    /// that has nothing in common with the last copy. Read again against the same earlier copy.
    case unclear

    /// Rows that appear once in each copy say how far they moved. A movement counts when at least three rows
    /// agree on it, twice as many as on any other movement, and twice as many as the rows still in place that
    /// have not stayed in place through an earlier movement (`staticRows`: a program's header, input box, status
    /// line). A frame the program has only half repainted fails the last test; counting it and then the finished
    /// frame would count the distance twice. The copies leave out blank rows at the end, so they can differ in
    /// length.
    static func between(
        _ old: [Substring],
        _ new: [Substring],
        staticRows: inout Set<Int>
    ) -> GhosttyViewportShift {
        if old == new { return .unchanged }

        func uniqueRows(_ rows: [Substring]) -> [Substring: Int] {
            var index: [Substring: Int] = [:]
            var repeated: Set<Substring> = []
            for (row, text) in rows.enumerated() {
                // Blank cells after a row's text are how the row was painted, not what it shows: an erased cell
                // reads as nothing and a written space as a space, and a pane restored from tmux's capture ends
                // its rows in spaces that the same rows painted live don't have.
                let text = text[..<(text.lastIndex(where: { $0 != " " }).map(text.index(after:)) ?? text.startIndex)]
                guard !text.isEmpty else { continue }
                if index.updateValue(row, forKey: text) != nil { repeated.insert(text) }
            }
            for text in repeated { index[text] = nil }
            return index
        }

        let oldRows = uniqueRows(old)
        let newRows = uniqueRows(new)
        var votes: [Int: Int] = [:]
        var inPlace: [Int] = []
        for (text, row) in newRows {
            guard let oldRow = oldRows[text] else { continue }
            votes[row - oldRow, default: 0] += 1
            if row == oldRow { inPlace.append(row) }
        }

        let moving = votes.filter { $0.key != 0 }.sorted { $0.value > $1.value }
        let unexplainedInPlace = inPlace.filter { !staticRows.contains($0) }.count
        if let best = moving.first,
           best.value >= 3,
           best.value >= 2 * (moving.dropFirst().first?.value ?? 0),
           best.value >= 2 * unexplainedInPlace {
            staticRows.formUnion(inPlace)
            return .moved(best.key)
        }
        let somethingMoved = (moving.first?.value ?? 0) >= 3
        return !somethingMoved && 2 * inPlace.count >= newRows.count ? .redrawn : .unclear
    }
}

/// Makes a program's content follow a target position on the forwarded mouse route.
///
/// A wheel report asks a program to scroll; how far it goes is the program's choice (one row, three rows, or more
/// when reports arrive close together). So the finger's travel alone can't say how many reports to send. This
/// sends a report whenever the target (finger travel plus UIKit's coast, in rows) is ahead of where the content
/// is seen to be, counting the reports still on their way at the rows-per-report the program has shown so far.
/// Content is never pulled back against the direction of travel: when a program overshoots, the target catches up.
///
/// When reports land and nothing is seen to move (the program is at its first or last row, or what it shows
/// can't be compared), each one counts as one row, which is the plain one-report-per-row rule. That rule is also
/// the ceiling: seeing the content only ever holds reports back, so a picture that arrives late, or can't be
/// read, never costs more reports than a row of travel each.
struct GhosttyScrollFollow {
    private struct Report {
        let sentAt: TimeInterval
        let direction: Double
    }

    /// Reports that land without movement before they start to count as one row each.
    private static let stalledReportCount = 4
    /// How long unclear frames are read against the last clear one before the newest takes its place.
    private static let unreadableFrameWindow: TimeInterval = 0.15

    private let reportsPerSecond: Double
    private let burstReports: Double
    private var availableReports: Double
    private var lastRefill: TimeInterval?

    private var reports: [Report] = []
    private var landedCount = 0
    /// When a report was sent with none on its way: the next movement times the round trip.
    private var probeSentAt: TimeInterval?
    private var unmovedCount = 0
    private var unmovedSince: TimeInterval?
    private var lastMovedAt: TimeInterval?
    private var stallCounted = 0
    private var stallCredit = 0.0
    private var stalledReports = 0
    private var movedRows = 0.0
    private var recentRowsPerReport = 1.0
    private var history: [(at: TimeInterval, movedRows: Double, landed: Int)] = []
    private var travelDirection = 0.0
    private var travelledRows = 0.0

    private var reference: [Substring]?
    private var referenceText: String?
    private var staticRows: Set<Int> = []
    private var unreadableSince: TimeInterval?

    /// Finger travel plus coast since the gesture began, in rows; positive scrolls toward earlier content.
    private(set) var targetRows = 0.0
    /// Rows the content has been seen to move since the gesture began, same sign.
    private(set) var seenRows = 0.0
    /// Rows per report the program has shown.
    private(set) var rowsPerReport = 1.0
    /// Seconds from sending a report to seeing the content move.
    private(set) var latency: TimeInterval

    init(reportsPerSecond: Double, burstSeconds: Double, latency: TimeInterval) {
        self.reportsPerSecond = max(reportsPerSecond, 1)
        self.burstReports = max(self.reportsPerSecond * burstSeconds, 1)
        self.availableReports = self.burstReports
        self.latency = min(max(latency, 0.02), 0.4)
    }

    var reportCount: Int { reports.count }

    mutating func moveTarget(byRows rows: Double) {
        guard rows != 0 else { return }
        targetRows += rows
        travelledRows += abs(rows)
        travelDirection = rows > 0 ? 1 : -1
    }

    /// Give the viewport's rows as they are now. `nil` when they can't be read.
    mutating func observe(viewportRows text: String?, at now: TimeInterval) {
        var moved = 0.0
        if let text, text != referenceText {
            let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let reference {
                switch GhosttyViewportShift.between(reference, rows, staticRows: &staticRows) {
                case .unchanged:
                    unreadableSince = nil
                case let .moved(shift):
                    moved = Double(shift)
                    setReference(rows, text)
                case .redrawn:
                    setReference(rows, text)
                case .unclear:
                    if let unreadableSince {
                        if now - unreadableSince >= Self.unreadableFrameWindow { setReference(rows, text) }
                    } else {
                        unreadableSince = now
                    }
                }
            } else {
                setReference(rows, text)
            }
        }
        account(moved: moved, at: now)
    }

    /// The direction of the report to send now (+1 toward earlier content, -1 toward later), or 0 for none.
    /// A non-zero answer is recorded as sent.
    mutating func nextReport(at now: TimeInterval) -> Int {
        if let lastRefill {
            availableReports = min(availableReports + max(0, now - lastRefill) * reportsPerSecond, burstReports)
        }
        lastRefill = now
        guard availableReports >= 1, Double(reports.count) + 1 <= travelledRows else { return 0 }

        // A program that moves further when reports come close together shows it in the last few reports before
        // it shows in the gesture's average, so reports on their way count at the larger of the two.
        let inFlight = reports[landedCount...].reduce(0) { $0 + $1.direction }
        let behind = targetRows - (seenRows + stallCredit) - inFlight * max(rowsPerReport, recentRowsPerReport)
        let threshold = (rowsPerReport + 1) / 2
        let direction: Double
        if behind >= threshold, travelDirection > 0 {
            direction = 1
        } else if behind <= -threshold, travelDirection < 0 {
            direction = -1
        } else {
            return 0
        }
        availableReports -= 1
        if landedCount == reports.count, probeSentAt == nil {
            probeSentAt = now
        }
        reports.append(Report(sentAt: now, direction: direction))
        return Int(direction)
    }

    /// True once every report has had time to land and the content is within a step of the target.
    func isSettled(at now: TimeInterval) -> Bool {
        guard landedCount == reports.count else { return false }
        return abs(targetRows - (seenRows + stallCredit)) < (rowsPerReport + 1) / 2
    }

    private mutating func setReference(_ rows: [Substring], _ text: String) {
        reference = rows
        referenceText = text
        unreadableSince = nil
    }

    private mutating func account(moved: Double, at now: TimeInterval) {
        var newlyLanded = 0
        while landedCount < reports.count, now - reports[landedCount].sentAt >= latency * 1.25 + 0.008 {
            landedCount += 1
            newlyLanded += 1
        }

        if moved != 0 {
            if let probeSentAt {
                let sample = now - probeSentAt
                latency = min(max(sample > latency ? sample : 0.7 * latency + 0.3 * sample, 0.02), 0.4)
                self.probeSentAt = nil
            }
            seenRows += moved
            movedRows += abs(moved)
            if stallCredit != 0, (moved > 0) == (stallCredit > 0) {
                let cancelled = min(abs(stallCredit), abs(moved))
                stallCredit -= stallCredit > 0 ? cancelled : -cancelled
                stalledReports = max(0, stalledReports - Int(cancelled.rounded()))
            }
            unmovedCount = 0
            unmovedSince = nil
            stallCounted = 0
            lastMovedAt = now
        } else {
            // A report sent before the last movement may be what moved it, so only those sent since count as unmoved.
            for report in reports[(landedCount - newlyLanded)..<landedCount]
            where lastMovedAt.map({ report.sentAt >= $0 }) ?? true {
                if unmovedSince == nil { unmovedSince = report.sentAt }
                unmovedCount += 1
            }
        }

        // Reports that have had well over a round trip and moved nothing: the program is at its first or last
        // row, or what it draws can't be compared. Each counts as one row from here on.
        if unmovedCount >= Self.stalledReportCount,
           let unmovedSince, now - unmovedSince >= 2.5 * latency + 0.05 {
            let fresh = unmovedCount - stallCounted
            stallCredit += Double(fresh) * reports[landedCount - 1].direction
            stalledReports += fresh
            stallCounted = unmovedCount
        }

        let effective = landedCount - stalledReports
        if movedRows > 0, effective > 0 {
            rowsPerReport = min(max(movedRows / Double(effective), 0.25), 20)
        }

        history.append((now, movedRows, effective))
        let window = max(0.2, 3 * latency)
        while let first = history.first, now - first.at > window, history.count > 1 {
            history.removeFirst()
        }
        if let first = history.first, effective - first.landed >= 2 {
            recentRowsPerReport = min(max((movedRows - first.movedRows) / Double(effective - first.landed), 0.25), 20)
        } else {
            recentRowsPerReport = rowsPerReport
        }
    }
}
