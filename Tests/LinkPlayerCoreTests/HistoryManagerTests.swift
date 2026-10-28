import XCTest
@testable import LinkPlayerCore

final class HistoryManagerTests: XCTestCase {

    private func makeStore() throws -> (JSONFileStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkPlayerTests-\(UUID().uuidString)")
        return (JSONFileStore(directory: dir), dir)
    }

    func testAddStoresMostRecentFirst() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)

        await history.add(url: URL(string: "https://e.com/first.mp4")!)
        await history.add(url: URL(string: "https://e.com/second.mp4")!)
        let entries = await history.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].url.hasSuffix("second.mp4"))
    }

    func testDeduplicatesSameURLMovingToTop() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)

        await history.add(url: URL(string: "https://e.com/a.mp4")!)
        await history.add(url: URL(string: "https://e.com/b.mp4")!)
        await history.add(url: URL(string: "https://e.com/a.mp4")!)
        let entries = await history.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].url.hasSuffix("a.mp4"))
    }

    func testSizeLimitEvictsOldest() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store, limit: 3)

        for i in 1...5 {
            await history.add(url: URL(string: "https://e.com/v\(i).mp4")!)
        }
        let entries = await history.all()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.url), [
            "https://e.com/v5.mp4", "https://e.com/v4.mp4", "https://e.com/v3.mp4"
        ])
    }

    func testRemoveSingleEntry() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)
        let e1 = await history.add(url: URL(string: "https://e.com/a.mp4")!)
        _ = await history.add(url: URL(string: "https://e.com/b.mp4")!)

        await history.remove(id: e1.id)
        let entries = await history.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].url.hasSuffix("b.mp4"))
    }

    func testClearEmptiesHistoryAndStorage() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)
        _ = await history.add(url: URL(string: "https://e.com/a.mp4")!)
        _ = await history.add(url: URL(string: "https://e.com/b.mp4")!)

        await history.clear()
        let entries = await history.all()
        XCTAssertTrue(entries.isEmpty)

        // A fresh manager reading the same store must see nothing.
        let reopened = HistoryManager(store: store)
        let reloaded = await reopened.all()
        XCTAssertTrue(reloaded.isEmpty)
    }

    func testPersistenceSurvivesRestart() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)
        _ = await history.add(url: URL(string: "https://e.com/persisted.mp4")!)

        let reopened = HistoryManager(store: store)
        let entries = await reopened.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url, "https://e.com/persisted.mp4")
    }

    // MARK: Privacy sanitization

    func testSensitiveQueryParametersAreStripped() {
        let url = URL(string: "https://cdn.example.com/video.mp4?title=hi&token=SECRET123&api_key=abc123&sig=xyz")!
        let clean = HistoryManager.sanitize(url)
        let q = clean.query ?? ""
        XCTAssertFalse(q.contains("SECRET123"))
        XCTAssertFalse(q.contains("abc123"))
        XCTAssertFalse(q.contains("xyz"))
        XCTAssertTrue(q.contains("title=hi"), "non-sensitive params preserved")
    }

    func testFragmentIsDropped() {
        let url = URL(string: "https://e.com/v.mp4#t=10&auth=zzz")!
        let clean = HistoryManager.sanitize(url)
        XCTAssertNil(clean.fragment)
    }

    func testRecordSanitizesBeforeStoring() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryManager(store: store)
        await history.record(url: URL(string: "https://e.com/v.mp4?access_token=TOPSECRET&q=keep")!,
                             title: nil)
        let entries = await history.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].url.contains("TOPSECRET"))
        XCTAssertTrue(entries[0].url.contains("q=keep"))
    }

    func testAllParamsSensitiveLeavesNoQueryString() {
        let url = URL(string: "https://e.com/v.mp4?password=hunter2")!
        let clean = HistoryManager.sanitize(url)
        XCTAssertNil(clean.query)
        XCTAssertEqual(clean.absoluteString, "https://e.com/v.mp4")
    }
}
