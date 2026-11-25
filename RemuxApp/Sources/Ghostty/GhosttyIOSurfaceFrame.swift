import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

/// Swift-owned pixels copied from one frame already published by Ghostty's
/// IOSurface renderer layer. Reading never asks the renderer to draw.
struct GhosttyIOSurfaceFrame: Sendable {
    enum ReadError: Error {
        case lockFailed
        case invalidGeometry
        case unsupportedPixelFormat(UInt32)
        case imageCreationFailed
    }

    private static let bgraPixelFormat: UInt32 = 0x4247_5241

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    static func rendererLayer(in viewLayer: CALayer) -> CALayer? {
        let layers = viewLayer.sublayers ?? []
        if let published = layers.first(where: { iosurface(from: $0) != nil }) {
            return published
        }
        // Ghostty's iOS Metal renderer installs exactly one direct sublayer.
        // Before its first frame that layer has no contents yet.
        return layers.count == 1 ? layers[0] : nil
    }

    /// The rows GhosttyKit published with the frame this layer shows: the cursor's row and the bottom of the lowest
    /// row holding anything, in the layer's points from its top edge; each nil when the frame has none. Nil before
    /// the first frame. GhosttyKit sets them on the layer in the same main-thread step that sets `contents`, as 16
    /// bytes: three Float32 values in surface pixels, -1 for none, then a UInt32 layout version.
    static func publishedRows(in layer: CALayer) -> (cursor: ClosedRange<CGFloat>?, contentBottom: CGFloat?)? {
        guard let data = layer.value(forKey: publishedRowsKey) as? Data, data.count >= 16 else { return nil }
        let values = data.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: Float32.self),
             raw.loadUnaligned(fromByteOffset: 4, as: Float32.self),
             raw.loadUnaligned(fromByteOffset: 8, as: Float32.self),
             raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        }
        guard values.3 == 1 else { return nil }
        let scale = max(layer.contentsScale, 1)
        // A row scrolled partly off the top starts above 0, so a cursor is told apart from none (-1 and -1) by its height.
        let cursor: ClosedRange<CGFloat>? = values.1 > values.0
            ? CGFloat(values.0) / scale...CGFloat(values.1) / scale
            : nil
        return (cursor, values.2 > 0 ? CGFloat(values.2) / scale : nil)
    }

    /// The layer key GhosttyKit sets the rows on, only when they differ from the frame before.
    static let publishedRowsKey = "remuxFrameRows"

    static func dimensions(in layer: CALayer) -> (width: Int, height: Int)? {
        guard let surface = iosurface(from: layer) else { return nil }
        return (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface))
    }

    /// Copies the currently published IOSurface while the caller still owns
    /// the layer publication boundary. Retaining the IOSurface is not enough:
    /// Metal reuses its fixed frame targets, so later draws may overwrite the
    /// same allocation even while another owner holds a CF reference.
    static func read(from layer: CALayer) throws -> Self {
        try copyPixels(from: layer, sourceRect: nil)
    }

    static func read(from layer: CALayer, sourceRect: CGRect) throws -> Self {
        try copyPixels(from: layer, sourceRect: sourceRect)
    }

    private static func copyPixels(
        from layer: CALayer,
        sourceRect: CGRect?
    ) throws -> Self {
        guard let surface = iosurface(from: layer) else {
            throw ReadError.invalidGeometry
        }
        guard IOSurfaceLock(surface, .readOnly, nil) == 0 else {
            throw ReadError.lockFailed
        }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw ReadError.invalidGeometry
        }
        let optionalBase: UnsafeMutableRawPointer? = IOSurfaceGetBaseAddress(surface)
        guard let base = optionalBase else {
            throw ReadError.invalidGeometry
        }
        let pixelFormat = IOSurfaceGetPixelFormat(surface)
        guard pixelFormat == bgraPixelFormat else {
            throw ReadError.unsupportedPixelFormat(pixelFormat)
        }
        guard let sourceRect else {
            let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(
                by: height
            )
            guard !overflow else { throw ReadError.invalidGeometry }
            return Self(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bytes: Data(bytes: base, count: byteCount)
            )
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let copiedRect = sourceRect.standardized.integral.intersection(bounds)
        guard !copiedRect.isNull, !copiedRect.isEmpty else {
            throw ReadError.invalidGeometry
        }
        let copiedX = Int(copiedRect.minX)
        let copiedY = Int(copiedRect.minY)
        let copiedWidth = Int(copiedRect.width)
        let copiedHeight = Int(copiedRect.height)
        let copiedBytesPerRow = copiedWidth * 4
        let (byteCount, overflow) = copiedBytesPerRow.multipliedReportingOverflow(
            by: copiedHeight
        )
        guard !overflow else { throw ReadError.invalidGeometry }
        var bytes = Data(count: byteCount)
        bytes.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<copiedHeight {
                let source = base.advanced(
                    by: (copiedY + row) * bytesPerRow + copiedX * 4
                )
                destinationBase.advanced(by: row * copiedBytesPerRow).copyMemory(
                    from: source,
                    byteCount: copiedBytesPerRow
                )
            }
        }
        return Self(
            width: copiedWidth,
            height: copiedHeight,
            bytesPerRow: copiedBytesPerRow,
            bytes: bytes
        )
    }

    func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: Self.colorSpace,
                bitmapInfo: Self.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { throw ReadError.imageCreationFailed }
        return image
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
    )

    private static func iosurface(from layer: CALayer) -> IOSurface? {
        guard let contents = layer.contents else { return nil }
        let value = contents as CFTypeRef
        guard CFGetTypeID(value) == IOSurfaceGetTypeID() else { return nil }
        return unsafeDowncast(contents as AnyObject, to: IOSurface.self)
    }
}

/// Calls `onChange` when GhosttyKit publishes different rows on a renderer layer. GhosttyKit sets them on the main
/// thread, in the same step that sets the frame's picture, so a move made in `onChange` shows with that picture.
final class GhosttyFrameRowsObserver: NSObject {
    let layer: CALayer
    private let onChange: @MainActor () -> Void
    private var rows: Data?

    init(layer: CALayer, onChange: @escaping @MainActor () -> Void) {
        self.layer = layer
        self.onChange = onChange
        rows = layer.value(forKey: GhosttyIOSurfaceFrame.publishedRowsKey) as? Data
        super.init()
        layer.addObserver(self, forKeyPath: GhosttyIOSurfaceFrame.publishedRowsKey, options: [.new], context: nil)
    }

    deinit {
        layer.removeObserver(self, forKeyPath: GhosttyIOSurfaceFrame.publishedRowsKey)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // A layer notifies twice for each value set on a key it stores.
        let rows = change?[.newKey] as? Data
        guard rows != self.rows else { return }
        self.rows = rows
        let onChange = onChange
        MainActor.assumeIsolated { onChange() }
    }
}
