import Foundation

/// One history entry: a media link the user opened successfully.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: String          // sanitized absolute string
    public var openedAt: Date

    public init(id: UUID = UUID(), url: String, openedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.openedAt = openedAt
    }

    public var parsedURL: URL? { URL(string: url) }
}

/// Device-only history of recently opened links.
/// - most-recent-first, deduplicated by canonical URL
/// - hard size cap (oldest evicted)
/// - sensitive query parameters stripped before storing
public actor HistoryManager: Recording {

    public static let defaultLimit = 50
    private let limit: Int
    private let store: JSONFileStore
    private let storeKey = "history"

    /// Query parameters whose values must never be persisted.
    static let sensitiveParameterNames: Set<String> = [
        "token", "access_token", "accesstoken", "authtoken", "auth",
        "api_key", "apikey", "key", "secret", "password", "passwd", "pwd",
        "session", "sessionid", "sid", "sig", "signature", "expires",
        "x-amz-credential", "x-amz-security-token", "x-goog-signature",
        "shared", "usertoken", "bearer"
    ]

    private(set) var entries: [HistoryEntry] = []
    private var loaded = false

    public init(store: JSONFileStore, limit: Int = HistoryManager.defaultLimit) {
        self.store = store
        self.limit = max(1, limit)
    }

    // MARK: Queries

    public func all() -> [HistoryEntry] {
        ensureLoaded()
        return entries
    }

    // MARK: Mutations

    /// `Recording` conformance used by PlaybackCoordinator after successful open.
    public func record(url: URL, title: String?) async {
        add(url: url)
    }

    @discardableResult
    public func add(url: URL) -> HistoryEntry {
        ensureLoaded()
        let sanitized = Self.sanitize(url).absoluteString
        // Deduplicate: move existing entry to the top instead of duplicating.
        entries.removeAll { $0.url == sanitized }
        let entry = HistoryEntry(url: sanitized)
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
        return entry
    }

    public func remove(id: UUID) {
        ensureLoaded()
        entries.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        entries = []
        loaded = true
        do { try store.remove(forKey: storeKey) } catch { /* best effort */ }
    }

    // MARK: Privacy helpers

    /// Removes credentials/tokens from query & fragment before storage.
    public static func sanitize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if let items = components.queryItems {
            let kept = items.filter {
                !sensitiveParameterNames.contains($0.name.lowercased())
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        components.fragment = nil   // fragments often carry player tokens too
        return components.url ?? url
    }

    // MARK: Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        entries = (try? store.read([HistoryEntry].self, forKey: storeKey)) ?? []
    }

    private func persist() {
        try? store.write(entries, forKey: storeKey)
    }
}
