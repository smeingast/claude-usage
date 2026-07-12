import XCTest
@testable import ClaudeUsageCore

// The new two-provider Settings keys added in package 4a. Nothing in production
// reads them until 4b, so these only assert the storage contract: correct
// defaults when unset, and a faithful round-trip through UserDefaults.
final class SettingsStorageTests: XCTestCase {

    private let keys = ["primaryProvider", "barShows", "showCodex", "graphs"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
    }
    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testDefaultsWhenUnset() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        XCTAssertEqual(Settings.primaryProvider, .claude)
        XCTAssertEqual(Settings.barShows, .primary)
        XCTAssertEqual(Settings.showCodex, .auto)
    }

    func testUnknownValuesFallBackToDefaults() {
        UserDefaults.standard.set("nonsense", forKey: "primaryProvider")
        UserDefaults.standard.set("nonsense", forKey: "barShows")
        UserDefaults.standard.set("nonsense", forKey: "showCodex")
        XCTAssertEqual(Settings.primaryProvider, .claude)
        XCTAssertEqual(Settings.barShows, .primary)
        XCTAssertEqual(Settings.showCodex, .auto)
    }

    func testPrimaryProviderRoundTrip() {
        for p in UsageProviderKind.allCases {
            Settings.primaryProvider = p
            XCTAssertEqual(Settings.primaryProvider, p)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "primaryProvider"), p.rawValue)
        }
    }

    func testBarShowsRoundTrip() {
        for b in BarShows.allCases {
            Settings.barShows = b
            XCTAssertEqual(Settings.barShows, b)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "barShows"), b.rawValue)
        }
    }

    func testShowCodexRoundTrip() {
        for s in ShowCodex.allCases {
            Settings.showCodex = s
            XCTAssertEqual(Settings.showCodex, s)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "showCodex"), s.rawValue)
        }
    }

    // The Graphs setting (amendment 26): default Both when unset or unknown, and a
    // faithful round-trip.
    func testGraphsDefaultAndRoundTrip() {
        UserDefaults.standard.removeObject(forKey: "graphs")
        XCTAssertEqual(Settings.graphs, .both)
        UserDefaults.standard.set("nonsense", forKey: "graphs")
        XCTAssertEqual(Settings.graphs, .both)
        for g in GraphsShown.allCases {
            Settings.graphs = g
            XCTAssertEqual(Settings.graphs, g)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "graphs"), g.rawValue)
        }
    }

    func testBarShowsAndShowCodexTitles() {
        XCTAssertEqual(BarShows.allCases.map(\.title), ["Primary", "Both", "Claude", "Codex"])
        XCTAssertEqual(ShowCodex.allCases.map(\.title), ["Auto", "On", "Off"])
        XCTAssertEqual(GraphsShown.allCases.map(\.title), ["Both", "Claude", "Codex"])
    }
}
