import Foundation

#if REMUX_FILE_PROVIDER_EXTENSION
struct RemuxTransportStartupTrace: Sendable {
    init(flowID: String?, startedAt: UInt64 = 0) {}

    func event(
        _ name: String,
        fields: [String: String] = [:],
        at timestamp: UInt64 = 0
    ) {}

    func stage<T>(
        _ name: String,
        fields: [String: String] = [:],
        operation: () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}
#else
struct RemuxTransportStartupTrace: Sendable {
    private let flowID: String?
    private let startedAt: UInt64

    init(flowID: String?, startedAt: UInt64 = GhosttyRuntimeTrace.nowNanos()) {
        self.flowID = flowID
        self.startedAt = startedAt
    }

    func event(
        _ name: String,
        fields: [String: String] = [:],
        at timestamp: UInt64 = GhosttyRuntimeTrace.nowNanos()
    ) {
        GhosttyRuntimeTrace.latency(
            "transport.startup.\(name) since_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt, to: timestamp))\(latencyFields(fields))"
        )

        if let flowID {
            GhosttyRuntimeTrace.flowEventIfActive(
                flowID,
                event: "transport.startup.\(name)",
                fields: fields,
                at: timestamp
            )
        }
    }

    func stage<T>(
        _ name: String,
        fields: [String: String] = [:],
        operation: () async throws -> T
    ) async throws -> T {
        let stageStart = GhosttyRuntimeTrace.nowNanos()
        event("\(name).begin", fields: fields, at: stageStart)

        do {
            let result = try await operation()
            let finishedAt = GhosttyRuntimeTrace.nowNanos()
            event(
                "\(name).end",
                fields: stageFields(fields, stageStart: stageStart, finishedAt: finishedAt),
                at: finishedAt
            )
            return result
        } catch {
            let failedAt = GhosttyRuntimeTrace.nowNanos()
            var failureFields = stageFields(fields, stageStart: stageStart, finishedAt: failedAt)
            failureFields["error"] = String(describing: error)
            event("\(name).failed", fields: failureFields, at: failedAt)
            throw error
        }
    }

    private func stageFields(
        _ fields: [String: String],
        stageStart: UInt64,
        finishedAt: UInt64
    ) -> [String: String] {
        var stageFields = fields
        stageFields["elapsed_ms"] = GhosttyRuntimeTrace.elapsedMilliseconds(from: stageStart, to: finishedAt)
        return stageFields
    }

    private func latencyFields(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }

        return " " + fields
            .sorted(by: { $0.key < $1.key })
            .map { key, value in "\(key)=\(sanitizeLatencyField(value))" }
            .joined(separator: " ")
    }

    private func sanitizeLatencyField(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
#endif
