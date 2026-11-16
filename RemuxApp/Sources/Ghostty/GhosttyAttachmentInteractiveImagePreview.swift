import SwiftUI
import UIKit

/// A preview picture that can be zoomed. It is decoded again only when its bytes change, so a redraw of the sheet
/// around it neither decodes it again nor resets the zoom. A page out of view goes back to fitting, as in Photos.
struct GhosttyAttachmentInteractiveImagePreview: UIViewRepresentable {
    let imageData: Data
    let isInView: Bool

    func makeUIView(context: Context) -> GhosttyAttachmentInteractiveImageView {
        let view = GhosttyAttachmentInteractiveImageView()
        view.configure(imageData: imageData)
        return view
    }

    func updateUIView(_ view: GhosttyAttachmentInteractiveImageView, context: Context) {
        view.configure(imageData: imageData)
        if !isInView {
            view.fit()
        }
    }
}

final class GhosttyAttachmentInteractiveImageView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var displayedData: Data?
    private var displayedImage: UIImage?
    private var laidOutBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(imageData: Data) {
        guard displayedData != imageData else { return }
        displayedData = imageData
        displayedImage = UIImage(data: imageData)
        imageView.image = displayedImage
        laidOutBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.size != laidOutBounds else { return }
        laidOutBounds = bounds.size
        resetImageLayout()
    }

    /// Back to the whole picture, unzoomed.
    func fit() {
        guard scrollView.zoomScale != scrollView.minimumZoomScale else { return }
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func setup() {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.bouncesZoom = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func resetImageLayout() {
        guard let image = displayedImage, !bounds.isEmpty else { return }

        scrollView.zoomScale = 1
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4

        let fittedSize = fittedImageSize(image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        centerImage()
    }

    private func fittedImageSize(_ imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame

        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }

        let targetZoomScale = min(scrollView.maximumZoomScale, 2.5)
        let point = recognizer.location(in: imageView)
        let width = scrollView.bounds.width / targetZoomScale
        let height = scrollView.bounds.height / targetZoomScale
        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        scrollView.zoom(to: rect, animated: true)
    }
}
