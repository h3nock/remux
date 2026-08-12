import XCTest
@testable import Remux

final class TerminalSettingsRepositoryTests: XCTestCase {
    func testFileBackedRepositoryLoadsDefaultWhenNoFileExists() async throws {
        let repository = FileBackedTerminalSettingsRepository(rootURL: temporaryRoot())

        let settings = try await repository.loadSettings()

        XCTAssertEqual(settings, .default)
    }

    func testFileBackedRepositoryUsesDeviceMultipaneDefaultWhenUnset() async throws {
        let repository = FileBackedTerminalSettingsRepository(
            rootURL: temporaryRoot(),
            defaultZoomMultipaneWindows: true
        )

        let settings = try await repository.loadSettings()

        XCTAssertTrue(settings.zoomMultipaneWindowsByDefault)
    }

    func testFileBackedRepositoryMigratesMissingMultipanePreferenceUsingDeviceDefault() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"[{"fontSize":10,"theme":"ghosttyDefault"}]"#.utf8).write(
            to: root.appendingPathComponent("terminal-settings.json")
        )
        let repository = FileBackedTerminalSettingsRepository(
            rootURL: root,
            defaultZoomMultipaneWindows: true
        )

        let settings = try await repository.loadSettings()

        XCTAssertTrue(settings.zoomMultipaneWindowsByDefault)
    }

    func testFileBackedRepositoryPersistsSettings() async throws {
        let root = temporaryRoot()
        let repository = FileBackedTerminalSettingsRepository(rootURL: root)
        let saved = TerminalSettings(
            fontSize: 16,
            theme: .remuxLight,
            allowInsecureRSAHostKeys: true,
            zoomMultipaneWindowsByDefault: true
        )

        try await repository.saveSettings(saved)

        let reloaded = try await FileBackedTerminalSettingsRepository(rootURL: root).loadSettings()
        XCTAssertEqual(reloaded, saved)
    }

    func testPersistedMultipanePreferenceOverridesTheDeviceDefault() async throws {
        let root = temporaryRoot()
        let repository = FileBackedTerminalSettingsRepository(
            rootURL: root,
            defaultZoomMultipaneWindows: true
        )
        let saved = TerminalSettings(
            fontSize: nil,
            theme: .ghosttyDefault,
            zoomMultipaneWindowsByDefault: false
        )

        try await repository.saveSettings(saved)

        let reloaded = try await FileBackedTerminalSettingsRepository(
            rootURL: root,
            defaultZoomMultipaneWindows: true
        ).loadSettings()
        XCTAssertFalse(reloaded.zoomMultipaneWindowsByDefault)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
