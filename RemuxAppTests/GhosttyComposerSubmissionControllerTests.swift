import UIKit
import XCTest
@testable import Remux

final class GhosttyComposerSubmissionControllerTests: XCTestCase {
    func testComposerMessagePlacesAttachmentReferencesAfterDraft() {
        XCTAssertEqual(
            GhosttyComposerMessageFormatter.message(
                draft: "Review these files",
                attachmentText: "~/first.txt ~/second.txt"
            ),
            "Review these files\n~/first.txt ~/second.txt"
        )
    }

    func testComposerMessageSupportsAttachmentOnlySubmission() {
        XCTAssertEqual(
            GhosttyComposerMessageFormatter.message(
                draft: "",
                attachmentText: "~/photo.png"
            ),
            "~/photo.png"
        )
    }

    func testComposerSessionRequiresEveryAttachmentToBeReady() {
        var session = GhosttyComposerSessionState()
        session.attachments = [.pasteboardImagePlaceholder()]

        XCTAssertTrue(session.hasContent)
        XCTAssertFalse(session.areAttachmentsReady)

        session.attachments = [.file(url: URL(fileURLWithPath: "/tmp/report.txt"))]
        XCTAssertTrue(session.areAttachmentsReady)

        session.attachments = [
            GhosttyPendingAttachment
                .pasteboardImagePlaceholder()
                .updating(detail: "Couldn’t load", preparationState: .failed),
        ]
        XCTAssertFalse(session.areAttachmentsReady)
    }

    @MainActor
    func testComposerCleansUnsentStagedFilesWhenReleased() async throws {
        let stagedURL = try GhosttyAttachmentStagingStore.stageDataSynchronously(
            Data("unsent".utf8),
            filename: "unsent.txt"
        )
        addTeardownBlock {
            GhosttyAttachmentStagingStore.cleanupSynchronously([stagedURL])
        }

        var session: GhosttyComposerModel? = GhosttyComposerModel()
        session?.draft = "Review this"
        let attachment = GhosttyPendingAttachment.file(url: stagedURL)
        session?.attachments = [attachment]
        XCTAssertEqual(
            session?.snapshot,
            GhosttyComposerSessionState(
                draft: "Review this",
                attachments: [attachment]
            )
        )
        session = nil

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while FileManager.default.fileExists(atPath: stagedURL.path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @MainActor
    func testClosingAndReopeningPreservesContentAndClearsTransientStatus() {
        let composer = GhosttyComposerModel()
        composer.draft = "Keep this draft"
        composer.attachments = [.file(url: URL(fileURLWithPath: "/tmp/report.txt"))]
        composer.statusMessage = "Couldn’t start dictation"

        composer.open()
        composer.close()
        composer.statusMessage = "Couldn’t finish sending. Check the terminal."
        composer.open()

        XCTAssertTrue(composer.isPresented)
        XCTAssertEqual(composer.draft, "Keep this draft")
        XCTAssertEqual(composer.attachments.count, 1)
        XCTAssertNil(composer.statusMessage)
    }

    @MainActor
    func testSuccessfulSubmissionUsesOneDestinationAndClearsDeliveredContent() async {
        let composer = GhosttyComposerModel()
        composer.draft = "Explain this"
        var prepareCount = 0
        var pastedMessages: [String] = []
        var enterCount = 0
        let destination = GhosttyComposerSubmissionDestination(
            workspaceID: UUID(),
            surfaceID: UUID(),
            destinationLabel: nil,
            makeAttachmentTransferService: {
                XCTFail("Text-only submission must not create an attachment service")
                return FailingComposerAttachmentTransferService()
            },
            prepareTerminalInput: {
                prepareCount += 1
            },
            sendPaste: { message in
                pastedMessages.append(message)
                return true
            },
            sendEnter: {
                enterCount += 1
                return true
            }
        )

        composer.submit(to: destination)
        await waitUntil { !composer.isSubmitting }

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(pastedMessages, ["Explain this"])
        XCTAssertEqual(enterCount, 1)
        XCTAssertEqual(composer.draft, "")
        XCTAssertTrue(composer.attachments.isEmpty)
        XCTAssertNil(composer.statusMessage)
    }

    @MainActor
    func testRejectedPastePreservesComposerContentAndNeverSendsEnter() async {
        let composer = GhosttyComposerModel()
        composer.draft = "Keep this"
        var enterCount = 0
        let destination = GhosttyComposerSubmissionDestination(
            workspaceID: UUID(),
            surfaceID: UUID(),
            destinationLabel: nil,
            makeAttachmentTransferService: {
                FailingComposerAttachmentTransferService()
            },
            prepareTerminalInput: {},
            sendPaste: { _ in false },
            sendEnter: {
                enterCount += 1
                return true
            }
        )

        composer.submit(to: destination)
        await waitUntil { !composer.isSubmitting }

        XCTAssertEqual(enterCount, 0)
        XCTAssertEqual(composer.draft, "Keep this")
        XCTAssertEqual(composer.statusMessage, "Couldn’t send. Message kept.")
    }

    @MainActor
    func testUnconfirmedEnterNamesDestinationInStatus() async {
        let composer = GhosttyComposerModel()
        composer.draft = "Run the tests"
        let destination = GhosttyComposerSubmissionDestination(
            workspaceID: UUID(),
            surfaceID: UUID(),
            destinationLabel: "mini: claude",
            makeAttachmentTransferService: {
                FailingComposerAttachmentTransferService()
            },
            prepareTerminalInput: {},
            sendPaste: { _ in true },
            sendEnter: { false }
        )

        composer.submit(to: destination)
        await waitUntil { !composer.isSubmitting }

        XCTAssertEqual(composer.draft, "")
        XCTAssertEqual(
            composer.statusMessage,
            "Couldn’t finish sending. Check “mini: claude”."
        )
    }

    func testDestinationLabelJoinsClampsAndFallsBack() {
        XCTAssertEqual(
            GhosttyComposerSubmissionDestination.label(
                sessionName: "mini",
                windowName: "claude"
            ),
            "mini: claude"
        )
        XCTAssertEqual(
            GhosttyComposerSubmissionDestination.label(
                sessionName: nil,
                windowName: "claude"
            ),
            "claude"
        )
        XCTAssertNil(
            GhosttyComposerSubmissionDestination.label(sessionName: "  ", windowName: nil)
        )
        XCTAssertEqual(
            GhosttyComposerSubmissionDestination.label(
                sessionName: "api-server-production",
                windowName: "claude-code"
            ),
            "api-ser…de-code"
        )
    }

    func testUploadedAttachmentAndDraftCanBeginSubmission() {
        let sourceID = UUID()
        let transferResult = GhosttyAttachmentTransferResult(
            transferID: UUID(),
            items: [
                .remoteFile(
                    sourceID: sourceID,
                    path: GhosttyRemoteAttachmentPath(
                        sourceID: sourceID,
                        filename: "report.txt",
                        remoteDirectory: ".cache/remux/attachments/job",
                        remoteTemporaryPath: ".cache/remux/attachments/job/.report.txt.part",
                        remoteFinalPath: ".cache/remux/attachments/job/report.txt",
                        terminalPath: "~/.cache/remux/attachments/job/report.txt"
                    )
                ),
            ]
        )
        let message = GhosttyComposerMessageFormatter.message(
            draft: "Summarize this report",
            attachmentText: GhosttyAttachmentTerminalInsertionFormatter.insertionText(
                for: transferResult
            )
        )
        var controller = GhosttyComposerSubmissionController()

        XCTAssertTrue(controller.beginSubmission(message))
        XCTAssertEqual(controller.phase, .sending)
        XCTAssertEqual(controller.finishSubmission(.submitted), .submitted)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testSuccessfulSubmissionReturnsIdleAndMarksDraftDelivered() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("first\nsecond"))
        let result = controller.finishSubmission(.submitted)

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRejectedPastePreservesDraft() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("draft"))
        let result = controller.finishSubmission(.pasteRejected)

        XCTAssertEqual(result, .pasteRejected)
        XCTAssertFalse(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAcceptedPasteWithRejectedEnterDoesNotOfferAnotherPaste() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("draft"))
        let result = controller.finishSubmission(.pastedAwaitingSubmit)

        XCTAssertEqual(result, .pastedAwaitingSubmit)
        XCTAssertTrue(result.didDeliverDraft)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCannotBeginAnotherSubmissionWhileSending() {
        var controller = GhosttyComposerSubmissionController()
        XCTAssertTrue(controller.beginSubmission("first"))
        XCTAssertFalse(controller.beginSubmission("second"))
        XCTAssertEqual(controller.phase, .sending)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct FailingComposerAttachmentTransferService: GhosttyAttachmentTransferService {
    func prepare() async {}

    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        _ = job
        _ = progress
        throw GhosttyAttachmentTransferError.cancelled
    }
}

@MainActor
final class GhosttyComposerModelStatusMessageTests: XCTestCase {
    func testEditingDraftClearsStatusMessage() {
        let composer = GhosttyComposerModel()
        composer.statusMessage = "Couldn’t send. Message kept."

        composer.draft = "retrying with an edit"

        XCTAssertNil(composer.statusMessage)
    }

    func testRewritingIdenticalDraftKeepsStatusMessage() {
        let composer = GhosttyComposerModel()
        composer.draft = "unchanged"
        composer.statusMessage = "Couldn’t send. Message kept."

        composer.draft = "unchanged"

        XCTAssertEqual(composer.statusMessage, "Couldn’t send. Message kept.")
    }
}

@MainActor
final class GhosttyComposerPhotoNamingTests: XCTestCase {
    func testARemovedPhotosNumberIsNotGivenToTheNextPhoto() throws {
        let composer = GhosttyComposerModel()
        let service = FailingComposerAttachmentTransferService()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

        composer.addCapturedPhoto(photo, preparing: service)
        composer.addCapturedPhoto(photo, preparing: service)
        XCTAssertEqual(composer.attachments.map(\.title), ["Photo 1", "Photo 2"])

        composer.removeAttachment(try XCTUnwrap(composer.attachments.last).id)
        composer.addCapturedPhoto(photo, preparing: service)
        XCTAssertEqual(composer.attachments.map(\.title), ["Photo 1", "Photo 3"])

        for attachment in composer.attachments {
            composer.removeAttachment(attachment.id)
        }
        composer.addCapturedPhoto(photo, preparing: service)
        XCTAssertEqual(composer.attachments.map(\.title), ["Photo"], "A draft with no photo left starts again.")
    }
}

@MainActor
final class GhosttyComposerAttachmentPrepareTests: XCTestCase {
    func testAddingAPastedFilePreparesTheDestinationsTransfer() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let url = try makeTemporaryFile()

        composer.addPastedFile(url, preparing: service)

        try await waitForPrepareCount(1, of: service)
        XCTAssertEqual(composer.attachments.count, 1)
    }

    func testAddingChosenFilesPreparesTheDestinationsTransferOnce() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let urls = [try makeTemporaryFile(), try makeTemporaryFile()]

        let didAdd = try await composer.addSecurityScopedFiles(urls, preparing: service)

        XCTAssertTrue(didAdd)
        try await waitForPrepareCount(1, of: service)
    }

    func testAddingACapturedPhotoStagesItAsAPhotoAndPreparesTheTransfer() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }

        composer.addCapturedPhoto(image, preparing: service)

        XCTAssertEqual(composer.attachments.map(\.preparationState), [.preparing])
        try await waitForPrepareCount(1, of: service)
        let deadline = ContinuousClock.now + .seconds(5)
        while composer.attachments.first?.preparationState == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attachment = try XCTUnwrap(composer.attachments.first)
        addTeardownBlock {
            GhosttyAttachmentStagingStore.cleanup([attachment])
        }
        XCTAssertEqual(attachment.preparationState, .ready)
        XCTAssertEqual(attachment.kind, .photo)
        XCTAssertNotNil(attachment.previewPayload)
        guard case .file(let url) = attachment.payload else {
            return XCTFail("A captured photo is staged as a file.")
        }
        XCTAssertEqual(url.pathExtension, "jpeg")
        XCTAssertEqual(try Data(contentsOf: url).prefix(2), Data([0xFF, 0xD8]))
    }

    /// A picture among the files picked in Files joins as a picture, prepared as a photo is under its own name;
    /// the others are files, sent as they are, in the order they were picked.
    func testAPictureFromFilesJoinsAsAPicture() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appendingPathComponent("shot.png")
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }).write(to: picture)
        let original = try Data(contentsOf: picture)
        let report = directory.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: report)

        let didAdd = try await composer.addSecurityScopedFiles([report, picture], preparing: service)

        XCTAssertTrue(didAdd)
        XCTAssertEqual(composer.attachments.map(\.kind), [.file, .picture])
        let deadline = ContinuousClock.now + .seconds(5)
        while composer.attachments.last?.preparationState == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prepared = try XCTUnwrap(composer.attachments.last)
        addTeardownBlock { GhosttyAttachmentStagingStore.cleanup([prepared]) }
        XCTAssertEqual(prepared.preparationState, .ready)
        XCTAssertEqual(prepared.title, "shot.png")
        XCTAssertTrue(prepared.supportsImageMarkup)
        guard case .file(let sentURL) = prepared.payload, case .imageData = prepared.previewPayload else {
            return XCTFail("A picture from Files is staged and previewed as a photo is.")
        }
        XCTAssertEqual(sentURL.lastPathComponent, "shot.png")
        XCTAssertNotEqual(sentURL, picture)
        XCTAssertEqual(try Data(contentsOf: picture), original, "The file in Files is left as it is.")
        XCTAssertEqual(composer.attachments.first?.title, "report.txt")
    }

    /// The draft's first photo is numbered once a second joins, before or after it is prepared, and is sent under
    /// its number.
    func testAPhotoIsSentUnderTheNumberItHasWhenSent() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        func waitUntilPrepared() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while composer.attachments.contains(where: { $0.preparationState == .preparing }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        composer.addCapturedPhoto(image, preparing: service)
        try await waitUntilPrepared()
        composer.addCapturedPhoto(image, preparing: service)
        try await waitUntilPrepared()

        let photos = composer.attachments
        addTeardownBlock { GhosttyAttachmentStagingStore.cleanup(photos) }
        XCTAssertEqual(photos.map(\.title), ["Photo 1", "Photo 2"])
        for (photo, number) in zip(photos, [1, 2]) {
            guard case .file(_, let filename) = try XCTUnwrap(photo.transferSource).payload else {
                return XCTFail("Expected a staged photo")
            }
            XCTAssertEqual(filename, "photo-\(number)-\(photo.id.uuidString.prefix(8).lowercased()).jpeg")
        }
    }

    /// A pasted file that holds a picture is a picture, as one picked in Files is: it can be marked up.
    func testAPastedPictureFileJoinsAsAPicture() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appendingPathComponent("pasted-shot.png")
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }).write(to: picture)

        composer.addPastedFile(picture, preparing: service)

        let deadline = ContinuousClock.now + .seconds(5)
        while composer.attachments.first?.preparationState == .preparing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prepared = try XCTUnwrap(composer.attachments.first)
        addTeardownBlock { GhosttyAttachmentStagingStore.cleanup([prepared]) }
        XCTAssertEqual(prepared.kind, .picture)
        XCTAssertEqual(prepared.title, "pasted-shot.png")
        XCTAssertTrue(prepared.supportsImageMarkup)
        guard case .file(let sentURL) = prepared.payload else { return XCTFail("Expected a staged picture") }
        XCTAssertNotEqual(sentURL, picture)
    }

    func testAddingNothingPreparesNothing() async throws {
        let composer = GhosttyComposerModel()
        let service = PrepareRecordingAttachmentTransferService()

        let didAdd = try await composer.addSecurityScopedFiles([], preparing: service)

        XCTAssertFalse(didAdd)
        try await Task.sleep(for: .milliseconds(50))
        let prepareCount = await service.prepareCount
        XCTAssertEqual(prepareCount, 0)
    }

    private func waitForPrepareCount(
        _ expected: Int,
        of service: PrepareRecordingAttachmentTransferService
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await service.prepareCount < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Settles any extra prepare the add might have started.
        try await Task.sleep(for: .milliseconds(20))
        let prepareCount = await service.prepareCount
        XCTAssertEqual(prepareCount, expected)
    }

    private func makeTemporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-composer-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: url)
        return url
    }
}

private actor PrepareRecordingAttachmentTransferService: GhosttyAttachmentTransferService {
    private(set) var prepareCount = 0

    func prepare() {
        prepareCount += 1
    }

    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        throw GhosttyAttachmentTransferError.cancelled
    }
}
