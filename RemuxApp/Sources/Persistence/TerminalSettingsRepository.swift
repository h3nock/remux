import Foundation

protocol TerminalSettingsRepository: Sendable {
    func loadSettings() async throws -> TerminalSettings
    func saveSettings(_ settings: TerminalSettings) async throws
}

actor FileBackedTerminalSettingsRepository: TerminalSettingsRepository {
    private let store: JSONFileStore<TerminalSettings>
    private let defaultSettings: TerminalSettings

    init(
        rootURL: URL,
        defaultZoomMultipaneWindows: Bool = false
    ) {
        var defaultSettings = TerminalSettings.default
        defaultSettings.zoomMultipaneWindowsByDefault = defaultZoomMultipaneWindows
        self.defaultSettings = defaultSettings
        let decoder = JSONDecoder()
        decoder.userInfo[.terminalSettingsDefaultMultipaneZoom] = defaultZoomMultipaneWindows
        self.store = JSONFileStore(
            fileURL: rootURL.appendingPathComponent("terminal-settings.json"),
            decoder: decoder
        )
    }

    func loadSettings() async throws -> TerminalSettings {
        try await store.load(defaultValue: [defaultSettings]).first ?? defaultSettings
    }

    func saveSettings(_ settings: TerminalSettings) async throws {
        try await store.save([settings])
    }
}
