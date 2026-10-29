import Foundation

/// The image bytes of one connection, kept as Herdr's own client keeps them
/// (`kitty_graphics/surface.rs`, `ClientState::set_scene`).
///
/// Herdr sends an image's bytes once, then only places it, and keeps counting it as delivered while a
/// scene places or retains it (`collect_scene`); a pane's terminal can't give them back, so they are kept
/// here for any terminal that needs the image again: a pane that comes back after another tab was shown,
/// or a pane's new terminal.
struct HerdrImageStore {
    private var bytes: [HerdrGraphicsAssetKey: [UInt8]] = [:]

    subscript(key: HerdrGraphicsAssetKey) -> [UInt8]? {
        bytes[key]
    }

    /// Takes every surface's scene in wire order, including surfaces presentation drops: an image's key
    /// names its content (source, size, format, length and fingerprint), so its bytes are right whichever
    /// surface carried them. Afterwards it holds what Herdr counts as delivered after that surface: the
    /// images the scene places or retains. Herdr sends any other image again before placing it again.
    mutating func receive(_ scene: HerdrGraphicsScene) {
        // Herdr's client drops an image whose bytes don't match their declared length.
        for asset in scene.assets where UInt64(asset.data.count) == asset.key.dataLength {
            bytes[asset.key] = asset.data
        }
        let kept = Set(scene.placements.map(\.asset)).union(scene.retainedAssets)
        bytes = bytes.filter { kept.contains($0.key) }
    }
}

/// One pane's images in its terminal, written as kitty graphics commands the way Herdr's client writes a
/// scene to its host terminal (`kitty_graphics.rs`): each image uploaded once with `a=t`, each placement
/// put at its cell with `a=p` and `C=1`, placements that went away deleted, and images Herdr no longer
/// keeps for the pane deleted with their pixels. The pane's terminal holds the decoded pixels and draws
/// them.
///
/// Herdr has already cropped each placement to its pane's text area, in the frame's cells
/// (`collect_scene`); only the origin changes, to the pane's own.
struct HerdrPaneImages {
    /// A placement in the pane's cells, with Herdr's source crop, pixel offsets and stacking order.
    struct Placement: Equatable, Sendable {
        var asset: HerdrGraphicsAssetKey
        let logicalPlacementID: UInt32
        let column: UInt16
        let row: UInt16
        let columns: UInt32
        let rows: UInt32
        let sourceX: UInt32
        let sourceY: UInt32
        let sourceWidth: UInt32
        let sourceHeight: UInt32
        let xOffset: UInt32
        let yOffset: UInt32
        let z: Int32
        let scrollbackOffset: UInt32
    }

    /// What one frame asks of a pane: its placements, and every image Herdr keeps for it, placed or
    /// retained while out of view.
    struct Scene: Equatable, Sendable {
        var placements: [Placement] = []
        var kept: Set<HerdrGraphicsAssetKey> = []

        /// No images, as the popup's terminal shows: its images aren't drawn.
        init() {}

        /// The pane's part of the frame's scene. A placement that doesn't lie inside the pane's text
        /// area isn't drawn, so it can't cover another pane; Herdr crops them all to it. Popup images
        /// are left out.
        init(_ scene: HerdrGraphicsScene, pane: HerdrSurfacePane) {
            func isPane(_ key: HerdrGraphicsAssetKey) -> Bool {
                guard case .terminal(.pane(let paneID), _) = key.source else { return false }
                return paneID == pane.paneID
            }
            let area = pane.innerRect
            for placement in scene.placements where isPane(placement.asset) {
                kept.insert(placement.asset)
                guard placement.x >= area.x, placement.y >= area.y, placement.cols > 0, placement.rows > 0 else {
                    continue
                }
                let column = placement.x - area.x
                let row = placement.y - area.y
                guard UInt64(column) + UInt64(placement.cols) <= UInt64(area.width),
                      UInt64(row) + UInt64(placement.rows) <= UInt64(area.height)
                else { continue }
                placements.append(Placement(
                    asset: placement.asset,
                    logicalPlacementID: placement.logicalPlacementID,
                    column: column,
                    row: row,
                    columns: placement.cols,
                    rows: placement.rows,
                    sourceX: placement.sourceX,
                    sourceY: placement.sourceY,
                    sourceWidth: placement.sourceWidth,
                    sourceHeight: placement.sourceHeight,
                    xOffset: placement.xOffset,
                    yOffset: placement.yOffset,
                    z: placement.z,
                    scrollbackOffset: placement.scrollbackOffset
                ))
            }
            kept.formUnion(scene.retainedAssets.filter(isPane))
        }
    }

    /// A placement as the terminal draws it, under the terminal's own image id.
    private struct Shown: Equatable {
        let imageID: UInt32
        let placement: Placement
    }

    /// Images uploaded into the terminal, by their id there. Ids are never reused in one terminal, so a
    /// deleted image's placements can't be mistaken for a new one's.
    private var imageIDs: [HerdrGraphicsAssetKey: UInt32] = [:]
    private var lastImageID: UInt32 = 0
    /// The terminal's placements; the one at index `i` has placement id `i + 1`.
    private var shown: [Shown] = []
    /// Set by a resize, which can move a placement with the cells it is anchored to.
    private var placesAll = false

    /// The terminal was resized: the next update places every placement again.
    mutating func terminalResized() {
        placesAll = true
    }

    /// The commands that make the terminal show `scene`, uploading the images it lacks from `store`; empty
    /// when it already does. A placement whose bytes haven't arrived is left out until they do, except
    /// one that only replaces the image of a placement the terminal shows: that one keeps showing the
    /// old image meanwhile, which stays in the terminal. The commands keep the cursor where they found
    /// it, as Herdr's client writes its graphics between DECSC and DECRC (`client/frame_output.rs`).
    mutating func update(to scene: Scene, from store: HerdrImageStore) -> [UInt8] {
        var uploads: [UInt8] = []
        var drawn: [Shown] = []
        for placement in scene.placements {
            if let imageID = imageIDs[placement.asset] {
                drawn.append(Shown(imageID: imageID, placement: placement))
            } else if let data = store[placement.asset] {
                lastImageID += 1
                imageIDs[placement.asset] = lastImageID
                Self.appendUpload(placement.asset, data: data, imageID: lastImageID, to: &uploads)
                drawn.append(Shown(imageID: lastImageID, placement: placement))
            } else if let previous = shownPlacement(replacedBy: placement) {
                drawn.append(previous)
            }
        }
        let drawnImages = Set(drawn.map(\.placement.asset))
        var commands: [UInt8] = []
        for (key, imageID) in imageIDs where !scene.kept.contains(key) && !drawnImages.contains(key) {
            Self.append("a=d,d=I,i=\(imageID),q=2", to: &commands)
            imageIDs[key] = nil
        }
        commands += uploads
        if drawn != shown || placesAll {
            for (index, old) in shown.enumerated() where index >= drawn.count || drawn[index].imageID != old.imageID {
                Self.append("a=d,d=i,i=\(old.imageID),p=\(index + 1),q=2", to: &commands)
            }
            for (index, new) in drawn.enumerated() where placesAll || index >= shown.count || shown[index] != new {
                Self.appendPlacement(new, placementID: UInt32(index + 1), to: &commands)
            }
            shown = drawn
            placesAll = false
        }
        guard !commands.isEmpty else { return [] }
        return Self.saveCursor + commands + Self.restoreCursor
    }

    /// The placement the terminal shows that `placement` differs from only by its image, the same
    /// source's earlier pixels, while those are still in the terminal. Herdr may send a replaced image's
    /// bytes in a later frame, and its client shows the old image until then, but only on a placement
    /// with everything else unchanged, so never at cells from before a scroll or resize
    /// (`kitty_graphics/surface.rs`, `refresh_display_scene`).
    private func shownPlacement(replacedBy placement: Placement) -> Shown? {
        shown.first { old in
            var candidate = old.placement
            candidate.asset = placement.asset
            return old.placement.asset.source == placement.asset.source
                && candidate == placement
                && imageIDs[old.placement.asset] == old.imageID
        }
    }

    // MARK: - Encoding

    private static let saveCursor: [UInt8] = [0x1B, 0x37]
    private static let restoreCursor: [UInt8] = [0x1B, 0x38]
    /// Herdr's client sends 3,072 bytes per chunk: 4,096 in base64, the kitty protocol's chunk limit.
    private static let chunkBytes = 3072

    private static func append(_ control: String, payload: ArraySlice<UInt8> = [], to bytes: inout [UInt8]) {
        bytes += [0x1B, 0x5F, 0x47]
        bytes += control.utf8
        bytes.append(0x3B)
        bytes += payload
        bytes += [0x1B, 0x5C]
    }

    /// `a=t` with the pixels in base64, in chunks (`m=1` on every one but the last).
    private static func appendUpload(
        _ key: HerdrGraphicsAssetKey,
        data: [UInt8],
        imageID: UInt32,
        to bytes: inout [UInt8]
    ) {
        let format = switch key.format {
        case .rgb: 24
        case .rgba: 32
        case .png: 100
        }
        let encoded = Array(Data(data).base64EncodedData())
        let chunk = chunkBytes / 3 * 4
        var start = 0
        repeat {
            let end = min(start + chunk, encoded.count)
            let more = end < encoded.count ? 1 : 0
            let control = start == 0
                ? "a=t,t=d,f=\(format),s=\(key.imageWidth),v=\(key.imageHeight),i=\(imageID),q=2,m=\(more)"
                : "m=\(more)"
            append(control, payload: encoded[start..<end], to: &bytes)
            start = end
        } while start < encoded.count
    }

    /// The cursor to the placement's cell, then `a=p` without moving the cursor (`C=1`). A zero source
    /// size means the whole image, so zeros are left out, as Herdr's client leaves them out.
    private static func appendPlacement(_ shown: Shown, placementID: UInt32, to bytes: inout [UInt8]) {
        let placement = shown.placement
        bytes += Array("\u{1B}[\(Int(placement.row) + 1);\(Int(placement.column) + 1)H".utf8)
        var control = "a=p,i=\(shown.imageID),p=\(placementID),c=\(placement.columns),r=\(placement.rows)"
            + ",z=\(placement.z),C=1,q=2"
        for (key, value) in [
            ("x", placement.sourceX), ("y", placement.sourceY),
            ("w", placement.sourceWidth), ("h", placement.sourceHeight),
            ("X", placement.xOffset), ("Y", placement.yOffset),
        ] where value > 0 {
            control += ",\(key)=\(value)"
        }
        append(control, to: &bytes)
    }
}
