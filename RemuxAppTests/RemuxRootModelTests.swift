import GhosttyKit
import SwiftUI
import UIKit
import XCTest
@testable import Remux

extension SavedServer {
    init(
        id: UUID = UUID(),
        identityID: SSHIdentity.ID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String
    ) {
        self.init(
            id: id,
            displayName: displayName,
            host: host,
            port: port,
            username: username,
            identityID: identityID
        )
    }
}

@MainActor
final class RemuxRootModelTests: XCTestCase {
    func testAppLifecycleProjectionMapsScenePhases() {
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .active).appLifecyclePhase, .active)
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .inactive).appLifecyclePhase, .inactive)
        XCTAssertEqual(RemuxAppLifecycleProjection(scenePhase: .background).appLifecyclePhase, .background)
    }

    func testAdjustTerminalFontSizePersistsAppGlobalSetting() async throws {
        let harness = makeHarness(
            settings: TerminalSettings(fontSize: nil, theme: .remuxDark)
        )
        await harness.model.load()

        await harness.model.adjustTerminalFontSize(
            by: 1,
            effectiveDefault: 12
        )

        XCTAssertEqual(harness.model.terminalSettings.fontSize, 13)
        let saved = try await harness.settingsRepository.loadSettings()
        XCTAssertEqual(saved.fontSize, 13)
    }

    func testQueuedFontSizeAdjustmentsPreserveDeliveryOrderAtClampBoundary() async throws {
        let initial = TerminalSettings(
            fontSize: TerminalSettings.maximumFontSize,
            theme: .remuxDark
        )
        let repository = BlockingFirstSaveTerminalSettingsRepository(settings: initial)
        let harness = makeHarness(
            settings: initial,
            settingsRepository: repository
        )
        await harness.model.load()

        harness.model.enqueueTerminalFontSizeAdjustment(
            by: 1,
            effectiveDefault: 10
        )
        await repository.waitForFirstSaveToStart()
        harness.model.enqueueTerminalFontSizeAdjustment(
            by: -1,
            effectiveDefault: 10
        )
        let secondSaveStartedBeforeRelease =
            await repository.waitForSecondSaveToStart()
        await repository.releaseFirstSave()
        await repository.waitForBothSavesToComplete()

        XCTAssertFalse(secondSaveStartedBeforeRelease)
        XCTAssertEqual(harness.model.terminalSettings.fontSize, 23)
        let saved = try await repository.loadSettings()
        XCTAssertEqual(saved.fontSize, 23)
    }

    func testSaveAndConnectPersistsNewProfileAndUsesCurrentSettings() async throws {
        let settings = TerminalSettings(fontSize: 15, theme: .remuxDark)
        let harness = makeHarness(settings: settings)
        await harness.model.load()
        harness.model.beginNewServer()
        harness.model.updateDraft { draft in
            draft.displayName = "Example Server"
            draft.host = "server.example.com"
            draft.port = "22"
            draft.username = "demo"
            draft.password = "demo-password"
            draft.sessionName = "base"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        let target = activeSession.target
        XCTAssertEqual(activeWorkspaceID, target.workspace.id)
        XCTAssertEqual(target.server.displayName, "Example Server")
        XCTAssertEqual(target.workspace.sessionName, "base")
        XCTAssertEqual(target.sshAuth.credential, .password("demo-password"))
        XCTAssertEqual(target.sshAuth.identityID, target.server.identityID)
        XCTAssertEqual(target.sshAuth.displayLabel, "Example Server")
        XCTAssertEqual(target.terminalSettings, settings)

        let snapshot = try await harness.profileRepository.loadSnapshot()
        let identity = try XCTUnwrap(snapshot.identities.first)
        let savedCredential = try await harness.credentialStore.loadCredential(identityID: identity.id)
        XCTAssertEqual(snapshot.servers, [target.server])
        XCTAssertEqual(snapshot.workspaces, [target.workspace])
        XCTAssertEqual(snapshot.identities, [identity])
        XCTAssertEqual(target.server.identityID, identity.id)
        XCTAssertEqual(identity.name, "Example Server")
        XCTAssertEqual(identity.authenticationKind, .password)
        XCTAssertEqual(savedCredential, .password("demo-password"))
    }

    func testLoadWithSavedProfileShowsLibraryInsteadOfAutoOpeningTerminal() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)

        await harness.model.load()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        XCTAssertEqual(harness.model.library.workspaces, [workspace])
    }

    func testLoadPrewarmsLatestSSHWorkspacePerRecentServer() async throws {
        let now = Date()
        let firstServer = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let secondServer = SavedServer(
            displayName: "Logs Host",
            host: "logs.example.test",
            username: "logger"
        )
        let olderFirstWorkspace = SavedWorkspace(
            serverID: firstServer.id,
            sessionName: "older",
            lastOpenedAt: now.addingTimeInterval(-120)
        )
        let newestFirstWorkspace = SavedWorkspace(
            serverID: firstServer.id,
            sessionName: "newest",
            lastOpenedAt: now
        )
        let secondWorkspace = SavedWorkspace(
            serverID: secondServer.id,
            sessionName: "logs",
            lastOpenedAt: now.addingTimeInterval(-30)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [firstServer, secondServer],
            workspaces: [
                olderFirstWorkspace,
                newestFirstWorkspace,
                secondWorkspace,
            ],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                prewarmer.record(target)
            }
        )
        try await harness.credentialHelper.savePassword("first-secret", for: firstServer.id)
        try await harness.credentialHelper.savePassword("second-secret", for: secondServer.id)

        await harness.model.load()

        let didPrewarm = await waitUntil {
            prewarmer.targets.count == 2
        }
        XCTAssertTrue(didPrewarm)

        let targets = prewarmer.targets
        XCTAssertEqual(Set(targets.map(\.server.id)), Set([firstServer.id, secondServer.id]))
        XCTAssertTrue(targets.contains { $0.workspace.id == newestFirstWorkspace.id })
        XCTAssertFalse(targets.contains { $0.workspace.id == olderFirstWorkspace.id })

        let didPrepareTransports = await waitUntil {
            transportFactory.events.filter { event in
                if case .prepared = event { return true }
                return false
            }.count == 2
        }
        XCTAssertTrue(didPrepareTransports)
        XCTAssertEqual(
            Set(transportFactory.targets.map(\.workspace.id)),
            Set([newestFirstWorkspace.id, secondWorkspace.id])
        )
    }

    func testLibraryPrewarmSkipsServersWithActiveSessions() async throws {
        let now = Date()
        let activePasswordBackedServer = makePasswordBackedServer(
            displayName: "Active Host",
            host: "active.example.test",
            username: "active"
        )
        let secondPasswordBackedServer = makePasswordBackedServer(
            displayName: "Second Host",
            host: "second.example.test",
            username: "second"
        )
        let activeServer = activePasswordBackedServer.server
        let secondServer = secondPasswordBackedServer.server
        let activeWorkspace = SavedWorkspace(
            serverID: activeServer.id,
            sessionName: "active",
            lastOpenedAt: now
        )
        let secondWorkspace = SavedWorkspace(
            serverID: secondServer.id,
            sessionName: "second",
            lastOpenedAt: now.addingTimeInterval(-10)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [activeServer],
            workspaces: [activeWorkspace],
            identities: [activePasswordBackedServer.identity],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                prewarmer.record(target)
            }
        )
        try await harness.credentialStore.saveCredential(
            .password("active-secret"),
            identityID: activePasswordBackedServer.identity.id
        )

        await harness.model.load()
        let didInitialPrewarm = await waitUntil {
            prewarmer.targets.count == 1
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 1
        }
        XCTAssertTrue(didInitialPrewarm)

        await harness.model.connect(to: activeWorkspace.id)
        XCTAssertEqual(harness.model.activeSessions.first?.target.server.id, activeServer.id)
        prewarmer.reset()
        transportFactory.reset()
        try await harness.profileRepository.saveProfile(
            server: secondServer,
            workspace: secondWorkspace
        )
        try await harness.profileRepository.saveIdentity(secondPasswordBackedServer.identity)
        try await harness.credentialStore.saveCredential(
            .password("second-secret"),
            identityID: secondPasswordBackedServer.identity.id
        )

        await harness.model.showLibrary()

        let didPrewarmInactiveServers = await waitUntil {
            prewarmer.targets.count == 1
                && transportFactory.targets.map(\.server.id) == [secondServer.id]
        }
        XCTAssertTrue(didPrewarmInactiveServers)

        XCTAssertEqual(
            Set(prewarmer.targets.map(\.server.id)),
            Set([secondServer.id])
        )
        XCTAssertFalse(prewarmer.targets.contains { $0.server.id == activeServer.id })
        XCTAssertEqual(
            Set(transportFactory.targets.map(\.server.id)),
            Set([secondServer.id])
        )
        XCTAssertFalse(transportFactory.targets.contains { $0.server.id == activeServer.id })
    }

    func testInFlightLibraryPrewarmDoesNotPrepareAfterActivation() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.connect(to: workspace.id)
        let didPrepareActivation = await waitUntil {
            transportFactory.preparedIDs.count == 1
        }
        XCTAssertTrue(didPrepareActivation)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets.map(\.workspace.id), [workspace.id])
        XCTAssertEqual(transportFactory.preparedIDs.count, 1)
    }

    func testInFlightLibraryPrewarmDoesNotPrepareStaleTargetAfterServerEdit() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.credentialStore.saveCredential(
            .password("secret"),
            identityID: passwordBackedServer.identity.id
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.host = "new-build.example.test"
            draft.password = "new-secret"
        }
        await harness.model.saveAndConnect()
        XCTAssertEqual(harness.model.state, .library)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets, [])
    }

    func testInFlightLibraryPrewarmDoesNotPrepareAfterSettingsChange() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let prewarmer = SuspendingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                await prewarmer.recordAndSuspend(target)
            }
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        let didStartLibraryPrewarm = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [workspace.id]
        }
        XCTAssertTrue(didStartLibraryPrewarm)

        await harness.model.updateTerminalSettings { settings in
            settings.fontSize = TerminalSettings.defaultExplicitFontSize
        }
        XCTAssertEqual(harness.model.state, .library)

        prewarmer.resumeAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transportFactory.targets, [])
    }

    func testActivationClosesPassivePreparedTransportsForSameServer() async throws {
        let now = Date()
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let warmedWorkspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "warmed",
            lastOpenedAt: now
        )
        let activatedWorkspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "activated",
            lastOpenedAt: now.addingTimeInterval(-60)
        )
        let prewarmer = RecordingSSHConnectionPrewarmer()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [warmedWorkspace, activatedWorkspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            sshConnectionPrewarmer: { target, _, _ in
                prewarmer.record(target)
            }
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        let didPrepareWarmedWorkspace = await waitUntil {
            prewarmer.targets.map(\.workspace.id) == [warmedWorkspace.id]
                && transportFactory.events.filter { event in
                    if case .prepared = event { return true }
                    return false
                }.count == 1
        }
        XCTAssertTrue(didPrepareWarmedWorkspace)
        let warmedTransportID = try XCTUnwrap(transportFactory.createdIDs.first)

        await harness.model.connect(to: activatedWorkspace.id)

        let didCloseWarmedAndPrepareActivated = await waitUntil {
            transportFactory.events.contains(.closed(warmedTransportID))
                && transportFactory.targets.map(\.workspace.id).contains(activatedWorkspace.id)
                && transportFactory.preparedIDs.count == 2
        }
        XCTAssertTrue(didCloseWarmedAndPrepareActivated)

        // The activated transport was claimed by the model itself; a
        // later request creates a fresh one.
        let activeTarget = try XCTUnwrap(harness.model.activeSessions.first?.target)
        XCTAssertEqual(activeTarget.workspace.id, activatedWorkspace.id)
        let activatedTransportID = try XCTUnwrap(transportFactory.createdIDs.last)
        let fresh = harness.model.makeTransport(for: activeTarget)
        let freshTransport = try XCTUnwrap(fresh as? RecordingRootTmuxControlTransport)
        XCTAssertNotEqual(freshTransport.id, activatedTransportID)
    }

    func testBeginNewWorkspaceUsesExistingServerAndLeavesSessionNameForUserInput() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.showLibrary()

        await harness.model.beginNewWorkspace(for: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.host, server.host)
        XCTAssertEqual(draft.username, server.username)
        XCTAssertEqual(draft.sessionName, "")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testBeginNewWorkspaceDoesNotGenerateSessionNameFromExistingWorkspaces() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let generated = SavedWorkspace(serverID: server.id, sessionName: "session-2")
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, generated],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginNewWorkspace(for: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.sessionName, "")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .newWorkspace(server.id))
    }

    func testNewWorkspaceSavesTypedSessionNameAndConnectsExistingServer() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let harness = makeHarness(
            servers: [server],
            workspaces: [],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.beginNewWorkspace(for: server.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "claude"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        XCTAssertEqual(activeWorkspaceID, activeSession.target.workspace.id)
        XCTAssertEqual(activeSession.target.server, server)
        XCTAssertEqual(activeSession.target.workspace.sessionName, "claude")
        XCTAssertEqual(activeSession.target.sshAuth.credential, .password("demo-password"))

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["claude"])
    }

    func testNewWorkspaceValidationDoesNotRequireHiddenServerFields() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let harness = makeHarness(
            servers: [server],
            workspaces: [],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.beginNewWorkspace(for: server.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "scratch"
            draft.password = ""
        }

        await harness.model.saveAndConnect()

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["scratch"])

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        XCTAssertEqual(activeWorkspaceID, snapshot.workspaces.first?.id)
        XCTAssertEqual(activeSession.target.server, server)
        XCTAssertEqual(activeSession.target.workspace.sessionName, "scratch")
        XCTAssertEqual(activeSession.target.sshAuth.credential, .password("demo-password"))
    }

    func testBeginEditServerLoadsServerScopedDraftWithoutReconnectTarget() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let base = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let logs = SavedWorkspace(
            serverID: server.id,
            sessionName: "logs",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginEditServer(serverID: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "logs")
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: nil))
    }

    func testBeginEditServerWorksWithoutExistingWorkspaces() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let harness = makeHarness(
            servers: [server],
            workspaces: [],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginEditServer(serverID: server.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "")
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: nil))
    }

    func testBeginCredentialRepairCapturesReconnectWorkspace() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginCredentialRepair(for: workspace.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, workspace.sessionName)
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: workspace.id))
    }

    func testCredentialRepairReconnectsOriginalWorkspaceWithoutDuplication() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("old-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginCredentialRepair(for: workspace.id)
        harness.model.updateDraft { draft in
            draft.password = "new-password"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        XCTAssertEqual(activeWorkspaceID, workspace.id)
        XCTAssertEqual(activeSession.target.workspace.id, workspace.id)
        XCTAssertEqual(activeSession.target.workspace.sessionName, workspace.sessionName)
        XCTAssertEqual(activeSession.target.sshAuth.credential, .password("new-password"))

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.id), [workspace.id])
        let savedCredential = try await harness.credentialStore.loadCredential(
            identityID: passwordBackedServer.identity.id
        )
        XCTAssertEqual(savedCredential, .password("new-password"))
    }

    func testBeginServerRepairCapturesReconnectWorkspace() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginServerRepair(for: workspace.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, workspace.sessionName)
        XCTAssertEqual(draft.password, "demo-password")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editServer(server.id, reconnectWorkspaceID: workspace.id))
    }

    func testServerRepairReconnectsOriginalWorkspaceWithoutDuplication() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginServerRepair(for: workspace.id)
        harness.model.updateDraft { draft in
            draft.host = "reachable.example.test"
        }

        await harness.model.saveAndConnect()

        guard
            case .terminal(let activeWorkspaceID) = harness.model.state,
            let activeSession = harness.model.activeSessions.first
        else {
            XCTFail("expected terminal state")
            return
        }

        XCTAssertEqual(activeWorkspaceID, workspace.id)
        XCTAssertEqual(activeSession.target.workspace.id, workspace.id)
        XCTAssertEqual(activeSession.target.workspace.sessionName, workspace.sessionName)
        XCTAssertEqual(activeSession.target.server.host, "reachable.example.test")

        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.id), [workspace.id])
        XCTAssertEqual(snapshot.servers.map(\.host), ["reachable.example.test"])
    }

    func testBeginEditWorkspaceUsesSessionScopedEditing() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()

        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: logs.id)

        guard case .setup(let draft, let validation, let mode) = harness.model.state else {
            XCTFail("expected setup state")
            return
        }

        XCTAssertEqual(draft.displayName, server.displayName)
        XCTAssertEqual(draft.sessionName, "logs")
        XCTAssertEqual(draft.password, "")
        XCTAssertEqual(validation, .empty)
        XCTAssertEqual(mode, .editWorkspace(server.id, logs.id))
    }

    func testEditServerSavesServerWithoutCreatingWorkspaceOrOpeningTerminal() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let harness = makeHarness(
            servers: [server],
            workspaces: [],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.displayName = "Build Host Updated"
            draft.host = "updated.example.com"
            draft.password = "updated-demo-password"
        }

        await harness.model.saveAndConnect()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.servers.map(\.displayName), ["Build Host Updated"])
        XCTAssertEqual(snapshot.servers.map(\.host), ["updated.example.com"])
        XCTAssertEqual(snapshot.servers.first?.identityID, passwordBackedServer.identity.id)
        XCTAssertEqual(snapshot.workspaces, [])
        let savedCredential = try await harness.credentialStore.loadCredential(
            identityID: passwordBackedServer.identity.id
        )
        XCTAssertEqual(savedCredential, .password("updated-demo-password"))
    }

    func testEditServerRestoresIdentityAndCredentialWhenServerSaveFails() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let harness = makeHarness(
            servers: [server],
            workspaces: [],
            identities: [passwordBackedServer.identity]
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.displayName = "Build Host Updated"
            draft.password = "updated-demo-password"
        }
        await harness.profileRepository.failNextSaveServer(
            with: ConnectionProfileRepositoryError.missingServer(server.id)
        )

        await harness.model.saveAndConnect()

        let snapshot = try await harness.profileRepository.loadSnapshot()
        let restoredIdentity = try XCTUnwrap(snapshot.identity(id: passwordBackedServer.identity.id))
        let restoredCredential = try await harness.credentialStore.loadCredential(
            identityID: passwordBackedServer.identity.id
        )
        XCTAssertEqual(restoredIdentity, passwordBackedServer.identity)
        XCTAssertEqual(restoredCredential, .password("demo-password"))
    }

    func testEditServerRefreshesIdleActiveSessionAuthBeforeAttach() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity],
            transportFactory: { target, trustedHostStore, _ in
                transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let originalSession = try XCTUnwrap(harness.model.activeSessions.first)
        let originalModel = harness.model.terminalScreenModel(for: originalSession)

        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.host = "updated.example.com"
            draft.username = "deploy"
            draft.password = "updated-demo-password"
        }

        await harness.model.saveAndConnect()

        let refreshedSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(refreshedSession.instanceID, originalSession.instanceID)
        XCTAssertEqual(refreshedSession.target.server.host, "updated.example.com")
        XCTAssertEqual(refreshedSession.target.server.username, "deploy")
        XCTAssertEqual(refreshedSession.target.sshAuth.username, "deploy")
        XCTAssertEqual(refreshedSession.target.sshAuth.credential, .password("updated-demo-password"))
        // A connecting model is not replaced by the edit (it would drop
        // the user's session); the refreshed target applies to the NEXT
        // runtime attempt.
        let refreshedModel = harness.model.terminalScreenModel(for: refreshedSession)
        XCTAssertTrue(originalModel === refreshedModel)
        XCTAssertEqual(modelFactory.createdKeys.count, 1)

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let attachedTarget = try XCTUnwrap(transportFactory.targets.last)
        XCTAssertEqual(attachedTarget.server.host, "updated.example.com")
        XCTAssertEqual(attachedTarget.server.username, "deploy")
        XCTAssertEqual(attachedTarget.sshAuth.username, "deploy")
        XCTAssertEqual(attachedTarget.sshAuth.credential, .password("updated-demo-password"))
    }

    func testEditServerKeepsRunningAttachmentTargetPinnedToVisibleTerminal() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let attachmentFactory = RecordingAttachmentTransferServiceFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [passwordBackedServer.identity],
            attachmentTransferServiceFactory: attachmentFactory.factory,
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialStore.saveCredential(
            .password("demo-password"),
            identityID: passwordBackedServer.identity.id
        )
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let originalSession = try XCTUnwrap(harness.model.activeSessions.first)
        let runningModel = harness.model.terminalScreenModel(for: originalSession)
        await waitForConnecting(runningModel)

        await harness.model.beginEditServer(serverID: server.id)
        harness.model.updateDraft { draft in
            draft.host = "updated.example.com"
            draft.username = "deploy"
            draft.password = "updated-demo-password"
        }

        await harness.model.saveAndConnect()

        let refreshedSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(refreshedSession.target.server.host, "updated.example.com")
        XCTAssertEqual(refreshedSession.target.sshAuth.username, "deploy")
        XCTAssertTrue(runningModel === harness.model.terminalScreenModel(for: refreshedSession))

        let entry = try XCTUnwrap(harness.model.activeTerminalScreenEntries.first)
        _ = entry.attachmentTransferServiceFactory()

        let attachmentTarget = try XCTUnwrap(attachmentFactory.targets.last)
        XCTAssertEqual(attachmentTarget.server.host, server.host)
        XCTAssertEqual(attachmentTarget.server.username, server.username)
        XCTAssertEqual(attachmentTarget.sshAuth.username, server.username)
        XCTAssertEqual(attachmentTarget.sshAuth.credential, .password("demo-password"))
    }

    func testEditWorkspaceSavesSessionWithoutOpeningTerminalOrChangingLastOpenedTime() async throws {
        let lastOpenedAt = Date(timeIntervalSince1970: 500)
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(
            serverID: server.id,
            sessionName: "base",
            lastOpenedAt: lastOpenedAt
        )
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: workspace.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "logs"
        }

        await harness.model.saveAndConnect()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions, [])
        let snapshot = try await harness.profileRepository.loadSnapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.sessionName), ["logs"])
        XCTAssertEqual(snapshot.workspaces.first?.lastOpenedAt, lastOpenedAt)
    }

    func testEditActiveWorkspaceRefreshesScreenPresentationWithoutReplacingModel() async throws {
        let settings = TerminalSettings(fontSize: 13, theme: .remuxLight)
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settings: settings,
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let sessionBeforeEdit = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: sessionBeforeEdit)
        XCTAssertEqual(harness.model.activeTerminalScreenEntries.first?.presentation.sessionName, "base")

        await harness.model.beginEditWorkspace(serverID: server.id, workspaceID: workspace.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "logs"
        }

        await harness.model.saveAndConnect()

        let sessionAfterEdit = try XCTUnwrap(harness.model.activeSessions.first)
        let entry = try XCTUnwrap(harness.model.activeTerminalScreenEntries.first)
        XCTAssertEqual(sessionAfterEdit.instanceID, sessionBeforeEdit.instanceID)
        XCTAssertTrue(entry.model === terminalModel)
        XCTAssertEqual(entry.presentation.workspaceID, workspace.id)
        XCTAssertEqual(entry.presentation.sessionName, "logs")
        XCTAssertEqual(entry.presentation.terminalTheme, settings.theme)
        XCTAssertEqual(sessionAfterEdit.target.workspace.sessionName, "logs")
    }

    func testConnectMultipleWorkspacesKeepsBothActiveWhileReturningToLibrary() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.showLibrary()
        await harness.model.connect(to: logs.id)

        XCTAssertEqual(Set(harness.model.activeSessions.map(\.id)), Set([base.id, logs.id]))
        XCTAssertEqual(harness.model.state, .terminal(logs.id))

        await harness.model.showLibrary()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(Set(harness.model.activeSessions.map(\.id)), Set([base.id, logs.id]))

        harness.model.showActiveSession(base.id)

        XCTAssertEqual(harness.model.state, .terminal(base.id))
    }

    func testConnectInstallsTerminalModelForActiveAttempt() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let key = TerminalRuntimeAttemptKey(session: session)
        let terminalModel = harness.model.terminalScreenModel(for: session)

        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: session))
        XCTAssertEqual(modelFactory.createdKeys, [key])
        XCTAssertTrue(terminalModel === modelFactory.createdModels[key])
    }

    func testConnectUsesLinkedPasswordIdentity() async throws {
        let identity = SSHIdentity(
            name: "Deploy Password",
            authenticationKind: .password
        )
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder",
            identityID: identity.id
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [identity]
        )
        try await harness.credentialStore.saveCredential(.password("identity-secret"), identityID: identity.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(session.target.sshAuth.credential, .password("identity-secret"))
        XCTAssertEqual(session.target.sshAuth.identityID, identity.id)
        XCTAssertEqual(session.target.sshAuth.displayLabel, "Deploy Password")
    }

    func testNewWorkspaceUsesLinkedPasswordIdentity() async throws {
        let identity = SSHIdentity(
            name: "Deploy Password",
            authenticationKind: .password
        )
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder",
            identityID: identity.id
        )
        let harness = makeHarness(servers: [server], identities: [identity])
        try await harness.credentialStore.saveCredential(.password("identity-secret"), identityID: identity.id)

        await harness.model.load()
        await harness.model.beginNewWorkspace(for: server.id)
        harness.model.updateDraft { draft in
            draft.sessionName = "logs"
        }

        await harness.model.saveAndConnect()

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(session.target.workspace.sessionName, "logs")
        XCTAssertEqual(session.target.sshAuth.credential, .password("identity-secret"))
        XCTAssertEqual(session.target.sshAuth.identityID, identity.id)
    }

    func testActiveTerminalScreenEntriesPairSessionsWithExactAttemptModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)

        let entries = harness.model.activeTerminalScreenEntries
        XCTAssertEqual(entries.map(\.id), harness.model.activeSessions.map(\.id))
        XCTAssertEqual(entries.map(\.instanceID), harness.model.activeSessions.map(\.instanceID))

        for (entry, session) in zip(entries, harness.model.activeSessions) {
            let key = TerminalRuntimeAttemptKey(session: session)
            let recordedModel = try XCTUnwrap(modelFactory.createdModels[key])

            XCTAssertEqual(entry.runtimeAttemptKey, key)
            XCTAssertTrue(entry.model === recordedModel)
            XCTAssertEqual(entry.presentation.workspaceID, session.target.workspace.id)
            XCTAssertEqual(entry.presentation.sessionName, session.target.workspace.sessionName)
            XCTAssertEqual(entry.presentation.terminalTheme, session.target.terminalSettings.theme)
        }
    }

    func testShowLibraryKeepsOwnedTerminalModelsAlive() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)

        await harness.model.showLibrary()

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertTrue(harness.model.terminalScreenModel(for: session) === terminalModel)
    }

    func testCloseActiveSessionStopsOwnedTerminalModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await waitForConnecting(terminalModel)

        harness.model.closeActiveSession(workspace.id)

        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        // Teardown ordering (surface -> link -> controller) is owned by
        // the model's async stop; completion nils the session.
        await waitForStopped(terminalModel)
    }

    func testAppLifecyclePhaseForegroundReportsDisconnectedModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await waitForConnecting(terminalModel)

        // Disconnect outside the terminal screen so the root's
        // auto-reconnect policy does not replace the model.
        await harness.model.showLibrary()
        await terminalModel.session?.disconnect()
        let didDetach = await waitUntil(timeout: 5) {
            if case .detached = terminalModel.session?.state { return true }
            return false
        }
        XCTAssertTrue(didDetach)

        // Foreground re-reports the disconnected state with the
        // foreground source so the root's policy can act on it.
        modelFactory.clearRecordedUpdates()
        harness.model.handleAppLifecyclePhase(.active)
        let foregroundReports = modelFactory.recordedUpdates.filter {
            $0.source == .foreground
        }
        XCTAssertEqual(foregroundReports.count, 1)
        XCTAssertNotNil(foregroundReports.first?.state.disconnectedReason)
    }

    func testAppLifecyclePhaseDoesNotInventForegroundStateForConnectingModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        harness.model.handleAppLifecyclePhase(.active)
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await waitForConnecting(terminalModel)

        modelFactory.clearRecordedUpdates()
        harness.model.handleAppLifecyclePhase(.active)
        XCTAssertTrue(modelFactory.recordedUpdates.allSatisfy {
            $0.source != .foreground
        })
    }

    func testAppLifecyclePhaseDoesNotForwardToReplacedTerminalModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        await waitForConnecting(oldModel)

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(newSession.instanceID, oldSession.instanceID)
        await waitForStopped(oldModel)

        modelFactory.clearRecordedUpdates()
        harness.model.handleAppLifecyclePhase(.active)
        XCTAssertTrue(modelFactory.recordedUpdates.allSatisfy {
            $0.instanceID != oldSession.instanceID
        })
    }

    func testReconnectStopsOldAttemptModelAndInstallsNewAttemptModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        await waitForConnecting(oldModel)

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)

        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(newSession.instanceID, oldSession.instanceID)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: oldSession))
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        await waitForStopped(oldModel)
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        XCTAssertEqual(
            modelFactory.createdKeys,
            [TerminalRuntimeAttemptKey(session: oldSession), TerminalRuntimeAttemptKey(session: newSession)]
        )
    }

    func testRepeatedConnectToSameWorkspaceStopsOldAttemptModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let oldModel = harness.model.terminalScreenModel(for: oldSession)
        await waitForConnecting(oldModel)

        await harness.model.connect(to: workspace.id)

        let newSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(newSession.instanceID, oldSession.instanceID)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: oldSession))
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: newSession))
        await waitForStopped(oldModel)
    }

    func testDeleteWorkspaceStopsOwnedTerminalModel() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await waitForConnecting(terminalModel)

        await harness.model.deleteWorkspace(workspace.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        await waitForStopped(terminalModel)
    }

    func testDeleteServerStopsAssociatedTerminalModels() async throws {
        let passwordBackedServer = makePasswordBackedServer()
        let server = passwordBackedServer.server
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [base, logs],
            identities: [passwordBackedServer.identity],
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialStore.saveCredential(
            .password("secret"),
            identityID: passwordBackedServer.identity.id
        )

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)
        let sessions = harness.model.activeSessions

        await harness.model.deleteServer(server.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertTrue(harness.model.activeSessions.isEmpty)
        XCTAssertTrue(sessions.allSatisfy { !harness.model.hasTerminalScreenModel(for: $0) })
        let snapshot = try await harness.profileRepository.loadSnapshot()
        let credential = try await harness.credentialStore.loadCredential(
            identityID: passwordBackedServer.identity.id
        )
        XCTAssertTrue(snapshot.identities.isEmpty)
        XCTAssertNil(credential)
    }

    func testFailedStateStopsOwnedTerminalModels() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let transportFactory = RecordingRootTransportFactory()
        let modelFactory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settingsRepository: FailingSaveTerminalSettingsRepository(),
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            },
            terminalScreenModelFactory: modelFactory.factory
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        let session = try XCTUnwrap(harness.model.activeSessions.first)
        let terminalModel = harness.model.terminalScreenModel(for: session)
        await waitForConnecting(terminalModel)

        await harness.model.updateTerminalSettings { settings in
            settings.fontSize = 19
        }

        guard case .failed = harness.model.state else {
            XCTFail("expected failed state")
            return
        }
        XCTAssertTrue(harness.model.activeSessions.isEmpty)
        XCTAssertTrue(harness.model.activeTerminalScreenEntries.isEmpty)
        XCTAssertFalse(harness.model.hasTerminalScreenModel(for: session))
        await waitForStopped(terminalModel)
    }

    func testRuntimeDisconnectMarksActiveSessionDisconnected() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        await harness.model.showLibrary()

        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport write failed: closed"
        )

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        XCTAssertEqual(outcome, .applied(.disconnected(reason)))
        XCTAssertEqual(harness.model.activeSessions.first?.runtimeState, .disconnected(reason))
        XCTAssertEqual(harness.model.state, .library)
    }

    func testRuntimeUpdateOutcomeReportsMissingSessionWithoutMutation() {
        let harness = makeHarness()
        let update = TerminalRuntimeStateUpdate(
            workspaceID: UUID(),
            instanceID: UUID(),
            state: .connected,
            source: .readiness
        )

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(update)

        XCTAssertEqual(outcome, .missingSession)
        XCTAssertTrue(harness.model.activeSessions.isEmpty)
        XCTAssertEqual(harness.model.state, .loading)
    }

    func testConnectingRuntimeUpdatePreservesReconnectingState() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .connecting,
                source: .runtime
            )
        )

        XCTAssertEqual(outcome, .applied(.reconnecting(.manualButton)))
        XCTAssertEqual(harness.model.activeSessions.first?.runtimeState, .reconnecting(.manualButton))
    }

    func testTappingDisconnectedActiveSessionRecreatesTerminalRuntime() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)
        await harness.model.showLibrary()

        let oldInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport disconnected after 2048 bytes"
        )
        harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: oldInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        harness.model.showActiveSession(workspace.id)

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(session.instanceID, oldInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.activeSessionTap))
        XCTAssertEqual(harness.model.state, .terminal(workspace.id))
    }

    func testTrustHostKeyUpdatesTrustAndReconnectsActiveSession() async throws {
        let pair = makePasswordBackedServer()
        let server = pair.server
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            identities: [pair.identity]
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        try saveTrustedHostIdentity(
            TrustedHostIdentity(
                serverID: server.id,
                host: server.host,
                keyType: "ssh-ed25519",
                openSSHPublicKey: "ssh-ed25519 trusted",
                trustedAt: Date(timeIntervalSince1970: 1)
            ),
            root: harness.trustedHostRoot
        )
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let oldSession = try XCTUnwrap(harness.model.activeSessions.first)
        let challenge = SSHHostKeyTrustChallenge(
            kind: .changed,
            serverID: server.id,
            host: server.host,
            trustedKeyType: "ssh-ed25519",
            trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
            receivedKeyType: "ecdsa-sha2-nistp256",
            receivedOpenSSHPublicKey: "ecdsa-sha2-nistp256 received"
        )
        let reason = TerminalDisconnectReason(
            kind: .hostKey,
            message: "host key changed",
            hostKeyChallenge: challenge
        )
        _ = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: oldSession.instanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        harness.model.trustHostKeyAndReconnect(workspace.id)

        let identities = try loadTrustedHostIdentities(root: harness.trustedHostRoot)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].serverID, server.id)
        XCTAssertEqual(identities[0].keyType, "ecdsa-sha2-nistp256")
        XCTAssertEqual(identities[0].openSSHPublicKey, "ecdsa-sha2-nistp256 received")

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertNotEqual(session.instanceID, oldSession.instanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.manualButton))
        XCTAssertEqual(harness.model.state, .terminal(workspace.id))
    }

    func testAutomaticTransportReconnectIsBoundedUntilManualReconnect() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let firstInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        let firstOutcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: firstInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        var session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            firstOutcome,
            .automaticReconnectStarted(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertNotEqual(session.instanceID, firstInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.transportLoss))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.contains(.transportLoss))

        let secondInstanceID = session.instanceID
        let secondOutcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: secondInstanceID,
                state: .disconnected(reason),
                source: .runtime
            )
        )

        session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            secondOutcome,
            .automaticReconnectSkipped(source: .transportLoss, state: .disconnected(reason))
        )
        XCTAssertEqual(session.instanceID, secondInstanceID)
        XCTAssertEqual(session.runtimeState, .disconnected(reason))
    }

    func testForegroundDisconnectRequestsForegroundReconnect() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport unavailable after foreground"
        )
        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .foreground
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(
            outcome,
            .automaticReconnectStarted(source: .foreground, state: .disconnected(reason))
        )
        XCTAssertNotEqual(session.instanceID, instanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.foreground))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.contains(.foreground))
    }

    func testReadinessDisconnectDoesNotRequestAutomaticReconnect() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "readiness observed disconnected"
        )
        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: instanceID,
                state: .disconnected(reason),
                source: .readiness
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(outcome, .applied(.disconnected(reason)))
        XCTAssertEqual(session.instanceID, instanceID)
        XCTAssertEqual(session.runtimeState, .disconnected(reason))
        XCTAssertTrue(session.automaticReconnectAttemptedSources.isEmpty)
    }

    func testRuntimeStateReportTrackerReportsForegroundDisconnectAfterRuntimeDisconnect() {
        var tracker = TerminalRuntimeStateReportTracker()
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        let disconnectedState = TerminalRuntimeState.disconnected(reason)

        XCTAssertTrue(tracker.shouldReport(state: .connecting, source: .readiness))
        XCTAssertFalse(tracker.shouldReport(state: .connecting, source: .foreground))
        XCTAssertTrue(tracker.shouldReport(state: disconnectedState, source: .runtime))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .readiness))
        XCTAssertTrue(tracker.shouldReport(state: disconnectedState, source: .foreground))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .foreground))
        XCTAssertFalse(tracker.shouldReport(state: disconnectedState, source: .runtime))
    }

    func testNonAutomaticDisconnectReasonsDoNotAutoReconnect() async throws {
        let reasons = [
            TerminalDisconnectReason(kind: .authentication, message: "permission denied"),
            TerminalDisconnectReason(kind: .hostKey, message: "host key changed"),
            TerminalDisconnectReason(kind: .profile, message: "invalid profile"),
            TerminalDisconnectReason(kind: .remoteExit, message: "remote exited"),
            TerminalDisconnectReason(kind: .runtime, message: "runtime rejected output"),
            TerminalDisconnectReason(kind: .userClosed, message: "closed by user"),
            TerminalDisconnectReason(kind: .unknown, message: "unknown failure"),
        ]

        for reason in reasons {
            let server = SavedServer(
                displayName: "Build Host",
                host: "build.example.test",
                username: "builder"
            )
            let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
            let harness = makeHarness(servers: [server], workspaces: [workspace])
            try await harness.credentialHelper.savePassword("secret", for: server.id)
            await harness.model.load()
            await harness.model.connect(to: workspace.id)

            let instanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
            harness.model.handleTerminalRuntimeStateUpdate(
                TerminalRuntimeStateUpdate(
                    workspaceID: workspace.id,
                    instanceID: instanceID,
                    state: .disconnected(reason),
                    source: .runtime
                )
            )

            let session = try XCTUnwrap(harness.model.activeSessions.first)
            XCTAssertEqual(session.instanceID, instanceID, "\(reason.kind)")
            XCTAssertEqual(session.runtimeState, .disconnected(reason), "\(reason.kind)")
            XCTAssertTrue(session.automaticReconnectAttemptedSources.isEmpty, "\(reason.kind)")
            XCTAssertEqual(harness.model.state, .terminal(workspace.id), "\(reason.kind)")
        }
    }

    func testStaleRuntimeFailureCallbackAfterReconnectIsIgnored() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let harness = makeHarness(servers: [server], workspaces: [workspace])
        try await harness.credentialHelper.savePassword("secret", for: server.id)
        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let oldInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        harness.model.reconnectActiveSession(workspace.id, source: .manualButton)
        let newInstanceID = try XCTUnwrap(harness.model.activeSessions.first?.instanceID)
        XCTAssertNotEqual(newInstanceID, oldInstanceID)

        let outcome = harness.model.handleTerminalRuntimeStateUpdate(
            TerminalRuntimeStateUpdate(
                workspaceID: workspace.id,
                instanceID: oldInstanceID,
                state: .disconnected(
                    TerminalDisconnectReason(
                        kind: .transportIO,
                        message: "stale tmux transport write failed: closed"
                    )
                ),
                source: .runtime
            )
        )

        let session = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(outcome, .staleInstance(current: newInstanceID, stale: oldInstanceID))
        XCTAssertEqual(session.instanceID, newInstanceID)
        XCTAssertEqual(session.runtimeState, .reconnecting(.manualButton))
    }

    func testConnectPreparesTransportAndTerminalClaimsPreparedTransport() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let transportFactory = RecordingRootTransportFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            transportFactory: { target, trustedHostStore, sshConnectionPool in
                _ = sshConnectionPool
                return transportFactory.makeTransport(
                    target: target,
                    trustedHostStore: trustedHostStore
                )
            }
        )
        try await harness.credentialHelper.savePassword("secret", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let prepared = await waitUntil {
            transportFactory.events.contains { event in
                if case .prepared = event { return true }
                return false
            }
        }
        XCTAssertTrue(prepared)

        // The activation's model claimed the prepared transport (eager
        // connect): exactly one transport exists, and a later request
        // for the same target must create a fresh one because the pool
        // was consumed.
        let target = try XCTUnwrap(harness.model.activeSessions.first?.target)
        let createdID = try XCTUnwrap(transportFactory.createdIDs.last)
        XCTAssertEqual(transportFactory.createdIDs.count, 1)

        let fresh = harness.model.makeTransport(for: target)
        let freshTransport = try XCTUnwrap(fresh as? RecordingRootTmuxControlTransport)
        XCTAssertNotEqual(freshTransport.id, createdID)
    }

    func testCloseActiveSessionRemovesOnlyThatRuntimeSession() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")
        let harness = makeHarness(servers: [server], workspaces: [base, logs])
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: base.id)
        await harness.model.connect(to: logs.id)

        harness.model.closeActiveSession(logs.id)

        XCTAssertEqual(harness.model.state, .library)
        XCTAssertEqual(harness.model.activeSessions.map(\.id), [base.id])
    }

    func testUpdateTerminalSettingsPersistsSettings() async throws {
        let harness = makeHarness()
        await harness.model.load()
        let updated = TerminalSettings(fontSize: 18, theme: .remuxLight)

        await harness.model.updateTerminalSettings { settings in
            settings = updated
        }

        XCTAssertEqual(harness.model.terminalSettings, updated)
        let savedSettings = try await harness.settingsRepository.loadSettings()
        XCTAssertEqual(savedSettings, updated)
    }

    func testUpdateTerminalSettingsRefreshesActiveSessionModelsWithoutReplacingRuntimeAttempt() async throws {
        let server = SavedServer(
            displayName: "Build Host",
            host: "build.example.test",
            username: "builder"
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        let factory = RecordingTerminalScreenModelFactory()
        let harness = makeHarness(
            servers: [server],
            workspaces: [workspace],
            settings: TerminalSettings(fontSize: nil, theme: .remuxDark),
            terminalScreenModelFactory: factory.factory
        )
        try await harness.credentialHelper.savePassword("demo-password", for: server.id)

        await harness.model.load()
        await harness.model.connect(to: workspace.id)

        let originalSession = try XCTUnwrap(harness.model.activeSessions.first)
        let originalKey = TerminalRuntimeAttemptKey(session: originalSession)
        let originalModel = try XCTUnwrap(factory.createdModels[originalKey])
        let updated = TerminalSettings(fontSize: nil, theme: .remuxLight)

        await harness.model.updateTerminalSettings { settings in
            settings = updated
        }

        let refreshedSession = try XCTUnwrap(harness.model.activeSessions.first)
        XCTAssertEqual(refreshedSession.instanceID, originalSession.instanceID)
        XCTAssertEqual(refreshedSession.target.terminalSettings, updated)
        XCTAssertTrue(harness.model.hasTerminalScreenModel(for: refreshedSession))
        XCTAssertTrue(originalModel === harness.model.terminalScreenModel(for: refreshedSession))
        XCTAssertEqual(
            harness.model.activeTerminalScreenEntries.first?.presentation.terminalTheme,
            updated.theme
        )
    }

    private func makeHarness(
        servers: [SavedServer] = [],
        workspaces: [SavedWorkspace] = [],
        identities: [SSHIdentity] = [],
        settings: TerminalSettings = .default,
        settingsRepository: (any TerminalSettingsRepository)? = nil,
        transportFactory: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            RemuxSSHRootService
        ) -> any TmuxControlTransport)? = nil,
        sshConnectionPrewarmer: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            RemuxSSHRootService
        ) async -> Void)? = nil,
        attachmentTransferServiceFactory: (@Sendable (
            TmuxConnectionTarget,
            TrustedHostStore,
            RemuxSSHRootService
        ) -> any GhosttyAttachmentTransferService)? = nil,
        terminalScreenModelFactory: RemuxRootModel.TerminalScreenModelFactory? = nil
    ) -> RemuxRootModelHarness {
        let profileRepository = TestConnectionProfileRepository(
            servers: servers,
            workspaces: workspaces,
            identities: identities
        )
        let settingsRepository = settingsRepository ?? TestTerminalSettingsRepository(settings: settings)
        let shortcutRepository = FileBackedShortcutRepository(rootURL: temporaryRoot())
        let credentialStore = TestSSHCredentialStore()
        let credentialHelper = TestServerCredentialStore(
            profileRepository: profileRepository,
            credentialStore: credentialStore
        )
        let trustedHostRoot = temporaryRoot()
        let trustedHostStore = TrustedHostStore(rootURL: trustedHostRoot)
        let resolvedTransportFactory = transportFactory ?? { _, _, _ in
            DeterministicTmuxControlTransport(chunks: [])
        }
        let resolvedSSHConnectionPrewarmer = sshConnectionPrewarmer ?? { _, _, _ in }
        let resolvedAttachmentTransferServiceFactory = attachmentTransferServiceFactory ?? { _, _, _ in
            FailingGhosttyAttachmentTransferService()
        }
        let resolvedTerminalScreenModelFactory = terminalScreenModelFactory ?? makeTestTerminalScreenModel
        let dependencies = RemuxAppDependencies(
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            keyboardSettingsRepository: FileBackedKeyboardSettingsRepository(rootURL: temporaryRoot()),
            shortcutRepository: shortcutRepository,
            credentialStore: credentialStore,
            trustedHostStore: trustedHostStore,
            transportFactory: resolvedTransportFactory,
            sshConnectionPrewarmer: resolvedSSHConnectionPrewarmer,
            attachmentTransferServiceFactory: resolvedAttachmentTransferServiceFactory,
            debugConnectionSeeder: { _, _ in false }
        )

        return RemuxRootModelHarness(
            model: RemuxRootModel(
                dependencies: dependencies,
                terminalScreenModelFactory: resolvedTerminalScreenModelFactory
            ),
            profileRepository: profileRepository,
            settingsRepository: settingsRepository,
            credentialHelper: credentialHelper,
            credentialStore: credentialStore,
            trustedHostRoot: trustedHostRoot
        )
    }

    /// The new model connects eagerly at creation; "running" for tests
    /// means the transport started and the session began attaching.
    private func waitForConnecting(
        _ model: TmuxScreenModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didConnect = await waitUntil(timeout: 5) {
            switch model.session?.state {
            case .attaching, .syncing, .ready: return true
            default: return false
            }
        }
        XCTAssertTrue(didConnect, file: file, line: line)
    }

    /// stop() is async (surface -> link -> controller teardown); the
    /// session is nilled when it completes.
    private func waitForStopped(
        _ model: TmuxScreenModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didStop = await waitUntil(timeout: 5) {
            model.session == nil
        }
        XCTAssertTrue(didStop, file: file, line: line)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func saveTrustedHostIdentity(_ identity: TrustedHostIdentity, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode([identity])
        try data.write(to: root.appendingPathComponent("trusted-hosts.json"), options: .atomic)
    }

    private func loadTrustedHostIdentities(root: URL) throws -> [TrustedHostIdentity] {
        let data = try Data(contentsOf: root.appendingPathComponent("trusted-hosts.json"))
        return try JSONDecoder().decode([TrustedHostIdentity].self, from: data)
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makePasswordBackedServer(
        displayName: String = "Build Host",
        host: String = "build.example.test",
        username: String = "builder"
    ) -> (
        server: SavedServer,
        identity: SSHIdentity
    ) {
        let identity = SSHIdentity(
            name: displayName,
            authenticationKind: .password
        )
        let server = SavedServer(
            displayName: displayName,
            host: host,
            username: username,
            identityID: identity.id
        )

        return (server, identity)
    }
}

private struct RemuxRootModelHarness {
    let model: RemuxRootModel
    let profileRepository: TestConnectionProfileRepository
    let settingsRepository: any TerminalSettingsRepository
    let credentialHelper: TestServerCredentialStore
    let credentialStore: TestSSHCredentialStore
    let trustedHostRoot: URL
}

@MainActor
private func makeTestTerminalScreenModel(
    target: TmuxConnectionTarget,
    sessionInstanceID: UUID,
    transportFactory: @escaping TmuxScreenModel.TransportFactory,
    onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
    initialClientSize: TmuxSessionController.ClientSize?
) -> TmuxScreenModel {
    TmuxScreenModel(
        target: target,
        sessionInstanceID: sessionInstanceID,
        transportFactory: transportFactory,
        onRuntimeStateChange: onRuntimeStateChange,
        initialClientSize: initialClientSize ?? .rootModelTestViewport
    )
}

@MainActor
private final class RecordingTerminalScreenModelFactory: @unchecked Sendable {
    private(set) var createdKeys: [TerminalRuntimeAttemptKey] = []
    private(set) var createdModels: [TerminalRuntimeAttemptKey: TmuxScreenModel] = [:]
    private(set) var recordedUpdates: [TerminalRuntimeStateUpdate] = []

    var factory: RemuxRootModel.TerminalScreenModelFactory {
        { target, sessionInstanceID, transportFactory, onRuntimeStateChange, initialClientSize in
            self.makeModel(
                target: target,
                sessionInstanceID: sessionInstanceID,
                transportFactory: transportFactory,
                onRuntimeStateChange: onRuntimeStateChange,
                initialClientSize: initialClientSize
            )
        }
    }

    func clearRecordedUpdates() {
        recordedUpdates.removeAll()
    }

    func makeModel(
        target: TmuxConnectionTarget,
        sessionInstanceID: UUID,
        transportFactory: @escaping TmuxScreenModel.TransportFactory,
        onRuntimeStateChange: @escaping (TerminalRuntimeStateUpdate) -> Void,
        initialClientSize: TmuxSessionController.ClientSize?
    ) -> TmuxScreenModel {
        let key = TerminalRuntimeAttemptKey(
            workspaceID: target.workspace.id,
            instanceID: sessionInstanceID
        )
        let model = TmuxScreenModel(
            target: target,
            sessionInstanceID: sessionInstanceID,
            transportFactory: transportFactory,
            onRuntimeStateChange: { update in
                self.recordedUpdates.append(update)
                onRuntimeStateChange(update)
            },
            initialClientSize: initialClientSize ?? .rootModelTestViewport
        )
        createdKeys.append(key)
        createdModels[key] = model
        return model
    }
}

private extension TmuxSessionController.ClientSize {
    static let rootModelTestViewport = Self(cols: 47, rows: 38)
}

private final class RecordingAttachmentTransferServiceFactory: @unchecked Sendable {
    private(set) var targets: [TmuxConnectionTarget] = []

    var factory: @Sendable (TmuxConnectionTarget, TrustedHostStore, RemuxSSHRootService) -> any GhosttyAttachmentTransferService {
        { target, _, _ in
            self.targets.append(target)
            return FailingGhosttyAttachmentTransferService()
        }
    }
}

private struct FailingGhosttyAttachmentTransferService: GhosttyAttachmentTransferService {
    func transfer(
        _ job: GhosttyAttachmentTransferJob,
        progress: @escaping GhosttyAttachmentTransferProgressHandler
    ) async throws -> GhosttyAttachmentTransferResult {
        _ = job
        _ = progress
        throw GhosttyAttachmentTransferError.noSources
    }
}

private enum RecordingRootTransportEvent: Equatable {
    case created(UUID)
    case prepared(UUID)
    case closed(UUID)
}

private final class SuspendingSSHConnectionPrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [TmuxConnectionTarget] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func recordAndSuspend(_ target: TmuxConnectionTarget) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            recordedTargets.append(target)
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func resumeAll() {
        lock.lock()
        let continuations = continuations
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class RecordingSSHConnectionPrewarmer: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets: [TmuxConnectionTarget] = []

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func record(_ target: TmuxConnectionTarget) {
        lock.lock()
        recordedTargets.append(target)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recordedTargets.removeAll()
        lock.unlock()
    }
}

private final class RecordingRootTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [RecordingRootTransportEvent] = []
    private var recordedTargets: [TmuxConnectionTarget] = []

    var events: [RecordingRootTransportEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var createdIDs: [UUID] {
        events.compactMap { event in
            if case .created(let id) = event { return id }
            return nil
        }
    }

    /// Transports prepared at least once. The link re-prepares its
    /// claimed transport (contractually idempotent), so raw prepared
    /// EVENT counts over-count; identity is what the pool tests mean.
    var preparedIDs: Set<UUID> {
        Set(events.compactMap { event in
            if case .prepared(let id) = event { return id }
            return nil
        })
    }

    var targets: [TmuxConnectionTarget] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTargets
    }

    func makeTransport(
        target: TmuxConnectionTarget,
        trustedHostStore: TrustedHostStore
    ) -> any TmuxControlTransport {
        _ = trustedHostStore
        let transport = RecordingRootTmuxControlTransport(factory: self)
        record(target: target)
        record(.created(transport.id))
        return transport
    }

    func record(target: TmuxConnectionTarget) {
        lock.lock()
        recordedTargets.append(target)
        lock.unlock()
    }

    func record(_ event: RecordingRootTransportEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recordedEvents.removeAll()
        recordedTargets.removeAll()
        lock.unlock()
    }
}

private actor RecordingRootTmuxControlTransport: TmuxControlTransport {
    nonisolated let id = UUID()
    nonisolated let receivedBytes: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let factory: RecordingRootTransportFactory

    init(factory: RecordingRootTransportFactory) {
        self.factory = factory

        var capturedContinuation: AsyncThrowingStream<Data, Error>.Continuation?
        receivedBytes = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func prepare() async {
        factory.record(.prepared(id))
    }

    func start(initialViewport: TmuxControlViewport?) async throws {
        _ = initialViewport
    }

    func send(_ data: Data) async throws {
        _ = data
    }

    func close(disposition: TmuxControlTransportCloseDisposition) async {
        _ = disposition
        factory.record(.closed(id))
        continuation.finish()
    }
}

private actor TestConnectionProfileRepository: ConnectionProfileRepository {
    private var servers: [SavedServer]
    private var workspaces: [SavedWorkspace]
    private var identities: [SSHIdentity]
    private var saveServerError: Error?

    init(
        servers: [SavedServer] = [],
        workspaces: [SavedWorkspace] = [],
        identities: [SSHIdentity] = []
    ) {
        self.servers = servers
        self.workspaces = workspaces
        let existingIdentityIDs = Set(identities.map(\.id))
        self.identities = identities + servers.compactMap { server in
            guard !existingIdentityIDs.contains(server.identityID) else { return nil }
            return SSHIdentity(
                id: server.identityID,
                name: server.displayName,
                authenticationKind: .password
            )
        }
    }

    func loadSnapshot() async throws -> ConnectionLibrarySnapshot {
        let serverIDs = Set(servers.map(\.id))
        return ConnectionLibrarySnapshot(
            servers: servers.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            workspaces: workspaces.filter { serverIDs.contains($0.serverID) },
            identities: identities.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    func loadProfile() async throws -> (SavedServer, SavedWorkspace)? {
        try await loadSnapshot().latestProfile
    }

    func saveServer(_ server: SavedServer) async throws {
        if let saveServerError {
            self.saveServerError = nil
            throw saveServerError
        }
        upsert(server, into: &servers)
    }

    func failNextSaveServer(with error: Error) {
        saveServerError = error
    }

    func saveWorkspace(_ workspace: SavedWorkspace) async throws {
        guard servers.contains(where: { $0.id == workspace.serverID }) else {
            throw ConnectionProfileRepositoryError.missingServer(workspace.serverID)
        }

        upsert(workspace, into: &workspaces)
    }

    func saveIdentity(_ identity: SSHIdentity) async throws {
        upsert(identity, into: &identities)
    }

    func saveIdentityProfile(
        identity: SSHIdentity,
        server: SavedServer,
        workspace: SavedWorkspace
    ) async throws {
        upsert(identity, into: &identities)
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func saveProfile(server: SavedServer, workspace: SavedWorkspace) async throws {
        upsert(server, into: &servers)
        upsert(workspace, into: &workspaces)
    }

    func deleteServer(id: SavedServer.ID) async throws {
        servers.removeAll { $0.id == id }
        workspaces.removeAll { $0.serverID == id }
    }

    func deleteWorkspace(id: SavedWorkspace.ID) async throws {
        workspaces.removeAll { $0.id == id }
    }

    func deleteIdentity(id: SSHIdentity.ID) async throws {
        identities.removeAll { $0.id == id }
    }

    private func upsert<Element: Identifiable>(_ element: Element, into elements: inout [Element]) where Element.ID: Equatable {
        if let index = elements.firstIndex(where: { $0.id == element.id }) {
            elements[index] = element
        } else {
            elements.append(element)
        }
    }
}

private actor TestTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings: TerminalSettings

    init(settings: TerminalSettings = .default) {
        self.settings = settings
    }

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        self.settings = settings
    }
}

private actor BlockingFirstSaveTerminalSettingsRepository: TerminalSettingsRepository {
    private var settings: TerminalSettings
    private var saveCount = 0
    private var completedSaveCount = 0
    private var firstSaveStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstSaveReleaseContinuation: CheckedContinuation<Void, Never>?
    private var bothSavesCompletedContinuation: CheckedContinuation<Void, Never>?

    init(settings: TerminalSettings) {
        self.settings = settings
    }

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        saveCount += 1
        if saveCount == 1 {
            firstSaveStartedContinuation?.resume()
            firstSaveStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstSaveReleaseContinuation = continuation
            }
        }

        self.settings = settings
        completedSaveCount += 1
        if completedSaveCount == 2 {
            bothSavesCompletedContinuation?.resume()
            bothSavesCompletedContinuation = nil
        }
    }

    func waitForFirstSaveToStart() async {
        guard saveCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstSaveStartedContinuation = continuation
        }
    }

    func releaseFirstSave() {
        firstSaveReleaseContinuation?.resume()
        firstSaveReleaseContinuation = nil
    }

    func waitForSecondSaveToStart() async -> Bool {
        for _ in 0..<100 where saveCount < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return saveCount == 2
    }

    func waitForBothSavesToComplete() async {
        guard completedSaveCount < 2 else { return }
        await withCheckedContinuation { continuation in
            bothSavesCompletedContinuation = continuation
        }
    }
}

private actor FailingSaveTerminalSettingsRepository: TerminalSettingsRepository {
    enum Failure: Error {
        case saveFailed
    }

    private var settings = TerminalSettings.default

    func loadSettings() async throws -> TerminalSettings {
        settings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        _ = settings
        throw Failure.saveFailed
    }
}

private actor TestServerCredentialStore {
    private let profileRepository: TestConnectionProfileRepository
    private let credentialStore: TestSSHCredentialStore

    init(
        profileRepository: TestConnectionProfileRepository,
        credentialStore: TestSSHCredentialStore
    ) {
        self.profileRepository = profileRepository
        self.credentialStore = credentialStore
    }

    func loadPassword(for serverID: SavedServer.ID) async throws -> String? {
        let snapshot = try await profileRepository.loadSnapshot()
        guard
            let server = snapshot.server(id: serverID),
            let identity = snapshot.identity(id: server.identityID),
            case .password(let password) = try await credentialStore.loadCredential(identityID: identity.id)
        else {
            return nil
        }
        return password
    }

    func savePassword(_ password: String, for serverID: SavedServer.ID) async throws {
        let snapshot = try await profileRepository.loadSnapshot()
        guard
            let server = snapshot.server(id: serverID),
            let identity = snapshot.identity(id: server.identityID)
        else {
            return
        }
        try await credentialStore.saveCredential(
            .password(password),
            identityID: identity.id
        )
    }

    func deletePassword(for serverID: SavedServer.ID) async throws {
        let snapshot = try await profileRepository.loadSnapshot()
        guard
            let server = snapshot.server(id: serverID),
            let identity = snapshot.identity(id: server.identityID)
        else {
            return
        }
        try await credentialStore.deleteCredential(identityID: identity.id)
    }
}

private actor TestSSHCredentialStore: SSHCredentialStore {
    private var credentials: [UUID: SSHCredential] = [:]

    func loadCredential(identityID: UUID) async throws -> SSHCredential? {
        credentials[identityID]
    }

    func saveCredential(_ credential: SSHCredential, identityID: UUID) async throws {
        credentials[identityID] = credential
    }

    func deleteCredential(identityID: UUID) async throws {
        credentials.removeValue(forKey: identityID)
    }
}
