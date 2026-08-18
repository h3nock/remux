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

    /// Copies only the requested pixels from the currently published
    /// IOSurface.
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

    static func sourceRect(
        width: Int,
        height: Int,
        centeredOn anchor: CGRect,
        maxWidth: UInt32,
        maxHeight: UInt32
    ) -> CGRect? {
        guard width > 0, height > 0,
              maxWidth > 0, maxHeight > 0,
              anchor.origin.x.isFinite, anchor.origin.y.isFinite,
              anchor.width.isFinite, anchor.height.isFinite,
              anchor.width > 0, anchor.height > 0
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard anchor.intersects(bounds) else { return nil }

        let aspectRatio = Double(maxWidth) / Double(maxHeight)
        var cropWidth = min(Double(width), Double(maxWidth))
        var cropHeight = min(Double(height), Double(maxHeight))
        if cropWidth / cropHeight > aspectRatio {
            cropWidth = cropHeight * aspectRatio
        } else {
            cropHeight = cropWidth / aspectRatio
        }

        let integralWidth = max(1, min(width, Int(cropWidth.rounded(.down))))
        let integralHeight = max(1, min(height, Int(cropHeight.rounded(.down))))
        let x = min(
            max(0, Int((anchor.midX - CGFloat(integralWidth) / 2).rounded(.down))),
            width - integralWidth
        )
        let y = min(
            max(0, Int((anchor.midY - CGFloat(integralHeight) / 2).rounded(.down))),
            height - integralHeight
        )
        return CGRect(x: x, y: y, width: integralWidth, height: integralHeight)
    }

    func image(maxWidth: UInt32, maxHeight: UInt32) throws -> CGImage {
        guard maxWidth > 0, maxHeight > 0,
              let provider = CGDataProvider(data: bytes as CFData),
              let source = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: Self.colorSpace,
                bitmapInfo: Self.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw ReadError.imageCreationFailed }

        let scale = min(
            1,
            min(
                Double(maxWidth) / Double(source.width),
                Double(maxHeight) / Double(source.height)
            )
        )
        guard scale < 1 else { return source }

        let targetWidth = max(1, Int((Double(source.width) * scale).rounded(.down)))
        let targetHeight = max(1, Int((Double(source.height) * scale).rounded(.down)))
        let targetBytesPerRow = targetWidth * 4
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetBytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: Self.bitmapInfo.rawValue
        ) else { throw ReadError.imageCreationFailed }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let image = context.makeImage() else { throw ReadError.imageCreationFailed }
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
