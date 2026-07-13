import XCTest
@testable import ClaudeUsageCore

// Codex window SHAPE. Codex windows are slotted by `window_minutes`, never by their
// position in the rollout event: on 2026-07-12 OpenAI moved the weekly window into
// `rate_limits.primary` and dropped `secondary` entirely for plus accounts. Both
// shapes -- and a return to the old one -- must be correct with no code change, and a
// window length neither side of this app has seen must still be labeled honestly.
final class CodexWindowShapeTests: XCTestCase {

    private let now = utcDate(2026, 7, 13, 13, 0, 0)
    private let observed = utcDate(2026, 7, 13, 12, 0, 0)
    private let fetched = utcDate(2026, 7, 13, 12, 0, 5)
    private var weekReset: Date { utcDate(2026, 7, 19, 13, 0, 0) }    // 6 days out
    private var fiveReset: Date { utcDate(2026, 7, 13, 15, 0, 0) }
    private func hm() -> DateFormatter { hmUTCFormatter() }

    // MARK: - Builders

    private func win(_ used: Double, minutes: Int?, resets: Date?) -> [String: Any] {
        var d: [String: Any] = ["used_percent": used]
        if let minutes { d["window_minutes"] = minutes }
        if let resets { d["resets_at"] = resets.timeIntervalSince1970 }
        return d
    }

    private func event(primary: [String: Any]?, secondary: [String: Any]? = nil) -> [String: Any] {
        var rl: [String: Any] = ["plan_type": "plus"]
        if let primary { rl["primary"] = primary }
        if let secondary { rl["secondary"] = secondary }
        return ["type": "event_msg", "timestamp": "2026-07-13T12:00:00.000Z",
                "payload": ["type": "token_count", "rate_limits": rl]]
    }

    private func snap(_ obj: [String: Any]) -> ProviderUsageSnapshot? {
        CodexUsageClient.snapshot(fromEvent: obj, fetchedAt: fetched)
    }

    // MARK: - Slotting by length

    /// The live shape as of 2026-07-13: a single WEEKLY window, arriving in the slot
    /// that used to carry the 5-hour one. It must land in the weekly slot and leave
    /// the near-term slot empty -- the bug this whole change exists to fix was showing
    /// this number under a "5-hour" label.
    func testWeeklyOnlyPrimaryLandsInTheWeeklySlot() {
        let s = snap(event(primary: win(23, minutes: 10080, resets: weekReset)))
        XCTAssertNil(s?.primary)
        XCTAssertEqual(s?.secondary?.utilization, 23)
        XCTAssertEqual(s?.secondary?.windowMinutes, 10080)
        XCTAssertEqual(s?.secondary?.title, "Weekly")
        XCTAssertEqual(s?.secondary?.id, "secondary")
        XCTAssertEqual(s?.secondary?.resetsAt, weekReset)
    }

    /// The pre-2026-07-12 shape still maps exactly as it did.
    func testOldTwoWindowShapeIsUnchanged() {
        let s = snap(event(primary: win(42, minutes: 300, resets: fiveReset),
                           secondary: win(17, minutes: 10080, resets: weekReset)))
        XCTAssertEqual(s?.primary?.utilization, 42)
        XCTAssertEqual(s?.primary?.title, "5-hour")
        XCTAssertEqual(s?.primary?.windowMinutes, 300)
        XCTAssertEqual(s?.secondary?.utilization, 17)
        XCTAssertEqual(s?.secondary?.title, "Weekly")
    }

    /// Position is not a contract: the same two windows listed the other way round
    /// still slot by length.
    func testWindowsSlotByLengthNotByPosition() {
        let s = snap(event(primary: win(17, minutes: 10080, resets: weekReset),
                           secondary: win(42, minutes: 300, resets: fiveReset)))
        XCTAssertEqual(s?.primary?.utilization, 42)
        XCTAssertEqual(s?.primary?.windowMinutes, 300)
        XCTAssertEqual(s?.secondary?.utilization, 17)
        XCTAssertEqual(s?.secondary?.windowMinutes, 10080)
    }

    /// A length this app has never seen is shown under its OWN data-driven title
    /// rather than forced into the "5-hour" label.
    func testUnfamiliarWindowKeepsItsOwnTitle() {
        let s = snap(event(primary: win(40, minutes: 1440, resets: weekReset)))
        XCTAssertEqual(s?.primary?.utilization, 40)
        XCTAssertEqual(s?.primary?.title, "1-day")
        XCTAssertNil(s?.secondary)
    }

    func testUnfamiliarWindowAlongsideWeekly() {
        let s = snap(event(primary: win(40, minutes: 1440, resets: fiveReset),
                           secondary: win(17, minutes: 10080, resets: weekReset)))
        XCTAssertEqual(s?.primary?.windowMinutes, 1440)
        XCTAssertEqual(s?.secondary?.windowMinutes, 10080)
    }

    func testWindowUnitLabels() {
        XCTAssertEqual(CodexUsageClient.windowUnit(minutes: 300), "5h")
        XCTAssertEqual(CodexUsageClient.windowUnit(minutes: 10080), "wk")
        XCTAssertEqual(CodexUsageClient.windowUnit(minutes: 1440), "1d")
        XCTAssertEqual(CodexUsageClient.windowUnit(minutes: 180), "3h")
        XCTAssertEqual(CodexUsageClient.windowUnit(minutes: nil), "win")
    }

    /// The backfill path feeds the history samples, so it must slot identically -- or
    /// the graph would draw a weekly series as a 5-hour one.
    func testBackfillEventSlotsLikeTheSnapshot() throws {
        let line = #"{"timestamp":"2026-07-13T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":23.0,"window_minutes":10080,"resets_at":\#(Int(weekReset.timeIntervalSince1970))},"secondary":null,"plan_type":"plus"}}}"#
        let ev = try XCTUnwrap(CodexUsageClient.event(from: Data(line.utf8)))
        XCTAssertNil(ev.primaryPercent)
        XCTAssertNil(ev.primaryResetsAt)
        XCTAssertEqual(ev.secondaryPercent, 23)
        XCTAssertEqual(ev.secondaryResetsAt, weekReset)
    }

    // MARK: - Derivation with no near-term window

    /// Observed AT `now` by default: an older reading is "aged", and the idle copy
    /// legitimately wins over the severity copy there (existing behavior).
    private func weeklyOnly(_ used: Double, reset: Date? = nil,
                            observedAt: Date? = nil) -> CodexUsageResult {
        let obs = observedAt ?? now
        let s = ProviderUsageSnapshot(
            provider: .codex, primary: nil,
            secondary: UsageWindow(id: "secondary", title: "Weekly", utilization: used,
                                   windowMinutes: 10080, resetsAt: reset ?? weekReset),
            extras: [], freshness: .observed(obs), fetchedAt: obs, planType: "plus")
        return CodexUsageResult(status: .ok, snapshot: s)
    }

    func testWeeklyOnlyExposesNoFiveHourWindow() {
        let d = ProviderState.deriveCodex(result: weeklyOnly(23), forecast: nil,
                                          now: now, hm: hm())
        XCTAssertFalse(d.hasFive)
        XCTAssertNil(d.five)
        XCTAssertEqual(d.week, 23)
        XCTAssertEqual(d.weekTitle, "Weekly")
        XCTAssertEqual(d.headResetsAt, weekReset)
        XCTAssertEqual(d.headWindowMinutes, 10080)
        XCTAssertEqual(d.kind, .normal)
        XCTAssertEqual(d.msg, "")
    }

    /// The forecast is 5-hour-shaped, so a weekly-only account never gets one, no
    /// matter how hot the computed burn rate is.
    func testForecastStaysOffWithoutAFiveHourWindow() {
        let hot = Forecast(ratePerHour: 30, projected: 100, crosses: true, crossTime: now)
        let d = ProviderState.deriveCodex(result: weeklyOnly(23, observedAt: now),
                                          forecast: hot, now: now, hm: hm())
        XCTAssertFalse(d.forecastActive)
        XCTAssertNil(d.projFive)
        XCTAssertNil(d.crossTime)
        XCTAssertNotEqual(d.kind, .pace)
    }

    /// With no near-term window the weekly one IS the headline, so it has to drive the
    /// severity: a 95% weekly reading that showed a calm teal dot would make the
    /// instrument useless for the shape Codex actually ships today.
    func testWeeklyDrivesSeverityWhenItIsTheOnlyWindow() {
        let d = ProviderState.deriveCodex(result: weeklyOnly(95), forecast: nil,
                                          now: now, hm: hm())
        XCTAssertEqual(d.kind, .red)
        XCTAssertTrue(d.isRed)
        XCTAssertTrue(d.weekIsRed)
        XCTAssertFalse(d.fiveIsRed)          // there is no 5-hour figure to redden
        XCTAssertEqual(d.pip, .red)
        XCTAssertEqual(d.msg, "Red zone \u{00B7} 5% headroom \u{00B7} resets in 6 days.")
    }

    /// The watch copy's settle clause is a forecast claim; without a forecast it would
    /// just restate the current value as a projection, so it names the reset instead.
    func testWeeklyOnlyWatchCopyMakesNoForecastClaim() {
        let d = ProviderState.deriveCodex(result: weeklyOnly(75), forecast: nil,
                                          now: now, hm: hm())
        XCTAssertEqual(d.kind, .watch)
        XCTAssertEqual(d.msg, "75% used \u{00B7} resets in 6 days.")
    }

    /// A rolled weekly window is the rolled HEADLINE window here: it leads the copy
    /// rather than being appended as a caveat to a 5-hour message that does not exist.
    func testWeeklyOnlyRollLeadsTheCopy() {
        let passed = utcDate(2026, 7, 13, 11, 0, 0)
        let d = ProviderState.deriveCodex(result: weeklyOnly(23, reset: passed),
                                          forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .inferredZero)
        XCTAssertTrue(d.inferredWeek)
        XCTAssertFalse(d.inferredFive)
        XCTAssertEqual(d.week, 0)
        XCTAssertEqual(d.rawWeek, 23)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "Window reset 11:00 passed idle \u{00B7} reads 0% until Codex runs \u{00B7} next reset in 7 days.")
        XCTAssertFalse(d.msg.contains("weekly reset passed, weekly reads 0%"))
    }

    /// Regression: with both windows present the chain still heads on the 5-hour one.
    func testTwoWindowShapeStillHeadsOnTheFiveHourWindow() {
        let s = ProviderUsageSnapshot(
            provider: .codex,
            primary: UsageWindow(id: "primary", title: "5-hour", utilization: 95,
                                 windowMinutes: 300, resetsAt: fiveReset),
            secondary: UsageWindow(id: "secondary", title: "Weekly", utilization: 20,
                                   windowMinutes: 10080, resetsAt: weekReset),
            extras: [], freshness: .observed(now), fetchedAt: now, planType: "plus")
        let d = ProviderState.deriveCodex(result: CodexUsageResult(status: .ok, snapshot: s),
                                          forecast: nil, now: now, hm: hm())
        XCTAssertTrue(d.hasFive)
        XCTAssertEqual(d.kind, .red)
        XCTAssertTrue(d.fiveIsRed)
        XCTAssertFalse(d.weekIsRed)
        XCTAssertEqual(d.headResetsAt, fiveReset)
        XCTAssertEqual(d.msg, "Red zone \u{00B7} 5% headroom \u{00B7} resets 15:00.")
    }

    /// No reading at all keeps the familiar two-window skeleton: an empty instrument
    /// must not announce a missing 5-hour window it has no evidence for.
    func testNoDataKeepsTheTwoWindowSkeleton() {
        let d = ProviderState.deriveCodex(result: CodexUsageResult(status: .noData, snapshot: nil),
                                          forecast: nil, now: now, hm: hm())
        XCTAssertTrue(d.hasFive)
        XCTAssertEqual(d.fiveTitle, "5-hour")
    }

    // MARK: - Glyph shape across every display style
    //
    // The rule, applied identically everywhere: the SOLE window is promoted into the
    // headline slot and the companion slot is not drawn at all. An empty ring, an empty
    // bar, or a leading em-dash would each read as a 5-hour window sitting at zero --
    // the one claim a weekly-only provider cannot make.

    /// Concentric drops to ONE ring. Both halves of the rule are pinned in pixels: the
    /// sole value is painted (not blank), and the companion ring is gone -- including
    /// its empty TRACK, which is what would have read as a 5-hour window at zero. The
    /// track is ink, so dropping it strictly reduces the painted-pixel count.
    func testConcentricGlyphDrawsOneRingWhenThereIsOnlyOneWindow() {
        let single = StatusRenderer.image(five: nil, week: 26, style: .concentric,
                                          mode: .brand, provider: .codex, singleWindow: true)
        let twoRing = StatusRenderer.image(five: nil, week: 26, style: .concentric,
                                           mode: .brand, provider: .codex)
        // Same value drawn in the headline slot of a normal two-ring glyph: identical
        // outer ring, PLUS an empty inner track. The single-window glyph is that minus
        // the track.
        let outerPlusTrack = StatusRenderer.image(five: 26, week: nil, style: .concentric,
                                                  mode: .brand, provider: .codex)
        XCTAssertGreaterThan(painted(single), 0, "the sole window must actually be drawn")
        XCTAssertLessThan(painted(single), painted(outerPlusTrack),
                          "the companion ring's empty track must be gone, not just its arc")
        XCTAssertNotEqual(rgba(single), rgba(twoRing))
    }

    /// `.single` draws the 5-hour window alone, so without the promotion a weekly-only
    /// Codex would render a COMPLETELY BLANK glyph.
    func testSingleRingGlyphIsNotBlankWhenThereIsOnlyAWeeklyWindow() {
        let single = StatusRenderer.image(five: nil, week: 26, style: .single,
                                          mode: .brand, provider: .codex, singleWindow: true)
        // Without the promotion this style has nothing to draw but the bare track.
        let trackOnly = StatusRenderer.image(five: nil, week: 26, style: .single,
                                             mode: .brand, provider: .codex)
        let promoted = StatusRenderer.image(five: 26, week: nil, style: .single,
                                            mode: .brand, provider: .codex)
        XCTAssertEqual(rgba(single), rgba(promoted), "the sole window takes the ring")
        XCTAssertNotEqual(rgba(single), rgba(trackOnly), "an empty ring is not an honest glyph")
    }

    /// Bars narrow to a single gauge rather than pairing the real value with an empty one.
    func testBarsGlyphNarrowsToOneGauge() {
        let single = StatusRenderer.image(five: nil, week: 26, style: .bars,
                                          mode: .brand, provider: .codex, singleWindow: true)
        let pair = StatusRenderer.image(five: nil, week: 26, style: .bars,
                                        mode: .brand, provider: .codex)
        XCTAssertEqual(single.size.width, 7)         // one gauge, no gap
        XCTAssertEqual(pair.size.width, 19)          // two gauges + gap
    }

    /// Percentages print the value alone, not "— / 26%".
    func testPercentagesPrintTheValueAlone() {
        let single = StatusRenderer.percentText(nil, 26, .brand, NSFont.systemFont(ofSize: 12),
                                                singleWindow: true)
        XCTAssertEqual(single.string, "26%")
        let pair = StatusRenderer.percentText(nil, 26, .brand, NSFont.systemFont(ofSize: 12))
        XCTAssertEqual(pair.string, "— / 26%")       // unchanged for a two-window provider
    }

    /// Claude, and the two-window Codex shape, are untouched by the flag's existence:
    /// the default renders exactly what it always did (the render goldens pin this too).
    func testTwoWindowGlyphsAreUnchanged() {
        for style in DisplayStyle.allCases where style != .percentages {
            let before = StatusRenderer.image(five: 42, week: 17, style: style, mode: .brand)
            let after = StatusRenderer.image(five: 42, week: 17, style: style, mode: .brand,
                                             singleWindow: false)
            XCTAssertEqual(rgba(before), rgba(after), "\(style) drifted")
        }
    }

    /// The PANEL rings (the 80 pt instrument and the 40 pt strip share this painter)
    /// follow the same rule as the bar glyph: one window, one ring. The companion ring's
    /// empty track must be gone, not merely un-filled.
    func testPanelRingsDrawOneRingWhenThereIsOnlyOneWindow() {
        func rings(singleWindow: Bool) -> NSImage {
            let size = NSSize(width: 80, height: 80)
            return NSImage(size: size, flipped: false) { rect in
                PanelRings.draw(in: rect, five: singleWindow ? nil : 26, week: 26,
                                projected: nil, mode: .brand, provider: .codex,
                                singleWindow: singleWindow)
                return true
            }
        }
        let single = rings(singleWindow: true)
        let twoRing = rings(singleWindow: false)
        XCTAssertGreaterThan(painted(single), 0, "the sole window must be drawn")
        XCTAssertLessThan(painted(single), painted(twoRing),
                          "the inner ring, track included, must be gone")
    }

    /// Raw pixels of a glyph, for identity comparisons.
    private func rgba(_ img: NSImage) -> Data {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return Data() }
        return data
    }

    /// Count of pixels carrying any ink, so "the empty track is gone" is testable.
    private func painted(_ img: NSImage) -> Int {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                n += 1
            }
        }
        return n
    }

    // MARK: - Repair of history recorded under the old assumption

    /// Samples stored between 2026-07-12 and this build put the WEEKLY figure in the
    /// 5-hour field. A 5-hour window cannot reset more than five hours after the
    /// reading that saw it, so a far-future reset identifies them exactly.
    func testRepairMovesMisfiledWeeklySamplesToTheWeeklySlot() {
        let t = utcDate(2026, 7, 13, 10, 0, 0)
        let s = HistorySample(t: t, five: 23, week: nil,
                              fiveResetsAt: utcDate(2026, 7, 19, 13, 0, 0), weekResetsAt: nil)
        let out = AppDelegate.repairCodexSamples([s])
        XCTAssertNil(out[0].five)
        XCTAssertNil(out[0].fiveResetsAt)
        XCTAssertEqual(out[0].week, 23)
        XCTAssertEqual(out[0].weekResetsAt, utcDate(2026, 7, 19, 13, 0, 0))
    }

    func testRepairLeavesGenuineFiveHourSamplesAlone() {
        let t = utcDate(2026, 7, 11, 10, 0, 0)
        let real = HistorySample(t: t, five: 42, week: 17,
                                 fiveResetsAt: utcDate(2026, 7, 11, 13, 0, 0),
                                 weekResetsAt: utcDate(2026, 7, 19, 13, 0, 0))
        // A 5-hour-only sample whose reset is genuinely within five hours: untouched.
        let lone = HistorySample(t: t, five: 42, week: nil,
                                 fiveResetsAt: utcDate(2026, 7, 11, 14, 30, 0), weekResetsAt: nil)
        let out = AppDelegate.repairCodexSamples([real, lone])
        XCTAssertEqual(out[0].five, 42)
        XCTAssertEqual(out[0].week, 17)
        XCTAssertEqual(out[1].five, 42)
        XCTAssertNil(out[1].week)
    }
}
