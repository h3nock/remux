import CoreGraphics
import Foundation
import os

enum GhosttyTerminalViewportHoldReason: Hashable {
    case sheet
    case coveredPresentation
    case keyboardTransition
    case topologyRefocus
    case unsizedInitialLayout

    var traceLabel: String {
        switch self {
        case .sheet:
            return "sheet"
        case .coveredPresentation:
            return "coveredPresentation"
        case .keyboardTransition:
            return "keyboardTransition"
        case .topologyRefocus:
            return "topologyRefocus"
        case .unsizedInitialLayout:
            return "unsizedInitialLayout"
        }
    }
}

enum GhosttyTerminalViewportGeometryHoldEffect: Equatable {
    case hold(effectiveSize: CGSize)
    case release(previousEffectiveSize: CGSize)
}

enum GhosttyTerminalViewportTopologyRefocusEffect: Equatable {
    case hold(effectiveSize: CGSize)
    case release(previousEffectiveSize: CGSize)
    case inactive
}

struct GhosttyTerminalViewportLiveSizeObservation: Equatable {
    enum Outcome: Equatable {
        case unchanged
        case observedWithoutStableUpdate
        case appliedStableSize
    }

    let previousLiveSize: CGSize
    let liveSize: CGSize
    let previousEffectiveSize: CGSize
    let effectiveSize: CGSize
    let wasFrozen: Bool
    let outcome: Outcome

    var didChangeLiveSize: Bool {
        previousLiveSize != liveSize
    }

    var didApplyStableSize: Bool {
        outcome == .appliedStableSize
    }
}

/// Experiment, on with `REMUX_KEYBOARD_PAN=1` at launch: the software keyboard and the bottom chrome cover
/// the bottom of the terminal instead of resizing it. The terminal keeps its resting size, so nothing is sent
/// to the server when the keyboard moves, and the terminal view slides up just far enough to keep the focused
/// pane's cursor row in view (`GhosttyCompositeViewportHostView`).
enum GhosttyKeyboardPanExperiment {
    /// Marks each keyboard move and each slide in Instruments' Points of Interest, with the slide on or off, so a
    /// profile taken on a phone can tell a move's frames from the rest. Free while nothing records.
    static let signposter = OSSignposter(subsystem: "dev.remux.app", category: .pointsOfInterest)

    /// REMUX_KEYBOARD_PAN_ROWS=live: the slide reads the terminal's live state (`contentGeometry`) instead of the
    /// rows GhosttyKit publishes with each frame, for comparing the two.
    static let readsLiveRows = ProcessInfo.processInfo.environment["REMUX_KEYBOARD_PAN_ROWS"] == "live"

    /// On when launched with REMUX_KEYBOARD_PAN=1. A review build compiled with REMUX_KEYBOARD_PAN_ON is on
    /// from its icon too, and off only when launched with REMUX_KEYBOARD_PAN=0.
    static let isEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["REMUX_KEYBOARD_PAN"]
        #if REMUX_KEYBOARD_PAN_ON
        return value != "0"
        #else
        return value == "1"
        #endif
    }()
}

struct GhosttyTerminalViewportCoordinator: Equatable {
    enum ReleasePolicy: Equatable {
        case adoptLatestLive
        case preserveCurrentEffective
    }

    /// With the keyboard pan, the size the terminal keeps is its resting size, the tallest live size seen
    /// at the current width, instead of the live size.
    var keepsRestingSize = GhosttyKeyboardPanExperiment.isEnabled
    private var tallestLiveSize: CGSize?

    private(set) var lastLiveSize = CGSize(width: 1, height: 1)
    private(set) var lastStableSize = CGSize(width: 1, height: 1)
    private(set) var frozenSize: CGSize?
    private(set) var holdReasons: Set<GhosttyTerminalViewportHoldReason> = []
    private(set) var keyboardTransitionTarget: GhosttyKeyboardViewportTransitionTarget?
    private var deferredReleasePolicy: ReleasePolicy?

    var latestLiveSize: CGSize {
        lastLiveSize
    }

    var isGeometryFrozen: Bool {
        holdReasons.contains { Self.isGeometryHold($0) }
    }

    var isFrozen: Bool {
        isGeometryFrozen
    }

    var isKeyboardTransitionActive: Bool {
        holdReasons.contains(.keyboardTransition)
    }

    var isTopologyRefocusActive: Bool {
        holdReasons.contains(.topologyRefocus)
    }

    var holdReasonTraceLabel: String {
        guard !holdReasons.isEmpty else { return "none" }
        return holdReasons
            .map(\.traceLabel)
            .sorted()
            .joined(separator: ",")
    }

    func effectiveSize(liveSize: CGSize) -> CGSize {
        if isGeometryFrozen, let frozenSize {
            return frozenSize
        }
        if Self.isUsable(lastStableSize) {
            return lastStableSize
        }

        let normalizedSize = Self.normalized(liveSize)
        return Self.isUsable(normalizedSize) ? normalizedSize : lastStableSize
    }

    @discardableResult
    mutating func observeLiveSize(_ size: CGSize) -> GhosttyTerminalViewportLiveSizeObservation {
        updateLiveSize(size, reconcilesStoredSize: false)
    }

    @discardableResult
    mutating func reconcileLiveSize(_ size: CGSize) -> GhosttyTerminalViewportLiveSizeObservation {
        updateLiveSize(size, reconcilesStoredSize: true)
    }

    private mutating func updateLiveSize(
        _ size: CGSize,
        reconcilesStoredSize: Bool
    ) -> GhosttyTerminalViewportLiveSizeObservation {
        let normalizedSize = Self.normalized(size)
        let previousLiveSize = lastLiveSize
        let previousEffectiveSize = effectiveSize(liveSize: previousLiveSize)
        let wasFrozen = isGeometryFrozen
        let didChangeLiveSize = lastLiveSize != normalizedSize
        lastLiveSize = normalizedSize

        func observation(
            outcome: GhosttyTerminalViewportLiveSizeObservation.Outcome
        ) -> GhosttyTerminalViewportLiveSizeObservation {
            GhosttyTerminalViewportLiveSizeObservation(
                previousLiveSize: previousLiveSize,
                liveSize: normalizedSize,
                previousEffectiveSize: previousEffectiveSize,
                effectiveSize: effectiveSize(liveSize: normalizedSize),
                wasFrozen: wasFrozen,
                outcome: outcome
            )
        }

        guard didChangeLiveSize || reconcilesStoredSize else {
            return observation(outcome: .unchanged)
        }
        guard Self.isUsable(normalizedSize) else {
            holdReasons.insert(.unsizedInitialLayout)
            freeze(using: normalizedSize)
            return observation(
                outcome: didChangeLiveSize ? .observedWithoutStableUpdate : .unchanged
            )
        }

        let didReleaseUnsizedInitialLayout = holdReasons.contains(.unsizedInitialLayout)
        if didReleaseUnsizedInitialLayout {
            removeHold(
                .unsizedInitialLayout,
                liveSize: normalizedSize,
                releasePolicy: .adoptLatestLive
            )
        }
        let resting = restingSize(for: normalizedSize)
        guard !isGeometryFrozen else {
            return observation(
                outcome: didChangeLiveSize ? .observedWithoutStableUpdate : .unchanged
            )
        }
        guard lastStableSize != resting else {
            return observation(
                outcome: didReleaseUnsizedInitialLayout
                    ? .appliedStableSize
                    : didChangeLiveSize ? .observedWithoutStableUpdate : .unchanged
            )
        }

        lastStableSize = resting
        return observation(outcome: .appliedStableSize)
    }

    /// The size the terminal keeps for a usable live size: the live size itself, or with `keepsRestingSize`
    /// the tallest live size at its width. A layout pass that reports a size reduced by the keyboard then
    /// changes nothing, whatever order it arrives in relative to the keyboard's notifications.
    private mutating func restingSize(for liveSize: CGSize) -> CGSize {
        guard keepsRestingSize else { return liveSize }
        if let tallestLiveSize,
           tallestLiveSize.width == liveSize.width,
           tallestLiveSize.height >= liveSize.height {
            return tallestLiveSize
        }
        tallestLiveSize = liveSize
        return liveSize
    }

    @discardableResult
    mutating func setSheetPresented(
        _ isPresented: Bool,
        liveSize: CGSize
    ) -> GhosttyTerminalViewportGeometryHoldEffect {
        setGeometryHold(.sheet, isActive: isPresented, liveSize: liveSize)
    }

    @discardableResult
    mutating func setCoveredPresentation(
        _ isCovered: Bool,
        liveSize: CGSize
    ) -> GhosttyTerminalViewportGeometryHoldEffect {
        setGeometryHold(.coveredPresentation, isActive: isCovered, liveSize: liveSize)
    }

    private mutating func setGeometryHold(
        _ reason: GhosttyTerminalViewportHoldReason,
        isActive: Bool,
        liveSize: CGSize,
        releasePolicy: ReleasePolicy = .adoptLatestLive
    ) -> GhosttyTerminalViewportGeometryHoldEffect {
        let previousEffectiveSize = effectiveSize(liveSize: liveSize)
        if isActive {
            holdReasons.insert(reason)
            freeze(using: liveSize)
            return .hold(effectiveSize: effectiveSize(liveSize: liveSize))
        } else {
            removeHold(reason, liveSize: liveSize, releasePolicy: releasePolicy)
            return .release(previousEffectiveSize: previousEffectiveSize)
        }
    }

    @discardableResult
    mutating func beginKeyboardTransition(
        target: GhosttyKeyboardViewportTransitionTarget?,
        allowsTargetOverride: Bool,
        liveSize: CGSize
    ) -> Bool {
        let wasActive = isKeyboardTransitionActive
        holdReasons.insert(.keyboardTransition)

        if keyboardTransitionTarget == nil || allowsTargetOverride {
            keyboardTransitionTarget = target
        }

        return !wasActive
    }

    mutating func completeKeyboardTransition(liveSize: CGSize) {
        keyboardTransitionTarget = nil
        removeHold(.keyboardTransition, liveSize: liveSize, releasePolicy: .adoptLatestLive)
    }

    @discardableResult
    mutating func requestTopologyRefocus(liveSize: CGSize) -> GhosttyTerminalViewportTopologyRefocusEffect {
        holdReasons.insert(.topologyRefocus)
        freeze(using: liveSize)
        return .hold(effectiveSize: effectiveSize(liveSize: liveSize))
    }

    @discardableResult
    mutating func completeTopologyRefocus(
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) -> GhosttyTerminalViewportTopologyRefocusEffect {
        let previousEffectiveSize = effectiveSize(liveSize: liveSize)
        removeHold(.topologyRefocus, liveSize: liveSize, releasePolicy: releasePolicy)
        return .release(previousEffectiveSize: previousEffectiveSize)
    }

    @discardableResult
    mutating func cancelTopologyRefocus(liveSize: CGSize) -> GhosttyTerminalViewportTopologyRefocusEffect {
        guard isTopologyRefocusActive else { return .inactive }
        let previousEffectiveSize = effectiveSize(liveSize: liveSize)
        removeHold(.topologyRefocus, liveSize: liveSize, releasePolicy: .adoptLatestLive)
        return .release(previousEffectiveSize: previousEffectiveSize)
    }

    static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: normalizedDimension(size.width),
            height: normalizedDimension(size.height)
        )
    }

    private static func normalizedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 1 else { return 1 }
        return value
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width > 1 && size.height > 1
    }

    private static func isGeometryHold(_ reason: GhosttyTerminalViewportHoldReason) -> Bool {
        switch reason {
        case .sheet, .coveredPresentation, .topologyRefocus, .unsizedInitialLayout:
            return true
        case .keyboardTransition:
            return false
        }
    }

    private mutating func freeze(using liveSize: CGSize) {
        guard frozenSize == nil else { return }
        if Self.isUsable(lastStableSize) {
            frozenSize = lastStableSize
            return
        }

        let normalizedSize = Self.normalized(liveSize)
        if Self.isUsable(normalizedSize) {
            frozenSize = normalizedSize
        }
    }

    private mutating func removeHold(
        _ reason: GhosttyTerminalViewportHoldReason,
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) {
        holdReasons.remove(reason)
        guard Self.isGeometryHold(reason) else { return }

        if isGeometryFrozen {
            rememberDeferredReleasePolicy(releasePolicy)
            return
        }

        releaseFreeze(liveSize: liveSize, releasePolicy: releasePolicy)
    }

    private mutating func rememberDeferredReleasePolicy(_ releasePolicy: ReleasePolicy) {
        guard releasePolicy == .preserveCurrentEffective else { return }
        deferredReleasePolicy = .preserveCurrentEffective
    }

    private mutating func releaseFreeze(
        liveSize: CGSize,
        releasePolicy: ReleasePolicy
    ) {
        let finalReleasePolicy = mergedReleasePolicy(releasePolicy)
        let normalizedSize = Self.normalized(liveSize)

        switch finalReleasePolicy {
        case .adoptLatestLive:
            if Self.isUsable(normalizedSize) {
                lastStableSize = restingSize(for: normalizedSize)
            } else if let frozenSize, Self.isUsable(frozenSize) {
                lastStableSize = frozenSize
            }

        case .preserveCurrentEffective:
            if let frozenSize, Self.isUsable(frozenSize) {
                lastStableSize = frozenSize
            } else if !Self.isUsable(lastStableSize), Self.isUsable(normalizedSize) {
                lastStableSize = normalizedSize
            }
        }

        frozenSize = nil
        deferredReleasePolicy = nil
    }

    private func mergedReleasePolicy(_ releasePolicy: ReleasePolicy) -> ReleasePolicy {
        if deferredReleasePolicy == .preserveCurrentEffective {
            return .preserveCurrentEffective
        }
        return releasePolicy
    }
}
