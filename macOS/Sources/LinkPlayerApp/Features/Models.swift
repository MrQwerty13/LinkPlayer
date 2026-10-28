import SwiftUI
import LinkPlayerCore

// MARK: - HistoryModel

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let manager: HistoryManager

    init(manager: HistoryManager) {
        self.manager = manager
        Task { await reload() }
    }

    func reload() async {
        entries = await manager.all()
    }

    func remove(_ id: UUID) async {
        await manager.remove(id: id)
        await reload()
    }

    func clear() async {
        await manager.clear()
        await reload()
    }

    var mostRecentURL: String? { entries.first?.url }
}

// MARK: - SettingsModel

@MainActor
final class SettingsModel: ObservableObject {
    // Mirrors AppSettings; every control below maps to real behavior.
    @Published var historyEnabled: Bool = true
    @Published var allowsInsecureHTTP: Bool = false
    @Published var autoPlayOnOpen: Bool = true
    @Published var launchBehavior: LaunchBehavior = .showEmptyPlayer
    @Published var volume: Double = 0.8

    private let manager: SettingsManager

    init(manager: SettingsManager) {
        self.manager = manager
        Task { await loadFromManager() }
    }

    func loadFromManager() async {
        let s = await manager.settings
        historyEnabled = s.historyEnabled
        allowsInsecureHTTP = s.allowsInsecureHTTP
        autoPlayOnOpen = s.autoPlayOnOpen
        launchBehavior = s.launchBehavior
        volume = Double(s.volume)
    }

    /// Persist any change made through the settings UI.
    func save() {
        let history = historyEnabled
        let http = allowsInsecureHTTP
        let auto = autoPlayOnOpen
        let launch = launchBehavior
        let vol = Float(volume)
        Task {
            await manager.update { s in
                s.historyEnabled = history
                s.allowsInsecureHTTP = http
                s.autoPlayOnOpen = auto
                s.launchBehavior = launch
                s.volume = vol
            }
        }
    }

    func resetToDefaults() {
        Task {
            await manager.resetToDefaults()
            await loadFromManager()
        }
    }
}
