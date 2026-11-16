import SwiftUI
import UIKit

/// The attachments of a draft, one at a time. Swiping or tapping a thumbnail moves between them, an image can be
/// marked up in place, and the one in view can be taken out of the draft, whether it is one of several or the
/// only one.
struct GhosttyAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAttachmentID: UUID?
    @State private var markupRequest: GhosttyAttachmentMarkupRequest?
    @State private var markupFailureMessage: String?
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

    /// Markup takes the preview's place between the same bars: the thumbnail band and the bottom bar keep their
    /// space while their contents go, so the picture does not move, and the drawing palette floats over that space.
    @ViewBuilder
    private var stage: some View {
        if let request = markupRequest {
            GhosttyAttachmentImageMarkupEditor(
                imageSource: request.imageSource,
                onCancel: {
                    markupRequest = nil
                },
                onDone: { result in
                    saveMarkup(result, request: request)
                }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: GhosttyAttachmentPreviewStyle.thumbnailBandHeight)
            }
            .toolbar {
                emptyBottomBar
            }
        } else {
            pager
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // The band is kept for a single attachment too, so the picture does not move when the
                    // thumbnails come and go.
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

    @ToolbarContentBuilder
    private var emptyBottomBar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .bottomBar) {
                Color.clear.frame(width: 1, height: 1)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .bottomBar) {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    /// Opens on the selected attachment, also when it comes back after markup: a paging scroll view bound to the
    /// selection opened on the first one instead, while the toolbar acted on the selected one.
    private var pager: some View {
        TabView(selection: $selectedAttachmentID) {
            ForEach(attachments) { attachment in
                page(attachment)
                    .tag(Optional(attachment.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("terminal.attachments.preview.pager")
    }

    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            closeButton
        }

        if let selectedAttachment {
            ToolbarItemGroup(placement: .bottomBar) {
                if selectedAttachment.supportsImageMarkup {
                    markupButton(for: selectedAttachment)
                }
                Spacer()
                removeButton(for: selectedAttachment)
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
            Label("Markup", systemImage: "pencil.tip.crop.circle")
        }
        .accessibilityIdentifier("terminal.attachments.preview.markup-selected")
    }

    private func removeButton(for attachment: GhosttyPendingAttachment) -> some View {
        Button(role: .destructive) {
            remove(attachment)
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .accessibilityLabel("Remove \(attachment.title)")
        .accessibilityIdentifier("terminal.attachments.preview.remove")
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
            // It opens on the selected attachment, then follows the selection.
            .onChange(of: selectedAttachmentID, initial: true) { previous, id in
                guard let id else { return }
                withAnimation(previous == id ? nil : .snappy) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("terminal.attachments.preview.strip")
    }

    private func thumbnailRailItem(_ attachment: GhosttyPendingAttachment) -> some View {
        let isInView = isSelected(attachment)

        return Button {
            guard !isInView else { return }
            Haptic.selection()
            withAnimation(.snappy) {
                selectedAttachmentID = attachment.id
            }
        } label: {
            GhosttyAttachmentPreviewThumbnail(attachment: attachment)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .accessibilityLabel(attachment.title)
        .accessibilityAddTraits(isInView ? .isSelected : [])
        .accessibilityIdentifier("terminal.attachments.preview.thumbnail")
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
                        .foregroundStyle(RemuxAccent.fill)
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
                    .foregroundStyle(RemuxAccent.fill)
                    .background(RemuxAccent.selectedFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(RemuxAccent.fill.opacity(0.18), lineWidth: 0.75)
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
            .tint(RemuxAccent.fill)
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

    /// The editor opens at once on the attachment's own file and reads the picture itself.
    private func beginMarkup(_ attachment: GhosttyPendingAttachment) {
        guard markupRequest == nil,
              attachment.supportsImageMarkup,
              let filename = attachment.imageMarkupFilename,
              let imageSource = GhosttyAttachmentMarkupImageSource(attachment.payload) else {
            return
        }

        markupFailureMessage = nil
        markupRequest = GhosttyAttachmentMarkupRequest(
            attachmentID: attachment.id,
            imageSource: imageSource,
            sourceFilename: filename
        )
    }

    private func saveMarkup(
        _ result: GhosttyAttachmentImageMarkupResult,
        request: GhosttyAttachmentMarkupRequest
    ) {
        Task {
            do {
                let saveStartedAt = GhosttyRuntimeTrace.nowNanos()
                let stagedURL = try await stageMarkupData(
                    result.picture.data,
                    filename: GhosttyAttachmentImageMarkupRenderer.outputFilename(
                        for: request.sourceFilename,
                        contentType: result.picture.contentType
                    )
                )

                let applyStartedAt = GhosttyRuntimeTrace.nowNanos()
                applyMarkup(
                    request: request,
                    stagedURL: stagedURL,
                    previewData: result.previewData
                )
                let completedAt = GhosttyRuntimeTrace.nowNanos()
                GhosttyRuntimeTrace.perf(
                    "attachment.markup.save format=\(result.picture.contentType.preferredFilenameExtension ?? "?") bytes=\(result.picture.data.count) save_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: saveStartedAt, to: completedAt)) apply_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: applyStartedAt, to: completedAt)) done_total_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: result.renderStartedAt, to: completedAt)) post_render_ms=\(GhosttyRuntimeTrace.elapsedMilliseconds(from: result.renderCompletedAt, to: completedAt))"
                )
            } catch {
                markupRequest = nil
                markupFailureMessage = "Markup could not be saved."
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

    private func applyMarkup(
        request: GhosttyAttachmentMarkupRequest,
        stagedURL: URL,
        previewData: Data
    ) {
        defer {
            markupRequest = nil
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

private struct GhosttyAttachmentMarkupRequest {
    let attachmentID: UUID
    let imageSource: GhosttyAttachmentMarkupImageSource
    let sourceFilename: String
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
