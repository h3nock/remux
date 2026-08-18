import CoreGraphics
import Foundation

/// Normalizes tmux pane geometry into equal-weight topology tiles.
enum PaneTopologyLayout {
    struct Pane: Equatable {
        let id: UUID
        let frame: GhosttyTerminalGridRect
    }

    struct Frames: Equatable {
        let byPaneID: [UUID: CGRect]

        func frame(for paneID: UUID) -> CGRect? {
            byPaneID[paneID]
        }
    }

    static func size(
        availableWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        let width = max(1, availableWidth)
        let height = min(max(0, maximumHeight), ceil(width * 0.75))
        return CGSize(width: width, height: height)
    }

    static func frames(
        panes: [Pane],
        size: CGSize
    ) -> Frames? {
        guard size.width.isFinite, size.width > 0,
              size.height.isFinite, size.height > 0,
              let topology = Topology(panes: panes)
        else { return nil }

        var framesByPaneID: [UUID: CGRect] = [:]
        topology.place(
            in: CGRect(origin: .zero, size: size),
            framesByPaneID: &framesByPaneID
        )
        return Frames(byPaneID: framesByPaneID)
    }

    private indirect enum Topology {
        case pane(UUID)
        case split(Axis, Topology, Topology)

        enum Axis {
            case horizontal
            case vertical
        }

        init?(panes: [Pane]) {
            guard !panes.isEmpty else { return nil }
            if panes.count == 1 {
                self = .pane(panes[0].id)
                return
            }

            if let groups = Self.partition(panes, axis: .horizontal),
               let first = Topology(panes: groups.0),
               let second = Topology(panes: groups.1) {
                self = .split(.horizontal, first, second)
                return
            }
            if let groups = Self.partition(panes, axis: .vertical),
               let first = Topology(panes: groups.0),
               let second = Topology(panes: groups.1) {
                self = .split(.vertical, first, second)
                return
            }
            return nil
        }

        private var paneCount: Int {
            switch self {
            case .pane:
                1
            case .split(_, let first, let second):
                first.paneCount + second.paneCount
            }
        }

        func place(
            in frame: CGRect,
            framesByPaneID: inout [UUID: CGRect]
        ) {
            switch self {
            case .pane(let id):
                framesByPaneID[id] = frame

            case .split(let axis, let first, let second):
                let firstFraction = CGFloat(first.paneCount) / CGFloat(paneCount)
                let firstFrame: CGRect
                let secondFrame: CGRect
                switch axis {
                case .horizontal:
                    let firstWidth = frame.width * firstFraction
                    firstFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: firstWidth,
                        height: frame.height
                    )
                    secondFrame = CGRect(
                        x: firstFrame.maxX,
                        y: frame.minY,
                        width: frame.width - firstWidth,
                        height: frame.height
                    )

                case .vertical:
                    let firstHeight = frame.height * firstFraction
                    firstFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: frame.width,
                        height: firstHeight
                    )
                    secondFrame = CGRect(
                        x: frame.minX,
                        y: firstFrame.maxY,
                        width: frame.width,
                        height: frame.height - firstHeight
                    )
                }
                first.place(in: firstFrame, framesByPaneID: &framesByPaneID)
                second.place(in: secondFrame, framesByPaneID: &framesByPaneID)
            }
        }

        private static func partition(
            _ panes: [Pane],
            axis: Axis
        ) -> ([Pane], [Pane])? {
            let sorted = panes.sorted {
                axis == .horizontal
                    ? $0.frame.x < $1.frame.x
                    : $0.frame.y < $1.frame.y
            }
            for index in 1..<sorted.count {
                let first = Array(sorted[..<index])
                let second = Array(sorted[index...])
                let firstEnd = first.map {
                    axis == .horizontal ? $0.maxX : $0.maxY
                }.max() ?? 0
                let secondStart = second.map {
                    axis == .horizontal ? $0.frame.x : $0.frame.y
                }.min() ?? 0
                if firstEnd < UInt64(secondStart) {
                    return (first, second)
                }
            }
            return nil
        }
    }
}

private extension PaneTopologyLayout.Pane {
    var maxX: UInt64 {
        UInt64(frame.x) + UInt64(frame.columns)
    }

    var maxY: UInt64 {
        UInt64(frame.y) + UInt64(frame.rows)
    }
}
