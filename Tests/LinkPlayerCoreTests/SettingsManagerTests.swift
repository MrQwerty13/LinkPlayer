import XCTest
@testable import LinkPlayerCore

final class SettingsManagerTests: XCTestCase {

    private func makeStore() throws -> (JSONFileStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkPlayerSettingsTests-\(UUID().uuidString)")
        return (JSONFileStore(directory: dir), dir)
    }

    func testDefaultsWhenNoStoredFile() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SettingsManager(store: store)
        let settings = await manager.settings
        XCTAssertEqual(settings, .default)
        XCTAssertTrue(settings.historyEnabled)
        XCTAssertFalse(settings.allowsInsecureHTTP)
        XCTAssertEqual(settings.launchBehavior, .showEmptyPlayer)
    }

    func testUpdatePersistsAndReloads() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SettingsManager(store: store)

        await manager.update { s in
            s.historyEnabled = false
            s.allowsInsecureHTTP = true
            s.launchBehavior = .reopenLastItem
            s.volume = 0.35
        }

        // Fresh instance reading the same file must see the changes.
        let reloaded = SettingsManager(store: store)
        let settings = await reloaded.settings
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertTrue(settings.allowsInsecureHTTP)
        XCTAssertEqual(settings.launchBehavior, .reopenLastItem)
        XCTAssertEqual(settings.volume, 0.35, accuracy: 0.001)
    }

    func testVolumeIsClamped() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SettingsManager(store: store)

        await manager.update { $0.volume = 5 }
        var v = await manager.volume
        XCTAssertEqual(v, 1.0, accuracy: 0.001)

        await manager.update { $0.volume = -3 }
        v = await manager.volume
        XCTAssertEqual(v, 0.0, accuracy: 0.001)
    }

    func testResetToDefaults() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SettingsManager(store: store)
        await manager.update { $0.historyEnabled = false }
        await manager.resetToDefaults()
        let settings = await manager.settings
        XCTAssertEqual(settings, .default)
    }

    func testConformsToSettingsProviding() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider: SettingsProviding = SettingsManager(store: store)
        let enabled = await provider.historyEnabled
        XCTAssertTrue(enabled)
        let behavior = await provider.launchBehavior
        XCTAssertEqual(behavior, .showEmptyPlayer)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json ]".utf8).write(to: dir.appendingPathComponent("settings.json"))

        let manager = SettingsManager(store: store)
        // Should not crash; falls back to defaults.
        let settings = await manager.settings
        XCTAssertEqual(settings, .default)
    }
}

final class JSONFileStoreTests: XCTestCase {

    func testRoundTripCodableArray() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore(directory: dir)

        struct Item: Codable, Equatable { let name: String; let date: Date }
        let items = [Item(name: "a", date: Date(timeIntervalSince1970: 1_700_000_000)),
                     Item(name: "b", date: Date(timeIntervalSince1970: 1_700_000_001))]
        try store.write(items, forKey: "items")
        let read = try store.read([Item].self, forKey: "items")
        XCTAssertEqual(read, items)
    }

    func testReadMissingKeyReturnsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreTest-\(UUID().uuidString)")
        let store = JSONFileStore(directory: dir)
        let value = try store.read([String].self, forKey: "nope")
        XCTAssertNil(value)
    }

    func testRemoveDeletesFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreTest-\(UUID().uuidString)")
        let store = JSONFileStore(directory: dir)
        try store.write(["x"], forKey: "list")
        try store.remove(forKey: "list")
        let value = try store.read([String].self, forKey: "list")
        XCTAssertNil(value)
    }
}
