import XCTest
import AppKit
@testable import ClaudeUsageCore

// Menu representedObject / state consistency for the renamed ColorMode. The real
// builder (`AppDelegate.buildColorMenu`) and handler (`selectColor`) are private,
// so this mirrors their exact enum-driven construction and asserts the
// invariants they rely on: every representedObject round-trips through
// `ColorMode(rawValue:)`, exactly one item is checked, and the checked item
// tracks `Settings.colorMode` (including the "claude" -> Brand migration).
final class ColorModeMenuTests: XCTestCase {

    private let key = "colorMode"
    private var saved: Any?

    override func setUp() { super.setUp(); saved = UserDefaults.standard.object(forKey: key) }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    /// Mirror of `AppDelegate.buildColorMenu`'s per-item construction.
    private func buildColorItems() -> [NSMenuItem] {
        ColorMode.allCases.map { c in
            let it = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
            it.representedObject = c.rawValue
            it.state = (c == Settings.colorMode) ? .on : .off
            return it
        }
    }

    /// Mirror of `selectColor`'s state fan-out for a chosen representedObject.
    private func applySelection(_ items: [NSMenuItem], raw: String) {
        items.forEach { $0.state = (($0.representedObject as? String) == raw) ? .on : .off }
    }

    func testRepresentedObjectsRoundTripAndTitlesAreConsistent() {
        for it in buildColorItems() {
            let raw = it.representedObject as? String
            XCTAssertNotNil(raw, "representedObject must be the rawValue string")
            let decoded = ColorMode(rawValue: raw!)
            XCTAssertNotNil(decoded, "selectColor must be able to decode \(raw!)")
            XCTAssertEqual(decoded!.title, it.title, "title must match the decoded case")
        }
        // The Brand item specifically carries "brand" / "Brand".
        let brand = buildColorItems().first { ($0.representedObject as? String) == "brand" }
        XCTAssertNotNil(brand)
        XCTAssertEqual(brand?.title, "Brand")
    }

    func testExactlyOneItemCheckedAndItTracksSettings() {
        for stored in ["brand", "thresholds", "monochrome", "heatmap", "accent"] {
            UserDefaults.standard.set(stored, forKey: key)
            let items = buildColorItems()
            let on = items.filter { $0.state == .on }
            XCTAssertEqual(on.count, 1, "exactly one item checked for stored \(stored)")
            XCTAssertEqual(on.first?.representedObject as? String, Settings.colorMode.rawValue)
        }
    }

    func testStoredClaudeChecksTheBrandItem() {
        // The migration is visible through the menu: a legacy "claude" value
        // leaves the Brand item (and only it) checked.
        UserDefaults.standard.set("claude", forKey: key)
        let on = buildColorItems().filter { $0.state == .on }
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on.first?.representedObject as? String, "brand")
        XCTAssertEqual(on.first?.title, "Brand")
    }

    func testSelectingAnItemChecksOnlyThatItem() {
        UserDefaults.standard.set("brand", forKey: key)
        let items = buildColorItems()
        for target in items {
            let raw = target.representedObject as! String
            applySelection(items, raw: raw)
            let on = items.filter { $0.state == .on }
            XCTAssertEqual(on.count, 1)
            XCTAssertEqual(on.first?.representedObject as? String, raw)
            // And the raw still decodes to a real case (what selectColor stores).
            XCTAssertNotNil(ColorMode(rawValue: raw))
        }
    }
}
