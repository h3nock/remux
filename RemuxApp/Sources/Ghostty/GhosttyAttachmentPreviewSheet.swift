import SwiftUI
import UIKit

/// The attachments of a draft, one at a time. Swiping or tapping a thumbnail moves between them, an image can be
/// marked up in place, and the one in view can be taken out of the draft.
struct GhosttyAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var selectedAttachmentID: UUID?
    @State private var markupRequest: GhosttyAttachmentMarkupRequest?
    @State private var preparingMarkupAttachmentID: UUID?
    @State private var markupFailureMessage: String?
    @State private var previewStageHeight: CGFloat?
    @Binding var attachments: [GhosttyPendingAttachment]
    let onRemove: (GhosttyPendingAttachment.ID) -> Void

    init(
        attachments: Binding<[GhosttyPendingAttachment]>,
        initiallySelectedAttachmentID: GhosttyPendingAttachment.ID,
        onRemove: @escaping (GhosttyPendingAttachment.ID) -> Void
    ) {
        _attachments = attachments
        _selectedAttachmentID = State(initialValue: initiallySelectedAttachmentID)
        self.onRemove = onRemove
    }

    var body: some View {
        NavigationStack {
            stage
                .navigationBarTitleDisplayMode(.inline)
                .containerBackground(.clear, for: .navigation)
        }
        .onAppear {
            ensureSelectedAttachment()
        }
        .onChange(of: attachments) { _, attachments in
            if attachments.isEmpty {
                dismiss()
            } else {
                ensureSelectedAttachment()
            }
        }
        .alert(
            "Markup Unavailable",
            isPresented: markupFailureAlertBinding,
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(markupFailureMessage ?? "Markup could not be opened.")
            }
        )
    }

    /// Markup takes the preview's place in the same frame, so the picture does not move when the bars change.
    @ViewBuilder
    private var stage: some View {
        if let request = markupRequest {
            GhosttyAttachmentImageMarkupEditor(
                imageURL: request.editingURL,
                outputFormat: request.outputFormat,
                onCancel: {
                    cancelMarkup(request)
                },
                onDone: { result in
                    saveMarkup(result, request: request)
                }
            )
            .frame(height: previewStageHeight, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            pager
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    previewStageHeight = height
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // The band is kept for a single attachment too, so the picture does not move when the
                    // thumbnails come and go, and a tall picture stays clear of the drawing palette.
                    ZStack {
                        if attachments.count > 1 {
                            thumbnailRail
                        }
                    }
                    .frame(height: GhosttyAttachmentPreviewStyle.thumbnailBandHeight)
                }
                .navigationTitle(navigationTitle)
                .toolbar {
                    previewToolbar
                }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(attachments) { attachment in
                    page(attachment)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedAttachmentID)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("terminal.attachments.preview.pager")
    }

    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            closeButton
        }

        if let selectedAttachment, selectedAttachment.supportsImageMarkup {
            ToolbarItemGroup(placement: .bottomBar) {
                markupButton(for: selectedAttachment)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) {
                Haptic.tap()
                dismiss()
            }
            .accessibilityIdentifier("terminal.attachments.preview.close")
        } else {
            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .accessibilityIdentifier("terminal.attachments.preview.close")
        }
    }

    private func markupButton(for attachment: GhosttyPendingAttachment) -> some View {
        Button {
            Haptic.chromeControlPress()
            beginMarkup(attachment)
        } label: {
            if preparingMarkupAttachmentID == attachment.id {
                ProgressView()
            } else {
                Label("Markup", systemImage: "pencil.tip.crop.circle")
            }
        }
        .disabled(preparingMarkupAttachmentID != nil)
        .accessibilityIdentifier("terminal.attachments.preview.markup-selected")
    }

    private var thumbnailRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(attachments) { attachment in
                        thumbnailRailItem(attachment)
                            .id(attachment.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.center, for: .alignment)
            .onChange(of: selectedAttachmentID) { _, id in
                guard let id else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("terminal.attachments.preview.strip")
    }

    /// The thumbnail of the attachment in view carries the control that takes it out of the draft.
    private func thumbnailRailItem(_ attachment: GhosttyPendingAttachment) -> some View {
        let isInView = isSelected(attachment)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Button {
            if isInView {
                remove(attachment)
            } else {
                Haptic.selection()
                withAnimation(.snappy) {
                    selectedAttachmentID = attachment.id
                }
            }
        } label: {
            GhosttyAttachmentPreviewThumbnail(attachment: attachment)
                .overlay {
                    if isInView {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: "trash")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(shape)
                .opacity(isInView ? 1 : 0.55)
                .padding(4)
                .overlay {
                    if isInView {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(GhosttySheetPalette.primary, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isInView ? "Remove \(attachment.title)" : "Show \(attachment.title)")
        .accessibilityIdentifier(
            isInView ? "terminal.attachments.preview.remove" : "terminal.attachments.preview.thumbnail"
        )
    }

    private func remove(_ attachment: GhosttyPendingAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        Haptic.chromeControlPress()
        let neighbor = attachments.indices.contains(index + 1)
            ? attachments[index + 1].id
            : (index > 0 ? attachments[index - 1].id : nil)
        withAnimation(.snappy) {
            selectedAttachmentID = neighbor
            onRemove(attachment.id)
        }
    }

    @ViewBuilder
    private func page(_ attachment: GhosttyPendingAttachment) -> some View {
        switch attachment.previewPayload {
        case .imageData(let data):
            imagePreview(data)
        case .file(let url):
            filePreview(url)
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        case .securityScopedFile(let file):
            filePreview(file)
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        case .link(let url):
            linkPreview(url)
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        case .text:
            textPreview(textBinding: textBinding(for: attachment))
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        default:
            unavailablePreview
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        }
    }

    @ViewBuilder
    private func imagePreview(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            GhosttyAttachmentInteractiveImagePreview(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailablePreview
                .padding(GhosttyAttachmentPreviewStyle.pagePadding)
        }
    }

    private func filePreview(_ url: URL) -> some View {
        GhosttyQuickLookPreview(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ghosttyAttachmentPreviewContentSurface()
            .accessibilityIdentifier("terminal.attachments.file-preview")
    }

    private func filePreview(_ file: GhosttySecurityScopedAttachmentFile) -> some View {
        GhosttyQuickLookPreview(file: file)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ghosttyAttachmentPreviewContentSurface()
            .accessibilityIdentifier("terminal.attachments.file-preview")
    }

    private func linkPreview(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(chromeStyle.accent)
                        .accessibilityHidden(true)

                    Text(linkTitle(for: url))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(GhosttySheetPalette.primary)
                        .lineLimit(1)
                }

                Text(url.absoluteString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            Link(destination: url) {
                Label("Open Link", systemImage: "arrow.up.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(chromeStyle.accent)
                    .background(chromeStyle.selectedFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(chromeStyle.accent.opacity(0.18), lineWidth: 0.75)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GhosttyAttachmentPreviewStyle.contentPadding)
        .ghosttyAttachmentPreviewContentSurface()
        .accessibilityIdentifier("terminal.attachments.link-preview")
    }

    private func linkTitle(for url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            return "Link"
        }

        return host
    }

    @ViewBuilder
    private func textPreview(textBinding: Binding<String>) -> some View {
        TextEditor(text: textBinding)
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .foregroundStyle(GhosttySheetPalette.primary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .tint(chromeStyle.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(GhosttyAttachmentPreviewStyle.contentPadding)
            .ghosttyAttachmentPreviewContentSurface()
            .accessibilityIdentifier("terminal.attachments.text-editor")
    }

    private var unavailablePreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(GhosttySheetPalette.secondary)

            Text("Preview unavailable")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GhosttySheetPalette.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(GhosttyAttachmentPreviewStyle.contentPadding)
        .ghosttyAttachmentPreviewContentSurface()
    }

    private var selectedAttachment: GhosttyPendingAttachment? {
        if let selectedAttachmentID,
           let attachment = attachments.first(where: { $0.id == selectedAttachmentID }) {
            return attachment
        }

        return attachments.first(where: \.isPreviewable) ?? attachments.first
    }

    /// A picture needs no title; a file is known by its name.
    private var navigationTitle: String {
        guard let selectedAttachment, selectedAttachment.kind == .file else { return "" }
        return selectedAttachment.title
    }

    private func isSelected(_ attachment: GhosttyPendingAttachment) -> Bool {
        selectedAttachment?.id == attachment.id
    }

    private func ensureSelectedAttachment() {
        guard !attachments.isEmpty else {
            selectedAttachmentID = nil
            return
        }

        if let selectedAttachmentID,
           attachments.contains(where: { $0.id == selectedAttachmentID }) {
            return
        }

        selectedAttachmentID = (attachments.first(where: \.isPreviewable) ?? attachments[0]).id
    }

    private func textBinding(for attachment: GhosttyPendingAttachment) -> Binding<String> {
        Binding {
            guard let currentAttachment = attachments.first(where: { $0.id == attachment.id }),
                  case .text(let text) = currentAttachment.payload else {
                return ""
            }

            return text
        } set: { text in
            updateTextAttachment(id: attachment.id, text: text)
        }
    }

    private func updateTextAttachment(id: UUID, text: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }

        attachments[index] = attachments[index].updatingText(text)
    }

    private var markupFailureAlertBinding: Binding<Bool> {
        Binding {
            markupFailureMessage != nil
        } set: { isPresented in
            if !isPresented {
                markupFailureMessage = nil
            }
        }
    }

    private func beginMarkup(_ attachment: GhosttyPendingAttachment) {
        guard preparingMarkupAttachmentID == nil, markupRequest == nil else { return }
        preparingMarkupAttachmentID = attachment.id
        markupFailureMessage = nil

        Task {
            do {
                let request = try await makeMarkupRequest(for: attachment)
                await MainActor.run {
                    guard attachments.contains(where: { $0.id == attachment.id }) else {
                        GhosttyAttachmentStagingStore.cleanupSynchronously([request.editingURL])
                        preparingMarkupAttachmentID = nil
                        return
                    }

                    markupRequest = request
                    preparingMarkupAttachmentID = nil
                }
            } catch {
                await MainActor.run {
                    preparingMarkupAttachmentID = nil
                    markupFailureMessage = "Markup could not be opened for this image."
                }
            }
        }
    }

    private func makeMarkupRequest(
        for attachment: GhosttyPendingAttachment
    ) async throws -> GhosttyAttachmentMarkupRequest {
        guard attachment.supportsImageMarkup,
              let filename = attachment.imageMarkupFilename else {
            throw GhosttyAttachmentMarkupError.unsupported
        }

        let editingURL: URL
        switch attachment.payload {
        case .file(let url):
            editingURL = try await GhosttyAttachmentStagingStore.stageFileURL(
                url,
                filename: filename
            )
        case .securityScopedFile(let file):
            editingURL = try await Task.detached(priority: .utility) {
                try file.withAccessibleURL { accessibleURL in
                    try GhosttyAttachmentStagingStore.stageFileURLSynchronously(
                        accessibleURL,
                        filename: filename
                    )
                }
            }.value
        case .link, .text, nil:
            throw GhosttyAttachmentMarkupError.unsupported
        }

        guard await GhosttyAttachmentImagePreviewData.makePreviewData(fromFileAt: editingURL) != nil else {
            GhosttyAttachmentStagingStore.cleanupSynchronously([editingURL])
            throw GhosttyAttachmentMarkupError.previewUnavailable
        }

        let outputFormat = GhosttyAttachmentImageMarkupOutputFormat.preferred(forFilename: filename)

        return GhosttyAttachmentMarkupRequest(
            attachmentID: attachment.id,
            editingURL: editingURL,
            outputFilename: GhosttyAttachmentImageMarkupRenderer.outputFilename(
                for: filename,
                outputFormat: outputFormat
            ),
            outputFormat: outputFormat
        )
    }

    private func cancelMarkup(_ request: GhosttyAttachmentMarkupRequest) {
        GhosttyAttachmentStagingStore.cleanupSynchronously([request.editingURL])
        markupRequest = nil
    }

    private func saveMarkup(
        _ result: GhosttyAttachmentImageMarkupResult,
        request: GhosttyAttachmentMarkupRequest
    ) {
        Task {
            do {
                let saveStartedAt = GhosttyRuntimeTrace.nowNanos()
                async let stagedURLTask = stageMarkupData(
                    result.data,
                    filename: request.outputFilename
                )
                async let previewDataTask = makeMarkupPreviewData(
                    from: result.data,
                    outputFormat: result.outputFormat
                )

                let stagedURL = try await stagedURLTask
                guard let previewData = await previewDataTask else {
                    GhosttyAttachmentStagingStore.cleanupSynchronously([
                        request.editingURL,
                        stagedURL,
                    ])
                    throw GhosttyAttachmentMarkupError.previewUnavailable
                }

                let applyStartedAt = GhosttyRuntimeTrace.nowNanos()
                await MainActor.run {
                    applyMarkup(
                        request: request,
                        stagedURL: stagedURL,
                        previewData: previewData
                    )
                }
                let completedAt = GhosttyRuntimeTrace.nowNanos()
                GhosttyRuntimeTrace.perf(
                    "attachment.markup.save format=\(result.outputFormat.traceLabel) bytes=\(result.data.count) save_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: saveStartedAt, to: completedAt)) apply_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: applyStartedAt, to: completedAt)) done_total_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: result.renderStartedAt, to: completedAt)) post_render_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: result.renderCompletedAt, to: completedAt))"
                )
            } catch {
                await MainActor.run {
                    GhosttyAttachmentStagingStore.cleanupSynchronously([request.editingURL])
                    markupRequest = nil
                    markupFailureMessage = "Markup could not be saved."
                }
            }
        }
    }

    private func stageMarkupData(_ data: Data, filename: String) async throws -> URL {
        let startedAt = GhosttyRuntimeTrace.nowNanos()
        let url = try await GhosttyAttachmentStagingStore.stageData(data, filename: filename)
        GhosttyRuntimeTrace.perf(
            "attachment.markup.stage bytes=\(data.count) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
        )
        return url
    }

    private func makeMarkupPreviewData(
        from data: Data,
        outputFormat: GhosttyAttachmentImageMarkupOutputFormat
    ) async -> Data? {
        let startedAt = GhosttyRuntimeTrace.nowNanos()
        let previewData = await GhosttyAttachmentImagePreviewData.makePreviewData(from: data)
        GhosttyRuntimeTrace.perf(
            "attachment.markup.preview format=\(outputFormat.traceLabel) source_bytes=\(data.count) preview_bytes=\(previewData?.count ?? 0) elapsed_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: startedAt))"
        )
        return previewData
    }

    private func applyMarkup(
        request: GhosttyAttachmentMarkupRequest,
        stagedURL: URL,
        previewData: Data
    ) {
        defer {
            markupRequest = nil
            GhosttyAttachmentStagingStore.cleanupSynchronously([request.editingURL])
        }

        guard let index = attachments.firstIndex(where: { $0.id == request.attachmentID }) else {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            return
        }

        let previousAttachment = attachments[index]
        attachments[index] = previousAttachment.updatingAnnotatedImage(
            fileURL: stagedURL,
            previewData: previewData
        )
        GhosttyAttachmentStagingStore.cleanup([previousAttachment])
    }

}

private struct GhosttyAttachmentMarkupRequest: Identifiable, Equatable {
    let attachmentID: UUID
    let editingURL: URL
    let outputFilename: String
    let outputFormat: GhosttyAttachmentImageMarkupOutputFormat

    var id: UUID {
        attachmentID
    }
}

private enum GhosttyAttachmentMarkupError: Error {
    case unsupported
    case previewUnavailable
}

private struct GhosttyAttachmentPreviewThumbnail: View {
    let attachment: GhosttyPendingAttachment

    var body: some View {
        Group {
            if case .imageData(let data) = attachment.previewPayload,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(GhosttySheetPalette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GhosttyAttachmentPreviewStyle.controlFill)
            }
        }
        .frame(width: 48, height: 48)
    }
}
