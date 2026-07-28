import Foundation

protocol KeyboardSettingsRepository: Sendable {
    func loadSettings() async throws -> KeyboardSettings
    func saveSettings(_ settings: KeyboardSettings) async throws
}

actor FileBackedKeyboardSettingsRepository: KeyboardSettingsRepository {
    private let store: JSONFileStore<KeyboardSettings>

    init(rootURL: URL) {
        self.store = JSONFileStore(fileURL: rootURL.appendingPathComponent("keyboard-settings.json"))
    }

    func loadSettings() async throws -> KeyboardSettings {
        let settings = try await store.load(defaultValue: [.default]).first ?? .default
        return try settings.validated()
    }

    func saveSettings(_ settings: KeyboardSettings) async throws {
        let validatedSettings = try settings.validated()
        try await store.save([validatedSettings])
    }
}
