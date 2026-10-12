import SwiftUI
import UIKit

struct GhosttyAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ghosttyTerminalChromeStyle) private var chromeStyle
    @State private var selectedAttachmentID: UUID?
    @State private var markupRequest: GhosttyAttachmentMarkupRequest?
    @State private var preparingMarkupAttachmentID: UUID?
    @State private var markupFailureMessage: String?
    @Binding var attachments: [GhosttyPendingAttachment]

    init(
        attachments: Binding<[GhosttyPendingAttachment]>,
        initiallySelectedAttachmentID: GhosttyPendingAttachment.ID
    ) {
        _attachments = attachments
        _selectedAttachmentID = State(initialValue: initiallySelectedAttachmentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if attachments.count > 1 {
                attachmentStrip
            }

            attachmentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .onAppear {
            ensureSelectedAttachment()
        }
        .onChange(of: attachments) { _, _ in
            ensureSelectedAttachment()
        }
        .fullScreenCover(item: $markupRequest) { request in
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

    private var header: some View {
        HStack(spacing: 12) {
            GhosttyAttachmentPreviewHeader(
                title: previewTitle
            )
            .layoutPriority(1)

            Spacer(minLength: 0)

            if let selectedAttachment,
               selectedAttachment.supportsImageMarkup {
                markupButton(for: selectedAttachment)
            }

            Button {
                Haptic.tap()
                dismiss()
            } label: {
                Text("Close")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 38)
            }
            .buttonStyle(GhosttyAttachmentPreviewCloseButtonStyle())
            .accessibilityIdentifier("terminal.attachments.preview.close")
        }
    }

    private var attachmentStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        Button {
                            Haptic.selection()
                            withAnimation(.easeOut(duration: 0.16)) {
                                selectedAttachmentID = attachment.id
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: attachment.systemName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolRenderingMode(.monochrome)

                                Text(attachment.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(
                                        maxWidth: GhosttyAttachmentPreviewStyle.chipTitleMaxWidth,
                                        alignment: .leading
                                    )
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                        }
                        .buttonStyle(
                            GhosttyAttachmentPreviewChipButtonStyle(
                                isSelected: isSelected(attachment),
                                chromeStyle: chromeStyle
                            )
                        )
                        .id(attachment.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .onChange(of: selectedAttachmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("terminal.attachments.preview.strip")
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if let attachment = selectedAttachment {
            attachmentPreviewCard(attachment)
        } else {
            unavailablePreviewCard
        }
    }

    private func attachmentPreviewCard(_ attachment: GhosttyPendingAttachment) -> some View {
        attachmentPreviewBody(attachment)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func markupButton(for attachment: GhosttyPendingAttachment) -> some View {
        let isPreparingSelectedMarkup = preparingMarkupAttachmentID == attachment.id

        return Button {
            Haptic.chromeControlPress()
            beginMarkup(attachment)
        } label: {
            if isPreparingSelectedMarkup {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 38, height: 38)
            } else {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 38, height: 38)
            }
        }
        .buttonStyle(
            GhosttyAttachmentPreviewActionButtonStyle(
                foreground: GhosttySheetPalette.primary
            )
        )
        .disabled(preparingMarkupAttachmentID != nil)
        .accessibilityLabel("Markup attachment")
        .accessibilityIdentifier("terminal.attachments.preview.markup-selected")
    }

    @ViewBuilder
    private func attachmentPreviewBody(_ attachment: GhosttyPendingAttachment) -> some View {
        switch attachment.previewPayload {
        case .imageData(let data):
            imagePreview(data, attachmentID: attachment.id)
        case .file(let url):
            filePreview(url)
        case .securityScopedFile(let file):
            filePreview(file)
        case .link(let url):
            linkPreview(url)
        case .text:
            textPreview(textBinding: textBinding(for: attachment))
        default:
            unavailablePreview
        }
    }

    private func imagePreview(_ data: Data, attachmentID: UUID) -> some View {
        GhosttyAttachmentImagePreview(data: data) { image in
            if let image {
                GhosttyAttachmentInteractiveImagePreview(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ghosttyAttachmentPreviewContentSurface(
                        fill: GhosttyAttachmentPreviewStyle.mediaFill
                    )
            } else {
                unavailablePreview
            }
        }
        .id(data)
        .id(attachmentID)
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

    private var unavailablePreviewCard: some View {
        unavailablePreview
    }

    private var selectedAttachment: GhosttyPendingAttachment? {
        if let selectedAttachmentID,
           let attachment = attachments.first(where: { $0.id == selectedAttachmentID }) {
            return attachment
        }

        return attachments.first(where: \.isPreviewable) ?? attachments.first
    }

    private var previewTitle: String {
        guard let selectedAttachment else {
            return "Attachment"
        }

        guard attachments.count > 1,
              let selectedIndex = attachments.firstIndex(where: {
                  $0.id == selectedAttachment.id
              }) else {
            return selectedAttachment.title
        }

        return "\(selectedAttachment.title) · \(selectedIndex + 1) of \(attachments.count)"
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

private struct GhosttyAttachmentImagePreview<Content: View>: View {
    @StateObject private var previewImage: GhosttyAttachmentPreviewImage
    private let content: (UIImage?) -> Content

    init(data: Data, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        // Keep construction lazy so repeated view initialization preserves the image and zoom.
        _previewImage = StateObject(wrappedValue: GhosttyAttachmentPreviewImage(data: data))
        self.content = content
    }

    var body: some View {
        content(previewImage.image)
    }
}

private final class GhosttyAttachmentPreviewImage: ObservableObject {
    let image: UIImage?

    init(data: Data) {
        image = UIImage(data: data)
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

private struct GhosttyAttachmentPreviewHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(GhosttySheetPalette.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
