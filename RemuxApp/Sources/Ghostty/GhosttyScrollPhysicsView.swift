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

    /// Cap on wheel reports per second for mouse-reporting programs; nil sends
    /// every row of travel. Rex sends one report per row of finger and coast
    /// travel without a cap (300–600 a second after a flick, measured on the
    /// phone). `REMUX_SCROLL_MOUSE_REPORT_CAP` sets a cap for experiments.
    static let mouseReportTicksPerSecondCap: Double? = positiveEnvironmentValue(
        "REMUX_SCROLL_MOUSE_REPORT_CAP"
    )

    /// Coast speed, in rows per second, below which a mouse-report coast is
    /// cut; nil lets UIKit end it. Rex keeps sending until the coast is down to
    /// about one or two rows a second. `REMUX_SCROLL_MOUSE_REPORT_TAIL_CUTOFF`
    /// sets one for experiments.
    static let mouseReportTailCutoffCellsPerSecond: Double? = positiveEnvironmentValue(
        "REMUX_SCROLL_MOUSE_REPORT_TAIL_CUTOFF"
    )

    private static func positiveEnvironmentValue(_ name: String) -> Double? {
        guard
            let raw = ProcessInfo.processInfo.environment[name],
            let value = Double(raw), value.isFinite, value > 0
        else {
            return nil
        }
        NSLog("Remux scrollTuning %@=%.2f (env override)", name, value)
        return value
    }
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
    /// (its 0.998-per-millisecond decay); the fastest synthetic flick measured
    /// on the simulator coasted about 17,000 pt.
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
    private let cellsPerSecondFloor: Double
    private var smoothedSpeed: Double?
    private var lastSampleTime: TimeInterval?

    init(smoothing: Double = 0.3, cellsPerSecondFloor: Double = Self.minimumCellsPerSecond) {
        self.smoothing = min(max(smoothing, 0.01), 1)
        self.cellsPerSecondFloor = max(cellsPerSecondFloor, 0)
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
        return smoothed < cellsPerSecondFloor * cellHeightPoints
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
