import Combine
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct GhosttyPhotoPickerTransfer: Transferable, Sendable {
    let stagedURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { receivedFile in
            let stagedURL = try await GhosttyAttachmentStagingStore.stageFileURL(
                receivedFile.file
            )
            return GhosttyPhotoPickerTransfer(stagedURL: stagedURL)
        }
    }
}

@MainActor
struct GhosttyComposerSubmissionDestination {
    let workspaceID: UUID
    let surfaceID: UUID
    /// Recognition hint for the half-delivered status, quoting the same
    /// names the switcher and windows sheet display. Nil when unavailable.
    let destinationLabel: String?
    let makeAttachmentTransferService: @Sendable () -> any GhosttyAttachmentTransferService
    let prepareTerminalInput: () -> Void
    let sendPaste: (String) async -> Bool
    let sendEnter: () async -> Bool

    nonisolated static func label(sessionName: String?, windowName: String?) -> String? {
        let parts = [sessionName, windowName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return clampedMiddle(parts.joined(separator: ": "), maxLength: 15)
    }

    private nonisolated static func clampedMiddle(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let keep = maxLength - 1
        let head = text.prefix((keep + 1) / 2)
        let tail = text.suffix(keep / 2)
        return "\(head)…\(tail)"
    }
}

@MainActor
final class GhosttyComposerModel: ObservableObject {
    private struct AttachmentTransferState {
        let uploadCount: Int
        var progress: GhosttyAttachmentTransferProgress?
    }

    private enum AttachmentPreparationSource {
        case photo(PhotosPickerItem)
        case pastedFile(URL)
        case pastedImage(GhosttyAttachmentPasteboardSnapshot.ImageProviderRequest)
    }

    private struct AttachmentPreparationJob {
        let source: AttachmentPreparationSource
        let attemptID: UUID
        var task: Task<Void, Never>?
    }

    private static var pasteSettlementDelay: Duration { .milliseconds(150) }

    @Published var isPresented = false
    @Published var draft = "" {
        didSet {
            // Editing dismisses stale status. This lives on the model because
            // the screen does not re-evaluate on draft changes.
            guard oldValue != draft else { return }
            clearStatusMessage()
        }
    }
    @Published var attachments: [GhosttyPendingAttachment] = []
    @Published var statusMessage: String?
    @Published private(set) var isSubmitting = false
    @Published private var attachmentTransferState: AttachmentTransferState?

    let dictationController: GhosttyComposerDictationController

    private var submissionController = GhosttyComposerSubmissionController()
    private var attachmentPreparationJobs: [
        GhosttyPendingAttachment.ID: AttachmentPreparationJob
    ] = [:]
    private var submissionTask: Task<Void, Never>?
    private var dictationObservation: AnyCancellable?

    init(
        dictationController: GhosttyComposerDictationController =
            GhosttyComposerDictationController.makeDefault()
    ) {
        self.dictationController = dictationController
        dictationObservation = dictationController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    isolated deinit {
        submissionTask?.cancel()
        for job in attachmentPreparationJobs.values {
            job.task?.cancel()
        }
        GhosttyAttachmentStagingStore.cleanup(attachments)
    }

    var snapshot: GhosttyComposerSessionState {
        GhosttyComposerSessionState(draft: draft, attachments: attachments)
    }

    var hasContent: Bool {
        snapshot.hasContent
    }

    var areAttachmentsReady: Bool {
        snapshot.areAttachmentsReady
    }

    var attachmentTransferUploadCount: Int {
        attachmentTransferState?.uploadCount ?? 0
    }

    var attachmentTransferProgress: GhosttyAttachmentTransferProgress? {
        attachmentTransferState?.progress
    }

    /// Clears the status message without firing `objectWillChange` when it
    /// is already nil. Draft edits clear status on every keystroke, so an
    /// unconditional write would invalidate every subscriber twice per key.
    func clearStatusMessage() {
        guard statusMessage != nil else { return }
        statusMessage = nil
    }

    func open() {
        statusMessage = nil
        dictationController.prepare()
        isPresented = true
    }

    func close() {
        statusMessage = nil
        isPresented = false
    }

    func startDictation() {
        guard dictationController.phase == .idle else { return }
        statusMessage = nil
        dictationController.start(
            draft: draft,
            onTranscript: { [weak self] transcript in
                self?.draft = transcript
            },
            onFailure: { [weak self] message in
                self?.statusMessage = message
            }
        )
    }

    func cancelDictation() {
        dictationController.cancel()
    }

    func finishDictation() {
        GhosttyRuntimeTrace.perf("composer.dictation.stopTapped")
        dictationController.finish()
    }

    func stopDictationImmediately() {
        dictationController.stopImmediately()
    }

    /// Each add below also prepares `transferService`, the server the attachment will be sent to, so Send doesn't
    /// wait for its connection.
    @discardableResult
    func addPhotoSelections(
        _ items: [PhotosPickerItem],
        preparing transferService: any GhosttyAttachmentTransferService
    ) -> Bool {
        let pendingAttachments = GhosttyPendingAttachment.mediaSelections(
            contentTypes: items.map(\.supportedContentTypes)
        )
        guard !pendingAttachments.isEmpty else { return false }

        attachments.append(contentsOf: pendingAttachments)
        statusMessage = nil
        prepareTransfer(transferService)
        for (item, attachment) in zip(items, pendingAttachments) {
            beginAttachmentPreparation(attachment.id, from: .photo(item))
        }
        return true
    }

    @discardableResult
    func addSecurityScopedFiles(
        _ urls: [URL],
        preparing transferService: any GhosttyAttachmentTransferService
    ) async throws -> Bool {
        guard !urls.isEmpty else { return false }
        let pendingAttachments = try await Task.detached(priority: .utility) {
            try GhosttyPendingAttachment.securityScopedFiles(urls: urls)
        }.value
        guard !pendingAttachments.isEmpty else { return false }

        attachments.append(contentsOf: pendingAttachments)
        statusMessage = nil
        prepareTransfer(transferService)
        return true
    }

    func addPastedImage(
        _ request: GhosttyAttachmentPasteboardSnapshot.ImageProviderRequest,
        preparing transferService: any GhosttyAttachmentTransferService
    ) {
        let attachment = GhosttyPendingAttachment.pasteboardImagePlaceholder()
        attachments.append(attachment)
        statusMessage = nil
        prepareTransfer(transferService)
        beginAttachmentPreparation(attachment.id, from: .pastedImage(request))
    }

    func addPastedFile(
        _ url: URL,
        preparing transferService: any GhosttyAttachmentTransferService
    ) {
        let filename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = GhosttyPendingAttachment(
            kind: .file,
            title: filename.isEmpty ? "File" : filename,
            detail: "Preparing…",
            preparationState: .preparing
        )
        attachments.append(placeholder)
        statusMessage = nil
        prepareTransfer(transferService)
        beginAttachmentPreparation(placeholder.id, from: .pastedFile(url))
    }

    private func prepareTransfer(_ transferService: any GhosttyAttachmentTransferService) {
        Task {
            await transferService.prepare()
        }
    }

    func removeAttachment(_ id: GhosttyPendingAttachment.ID) {
        guard !isSubmitting,
              let index = attachments.firstIndex(where: { $0.id == id }) else {
            return
        }

        attachmentPreparationJobs.removeValue(forKey: id)?.task?.cancel()
        let attachment = attachments.remove(at: index)
        GhosttyAttachmentStagingStore.cleanup([attachment])
    }

    func retryAttachment(_ attachmentID: GhosttyPendingAttachment.ID) {
        guard let attachment = attachments.first(where: { $0.id == attachmentID }),
              attachment.didFailPreparingTransferSource,
              let source = attachmentPreparationJobs[attachmentID]?.source else {
            return
        }
        beginAttachmentPreparation(attachmentID, from: source)
    }

    func submit(to destination: GhosttyComposerSubmissionDestination) {
        guard !isSubmitting else { return }

        if dictationController.phase == .recording {
            dictationController.finish(afterTranscription: { [weak self] in
                self?.submit(to: destination)
            })
            return
        }
        guard !dictationController.phase.isActive else { return }

        let session = snapshot
        guard session.hasContent else { return }
        guard session.areAttachmentsReady else {
            statusMessage = attachmentPreparationMessage(for: session.attachments)
            return
        }

        isSubmitting = true
        statusMessage = nil
        submissionTask = Task { @MainActor [weak self] in
            await self?.performSubmission(session, to: destination)
        }
    }

    private func performSubmission(
        _ session: GhosttyComposerSessionState,
        to destination: GhosttyComposerSubmissionDestination
    ) async {
        let attachmentText: String
        if session.attachments.isEmpty {
            attachmentText = ""
        } else {
            let job: GhosttyAttachmentTransferJob
            do {
                job = try GhosttyAttachmentTransferJobBuilder.job(
                    workspaceID: destination.workspaceID,
                    attachments: session.attachments
                )
            } catch {
                finishBeforeDelivery(
                    status: attachmentPreparationMessage(for: session.attachments)
                )
                return
            }

            attachmentTransferState = AttachmentTransferState(
                uploadCount: job.uploadSourceCount,
                progress: nil
            )
            do {
                let service = destination.makeAttachmentTransferService()
                let result = try await service.transfer(job) { [weak self] progress in
                    await MainActor.run {
                        self?.attachmentTransferState?.progress = progress
                    }
                }
                attachmentText = GhosttyAttachmentTerminalInsertionFormatter.insertionText(
                    for: result
                )
            } catch {
                finishBeforeDelivery(status: attachmentSendFailureMessage(for: error))
                return
            }
            attachmentTransferState = nil
        }

        let message = GhosttyComposerMessageFormatter.message(
            draft: session.draft,
            attachmentText: attachmentText
        )
        guard !message.isEmpty else {
            finishBeforeDelivery(status: "Couldn’t send. Message kept.")
            return
        }

        destination.prepareTerminalInput()
        var controller = submissionController
        guard controller.beginSubmission(message) else {
            finishBeforeDelivery(status: nil)
            return
        }
        submissionController = controller

        let didPaste = await destination.sendPaste(message)
        guard didPaste else {
            finishDelivery(.pasteRejected, session: session, destination: destination)
            return
        }

        do {
            try await Task.sleep(for: Self.pasteSettlementDelay)
        } catch {
            finishDelivery(.pastedAwaitingSubmit, session: session, destination: destination)
            return
        }

        let result: GhosttyComposerSubmissionController.DraftResult =
            await destination.sendEnter() ? .submitted : .pastedAwaitingSubmit
        finishDelivery(result, session: session, destination: destination)
    }

    private func finishBeforeDelivery(status: String?) {
        attachmentTransferState = nil
        submissionTask = nil
        isSubmitting = false
        statusMessage = status
    }

    private func finishDelivery(
        _ proposedResult: GhosttyComposerSubmissionController.DraftResult,
        session: GhosttyComposerSessionState,
        destination: GhosttyComposerSubmissionDestination
    ) {
        var controller = submissionController
        let result = controller.finishSubmission(proposedResult)
        submissionController = controller
        attachmentTransferState = nil
        submissionTask = nil
        isSubmitting = false

        if result.didDeliverDraft {
            draft = ""
            attachments.removeAll()
            GhosttyAttachmentStagingStore.cleanup(session.attachments)
        }

        switch result {
        case .notStarted:
            break
        case .pasteRejected:
            statusMessage = "Couldn’t send. Message kept."
        case .submitted:
            statusMessage = nil
        case .pastedAwaitingSubmit:
            if let label = destination.destinationLabel {
                statusMessage = "Couldn’t finish sending. Check “\(label)”."
            } else {
                statusMessage = "Couldn’t finish sending. Check the terminal."
            }
        }
    }

    private func beginAttachmentPreparation(
        _ attachmentID: GhosttyPendingAttachment.ID,
        from source: AttachmentPreparationSource
    ) {
        guard attachments.contains(where: { $0.id == attachmentID }) else { return }

        attachmentPreparationJobs[attachmentID]?.task?.cancel()
        updateAttachment(
            id: attachmentID,
            detail: "Preparing…",
            preparationState: .preparing
        )

        let attemptID = UUID()
        attachmentPreparationJobs[attachmentID] = AttachmentPreparationJob(
            source: source,
            attemptID: attemptID,
            task: nil
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch source {
            case .photo(let item):
                await preparePhotoAttachment(
                    item,
                    attachmentID: attachmentID,
                    attemptID: attemptID
                )
            case .pastedFile(let url):
                await preparePastedFileAttachment(
                    url,
                    attachmentID: attachmentID,
                    attemptID: attemptID
                )
            case .pastedImage(let request):
                await preparePastedImageAttachment(
                    request,
                    attachmentID: attachmentID,
                    attemptID: attemptID
                )
            }
        }

        guard attachmentPreparationJobs[attachmentID]?.attemptID == attemptID else {
            task.cancel()
            return
        }
        attachmentPreparationJobs[attachmentID]?.task = task
    }

    private func preparePhotoAttachment(
        _ item: PhotosPickerItem,
        attachmentID: GhosttyPendingAttachment.ID,
        attemptID: UUID
    ) async {
        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }),
              let title = attachments.first(where: { $0.id == attachmentID })?.title else {
            failAttachmentPreparation(attachmentID, attemptID: attemptID)
            return
        }

        var stagedURL: URL?
        do {
            guard let transfer = try await item.loadTransferable(
                type: GhosttyPhotoPickerTransfer.self
            ) else {
                failAttachmentPreparation(attachmentID, attemptID: attemptID)
                return
            }
            stagedURL = transfer.stagedURL
            try Task.checkCancellation()

            let renamedURL = try await GhosttyAttachmentStagingStore.renameStagedFile(
                transfer.stagedURL,
                filename: GhosttyAttachmentStagingStore.imageFilename(
                    title: title,
                    contentTypes: item.supportedContentTypes,
                    uniqueID: attachmentID
                )
            )
            stagedURL = renamedURL
            guard let photo = await GhosttyPendingAttachment.photo(
                title: title,
                stagedFileURL: renamedURL
            ) else {
                failAttachmentPreparation(attachmentID, attemptID: attemptID)
                return
            }
            applyPreparedAttachment(photo, to: attachmentID, attemptID: attemptID)
        } catch is CancellationError {
            if let stagedURL {
                GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            }
        } catch {
            if let stagedURL {
                GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            }
            failAttachmentPreparation(attachmentID, attemptID: attemptID)
        }
    }

    private func preparePastedFileAttachment(
        _ url: URL,
        attachmentID: GhosttyPendingAttachment.ID,
        attemptID: UUID
    ) async {
        var stagedURL: URL?
        do {
            let preparedURL = try await GhosttyAttachmentStagingStore.stageFileURL(url)
            stagedURL = preparedURL
            try Task.checkCancellation()
            applyPreparedAttachment(
                .file(url: preparedURL),
                to: attachmentID,
                attemptID: attemptID
            )
        } catch is CancellationError {
            if let stagedURL {
                GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            }
        } catch {
            if let stagedURL {
                GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
            }
            failAttachmentPreparation(attachmentID, attemptID: attemptID)
        }
    }

    private func preparePastedImageAttachment(
        _ request: GhosttyAttachmentPasteboardSnapshot.ImageProviderRequest,
        attachmentID: GhosttyPendingAttachment.ID,
        attemptID: UUID
    ) async {
        guard let attachment = await GhosttyAttachmentPasteboardSnapshot.imageAttachment(
            from: request
        ) else {
            failAttachmentPreparation(attachmentID, attemptID: attemptID)
            return
        }
        applyPreparedAttachment(attachment, to: attachmentID, attemptID: attemptID)
    }

    private func applyPreparedAttachment(
        _ preparedAttachment: GhosttyPendingAttachment,
        to attachmentID: GhosttyPendingAttachment.ID,
        attemptID: UUID
    ) {
        guard attachmentPreparationJobs[attachmentID]?.attemptID == attemptID,
              attachments.contains(where: { $0.id == attachmentID }) else {
            GhosttyAttachmentStagingStore.cleanup([preparedAttachment])
            return
        }

        updateAttachment(
            id: attachmentID,
            payload: preparedAttachment.payload,
            previewPayload: preparedAttachment.previewPayload,
            detail: preparedAttachment.detail,
            preparationState: .ready
        )
        attachmentPreparationJobs.removeValue(forKey: attachmentID)
    }

    private func failAttachmentPreparation(
        _ attachmentID: GhosttyPendingAttachment.ID,
        attemptID: UUID,
        detail: String = "Couldn’t load"
    ) {
        guard attachmentPreparationJobs[attachmentID]?.attemptID == attemptID else { return }
        guard attachments.contains(where: { $0.id == attachmentID }) else {
            attachmentPreparationJobs.removeValue(forKey: attachmentID)
            return
        }

        updateAttachment(
            id: attachmentID,
            detail: detail,
            preparationState: .failed
        )
        attachmentPreparationJobs[attachmentID]?.task = nil
    }

    private func updateAttachment(
        id: UUID,
        payload: GhosttyAttachmentPayload? = nil,
        previewPayload: GhosttyAttachmentPreviewPayload? = nil,
        detail: String,
        preparationState: GhosttyPendingAttachment.PreparationState? = nil
    ) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index] = attachments[index].updating(
            payload: payload,
            previewPayload: previewPayload,
            detail: detail,
            preparationState: preparationState
        )
    }

    private func attachmentPreparationMessage(
        for attachments: [GhosttyPendingAttachment]
    ) -> String {
        if attachments.contains(where: \.didFailPreparingTransferSource) {
            return "An attachment couldn’t load. Retry or remove it."
        }
        if attachments.contains(where: \.isPreparingTransferSource) {
            return "An attachment is still preparing."
        }
        return "An attachment isn’t ready yet."
    }

    private func attachmentSendFailureMessage(for error: Error) -> String {
        guard let transferError = error as? GhosttyAttachmentTransferError else {
            return "Couldn’t send the attachment."
        }

        switch transferError {
        case .noSources, .localSourceUnavailable:
            return "An attachment isn’t ready yet."
        case .securityScopedSourceUnavailable:
            return "Choose the file again to send it."
        case .remoteDirectoryCreationFailed, .uploadFailed, .remoteRenameFailed:
            return "Server couldn’t save the attachment."
        case .remoteOperationTimedOut:
            return "Upload stalled. Check network or VPN."
        case .remotePathResolutionFailed:
            return "Couldn’t start the upload. Try again."
        case .cancelled:
            return "Upload canceled."
        case .terminalInsertionFailed:
            return "Couldn’t send the attachment."
        }
    }
}
