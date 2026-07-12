import XCTest
@testable import ClaudeUsageCore

/// The Codex/Claude history persistence: a `HistoryStore(filename:)` round-trip and the
/// `AppDelegate.mergeHistorySamples` whole-second dedup that the in-memory merge relies
/// on. `HistoryStore` writes under the shared Application Support directory (no directory
/// injection), so each store test uses a unique filename and removes just that file in a
/// `defer`, never the (possibly real) app directory around it.
final class HistoryStoreTests: XCTestCase {

    /// The on-disk URL a `HistoryStore(filename:)` would use, recomputed the same way the
    /// store does so the test can delete exactly the file it created.
    private func storeURL(_ filename: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("eu.smeingast.claude-menubar-usage", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func testSameSecondAppendsLoadBothAndMergeDedupsToOne() throws {
        let filename = "history-test-\(UUID().uuidString).jsonl"
        let url = storeURL(filename)
        defer { if let url { try? FileManager.default.removeItem(at: url) } }

        let store = HistoryStore(filename: filename)
        // Two samples in the SAME whole second: append rounds `t` to whole seconds on
        // disk, so both land on the identical timestamp key.
        let base = Date().timeIntervalSince1970.rounded(.down)
        let a = HistorySample(t: Date(timeIntervalSince1970: base + 0.1),
                              five: 10, week: 5, fiveResetsAt: nil, weekResetsAt: nil)
        let b = HistorySample(t: Date(timeIntervalSince1970: base + 0.3),
                              five: 20, week: 6, fiveResetsAt: nil, weekResetsAt: nil)
        store.append(a)
        store.append(b)

        // append() is async on the store's serial queue; load() is a sync barrier on the
        // SAME queue, so it observes both appends. The store never dedups: two lines land,
        // both come back.
        let loaded = store.load(maxAge: 100 * 365 * 24 * 3600)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map { Int($0.t.timeIntervalSince1970.rounded()) }).count, 1)

        // The in-memory merge is what collapses the same-second pair to one sample.
        let merged = AppDelegate.mergeHistorySamples([], loaded)
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeSamplesDedupsSameSecondSecondArgumentWins() {
        // Two hand-built samples that round to the SAME whole second but carry different
        // values. mergeHistorySamples keys on the rounded second, and the later element
        // (here `b`, folded in after `a`) wins the key, matching the documented policy.
        let base = 1_783_800_000.0
        let a = HistorySample(t: Date(timeIntervalSince1970: base + 0.1),
                              five: 10, week: 5, fiveResetsAt: nil, weekResetsAt: nil)
        let b = HistorySample(t: Date(timeIntervalSince1970: base + 0.3),
                              five: 20, week: 6, fiveResetsAt: nil, weekResetsAt: nil)
        let merged = AppDelegate.mergeHistorySamples([a], [b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.five, 20)   // b wins the same-second key
        XCTAssertEqual(merged.first?.week, 6)
    }
}
