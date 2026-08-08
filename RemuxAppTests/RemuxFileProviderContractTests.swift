@preconcurrency import Citadel
import FileProvider
import Foundation
import NIOEmbedded
@preconcurrency import NIOSSH
import UniformTypeIdentifiers
import XCTest
@testable import Remux

final class RemuxFileProviderContractTests: XCTestCase {
    func testSDKCreateRequestPreservesSupportedFieldsAndOptions() throws {
        let contentsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let template = FileProviderTestSDKItem(
            identifier: NSFileProviderItemIdentifier(rawValue: "template"),
            parentIdentifier: .rootContainer,
            filename: "report.txt",
            contentType: .plainText
        )

        let request = try FileProviderSDKRequestAdapter.createRequest(
            itemTemplate: template,
            fields: [.filename, .contents],
            contentsURL: contentsURL,
            options: [.mayAlreadyExist]
        )

        XCTAssertEqual(request.parentIdentifier, template.parentItemIdentifier)
        XCTAssertEqual(request.filename, template.filename)
        XCTAssertEqual(request.type, .regular)
        XCTAssertEqual(request.templateIdentifier, template.itemIdentifier)
        XCTAssertEqual(request.contentsURL, contentsURL)
        XCTAssertEqual(request.fields, [.filename, .contents])
        XCTAssertEqual(request.options, [.mayAlreadyExist])
    }

    func testSDKCreateRequestMapsFoldersToDirectories() throws {
        let template = FileProviderTestSDKItem(
            identifier: NSFileProviderItemIdentifier(rawValue: "template"),
            parentIdentifier: .rootContainer,
            filename: "notes",
            contentType: .folder
        )

        let request = try FileProviderSDKRequestAdapter.createRequest(
            itemTemplate: template,
            fields: [.filename],
            contentsURL: nil,
            options: []
        )

        XCTAssertEqual(request.type, .directory)
    }

    func testSDKCreateRequestRejectsSymbolicLinks() {
        let template = FileProviderTestSDKItem(
            identifier: NSFileProviderItemIdentifier(rawValue: "template"),
            parentIdentifier: .rootContainer,
            filename: "link",
            contentType: .symbolicLink
        )

        XCTAssertThrowsError(
            try FileProviderSDKRequestAdapter.createRequest(
                itemTemplate: template,
                fields: [.filename],
                contentsURL: nil,
                options: []
            )
        ) { error in
            XCTAssertEqual(
                error as? FileProviderMutationValidationError,
                .symbolicLinkMutation
            )
        }
    }

    func testSDKModifyRequestPreservesOnlyMutationInputs() throws {
        let contentsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let item = FileProviderTestSDKItem(
            identifier: NSFileProviderItemIdentifier(rawValue: "item"),
            parentIdentifier: .rootContainer,
            filename: "renamed.txt",
            contentType: .plainText
        )
        let version = NSFileProviderItemVersion(
            contentVersion: Data("content".utf8),
            metadataVersion: Data("metadata".utf8)
        )

        let request = FileProviderSDKRequestAdapter.modifyRequest(
            item: item,
            baseVersion: version,
            changedFields: [.filename, .contents, .tagData],
            contentsURL: contentsURL,
            options: [.mayAlreadyExist]
        )

        XCTAssertEqual(request.identifier, item.itemIdentifier)
        XCTAssertEqual(request.parentIdentifier, item.parentItemIdentifier)
        XCTAssertEqual(request.filename, item.filename)
        XCTAssertEqual(request.baseVersion, version)
        XCTAssertEqual(request.changedFields, [.filename, .contents, .tagData])
        XCTAssertEqual(request.contentsURL, contentsURL)
        XCTAssertEqual(request.options, [.mayAlreadyExist])
    }

    func testSDKDeleteRequestPreservesIdentifierAndVersion() {
        let version = NSFileProviderItemVersion(
            contentVersion: Data("content".utf8),
            metadataVersion: Data("metadata".utf8)
        )

        let request = FileProviderSDKRequestAdapter.deleteRequest(
            identifier: NSFileProviderItemIdentifier(rawValue: "item"),
            baseVersion: version
        )

        XCTAssertEqual(request.identifier, NSFileProviderItemIdentifier(rawValue: "item"))
        XCTAssertEqual(request.baseVersion, version)
    }

    func testRequestProgressCancellationCancelsWorkAndCompletesExactlyOnce() async {
        let controller = FileProviderRequestController()
        let state = FileProviderTestRequestState()
        let completions = FileProviderTestCompletionRecorder<Int>()

        let progress = controller.perform(
            operation: {
                try await state.run()
            },
            completion: { result in
                Task {
                    await completions.record(result)
                }
            }
        )
        await state.waitUntilStarted()

        progress.cancel()
        await completions.waitForFirst()

        let wasCancelled = await state.wasCancelled()
        let results = await completions.results()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected cancellation to fail the request")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
    }

    func testRequestControllerInvalidationCancelsWorkAndCompletesExactlyOnce() async {
        let controller = FileProviderRequestController()
        let state = FileProviderTestRequestState()
        let completions = FileProviderTestCompletionRecorder<Int>()

        _ = controller.perform(
            operation: {
                try await state.run()
            },
            completion: { result in
                Task {
                    await completions.record(result)
                }
            }
        )
        await state.waitUntilStarted()

        controller.invalidate()
        await completions.waitForFirst()

        let wasCancelled = await state.wasCancelled()
        let results = await completions.results()
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected invalidation to fail the request")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
    }

    func testRequestControllerInvalidationWaitsForCancelledWorkToFinish() async {
        let controller = FileProviderRequestController()
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        _ = controller.perform(
            operation: {
                await gate.beginAndWait()
                return 1
            },
            completion: { _ in }
        )
        await gate.waitUntilStarted()

        controller.invalidate()
        let drain = Task {
            await controller.waitUntilInvalidated()
            await completion.finish()
        }
        let finishedBeforeRelease = await completion.waitUntilFinished(
            timeout: .milliseconds(100)
        )
        XCTAssertFalse(finishedBeforeRelease)

        await gate.release()
        await drain.value

        let finishedAfterRelease = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        XCTAssertTrue(finishedAfterRelease)
    }

    func testRequestStartedAfterInvalidationIsRejectedWithoutRunningOperation() async {
        let controller = FileProviderRequestController()
        let invocations = FileProviderTestInvocationCounter()
        let completions = FileProviderTestCompletionRecorder<Int>()
        let drained = FileProviderTestCompletionFlag()
        controller.invalidate {
            await drained.finish()
        }

        let progress = controller.perform(
            operation: {
                await invocations.record()
            },
            completion: { result in
                Task {
                    await completions.record(result)
                }
            }
        )

        await completions.waitForFirst()
        let didDrain = await drained.waitUntilFinished(timeout: .seconds(1))
        let invocationCount = await invocations.count()
        let results = await completions.results()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected invalidation to reject the request")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
        XCTAssertEqual(progress.totalUnitCount, 1)
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertTrue(didDrain)
    }

    func testExtensionCoreItemLookupDecodesIdentifierAndProjectsResult() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 42)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let completions = FileProviderTestCompletionRecorder<FileProviderItemProjection>()
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let record = try await snapshots.record(directory: .root, items: [remoteItem])
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                FileManager.default.temporaryDirectory
            }
        )
        let identifier = record[0].itemIdentifier

        _ = core.item(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await completions.waitForFirst()

        let results = await completions.results()
        guard case .success(let projection) = results.first else {
            XCTFail("Expected a projected item")
            return
        }
        XCTAssertEqual(projection.itemIdentifier, identifier)
        XCTAssertEqual(projection.filename, "report.txt")
        XCTAssertEqual(
            projection.capabilities,
            [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        )
        let itemPaths = await service.itemPaths()
        XCTAssertEqual(itemPaths, [remoteItem.path])
    }

    func testExtensionCoreFetchUsesOnlyTheDomainTemporaryDirectory() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let completions = FileProviderTestCompletionRecorder<FileProviderFetchedContents>()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let record = try await snapshots.record(directory: .root, items: [remoteItem])
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                temporaryDirectory
            }
        )
        let identifier = record[0].itemIdentifier

        _ = core.fetchContents(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await completions.waitForFirst()

        let results = await completions.results()
        guard case .success(let fetched) = results.first else {
            XCTFail("Expected fetched contents")
            return
        }
        XCTAssertEqual(
            fetched.localURL.deletingLastPathComponent().standardizedFileURL,
            temporaryDirectory.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: fetched.localURL), Data("contents".utf8))
        XCTAssertEqual(fetched.item.itemIdentifier, identifier)
        let fetchURLs = await service.fetchURLs()
        XCTAssertEqual(fetchURLs, [fetched.localURL])
    }

    func testFetchProgressTracksRemoteSizeAndCumulativeBytesUntilSuccess() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderProgressRemoteService(item: remoteItem)
        let completions =
            FileProviderTestCompletionRecorder<FileProviderFetchedContents>()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let record = try await snapshots.record(directory: .root, items: [remoteItem])
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                temporaryDirectory
            }
        )
        let identifier = record[0].itemIdentifier

        let progress = core.fetchContents(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await service.waitUntilPartialProgress()

        XCTAssertEqual(progress.totalUnitCount, 8)
        XCTAssertEqual(progress.completedUnitCount, 3)
        XCTAssertFalse(progress.isFinished)

        await service.finishFetch()
        await completions.waitForFirst()

        XCTAssertEqual(progress.totalUnitCount, 8)
        XCTAssertEqual(progress.completedUnitCount, 8)
        XCTAssertTrue(progress.isFinished)
        let results = await completions.results()
        guard case .success = results.first else {
            XCTFail("Expected fetch to succeed")
            return
        }
    }

    func testSuccessfulEmptyFetchCompletesProgress() async throws {
        let remoteItem = try fileProviderTestItem(relative: "empty.txt", size: 0)
        let service = FileProviderEmptyFetchRemoteService(item: remoteItem)
        let completions =
            FileProviderTestCompletionRecorder<FileProviderFetchedContents>()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let record = try await snapshots.record(directory: .root, items: [remoteItem])
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                temporaryDirectory
            }
        )
        let identifier = record[0].itemIdentifier

        let progress = core.fetchContents(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await completions.waitForFirst()

        XCTAssertEqual(progress.totalUnitCount, 1)
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertTrue(progress.isFinished)
    }

    func testFetchCancellationAfterRemoteSuccessRemovesTemporaryFile() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderDelayedFetchRemoteService(item: remoteItem)
        let completions =
            FileProviderTestCompletionRecorder<FileProviderFetchedContents>()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let record = try await snapshots.record(directory: .root, items: [remoteItem])
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                temporaryDirectory
            }
        )
        let identifier = record[0].itemIdentifier
        let progress = core.fetchContents(for: identifier) { result in
            Task {
                await completions.record(result)
            }
        }
        await service.waitUntilFetchCreated()

        progress.cancel()
        await service.finishFetch()
        await completions.waitForFirst()

        let results = await completions.results()
        guard case .failure(let error) = results.first else {
            XCTFail("Expected cancellation to fail the fetch")
            return
        }
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error.code, NSUserCancelledError)
        let fetchedLocalURL = await service.localURL
        let localURL = try XCTUnwrap(fetchedLocalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testExtensionCoreMapsRejectedMutationWithoutRemoteCalls() async throws {
        let remoteItem = try fileProviderTestItem(relative: "report.txt", size: 8)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                FileManager.default.temporaryDirectory
            }
        )
        let completions = FileProviderTestCompletionRecorder<Void>()

        _ = core.failedMutation(
            error: FileProviderMutationValidationError.symbolicLinkMutation
        ) { error in
            Task {
                await completions.record(.failure(error))
            }
        }
        await completions.waitForFirst()
        let results = await completions.results()
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else {
            XCTFail("Expected rejected mutation error")
            return
        }
        XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(error.code, NSFileProviderError.cannotSynchronize.rawValue)
        let remoteCallCount = await service.totalCallCount()
        XCTAssertEqual(remoteCallCount, 0)
    }

    func testExtensionInvalidationDrainsEnumeratorsBeforeClosingService() async throws {
        let remoteItem = try fileProviderTestItem(relative: "item.txt", size: 1)
        let service = FileProviderRecordingRemoteService(item: remoteItem)
        let snapshots = FileProviderSnapshotStore(rootURL: fileProviderTestSnapshotRoot())
        let core = FileProviderReplicatedExtensionCore(
            service: service,
            snapshots: snapshots,
            rootDisplayName: "Fixture",
            temporaryDirectoryURL: {
                FileManager.default.temporaryDirectory
            }
        )
        let enumerator = FileProviderTestEnumeratorLifecycle()
        XCTAssertTrue(core.registerEnumerator(enumerator))

        core.invalidate()
        core.invalidate()
        await enumerator.waitUntilDrainStarted()

        let invalidateWasCalled = enumerator.invalidateWasCalled
        let serviceCallCountBeforeDrain = await service.invalidationCallCount()
        XCTAssertTrue(invalidateWasCalled)
        XCTAssertEqual(serviceCallCountBeforeDrain, 0)

        await enumerator.finishDrain()
        await service.waitUntilInvalidated()

        let serviceCallCountAfterDrain = await service.invalidationCallCount()
        XCTAssertEqual(serviceCallCountAfterDrain, 1)
    }

    func testSharedAuthenticationFactoryPreservesPasswordCredentials() throws {
        let authentication = ResolvedSSHAuth.password(
            username: "reader",
            password: "test-password",
            identityID: UUID(),
            displayLabel: "Fixture"
        )

        let credential: SSHCredential
        switch authentication.credential {
        case .password(let password):
            credential = .password(password)
        case .privateKey(let privateKey):
            credential = .privateKey(privateKey)
        }

        let method = try SSHAuthenticationMethodFactory.make(
            username: authentication.username,
            credential: credential
        )
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        method.nextAuthenticationType(
            availableMethods: [.password],
            nextChallengePromise: promise
        )
        let offer = try XCTUnwrap(promise.futureResult.wait())

        XCTAssertEqual(offer.username, "reader")
        guard case .password(let password) = offer.offer else {
            XCTFail("Expected password authentication")
            return
        }
        XCTAssertEqual(password.password, "test-password")
    }

    func testSSHRootKeyCanBeBuiltWithoutATmuxConnectionTarget() {
        let identityID = UUID()
        let server = SavedServer(
            displayName: "Fixture",
            host: "reader.example.test",
            port: 2222,
            username: "saved-user",
            identityID: identityID
        )
        let authentication = ResolvedSSHAuth.password(
            username: "resolved-user",
            password: "test-password",
            identityID: identityID,
            displayLabel: "Fixture"
        )

        let key = RemuxSSHRootKey(server: server, auth: authentication)

        XCTAssertEqual(key.serverID, server.id)
        XCTAssertEqual(key.host, "reader.example.test")
        XCTAssertEqual(key.port, 2222)
        XCTAssertEqual(key.username, "resolved-user")
    }

    func testEnumeratorCoreRefreshesImmediatelyAndRecordsTerminalPage() async throws {
        let home = "/home/reader"
        let metadata = RemuxSFTPFileMetadata(
            size: 7,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 500)
        )
        let client = FileProviderTestSFTPClient(
            realPaths: [".": .success(home)],
            listings: [
                home: [RemuxSFTPDirectoryEntry(name: "now.txt", metadata: metadata)],
            ]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let page = try await core.enumerateItems()

        XCTAssertEqual(page.items.map(\.remoteItem.name), ["now.txt"])
        XCTAssertNil(page.nextPage)
        let persisted = try await snapshots.items(directory: .root)
        XCTAssertEqual(persisted, page.items)
        let currentAnchor = try await core.currentSyncAnchor()
        XCTAssertNotNil(currentAnchor)
    }

    func testEnumeratorCoreReportsRetainedSnapshotChanges() async throws {
        let home = "/home/reader"
        let client = FileProviderTestSFTPClient(
            realPaths: [".": .success(home)],
            listings: [home: []]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let original = try fileProviderTestItem(relative: "changed.txt", size: 1)
        let removed = try fileProviderTestItem(relative: "removed.txt", size: 2)
        let requested = try await snapshots.record(
            directory: .root,
            items: [original, removed]
        )
        let requestedCurrentAnchor = try await snapshots.currentAnchor()
        let requestedAnchor = try XCTUnwrap(requestedCurrentAnchor)
        let updated = try fileProviderTestItem(relative: "changed.txt", size: 3)
        _ = try await snapshots.record(directory: .root, items: [updated])
        let latestCurrentAnchor = try await snapshots.currentAnchor()
        let latestAnchor = try XCTUnwrap(latestCurrentAnchor)
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: FileProviderTestSignaler()
        )

        let changes = try await core.enumerateChanges(from: requestedAnchor)

        XCTAssertEqual(changes.updated.map(\.remoteItem), [updated])
        XCTAssertEqual(
            changes.deleted,
            [requested[1].itemIdentifier]
        )
        XCTAssertFalse(changes.moreComing)
        XCTAssertEqual(changes.anchor, latestAnchor)
    }

    func testWorkingSetAggregatesNestedCreateUpdateDeleteAndSignalsOnlyWorkingSet() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let original = try fileProviderTestItem(
            relative: "nested/updated.txt",
            size: 1
        )
        let removed = try fileProviderTestItem(
            relative: "nested/deleted.txt",
            size: 2
        )
        let changed = try fileProviderTestItem(
            relative: "nested/updated.txt",
            size: 3
        )
        let created = try fileProviderTestItem(
            relative: "nested/created.txt",
            size: 4
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        let rootRecord = try await snapshots.record(directory: .root, items: [rootItem])
        let baseline = try await snapshots.record(
            directory: directory,
            items: [original, removed]
        )
        let baselineCurrentAnchor = try await snapshots.currentAnchor()
        let baselineAnchor = try XCTUnwrap(baselineCurrentAnchor)
        let signaler = FileProviderTestSignaler()
        let nestedCore = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: FileProviderTestSequencedRemoteService(
                listings: [[changed, created]]
            ),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        let workingSetCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(listings: [[]]),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )

        try await nestedCore.refreshAndSignalChanges()
        let page = try await workingSetCore.enumerateItems()
        let changes = try await workingSetCore.enumerateChanges(
            from: baselineAnchor
        )

        XCTAssertEqual(page.items.map(\.remoteItem), [rootItem, created, changed])
        XCTAssertEqual(changes.updated.map(\.remoteItem), [created, changed])
        XCTAssertEqual(
            changes.updated.map(\.parentIdentity),
            [rootRecord[0].identity, rootRecord[0].identity]
        )
        XCTAssertEqual(
            changes.deleted,
            [
                try XCTUnwrap(
                    baseline.first {
                        $0.remoteItem.path == removed.path
                    }
                ).itemIdentifier,
            ]
        )
        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(signals, [.workingSet])
    }

    func testChangedDirectoryPollSignalsOnlyWorkingSet() async throws {
        let home = "/home/reader"
        let original = RemuxSFTPFileMetadata(
            size: 1,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 600)
        )
        let changed = RemuxSFTPFileMetadata(
            size: 2,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: 601)
        )
        let client = FileProviderSequencedSFTPClient(
            home: home,
            listings: [
                [RemuxSFTPDirectoryEntry(name: "item.txt", metadata: original)],
                [RemuxSFTPDirectoryEntry(name: "item.txt", metadata: changed)],
            ]
        )
        let service = try await FileProviderRemoteServiceFixture.make(client: client).service
        let snapshots = FileProviderSnapshotStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let signaler = FileProviderTestSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        try await core.refreshAndSignalChanges()

        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(signals, [.workingSet])
    }

    func testUnchangedNestedPollDoesNotAdvanceGenerationOrSignalAgain() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let item = try fileProviderTestItem(
            relative: "nested/same.txt",
            size: 1
        )
        let snapshots = FileProviderSnapshotStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        _ = try await snapshots.record(directory: .root, items: [rootItem])
        let signaler = FileProviderTestSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: FileProviderTestSequencedRemoteService(
                listings: [[item], [item], [item]]
            ),
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()
        try await core.refreshAndSignalChanges()
        let currentAnchorBeforeUnchangedPoll = try await core.currentSyncAnchor()
        let anchorBeforeUnchangedPoll = try XCTUnwrap(
            currentAnchorBeforeUnchangedPoll
        )

        try await core.refreshAndSignalChanges()

        let currentAnchorAfterUnchangedPoll = try await core.currentSyncAnchor()
        let anchorAfterUnchangedPoll = try XCTUnwrap(
            currentAnchorAfterUnchangedPoll
        )
        let signals = await signaler.signaledIdentifiers()
        XCTAssertEqual(anchorAfterUnchangedPoll, anchorBeforeUnchangedPoll)
        XCTAssertEqual(signals, [.workingSet])
    }

    func testCancelledSnapshotRecordDoesNotPersistAfterStorageBoundary() async throws {
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockingGate = FileProviderBlockingGate()
        let snapshots = FileProviderSnapshotStore(
            rootURL: snapshotRoot,
            fileManager: FileProviderBlockingFileManager(gate: blockingGate)
        )
        let item = try fileProviderTestItem(relative: "cancelled.txt", size: 1)
        let record = Task {
            try await snapshots.record(directory: .root, items: [item])
        }
        await blockingGate.waitUntilEntered()

        record.cancel()
        blockingGate.release()

        await XCTAssertFileProviderThrowsAsync { try await record.value }
        let stateURL = snapshotRoot.appendingPathComponent(
            "snapshot-generations.json"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testCancelledNestedSignalIsDrainedByReopenedWorkingSet() async throws {
        let directory = try FileProviderRemotePath(relative: "nested")
        let rootItem = try fileProviderTestItem(
            relative: "nested",
            size: 0,
            type: .directory
        )
        let original = try fileProviderTestItem(
            relative: "nested/item.txt",
            size: 1
        )
        let changed = try fileProviderTestItem(
            relative: "nested/item.txt",
            size: 2
        )
        let service = FileProviderTestSequencedRemoteService(
            listings: [[original], [changed]]
        )
        let signaler = FileProviderBlockingSignaler()
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshots = FileProviderSnapshotStore(rootURL: snapshotRoot)
        _ = try await snapshots.record(directory: .root, items: [rootItem])
        let core = FileProviderEnumeratorCore(
            scope: .directory(directory),
            service: service,
            snapshots: snapshots,
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()
        let refresh = Task {
            try await core.refreshAndSignalChanges()
        }
        await signaler.waitUntilFirstSignal()

        refresh.cancel()
        await signaler.release()

        await XCTAssertFileProviderThrowsAsync { try await refresh.value }
        let identifiers = await signaler.signaledIdentifiers()
        XCTAssertEqual(identifiers, [.workingSet])

        let retrySignaler = FileProviderTestSignaler()
        let reopenedCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(
                listings: [[changed]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: retrySignaler
        )

        try await reopenedCore.refreshAndSignalChanges()
        try await reopenedCore.refreshAndSignalChanges()

        let retryIdentifiers = await retrySignaler.signaledIdentifiers()
        XCTAssertEqual(retryIdentifiers, [.workingSet])
    }

    func testFailedSignalDeliveryRemainsPendingUntilRetrySucceeds() async throws {
        let original = try fileProviderTestItem(relative: "item.txt", size: 1)
        let changed = try fileProviderTestItem(relative: "item.txt", size: 2)
        let signaler = FileProviderFailingOnceSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: FileProviderTestSequencedRemoteService(
                listings: [[original], [changed]]
            ),
            snapshots: FileProviderSnapshotStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: signaler
        )
        _ = try await core.enumerateItems()

        await XCTAssertFileProviderThrowsAsync {
            try await core.refreshAndSignalChanges()
        }
        try await core.refreshAndSignalChanges()
        try await core.refreshAndSignalChanges()

        let identifiers = await signaler.signaledIdentifiers()
        XCTAssertEqual(identifiers, [.workingSet])
    }

    func testOlderSignalDeliveryDoesNotAcknowledgeNewerSnapshot() async throws {
        let original = try fileProviderTestItem(relative: "item.txt", size: 1)
        let firstChange = try fileProviderTestItem(
            relative: "item.txt",
            size: 2
        )
        let secondChange = try fileProviderTestItem(
            relative: "item.txt",
            size: 3
        )
        let snapshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockingSignaler = FileProviderBlockingSignaler()
        let core = FileProviderEnumeratorCore(
            scope: .directory(.root),
            service: FileProviderTestSequencedRemoteService(
                listings: [[original], [firstChange], [secondChange]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: blockingSignaler
        )
        _ = try await core.enumerateItems()
        let firstDelivery = Task {
            try await core.refreshAndSignalChanges()
        }
        await blockingSignaler.waitUntilFirstSignal()

        let newerPage = try await core.enumerateItems()
        XCTAssertEqual(newerPage.items.map(\.remoteItem), [secondChange])
        await blockingSignaler.release()
        try await firstDelivery.value

        let retrySignaler = FileProviderTestSignaler()
        let reopenedCore = FileProviderEnumeratorCore(
            scope: .workingSet,
            service: FileProviderTestSequencedRemoteService(
                listings: [[secondChange]]
            ),
            snapshots: FileProviderSnapshotStore(rootURL: snapshotRoot),
            coordinator: FileProviderDomainOperationCoordinator(),
            signaler: retrySignaler
        )

        try await reopenedCore.refreshAndSignalChanges()
        try await reopenedCore.refreshAndSignalChanges()

        let retryIdentifiers = await retrySignaler.signaledIdentifiers()
        XCTAssertEqual(retryIdentifiers, [.workingSet])
    }

    func testPollingLoopSleepsBeforeFirstRefresh() async {
        let refreshes = FileProviderTestRefreshCounter()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await refreshes.record()
            }
        )

        loop.start()
        await clock.waitForSleepCount(1)

        let refreshCountBeforeSleep = await refreshes.count()
        XCTAssertEqual(refreshCountBeforeSleep, 0)

        await clock.advance()
        await refreshes.wait(for: 1)

        let refreshCount = await refreshes.count()
        XCTAssertEqual(refreshCount, 1)
        loop.invalidate()
    }

    func testPollingLoopRetriesFailedSleepBeforeRefreshing() async {
        let refreshes = FileProviderTestRefreshCounter()
        let clock = FileProviderTestPollingClock()
        await clock.failNextSleep()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await refreshes.record()
            }
        )

        loop.start()
        await clock.waitForSleepCount(2)

        let refreshCountAfterFailedSleep = await refreshes.count()
        XCTAssertEqual(refreshCountAfterFailedSleep, 0)
        loop.invalidate()
    }

    func testPollingLoopWaitsFiveSecondsBetweenRefreshes() async {
        let refreshes = FileProviderTestRefreshCounter()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await refreshes.record()
            }
        )

        loop.start()
        await clock.waitForSleepCount(1)
        await clock.advance()
        await refreshes.wait(for: 1)
        await clock.waitForSleepCount(2)

        let durations = await clock.requestedDurations()
        XCTAssertEqual(durations, [.seconds(5), .seconds(5)])

        await clock.advance()
        await refreshes.wait(for: 2)

        let refreshCount = await refreshes.count()
        XCTAssertEqual(refreshCount, 2)
        loop.invalidate()
    }

    func testPollingLoopSleepsFiveSecondsAfterEachCompletedRefresh() async {
        let gate = FileProviderTestRefreshGate()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await gate.beginAndWait()
            }
        )

        loop.start()
        await clock.waitForSleepCount(1)
        await clock.advance()
        await gate.waitUntilStarted()

        let durationsBeforeRefreshCompleted = await clock.requestedDurations()
        XCTAssertEqual(durationsBeforeRefreshCompleted, [.seconds(5)])

        await gate.release()
        await clock.waitForSleepCount(2)

        let durations = await clock.requestedDurations()
        XCTAssertEqual(durations, [.seconds(5), .seconds(5)])
        loop.invalidate()
    }

    func testPollingLoopInvalidationCancelsCurrentRefresh() async {
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                try await gate.beginCancellableAndWait()
            }
        )
        loop.start()
        await clock.waitForSleepCount(1)
        await clock.advance()
        await gate.waitUntilStarted()

        loop.invalidate()
        let drain = Task {
            await loop.waitUntilInvalidated()
            await completion.finish()
        }
        let finishedAfterCancellation = await completion.waitUntilFinished(
            timeout: .milliseconds(100)
        )
        let wasCancelled = await gate.wasCancelled()
        if !finishedAfterCancellation {
            await gate.release()
            await drain.value
        }

        XCTAssertTrue(wasCancelled)
    }

    func testPollingLoopInvalidationWaitsForCurrentRefreshToFinish() async {
        let gate = FileProviderTestRefreshGate()
        let completion = FileProviderTestCompletionFlag()
        let clock = FileProviderTestPollingClock()
        let loop = FileProviderPollingLoop(
            clock: clock,
            refresh: {
                await gate.beginAndWait()
            }
        )
        loop.start()
        await clock.waitForSleepCount(1)
        await clock.advance()
        await gate.waitUntilStarted()

        loop.invalidate()
        let drain = Task {
            await loop.waitUntilInvalidated()
            await completion.finish()
        }
        let finishedBeforeRelease = await completion.waitUntilFinished(
            timeout: .milliseconds(100)
        )
        XCTAssertFalse(finishedBeforeRelease)

        await gate.release()
        await drain.value

        let finishedAfterRelease = await completion.waitUntilFinished(
            timeout: .seconds(1)
        )
        XCTAssertTrue(finishedAfterRelease)
    }

    func testItemProjectionExposesWritableFileProviderMetadata() throws {
        let remoteItem = try FileProviderRemoteItem(
            path: FileProviderRemotePath(relative: "folder/report.txt"),
            metadata: RemuxSFTPFileMetadata(
                size: 42,
                permissions: 0o100640,
                modificationDate: Date(timeIntervalSince1970: 800)
            )
        )

        let itemIdentity = FileProviderItemIdentity.item(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let parentIdentity = FileProviderItemIdentity.item(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let projection = FileProviderItemProjection(
            item: FileProviderIdentifiedItem(
                identity: itemIdentity,
                parentIdentity: parentIdentity,
                remoteItem: remoteItem
            ),
            rootDisplayName: "Server"
        )

        XCTAssertEqual(
            projection.itemIdentifier,
            itemIdentity.itemIdentifier
        )
        XCTAssertEqual(
            projection.parentItemIdentifier,
            parentIdentity.itemIdentifier
        )
        XCTAssertEqual(projection.filename, "report.txt")
        XCTAssertEqual(projection.contentType, .plainText)
        XCTAssertEqual(projection.documentSize, 42)
        XCTAssertEqual(projection.contentModificationDate, Date(timeIntervalSince1970: 800))
        XCTAssertEqual(
            projection.capabilities,
            [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        )
        XCTAssertEqual(
            projection.itemVersion.contentVersion,
            remoteItem.contentVersion
        )
        XCTAssertEqual(
            projection.itemVersion.metadataVersion,
            remoteItem.metadataVersion
        )
        XCTAssertNil(projection.symlinkTargetPath)
    }
}

private actor FileProviderEmptyFetchRemoteService: FileProviderRemoteServicing {
    private let returnedItem: FileProviderRemoteItem
    private var mutationAccessCallCount = 0

    init(item: FileProviderRemoteItem) {
        self.returnedItem = item
    }

    func item(at path: FileProviderRemotePath) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func list(directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        []
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        try Data().write(to: localURL)
        await progress(
            FileProviderRemoteFetchProgress(
                totalByteCount: 0,
                completedByteCount: 0
            )
        )
        return returnedItem
    }

    func invalidate() {
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) throws -> Value {
        mutationAccessCallCount += 1
        throw RemuxSFTPClientError.noSuchFile("mutation access")
    }
}

private actor FileProviderProgressRemoteService: FileProviderRemoteServicing {
    private let returnedItem: FileProviderRemoteItem
    private let partialProgressGate = FileProviderTestRefreshGate()
    private var mutationAccessCallCount = 0

    init(item: FileProviderRemoteItem) {
        self.returnedItem = item
    }

    func item(at path: FileProviderRemotePath) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func list(directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        []
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        await progress(
            FileProviderRemoteFetchProgress(
                totalByteCount: 8,
                completedByteCount: 3
            )
        )
        await partialProgressGate.beginAndWait()
        await progress(
            FileProviderRemoteFetchProgress(
                totalByteCount: 8,
                completedByteCount: 6
            )
        )
        try Data("contents".utf8).write(to: localURL)
        return returnedItem
    }

    func waitUntilPartialProgress() async {
        await partialProgressGate.waitUntilStarted()
    }

    func finishFetch() async {
        await partialProgressGate.release()
    }

    func invalidate() {
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) throws -> Value {
        mutationAccessCallCount += 1
        throw RemuxSFTPClientError.noSuchFile("mutation access")
    }
}

private actor FileProviderTestRequestState {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationObserved = false

    func run() async throws -> Int {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        do {
            try await Task.sleep(for: .seconds(60))
            return 1
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }
}

private actor FileProviderTestInvocationCounter {
    private var invocationCount = 0

    func record() -> Int {
        invocationCount += 1
        return invocationCount
    }

    func count() -> Int {
        invocationCount
    }
}

private actor FileProviderTestCompletionRecorder<Value: Sendable> {
    private var recordedResults: [Result<Value, NSError>] = []
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ result: Result<Value, NSError>) {
        recordedResults.append(result)
        let waiters = firstWaiters
        firstWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForFirst() async {
        guard recordedResults.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }

    func results() -> [Result<Value, NSError>] {
        recordedResults
    }
}

private actor FileProviderTestCompletionFlag {
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func finish() {
        finished = true
        let waiters = self.waiters.values
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitUntilFinished(timeout: Duration) async -> Bool {
        guard !finished else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                timeOut(waiterID: waiterID)
            }
        }
    }

    private func timeOut(waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }
}

private actor FileProviderRecordingRemoteService: FileProviderRemoteServicing {
    private let returnedItem: FileProviderRemoteItem
    private var recordedItemPaths: [FileProviderRemotePath] = []
    private var recordedFetchURLs: [URL] = []
    private var mutationAccessCallCount = 0
    private var invalidationCount = 0
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []

    init(item: FileProviderRemoteItem) {
        self.returnedItem = item
    }

    func item(at path: FileProviderRemotePath) -> FileProviderRemoteItem {
        recordedItemPaths.append(path)
        return returnedItem
    }

    func list(directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        []
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        recordedFetchURLs.append(localURL)
        try Data("contents".utf8).write(to: localURL)
        await progress(
            FileProviderRemoteFetchProgress(
                totalByteCount: 8,
                completedByteCount: 8
            )
        )
        return returnedItem
    }

    func itemPaths() -> [FileProviderRemotePath] {
        recordedItemPaths
    }

    func fetchURLs() -> [URL] {
        recordedFetchURLs
    }

    func totalCallCount() -> Int {
        recordedItemPaths.count + recordedFetchURLs.count
    }

    func invalidate() {
        invalidationCount += 1
        let invalidationWaiters = self.invalidationWaiters
        self.invalidationWaiters.removeAll()
        invalidationWaiters.forEach { $0.resume() }
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) throws -> Value {
        mutationAccessCallCount += 1
        throw RemuxSFTPClientError.noSuchFile("mutation access")
    }

    func invalidationCallCount() -> Int {
        invalidationCount
    }

    func waitUntilInvalidated() async {
        guard invalidationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            invalidationWaiters.append(continuation)
        }
    }
}

private actor FileProviderDelayedFetchRemoteService: FileProviderRemoteServicing {
    private let returnedItem: FileProviderRemoteItem
    private var createdURL: URL?
    private var creationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFinish = false
    private var mutationAccessCallCount = 0

    init(item: FileProviderRemoteItem) {
        self.returnedItem = item
    }

    var localURL: URL? {
        createdURL
    }

    func item(at path: FileProviderRemotePath) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func list(directory: FileProviderRemotePath) -> [FileProviderRemoteItem] {
        []
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) async throws -> FileProviderRemoteItem {
        try Data("contents".utf8).write(to: localURL)
        createdURL = localURL
        let creationWaiters = self.creationWaiters
        self.creationWaiters.removeAll()
        creationWaiters.forEach { $0.resume() }

        guard !shouldFinish else { return returnedItem }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
        return returnedItem
    }

    func waitUntilFetchCreated() async {
        guard createdURL == nil else { return }
        await withCheckedContinuation { continuation in
            creationWaiters.append(continuation)
        }
    }

    func finishFetch() {
        shouldFinish = true
        let finishWaiters = self.finishWaiters
        self.finishWaiters.removeAll()
        finishWaiters.forEach { $0.resume() }
    }

    func invalidate() {
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) throws -> Value {
        mutationAccessCallCount += 1
        throw RemuxSFTPClientError.noSuchFile("mutation access")
    }
}

private final class FileProviderTestEnumeratorLifecycle:
    FileProviderEnumeratorInvalidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let drainGate = FileProviderTestRefreshGate()
    private var invalidated = false

    var invalidateWasCalled: Bool {
        lock.withLock { invalidated }
    }

    func invalidate() {
        lock.withLock {
            invalidated = true
        }
    }

    func waitUntilInvalidated() async {
        await drainGate.beginAndWait()
    }

    func waitUntilDrainStarted() async {
        await drainGate.waitUntilStarted()
    }

    func finishDrain() async {
        await drainGate.release()
    }
}

private actor FileProviderTestSequencedRemoteService: FileProviderRemoteServicing {
    private let listings: [[FileProviderRemoteItem]]
    private let firstRefreshGate: FileProviderTestRefreshGate?
    private var nextListingIndex = 0
    private var mutationAccessCallCount = 0

    init(
        listings: [[FileProviderRemoteItem]],
        firstRefreshGate: FileProviderTestRefreshGate? = nil
    ) {
        self.listings = listings
        self.firstRefreshGate = firstRefreshGate
    }

    func item(at path: FileProviderRemotePath) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func list(directory: FileProviderRemotePath) async -> [FileProviderRemoteItem] {
        let index = min(nextListingIndex, listings.count - 1)
        nextListingIndex += 1
        if index == 0, let firstRefreshGate {
            await firstRefreshGate.beginAndWait()
        }
        return listings[index]
    }

    func fetch(
        path: FileProviderRemotePath,
        to localURL: URL,
        progress: @escaping @Sendable (FileProviderRemoteFetchProgress) async -> Void
    ) throws -> FileProviderRemoteItem {
        throw RemuxSFTPClientError.noSuchFile(path.relative)
    }

    func invalidate() {
    }

    func withMutationAccess<Value: Sendable>(
        _ operation: @Sendable (any FileProviderRemoteMutationAccess) async throws -> Value
    ) throws -> Value {
        mutationAccessCallCount += 1
        throw RemuxSFTPClientError.noSuchFile("mutation access")
    }

    func listCallCount() -> Int {
        nextListingIndex
    }
}

private actor FileProviderBlockingSignaler: FileProviderEnumeratorSignaling {
    private var identifiers: [NSFileProviderItemIdentifier] = []
    private var firstSignalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) async {
        identifiers.append(identifier)
        guard identifiers.count == 1 else { return }

        let firstSignalWaiters = self.firstSignalWaiters
        self.firstSignalWaiters.removeAll()
        firstSignalWaiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstSignal() async {
        guard identifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstSignalWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private final class FileProviderBlockingGate: @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() {
        let entryWaiters = lock.withLock {
            hasEntered = true
            let entryWaiters = self.entryWaiters
            self.entryWaiters.removeAll()
            return entryWaiters
        }
        entryWaiters.forEach { $0.resume() }
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !hasEntered else { return true }
                entryWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class FileProviderBlockingFileManager: FileManager {
    private let gate: FileProviderBlockingGate

    init(gate: FileProviderBlockingGate) {
        self.gate = gate
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        gate.wait()
        return super.fileExists(atPath: path)
    }
}

private func XCTAssertFileProviderThrowsAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
    }
}

private final class FileProviderTestSDKItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
    }
}

private func fileProviderTestItem(
    relative: String,
    size: UInt64,
    type: RemuxSFTPFileType = .regular
) throws -> FileProviderRemoteItem {
    try FileProviderRemoteItem(
        path: FileProviderRemotePath(relative: relative),
        metadata: RemuxSFTPFileMetadata(
            size: size,
            permissions: 0o100644,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(size)),
            type: type
        )
    )
}

private func fileProviderTestSnapshotRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor FileProviderTestRefreshGate {
    private var count = 0
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var cancellationObserved = false

    func beginAndWait() async {
        count += 1
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func recordUnexpectedOperation() {
        count += 1
    }

    func beginCancellableAndWait() async throws {
        try await withTaskCancellationHandler {
            await beginAndWait()
            try Task.checkCancellation()
        } onCancel: {
            Task {
                await self.recordCancellationAndRelease()
            }
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func operationCount() -> Int {
        count
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }

    private func recordCancellationAndRelease() {
        cancellationObserved = true
        release()
    }
}

private actor FileProviderTestSignaler: FileProviderEnumeratorSignaling {
    private var identifiers: [NSFileProviderItemIdentifier] = []

    func signalEnumerator(for identifier: NSFileProviderItemIdentifier) {
        identifiers.append(identifier)
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private actor FileProviderFailingOnceSignaler:
    FileProviderEnumeratorSignaling
{
    private enum Failure: Error {
        case rejected
    }

    private var shouldFail = true
    private var identifiers: [NSFileProviderItemIdentifier] = []

    func signalEnumerator(
        for identifier: NSFileProviderItemIdentifier
    ) throws {
        if shouldFail {
            shouldFail = false
            throw Failure.rejected
        }
        identifiers.append(identifier)
    }

    func signaledIdentifiers() -> [NSFileProviderItemIdentifier] {
        identifiers
    }
}

private actor FileProviderSequencedSFTPClient: RemuxSFTPFileProviderClient {
    private let home: String
    private let listings: [[RemuxSFTPDirectoryEntry]]
    private var listingIndex = 0

    init(home: String, listings: [[RemuxSFTPDirectoryEntry]]) {
        self.home = home
        self.listings = listings
    }

    func realPath(atPath path: String) async throws -> String {
        guard path == "." else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return home
    }

    func listDirectory(atPath path: String) async throws -> [RemuxSFTPDirectoryEntry] {
        guard path == home, !listings.isEmpty else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        let index = min(listingIndex, listings.count - 1)
        listingIndex += 1
        return listings[index]
    }

    func metadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        let name = (path as NSString).lastPathComponent
        guard let metadata = listings.last?.first(where: { $0.name == name })?.metadata else {
            throw RemuxSFTPClientError.noSuchFile(path)
        }
        return metadata
    }

    func linkMetadata(atPath path: String) async throws -> RemuxSFTPFileMetadata {
        try await metadata(atPath: path)
    }

    func withFile<ReturnValue: Sendable>(
        atPath path: String,
        _ operation: @Sendable (RemuxSFTPReadableFile) async throws -> ReturnValue
    ) async throws -> ReturnValue {
        throw RemuxSFTPClientError.noSuchFile(path)
    }

    func createDirectory(atPath path: String) async throws {
        throw RemuxSFTPClientError.noSuchFile(path)
    }

    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        progress: @escaping RemuxSFTPFileUploadProgressHandler
    ) async throws {
        throw RemuxSFTPClientError.noSuchFile(remotePath)
    }

    func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        throw RemuxSFTPClientError.noSuchFile(sourcePath)
    }

    func removeFile(atPath path: String) async throws {
        throw RemuxSFTPClientError.noSuchFile(path)
    }

    func removeEmptyDirectory(atPath path: String) async throws {
        throw RemuxSFTPClientError.noSuchFile(path)
    }
}

private actor FileProviderTestRefreshCounter {
    private var refreshCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        refreshCount += 1
        let ready = waiters.filter { refreshCount >= $0.count }
        waiters.removeAll { refreshCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for count: Int) async {
        guard refreshCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func count() -> Int {
        refreshCount
    }
}

private actor FileProviderTestPollingClock: FileProviderPollingClock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum SleepError: Error {
        case rejected
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []
    private var failuresRemaining = 0
    private var sleepCountWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let shouldFail = failuresRemaining > 0
        if shouldFail {
            failuresRemaining -= 1
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                durations.append(duration)
                let ready = sleepCountWaiters.filter {
                    durations.count >= $0.count
                }
                sleepCountWaiters.removeAll { durations.count >= $0.count }
                ready.forEach { $0.continuation.resume() }
                if shouldFail {
                    continuation.resume(throwing: SleepError.rejected)
                    return
                }
                waiters.append(
                    Waiter(
                        id: id,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func failNextSleep() {
        failuresRemaining += 1
    }

    func waitForSleepCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            sleepCountWaiters.append((count, continuation))
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
