import XCTest
import AppKit
@testable import ClaudeUsageCore

// The color-resolution contract for package 4a: the ColorMode "claude" -> "brand"
// rename with its stored-value migration, and the dormant `provider` / `role`
// additions on `StatusRenderer.color(_:_:provider:role:)`. The table asserts that
// the defaults reproduce today's behavior and that provider/role only bite where
// the amendments say they should (Brand hue, System secondary dimming).
final class ColorResolutionTests: XCTestCase {

    // MARK: - ColorMode getter migration + setter raw string [B10]

    private let key = "colorMode"
    private var savedColorMode: Any?

    override func setUp() {
        super.setUp()
        savedColorMode = UserDefaults.standard.object(forKey: key)
    }
    override func tearDown() {
        // Restore whatever the machine had, so the test is hermetic against the
        // shared standard defaults the app actually uses.
        if let savedColorMode { UserDefaults.standard.set(savedColorMode, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testGetterMigratesStoredClaudeToBrand() {
        UserDefaults.standard.set("claude", forKey: key)   // the pre-4a rawValue
        XCTAssertEqual(Settings.colorMode, .brand)
    }

    func testGetterMissingValueDefaultsToBrand() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Settings.colorMode, .brand)
    }

    func testGetterUnknownValueDefaultsToBrand() {
        UserDefaults.standard.set("retired-mode", forKey: key)
        XCTAssertEqual(Settings.colorMode, .brand)
    }

    func testKnownRawValuesRoundTripThroughGetter() {
        for m in ColorMode.allCases {
            UserDefaults.standard.set(m.rawValue, forKey: key)
            XCTAssertEqual(Settings.colorMode, m, "\(m.rawValue) should round-trip")
        }
    }

    func testSetterWritesBrandRawString() {
        Settings.colorMode = .brand
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "brand")
    }

    func testBrandRawValueAndTitle() {
        XCTAssertEqual(ColorMode.brand.rawValue, "brand")
        XCTAssertEqual(ColorMode.brand.title, "Brand")
    }

    // MARK: - color(_:_:provider:role:) table

    /// Resolve a (possibly dynamic) color to sRGB RGBA under a pinned appearance.
    private func rgba(_ c: NSColor, dark: Bool) -> [CGFloat] {
        var out: [CGFloat] = [0, 0, 0, 0]
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let s = c.usingColorSpace(.sRGB) ?? c
            out = [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
        }
        return out
    }

    func testBrandBelowCapIsProviderAccent() {
        // Identity: color() returns the very same static accent instance.
        XCTAssertTrue(StatusRenderer.color(50, .brand, provider: .claude) === StatusRenderer.claudeCoral)
        XCTAssertTrue(StatusRenderer.color(89.9, .brand, provider: .claude) === StatusRenderer.claudeCoral)
        XCTAssertTrue(StatusRenderer.color(50, .brand, provider: .codex) === StatusRenderer.codexTeal)
    }

    func testBrandDefaultProviderIsClaude() {
        // The default (no provider) keeps the pre-4a coral, never teal.
        XCTAssertTrue(StatusRenderer.color(50, .brand) === StatusRenderer.claudeCoral)
    }

    func testBrandRedOverrideAtNinetyPerProvider() {
        XCTAssertEqual(StatusRenderer.color(90, .brand, provider: .claude), .systemRed)
        XCTAssertEqual(StatusRenderer.color(95, .brand, provider: .codex), .systemRed)
        XCTAssertEqual(StatusRenderer.color(100, .brand), .systemRed)
    }

    func testMonochromeIsLabelIgnoringProviderAndRole() {
        XCTAssertEqual(StatusRenderer.color(50, .monochrome), .labelColor)
        XCTAssertEqual(StatusRenderer.color(95, .monochrome, provider: .codex, role: .secondary), .labelColor)
    }

    func testThresholdsBandsIgnoreProvider() {
        XCTAssertEqual(StatusRenderer.color(69, .thresholds, provider: .codex), .labelColor)
        XCTAssertEqual(StatusRenderer.color(70, .thresholds, provider: .codex), .systemOrange)
        XCTAssertEqual(StatusRenderer.color(89, .thresholds), .systemOrange)
        XCTAssertEqual(StatusRenderer.color(90, .thresholds), .systemRed)
    }

    func testHeatmapHueRampIgnoresProvider() {
        // 0% sits at the green end of the ramp (hue 0.34); 100% at the red end.
        // (Hue 0.0 wraps to 1.0 on the wheel, so assert redness via RGBA rather
        // than the hue value at the endpoint.)
        XCTAssertEqual(StatusRenderer.color(0, .heatmap).hueComponent, 0.34, accuracy: 0.001)
        let hot = rgba(StatusRenderer.color(100, .heatmap), dark: false)
        XCTAssertGreaterThan(hot[0], 0.8)                 // strong red
        XCTAssertLessThan(hot[1], 0.2)                    // little green
        XCTAssertLessThan(hot[2], 0.2)                    // little blue
        let cold = rgba(StatusRenderer.color(0, .heatmap), dark: false)
        XCTAssertGreaterThan(cold[1], hot[1])             // greener at 0% than at 100%
        // Provider must not affect the heat color (hue encodes intensity here).
        XCTAssertEqual(rgba(StatusRenderer.color(55, .heatmap, provider: .claude), dark: false),
                       rgba(StatusRenderer.color(55, .heatmap, provider: .codex), dark: false))
    }

    func testAccentPrimaryIsFullSystemAccent() {
        XCTAssertEqual(StatusRenderer.color(50, .accent), .controlAccentColor)
        XCTAssertEqual(StatusRenderer.color(50, .accent, role: .primary), .controlAccentColor)
    }

    func testAccentSecondaryRoleDimsByAlphaNotProvider() {
        // Amendment 14: the secondary ROLE dims via alpha; the provider is
        // irrelevant to the dimming.
        let dimClaude = StatusRenderer.color(50, .accent, provider: .claude, role: .secondary)
        let dimCodex  = StatusRenderer.color(50, .accent, provider: .codex, role: .secondary)
        XCTAssertEqual(rgba(dimClaude, dark: false)[3], StatusRenderer.secondaryRoleDim, accuracy: 0.01)
        XCTAssertEqual(rgba(dimClaude, dark: false), rgba(dimCodex, dark: false),
                       "System-mode dimming must not depend on the provider")
        // And it is genuinely dimmer than the primary accent.
        XCTAssertLessThan(rgba(dimClaude, dark: false)[3], rgba(NSColor.controlAccentColor, dark: false)[3])
    }
}
