import Foundation

enum GhosttyRuntimeTrace {
    static let paneSwitchFlow = "tmux.paneSwitch"
    static let isEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_IO"] == "1"
    private static let latencyMode = ProcessInfo.processInfo.environment["REMUX_TRACE_LATENCY"]
    static let latencyEnabled = latencyMode == "1" || latencyMode == "minimal"
    private static let verboseLatencyEnabled = latencyMode == "1"
    static let diagnosticsEnabled = isEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_GHOSTTY_DIAGNOSTICS"] == "1"
    static let perfEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_PERF"] == "1"
    static let tmuxViewportEnabled = ProcessInfo.processInfo.environment["REMUX_TRACE_TMUX_VIEWPORT"] == "1"

    private static let latencyProbeStore = GhosttyLatencyProbeStore()
    private static let latencyMarkerAccumulator = GhosttyLatencyMarkerAccumulator()
    private static let flowTraceStore = GhosttyFlowTraceStore()

    static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Wall-clock nanoseconds used only to correlate Remux milestones with
    /// renderer completion timestamps emitted inside libghostty. Durations
    /// continue to use the monotonic clock above.
    static func wallNanos() -> UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_REALTIME, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    static func diagnostics(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        NSLog("Remux diag %@", message())
    }

    /// Lightweight perf signpost. Gated on REMUX_TRACE_PERF=1 so it's a true
    /// no-op (and the message autoclosure is not evaluated) in normal builds.
    /// `thread` is captured because some Ghostty callbacks fire off-main and
    /// we want to see which queue is actually doing the work.
    static func perf(_ message: @autoclosure () -> String) {
        guard perfEnabled else { return }
        let threadLabel = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        NSLog("Remux perf t=%llu thread=%@ %@", nowNanos(), threadLabel, message())
    }

    /// Wraps a block, recording its entry thread and elapsed duration when
    /// REMUX_TRACE_PERF=1. Always cheap when disabled; the only cost is one
    /// `nowNanos()` call before invoking the body.
    static func perfMeasure<T>(_ label: @autoclosure () -> String, _ body: () -> T) -> T {
        guard perfEnabled else { return body() }
        let entryThread = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
        let start = nowNanos()
        let result = body()
        NSLog(
            "Remux perf t=%llu thread=%@ %@ elapsed_ms=%@",
            start,
            entryThread,
            label(),
            elapsedMilliseconds(from: start)
        )
        return result
    }

    static func latency(_ message: @autoclosure () -> String) {
        guard latencyEnabled else { return }
        let resolvedMessage = message()
        guard verboseLatencyEnabled || isMinimalLatencyMessage(resolvedMessage) else { return }

        NSLog("Remux latency t=%llu %@", nowNanos(), resolvedMessage)
    }

    static func tmuxViewport(_ message: @autoclosure () -> String) {
        guard tmuxViewportEnabled else { return }
        NSLog("Remux tmuxViewport t=%llu %@", nowNanos(), message())
    }

    static func viewportDescription(_ viewport: TmuxControlViewport) -> String {
        "\(viewport.columns)x\(viewport.rows) px=\(viewport.pixelWidth)x\(viewport.pixelHeight)"
    }

    static func formatTraceFields(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(key)=\(sanitizeTraceValue(fields[key] ?? ""))"
        }.joined(separator: " ")
    }

    private static func sanitizeTraceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func flowBegin(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        startedAt: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let timestamp = startedAt ?? nowNanos()
        flowTraceStore.begin(flow: flow, at: timestamp)
        logFlow(flow, event: event, startedAt: timestamp, at: timestamp, fields: fields())
    }

    static func flowEvent(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.start(for: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEventIfActive(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.start(for: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEventSince(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: startedAt, at: eventTimestamp, fields: fields())
    }

    /// Like `flowEventIfActive`, but logs only the first occurrence of
    /// `event` per flow lifetime — for emission sites that fire
    /// repeatedly (SwiftUI view init, layout passes) where only the
    /// first occurrence is the milestone.
    static func flowEventOnce(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.markOnce(flow: flow, event: event) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEnd(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        let start = flowTraceStore.end(flow: flow) ?? eventTimestamp
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func flowEndIfActive(
        _ flow: String,
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard flowTraceEnabled else { return }
        guard let start = flowTraceStore.end(flow: flow) else { return }
        let eventTimestamp = timestamp ?? nowNanos()
        logFlow(flow, event: event, startedAt: start, at: eventTimestamp, fields: fields())
    }

    static func isFlowActive(_ flow: String) -> Bool {
        guard flowTraceEnabled else { return false }
        return flowTraceStore.start(for: flow) != nil
    }

    static func flowStartIfActive(_ flow: String) -> UInt64? {
        guard flowTraceEnabled else { return nil }
        return flowTraceStore.start(for: flow)
    }

    static func elapsedMilliseconds(from start: UInt64, to end: UInt64 = nowNanos()) -> String {
        String(format: "%.3f", Double(end &- start) / 1_000_000)
    }

    static func registerLatencyProbe(marker: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()
        latencyProbeStore.register(marker: marker, label: label, submittedAt: timestamp)
        latency("probe_register label=\(label) marker=\(marker)")
    }

    static func registerLatencyMarkers(in text: String, label: String, submittedAt: UInt64? = nil) {
        guard latencyEnabled else { return }
        let timestamp = submittedAt ?? nowNanos()

        for marker in latencyMarkerAccumulator.append(text) {
            registerLatencyProbe(marker: marker, label: label, submittedAt: timestamp)
        }
    }

    static func observeInboundData(_ data: Data, source: String) {
        guard latencyEnabled, !data.isEmpty else { return }

        let now = nowNanos()
        let hits = latencyProbeStore.recordHits(in: data)
        for hit in hits {
            latency(
                "probe_hit label=\(hit.label) marker=\(hit.marker) hit=\(hit.hitCount) source=\(source) bytes=\(data.count) offset=\(hit.offset) delta_ms=\(elapsedMilliseconds(from: hit.submittedAt, to: now)) preview=\(preview(data, limit: 160))"
            )
            flowEventIfActive(
                "terminal.input",
                event: "probe.hit",
                fields: [
                    "label": hit.label,
                    "marker": hit.marker,
                    "source": source,
                    "delta_ms": elapsedMilliseconds(from: hit.submittedAt, to: now),
                ],
                at: now
            )
        }
    }

    static func preview(_ data: Data, limit: Int = 48) -> String {
        data
            .prefix(limit)
            .map { byte in
                if byte >= 0x20, byte <= 0x7E {
                    return String(UnicodeScalar(byte))
                }

                return String(format: "\\x%02X", byte)
            }
            .joined()
    }

    private static func isMinimalLatencyMessage(_ message: String) -> Bool {
        message.hasPrefix("probe_") ||
            message.hasPrefix("debugLatencyProbe")
    }

    static let flowTraceEnabled = perfEnabled || latencyEnabled ||
        ProcessInfo.processInfo.environment["REMUX_TRACE_FLOWS"] == "1"

    private static func logFlow(
        _ flow: String,
        event: String,
        startedAt: UInt64,
        at timestamp: UInt64,
        fields: [String: String]
    ) {
        var parts = [
            "flow=\(flow)",
            "event=\(event)",
            "since_ms=\(elapsedMilliseconds(from: startedAt, to: timestamp))",
        ]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(normalizeFieldValue(value))")
        }
        NSLog("Remux flow t=%llu %@", timestamp, parts.joined(separator: " "))
    }

    private static func normalizeFieldValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

enum GhosttyTmuxActionTrace {
    enum Action: Equatable, Sendable {
        case newWindow
        case splitPane

        var flow: String {
            switch self {
            case .newWindow:
                "tmux.newWindow"
            case .splitPane:
                "tmux.splitPane"
            }
        }

    }

    static func traceActiveTopologyFlows(
        event: String,
        fields: @autoclosure () -> [String: String] = [:],
        at timestamp: UInt64? = nil
    ) {
        guard GhosttyRuntimeTrace.flowTraceEnabled else { return }

        var resolvedFields: [String: String]?
        for action in [Action.newWindow, .splitPane] where GhosttyRuntimeTrace.isFlowActive(action.flow) {
            if resolvedFields == nil {
                resolvedFields = fields()
            }
            GhosttyRuntimeTrace.flowEventIfActive(
                action.flow,
                event: event,
                fields: resolvedFields ?? [:],
                at: timestamp
            )
        }
    }
}

final class GhosttyFlowTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: UInt64] = [:]
    private var onceEvents: Set<String> = []

    func begin(flow: String, at timestamp: UInt64) {
        lock.withLock {
            starts[flow] = timestamp
            clearOnceEventsLocked(flow: flow)
        }
    }

    func start(for flow: String) -> UInt64? {
        lock.withLock {
            starts[flow]
        }
    }

    func end(flow: String) -> UInt64? {
        lock.withLock {
            clearOnceEventsLocked(flow: flow)
            return starts.removeValue(forKey: flow)
        }
    }

    /// First occurrence of `event` for an active flow: returns the
    /// flow's start time exactly once per flow lifetime, nil after
    /// (and always nil for inactive flows). A new `begin` re-arms.
    func markOnce(flow: String, event: String) -> UInt64? {
        lock.withLock {
            guard let start = starts[flow] else { return nil }
            guard onceEvents.insert("\(flow)#\(event)").inserted else { return nil }
            return start
        }
    }

    private func clearOnceEventsLocked(flow: String) {
        let prefix = "\(flow)#"
        onceEvents = onceEvents.filter { !$0.hasPrefix(prefix) }
    }
}

final class GhosttyLatencyMarkerAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix = "__REMUX_LATENCY_"
    private let maxBufferedCharacters: Int
    private var buffer = ""

    init(maxBufferedCharacters: Int = 256) {
        self.maxBufferedCharacters = max(32, maxBufferedCharacters)
    }

    func append(_ text: String) -> [String] {
        lock.withLock {
            appendLocked(text)
        }
    }

    private func appendLocked(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        buffer.append(text)
        var markers: [String] = []

        while true {
            guard let prefixRange = buffer.range(of: prefix) else {
                preservePossiblePrefixSuffix()
                return markers
            }

            if prefixRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<prefixRange.lowerBound)
            }

            let markerBodyStart = buffer.index(buffer.startIndex, offsetBy: prefix.count)
            guard let markerEnd = buffer[markerBodyStart...].range(of: "__")?.upperBound else {
                trimUnclosedMarkerIfNeeded()
                return markers
            }

            markers.append(String(buffer[buffer.startIndex..<markerEnd]))
            buffer.removeSubrange(buffer.startIndex..<markerEnd)
        }
    }

    private func preservePossiblePrefixSuffix() {
        let suffixLength = min(buffer.count, prefix.count - 1)
        buffer = String(buffer.suffix(suffixLength))
    }

    private func trimUnclosedMarkerIfNeeded() {
        guard buffer.count > maxBufferedCharacters else { return }
        buffer = String(buffer.suffix(maxBufferedCharacters))
    }
}

final class GhosttyLatencyProbeStore: @unchecked Sendable {
    struct Hit {
        let marker: String
        let label: String
        let submittedAt: UInt64
        let hitCount: Int
        let offset: Int
    }

    private struct Probe {
        let marker: String
        let markerData: Data
        let label: String
        let submittedAt: UInt64
        var hitCount: Int
    }

    private let lock = NSLock()
    private var probes: [String: Probe] = [:]
    private var recentData = Data()

    func register(marker: String, label: String, submittedAt: UInt64) {
        lock.withLock {
            probes[marker] = Probe(
                marker: marker,
                markerData: Data(marker.utf8),
                label: label,
                submittedAt: submittedAt,
                hitCount: 0
            )
        }
    }

    func recordHits(in data: Data) -> [Hit] {
        lock.withLock {
            var hits: [Hit] = []
            var searchableData = recentData
            let previousByteCount = searchableData.count
            searchableData.append(data)

            for marker in probes.keys.sorted() {
                guard var probe = probes[marker] else { continue }
                guard let range = searchableData.range(of: probe.markerData) else { continue }
                guard range.upperBound > previousByteCount else { continue }

                probe.hitCount += 1
                probes[marker] = probe
                hits.append(
                    Hit(
                        marker: probe.marker,
                        label: probe.label,
                        submittedAt: probe.submittedAt,
                        hitCount: probe.hitCount,
                        offset: max(0, range.lowerBound - previousByteCount)
                    )
                )
            }

            if let maxMarkerLength = probes.values.map(\.markerData.count).max(), maxMarkerLength > 1 {
                recentData = searchableData.suffix(maxMarkerLength - 1)
            } else {
                recentData.removeAll(keepingCapacity: true)
            }

            return hits
        }
    }
}
