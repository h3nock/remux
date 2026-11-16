import ImageIO
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Markup of one image, shown in the attachment preview's own frame. Its controls go to the surrounding
/// navigation bar: cancel, undo and redo, and the confirmation that keeps the marks.
struct GhosttyAttachmentImageMarkupEditor: View {
    /// The prepared picture's file, which the editor reads and never writes.
    let imageURL: URL
    /// Shown while the picture is read, in the same place, so the picture doesn't change.
    let preview: UIImage?
    let onCancel: () -> Void
    let onDone: (GhosttyAttachmentImageMarkupResult) -> Void

    @State private var phase: LoadPhase = .loading
    @State private var isLoadingLong = false
    @State private var drawing = PKDrawing()
    @State private var isRendering = false
    @State private var isConfirmingDiscard = false
    @State private var saveFailureMessage: String?
    @StateObject private var undo = GhosttyAttachmentMarkupUndo()

    var body: some View {
        editorContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Markup")
            .toolbar {
                toolbarContent
            }
            .interactiveDismissDisabled()
            .task(id: imageURL) {
                await loadImage()
            }
            .alert(
                "Markup Unavailable",
                isPresented: saveFailureAlertBinding,
                actions: {
                    Button("OK", role: .cancel) {}
                },
                message: {
                    Text(saveFailureMessage ?? "Markup could not be saved.")
                }
            )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Cancel stands on its own, ahead of undo and redo, as in the system's Markup.
        ToolbarItem(placement: .topBarLeading) {
            cancelButton
                .disabled(isRendering)
                .accessibilityIdentifier("terminal.attachments.markup.cancel")
                .confirmationDialog(
                    "Are you sure you want to discard your changes?",
                    isPresented: $isConfirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard Changes", role: .destructive) {
                        onCancel()
                    }
                    Button("Keep Editing", role: .cancel) {}
                }
        }

        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarLeading)
        }

        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                undo.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!undo.canUndo || isRendering)
            .accessibilityIdentifier("terminal.attachments.markup.undo")

            Button {
                undo.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!undo.canRedo || isRendering)
            .accessibilityIdentifier("terminal.attachments.markup.redo")
        }

        ToolbarItem(placement: .confirmationAction) {
            if isRendering {
                ProgressView()
            } else {
                doneButton
                    .disabled(!canFinish)
                    .accessibilityIdentifier("terminal.attachments.markup.done")
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .cancel) {
                cancel()
            }
        } else {
            Button("Cancel") {
                cancel()
            }
        }
    }

    @ViewBuilder
    private var doneButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm) {
                finishMarkup()
            }
        } else {
            Button("Done") {
                finishMarkup()
            }
        }
    }

    /// Marks are only kept by the confirmation, so leaving with any on the canvas asks first.
    private func cancel() {
        if hasDrawing {
            isConfirmingDiscard = true
        } else {
            onCancel()
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch phase {
        case .loading:
            ZStack {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                }
                if isLoadingLong {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            // A picture is read in tens of milliseconds; only a slower one, such as a large file, shows that it is
            // still loading.
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                isLoadingLong = true
            }

        case .loaded(let image):
            GhosttyAttachmentMarkupCanvas(
                image: image,
                documentSize: GhosttyAttachmentImageMarkupRenderer.documentSize(for: image.size),
                drawing: $drawing,
                undo: undo
            )
            // What is saved is the drawing as it was when Done was tapped, so no stroke starts while it is written.
            .allowsHitTesting(!isRendering)
            .accessibilityLabel("Markup canvas")
            .accessibilityIdentifier("terminal.attachments.markup.canvas")

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                Text("Image could not be opened.")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var hasDrawing: Bool {
        !drawing.bounds.isEmpty
    }

    private var canFinish: Bool {
        guard let image = phase.loadedImage else { return false }
        let documentSize = GhosttyAttachmentImageMarkupRenderer.documentSize(for: image.size)
        return !isRendering && documentSize.width > 0 && documentSize.height > 0
    }

    private var saveFailureAlertBinding: Binding<Bool> {
        Binding {
            saveFailureMessage != nil
        } set: { isPresented in
            if !isPresented {
                saveFailureMessage = nil
            }
        }
    }

    private func loadImage() async {
        phase = .loading
        let startedAt = GhosttyRuntimeTrace.nowNanos()
        let url = imageURL
        // Decoded here, off the main thread, so showing it decodes nothing there.
        let image = await Task.detached(priority: .userInitiated) {
            GhosttyAttachmentImageMarkupRenderer.baseImage(at: url)
        }.value
        GhosttyRuntimeTrace.perf(
            "attachment.markup.open loaded=\(image != nil) px=\(image.map { "\($0.width)x\($0.height)" } ?? "-") elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
        )

        guard let image else {
            phase = .failed
            return
        }

        phase = .loaded(UIImage(cgImage: image))
    }

    private func finishMarkup() {
        guard case .loaded(let image) = phase, let baseImage = image.cgImage, canFinish else { return }
        guard !drawing.bounds.isEmpty else {
            onCancel()
            return
        }

        let documentSize = GhosttyAttachmentImageMarkupRenderer.documentSize(for: image.size)
        let drawing = drawing
        isRendering = true

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GhosttyAttachmentImageMarkupRenderer.renderData(
                        baseImage: baseImage,
                        drawing: drawing,
                        documentSize: documentSize
                    )
                }.value
                onDone(result)
            } catch {
                isRendering = false
                saveFailureMessage = "Markup could not be saved."
            }
        }
    }
}

/// Undo and redo for the canvas. PencilKit registers each stroke with the canvas's own undo manager.
@MainActor
final class GhosttyAttachmentMarkupUndo: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    fileprivate weak var canvasView: PKCanvasView?

    func undo() {
        canvasView?.undoManager?.undo()
        refresh()
    }

    func redo() {
        canvasView?.undoManager?.redo()
        refresh()
    }

    fileprivate func refresh() {
        let manager = canvasView?.undoManager
        canUndo = manager?.canUndo ?? false
        canRedo = manager?.canRedo ?? false
    }
}

struct GhosttyAttachmentImageMarkupResult: Sendable {
    /// Written as any rewritten picture is (`GhosttyAttachmentPhotoPreparation.rewrittenPicture(for:)`).
    let picture: GhosttyAttachmentPhotoPreparation.EncodedPicture
    let previewData: Data
    let renderStartedAt: UInt64
    let renderCompletedAt: UInt64
}

enum GhosttyAttachmentImageMarkupRenderer {
    static let maxDocumentLongSide: CGFloat = 1_024

    enum RenderError: Error, Equatable {
        case invalidDocumentSize
        case invalidImageSize
        case encodingFailed
    }

    /// The picture at `url`, upright and at most the size it is sent at
    /// (`GhosttyAttachmentPhotoPreparation.maxPixelDimension`), which is all the editor shows and all a marked-up
    /// picture is drawn from. Nil when it can't be read.
    static func baseImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }
        return GhosttyAttachmentImageCoding.uprightImage(
            from: source,
            maxPixelDimension: GhosttyAttachmentPhotoPreparation.maxPixelDimension
        )
    }

    static func outputFilename(
        for sourceFilename: String,
        contentType: UTType
    ) -> String {
        let component = sourceFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { character in
                character == "/" || character == "\\"
            }
            .last
            .map(String.init) ?? "image"
        let stem = URL(fileURLWithPath: component)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture marked up again stays one marked-up picture.
        let annotatedStem = stem.hasSuffix("-annotated") ? stem : "\(stem.isEmpty ? "image" : stem)-annotated"
        return "\(annotatedStem).\(contentType.preferredFilenameExtension ?? "jpeg")"
    }

    static func documentSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let longSide = max(imageSize.width, imageSize.height)
        let scale = min(1, maxDocumentLongSide / longSide)
        return CGSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
    }

    /// `drawing` over `baseImage`, written with its preview. It runs on any thread: PencilKit draws a drawing on any
    /// thread, and the appearance the marks are drawn in is set for the calling thread only.
    static func renderData(
        baseImage: CGImage,
        drawing: PKDrawing,
        documentSize: CGSize
    ) throws -> GhosttyAttachmentImageMarkupResult {
        let totalStartedAt = GhosttyRuntimeTrace.nowNanos()
        guard documentSize.width > 0, documentSize.height > 0 else {
            throw RenderError.invalidDocumentSize
        }

        let sourceImageSize = CGSize(width: baseImage.width, height: baseImage.height)
        guard sourceImageSize.width > 0, sourceImageSize.height > 0 else {
            throw RenderError.invalidImageSize
        }
        // An annotated picture is sent as a rewritten picture is.
        let outputImageSize = GhosttyAttachmentPhotoPreparation.sentSize(for: sourceImageSize)
        guard outputImageSize.width > 0, outputImageSize.height > 0 else {
            throw RenderError.invalidImageSize
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // See-through parts of the picture stay so, and decide its format. A picture with no alpha channel has none,
        // so its marked-up copy is drawn opaque and has none to look for.
        format.opaque = !hasAlphaChannel(baseImage)

        let renderer = UIGraphicsImageRenderer(size: outputImageSize, format: format)
        let compositeStartedAt = GhosttyRuntimeTrace.nowNanos()
        let renderedImage = renderer.image { _ in
            UIImage(cgImage: baseImage).draw(in: CGRect(origin: .zero, size: outputImageSize))

            let drawingScale = min(
                outputImageSize.width / documentSize.width,
                outputImageSize.height / documentSize.height
            )
            var drawingImage: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawingImage = drawing.image(
                    from: CGRect(origin: .zero, size: documentSize),
                    scale: drawingScale
                )
            }
            drawingImage?.draw(in: CGRect(origin: .zero, size: outputImageSize))
        }
        let compositeCompletedAt = GhosttyRuntimeTrace.nowNanos()

        let encodeStartedAt = GhosttyRuntimeTrace.nowNanos()
        let picture = renderedImage.cgImage.flatMap(GhosttyAttachmentPhotoPreparation.rewrittenPicture(for:))
        let previewData = renderedImage.cgImage.flatMap(GhosttyAttachmentImagePreviewData.previewData(for:))
        let encodeCompletedAt = GhosttyRuntimeTrace.nowNanos()

        guard let picture, !picture.data.isEmpty, let previewData else {
            throw RenderError.encodingFailed
        }

        GhosttyRuntimeTrace.perf(
            "attachment.markup.render format=\(picture.contentType.preferredFilenameExtension ?? "?") bytes=\(picture.data.count) source_px=\(Int(sourceImageSize.width))x\(Int(sourceImageSize.height)) output_px=\(Int(outputImageSize.width))x\(Int(outputImageSize.height)) document_px=\(Int(documentSize.width))x\(Int(documentSize.height)) composite_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: compositeStartedAt, to: compositeCompletedAt)) encode_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: encodeStartedAt, to: encodeCompletedAt)) total_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: totalStartedAt, to: encodeCompletedAt))"
        )

        return GhosttyAttachmentImageMarkupResult(
            picture: picture,
            previewData: previewData,
            renderStartedAt: totalStartedAt,
            renderCompletedAt: encodeCompletedAt
        )
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }
}

private struct GhosttyAttachmentMarkupCanvas: UIViewRepresentable {
    let image: UIImage
    let documentSize: CGSize
    /// Follows the canvas: every change to the drawing, undo and redo included, starts in PencilKit.
    @Binding var drawing: PKDrawing
    let undo: GhosttyAttachmentMarkupUndo

    func makeCoordinator() -> Coordinator {
        Coordinator(
            drawing: $drawing,
            undo: undo,
            documentSize: documentSize
        )
    }

    func makeUIView(context: Context) -> GhosttyAttachmentMarkupSurfaceView {
        let surfaceView = GhosttyAttachmentMarkupSurfaceView()
        context.coordinator.attach(to: surfaceView)
        surfaceView.configure(image: image, documentSize: documentSize)
        surfaceView.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] canvasView in
            coordinator?.canvasWindowAttachmentDidChange(canvasView)
        }
        context.coordinator.attachToolPicker(to: surfaceView.canvasView)
        return surfaceView
    }

    func updateUIView(_ surfaceView: GhosttyAttachmentMarkupSurfaceView, context: Context) {
        surfaceView.configure(image: image, documentSize: documentSize)
        context.coordinator.updateToolPicker(for: surfaceView.canvasView)
    }

    static func dismantleUIView(_ uiView: GhosttyAttachmentMarkupSurfaceView, coordinator: Coordinator) {
        uiView.onWindowAttachmentChanged = nil
        coordinator.detachToolPicker(from: uiView.canvasView)
        coordinator.detach(from: uiView)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding private var drawing: PKDrawing
        private let undo: GhosttyAttachmentMarkupUndo
        private let toolPicker: PKToolPicker
        private weak var surfaceView: GhosttyAttachmentMarkupSurfaceView?

        init(drawing: Binding<PKDrawing>, undo: GhosttyAttachmentMarkupUndo, documentSize: CGSize) {
            _drawing = drawing
            self.undo = undo
            toolPicker = Self.makeToolPicker(documentSize: documentSize)
        }

        func attach(to surfaceView: GhosttyAttachmentMarkupSurfaceView) {
            self.surfaceView = surfaceView
            undo.canvasView = surfaceView.canvasView
            surfaceView.scrollView.delegate = self
            surfaceView.canvasView.delegate = self
        }

        func detach(from surfaceView: GhosttyAttachmentMarkupSurfaceView) {
            if surfaceView.scrollView.delegate === self {
                surfaceView.scrollView.delegate = nil
            }
            if surfaceView.canvasView.delegate === self {
                surfaceView.canvasView.delegate = nil
            }
            if self.surfaceView === surfaceView {
                self.surfaceView = nil
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
            // The stroke's undo registration lands after this callback.
            Task { @MainActor [undo] in
                undo.refresh()
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            guard scrollView === surfaceView?.scrollView else { return nil }
            return surfaceView?.contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard scrollView === surfaceView?.scrollView else { return }
            surfaceView?.centerDocument()
        }

        func attachToolPicker(to canvasView: PKCanvasView) {
            toolPicker.addObserver(canvasView)
            showToolPicker(for: canvasView)
        }

        /// Brings the palette back whenever the canvas has let go of the keyboard focus it needs to show it.
        func updateToolPicker(for canvasView: PKCanvasView) {
            guard !canvasView.isFirstResponder else { return }
            showToolPicker(for: canvasView)
        }

        func canvasWindowAttachmentDidChange(_ canvasView: PKCanvasView) {
            showToolPicker(for: canvasView)
        }

        func detachToolPicker(from canvasView: PKCanvasView) {
            toolPicker.setVisible(false, forFirstResponder: canvasView)
            toolPicker.removeObserver(canvasView)
        }

        private func showToolPicker(for canvasView: PKCanvasView) {
            guard canvasView.window != nil else { return }
            canvasView.becomeFirstResponder()
            toolPicker.setVisible(true, forFirstResponder: canvasView)
        }

        private static func makeToolPicker(documentSize: CGSize) -> PKToolPicker {
            let widths = toolWidths(documentSize: documentSize)
            let pen = PKToolPickerInkingItem(
                type: .pen,
                color: .systemBlue,
                width: widths.pen,
                identifier: "remux.markup.pen"
            )
            pen.allowsColorSelection = true

            let marker = PKToolPickerInkingItem(
                type: .marker,
                color: .systemYellow,
                width: widths.marker,
                identifier: "remux.markup.marker"
            )
            marker.allowsColorSelection = true

            let monoline = PKToolPickerInkingItem(
                type: .monoline,
                color: .white,
                width: widths.monoline,
                identifier: "remux.markup.monoline"
            )
            monoline.allowsColorSelection = true

            let eraser = PKToolPickerEraserItem(type: .bitmap)
            let lasso = PKToolPickerLassoItem()
            let ruler = PKToolPickerRulerItem()
            let picker = PKToolPicker(
                toolItems: [
                    pen,
                    marker,
                    monoline,
                    eraser,
                    lasso,
                    ruler,
                ]
            )
            picker.selectedToolItem = pen
            picker.showsDrawingPolicyControls = false
            picker.colorUserInterfaceStyle = .light
            picker.stateAutosaveName = "dev.remux.markup.tool-picker"
            return picker
        }

        private static func toolWidths(documentSize: CGSize) -> (pen: CGFloat, marker: CGFloat, monoline: CGFloat) {
            let longSide = max(documentSize.width, documentSize.height)
            guard longSide > 0 else {
                return (pen: 5, marker: 16, monoline: 7)
            }

            let documentScale = min(1, longSide / GhosttyAttachmentImageMarkupRenderer.maxDocumentLongSide)
            return (
                pen: max(5, 12 * documentScale),
                marker: max(16, 32 * documentScale),
                monoline: max(7, 18 * documentScale)
            )
        }
    }
}

private final class GhosttyAttachmentMarkupSurfaceView: UIView {
    let scrollView = UIScrollView()
    let contentView = UIView()
    let canvasView = GhosttyAttachmentMarkupCanvasView()
    var onWindowAttachmentChanged: ((PKCanvasView) -> Void)?

    private let imageView = UIImageView()
    private var displayedImage: UIImage?
    private var documentSize: CGSize = .zero
    private var needsInitialZoom = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: UIImage, documentSize: CGSize) {
        guard documentSize.width > 0, documentSize.height > 0 else { return }
        let imageChanged = displayedImage !== image || self.documentSize != documentSize
        guard imageChanged else { return }

        displayedImage = image
        self.documentSize = documentSize
        needsInitialZoom = true

        imageView.image = image
        contentView.bounds = CGRect(origin: .zero, size: documentSize)
        contentView.frame = CGRect(origin: .zero, size: documentSize)
        imageView.frame = contentView.bounds
        canvasView.frame = contentView.bounds
        canvasView.contentSize = documentSize
        scrollView.contentSize = documentSize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateZoomScales()
        centerDocument()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowAttachmentChanged?(canvasView)
    }

    func centerDocument() {
        let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        let inset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
            scrollView.scrollIndicatorInsets = inset
        }
    }

    private func setup() {
        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(scrollView)

        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        contentView.addSubview(imageView)

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.isScrollEnabled = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        contentView.addSubview(canvasView)
    }

    private func updateZoomScales() {
        guard documentSize.width > 0,
              documentSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let fitZoom = min(bounds.width / documentSize.width, bounds.height / documentSize.height)
        let maximumZoom = max(fitZoom * 8, 4)
        let previousZoom = scrollView.zoomScale

        scrollView.minimumZoomScale = fitZoom
        scrollView.maximumZoomScale = maximumZoom

        if needsInitialZoom || previousZoom <= 0 {
            scrollView.setZoomScale(fitZoom, animated: false)
            needsInitialZoom = false
            return
        }

        let clampedZoom = min(max(previousZoom, fitZoom), maximumZoom)
        if abs(clampedZoom - previousZoom) > 0.001 {
            scrollView.setZoomScale(clampedZoom, animated: false)
        }
    }
}

private final class GhosttyAttachmentMarkupCanvasView: PKCanvasView {
    override var canBecomeFirstResponder: Bool {
        true
    }
}

private enum LoadPhase {
    case loading
    case loaded(UIImage)
    case failed

    var loadedImage: UIImage? {
        guard case .loaded(let image) = self else { return nil }
        return image
    }
}
