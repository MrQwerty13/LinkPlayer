import Foundation

/// Read-only view of user preferences, consumed by core services.
public protocol SettingsProviding: Sendable {
    var historyEnabled: Bool { get async }
    var allowsInsecureHTTP: Bool { get async }
    var autoPlayOnOpen: Bool { get async }
    var launchBehavior: LaunchBehavior { get async }
    var volume: Float { get async }
}

public enum LaunchBehavior: String, Codable, CaseIterable, Sendable {
    /// Show the empty state with the URL field focused (default).
    case showEmptyPlayer
    /// Reopen the last played resource automatically.
    case reopenLastItem
    /// Open with the history panel visible.
    case showHistory

    public var displayName: String {
        switch self {
        case .showEmptyPlayer: return "Start with an empty player"
        case .reopenLastItem:  return "Reopen the last video"
        case .showHistory:     return "Show history"
        }
    }
}

/// Mutable settings model persisted through JSONFileStore.
/// Every value here has a real effect on app behavior — no decorative switches.
public struct AppSettings: Codable, Equatable, Sendable {
    public var historyEnabled: Bool = true
    public var allowsInsecureHTTP: Bool = false
    public var autoPlayOnOpen: Bool = true
    public var launchBehavior: LaunchBehavior = .showEmptyPlayer
    /// 0…1 system-style volume.
    public var volume: Float = 0.8

    public init() {}

    public static let `default` = AppSettings()
}

/// Actor that owns settings state + persistence and vends snapshots to consumers.
public actor SettingsManager: SettingsProviding {

    private let store: JSONFileStore
    private let storeKey = "settings"
    private(set) public var settings: AppSettings

    public init(store: JSONFileStore) {
        self.store = store
        self.settings = (try? store.read(AppSettings.self, forKey: storeKey)) ?? .default
    }

    public func update(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
        clamp()
        try? store.write(settings, forKey: storeKey)
    }

    public func resetToDefaults() {
        settings = .default
        try? store.write(settings, forKey: storeKey)
    }

    private func clamp() {
        settings.volume = min(max(settings.volume, 0), 1)
    }

    // MARK: SettingsProviding

    public var historyEnabled: Bool { settings.historyEnabled }
    public var allowsInsecureHTTP: Bool { settings.allowsInsecureHTTP }
    public var autoPlayOnOpen: Bool { settings.autoPlayOnOpen }
    public var launchBehavior: LaunchBehavior { settings.launchBehavior }
    public var volume: Float { settings.volume }
}
