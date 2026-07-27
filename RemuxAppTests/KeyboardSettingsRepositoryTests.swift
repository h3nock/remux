import Foundation
import XCTest
@testable import Remux

final class KeyboardSettingsRepositoryTests: XCTestCase {
    func testFileBackedRepositoryLoadsDefaultWhenNoFileExists() async throws {
        let repository = FileBackedKeyboardSettingsRepository(rootURL: temporaryRoot())

        let settings = try await repository.loadSettings()

        XCTAssertEqual(settings, .default)
    }

    func testFileBackedRepositoryPersistsSettings() async throws {
        let root = temporaryRoot()
        let repository = FileBackedKeyboardSettingsRepository(rootURL: root)
        var saved = try KeyboardSettings.default.validated(updating: .home, to: nil)
        saved.hideButtonBarWhenPhysicalKeyboardConnected = false

        try await repository.saveSettings(saved)

        let reloaded = try await FileBackedKeyboardSettingsRepository(rootURL: root).loadSettings()
        XCTAssertEqual(reloaded, saved)
    }

    func testFileBackedRepositoryRejectsDecodedDuplicateBindings() async throws {
        let root = temporaryRoot()
        let duplicate = KeyboardKeyBinding(input: "x", modifiers: [.command])
        let invalid = KeyboardSettings(
            bindings: [
                .home: duplicate,
                .commandPalette: duplicate,
            ],
            hideButtonBarWhenPhysicalKeyboardConnected: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([invalid]).write(
            to: root.appendingPathComponent("keyboard-settings.json"),
            options: .atomic
        )
        let repository = FileBackedKeyboardSettingsRepository(rootURL: root)

        await XCTAssertThrowsErrorAsync(try await repository.loadSettings()) { error in
            guard case KeyboardSettings.ValidationError.duplicateBinding = error else {
                return XCTFail("Expected duplicate binding, got \(error)")
            }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
