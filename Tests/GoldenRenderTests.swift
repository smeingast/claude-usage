import XCTest
@testable import ClaudeUsageCore

/// Character-for-character goldens for every string the menu render produces from a
/// snapshot: the bar tooltip, the status row, the weekly model rows (text + hidden
/// state), and the recorded history sample. Any drift here is a user-visible change
/// and must fail the build.
final class GoldenRenderTests: XCTestCase {
    private let fetched = utcDate(2026, 1, 2, 13, 40)

    private func snap(five: Double?, week: Double?,
                      fiveReset: Date? = nil, weekReset: Date? = nil,
                      extras: [UsageWindow] = []) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: .claude,
            primary: five.map {
                UsageWindow(id: "primary", title: "5-hour", utilization: $0,
                            windowMinutes: 300, resetsAt: fiveReset)
            },
            secondary: week.map {
                UsageWindow(id: "secondary", title: "Weekly", utilization: $0,
                            windowMinutes: 10080, resetsAt: weekReset)
            },
            extras: extras,
            freshness: .live, fetchedAt: fetched, planType: nil)
    }

    private func win(_ util: Double, reset: Date? = nil) -> UsageWindow {
        UsageWindow(id: "opus", title: "Weekly · Opus", utilization: util,
                    windowMinutes: 10080, resetsAt: reset)
    }

    // MARK: - Tooltip

    func testTooltipFull() {
        XCTAssertEqual(AppDelegate.tooltipText(snap(five: 42, week: 61), lastError: nil),
                       "Claude usage\n5-hour: 42%\nWeekly: 61%")
    }

    func testTooltipMissingWeekly() {
        XCTAssertEqual(AppDelegate.tooltipText(snap(five: 42, week: nil), lastError: nil),
                       "Claude usage\n5-hour: 42%")
    }

    func testTooltipMissingBothHeadlineWindows() {
        XCTAssertEqual(AppDelegate.tooltipText(snap(five: nil, week: nil), lastError: nil),
                       "Claude usage")
    }

    func testTooltipStaleWithSnapshotAppendsWarning() {
        XCTAssertEqual(
            AppDelegate.tooltipText(snap(five: 42, week: 61), lastError: "Server returned HTTP 500."),
            "Claude usage\n5-hour: 42%\nWeekly: 61%\n⚠ Server returned HTTP 500.")
    }

    func testTooltipRoundsPercentages() {
        XCTAssertEqual(AppDelegate.tooltipText(snap(five: 42.6, week: 0.4), lastError: nil),
                       "Claude usage\n5-hour: 43%\nWeekly: 0%")
    }

    // MARK: - Status line

    func testStatusUpdatedWhenSnapshotAndNoError() {
        XCTAssertEqual(
            AppDelegate.statusLineText(fetchedAt: fetched, lastError: nil, formatter: hmUTCFormatter()),
            "Updated 13:40")
    }

    func testStatusStaleWhenSnapshotAndError() {
        XCTAssertEqual(
            AppDelegate.statusLineText(fetchedAt: fetched, lastError: "Network error: offline",
                                       formatter: hmUTCFormatter()),
            "Stale — Network error: offline")
    }

    func testStatusLoadingWhenNoSnapshotNoError() {
        XCTAssertEqual(
            AppDelegate.statusLineText(fetchedAt: nil, lastError: nil, formatter: hmUTCFormatter()),
            "Loading…")
    }

    func testStatusErrorWhenNoSnapshot() {
        XCTAssertEqual(
            AppDelegate.statusLineText(fetchedAt: nil,
                                       lastError: "Not authorized. Open Claude Code and sign in.",
                                       formatter: hmUTCFormatter()),
            "Not authorized. Open Claude Code and sign in.")
    }

    // MARK: - Model rows (text + hidden state)

    func testModelRowVisibleOnlyWhenInUse() {
        XCTAssertTrue(AppDelegate.modelRowVisible(win(12)))
        XCTAssertFalse(AppDelegate.modelRowVisible(win(0)))     // <= 0 hides the row
        XCTAssertFalse(AppDelegate.modelRowVisible(nil))        // missing extra hides the row
    }

    func testModelRowTextNoReset() {
        XCTAssertEqual(
            AppDelegate.modelRowText("Weekly · Opus", win(12), resetFormatter: hmUTCFormatter()),
            "Weekly · Opus — 12%")
    }

    func testModelRowTextWithReset() {
        let reset = utcDate(2026, 1, 4, 3, 0)
        XCTAssertEqual(
            AppDelegate.modelRowText("Weekly · Opus", win(12, reset: reset),
                                     resetFormatter: hmUTCFormatter()),
            "Weekly · Opus — 12%  ·  resets 03:00")
    }

    func testModelRowTextNilWindowShowsEmDashes() {
        XCTAssertEqual(
            AppDelegate.modelRowText("Weekly · Sonnet", nil, resetFormatter: hmUTCFormatter()),
            "Weekly · Sonnet — —")
    }

    // MARK: - History sample

    func testHistorySampleFull() {
        let fr = utcDate(2026, 1, 2, 14, 0)
        let wr = utcDate(2026, 1, 9, 3, 0)
        let hs = AppDelegate.historySample(from: snap(five: 42, week: 61, fiveReset: fr, weekReset: wr))
        XCTAssertEqual(hs.t, fetched)
        XCTAssertEqual(hs.five, 42)
        XCTAssertEqual(hs.week, 61)
        XCTAssertEqual(hs.fiveResetsAt, fr)
        XCTAssertEqual(hs.weekResetsAt, wr)
    }

    func testHistorySampleMissingWeeklyKeepsGaps() {
        let hs = AppDelegate.historySample(from: snap(five: 42, week: nil,
                                                      fiveReset: utcDate(2026, 1, 2, 14, 0)))
        XCTAssertEqual(hs.five, 42)
        XCTAssertNil(hs.week)                         // genuine gap, never 0
        XCTAssertNil(hs.weekResetsAt)
    }

    /// The whole record path, driven from a Claude `UsageSnapshot` through the
    /// adapter: proves the recorded sample is identical to the pre-refactor code
    /// that read `fiveHour`/`sevenDay` directly.
    func testHistorySampleThroughAdapterMatchesRawFields() {
        let fr = utcDate(2026, 1, 2, 14, 0)
        let wr = utcDate(2026, 1, 9, 3, 0)
        let usage = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 42, resetsAt: fr),
            sevenDay: LimitWindow(utilization: 61, resetsAt: wr),
            sevenDayOpus: nil, sevenDaySonnet: nil, fetchedAt: fetched)
        let hs = AppDelegate.historySample(from: ProviderUsageSnapshot(claude: usage))
        XCTAssertEqual(hs.t, fetched)
        XCTAssertEqual(hs.five, 42)
        XCTAssertEqual(hs.week, 61)
        XCTAssertEqual(hs.fiveResetsAt, fr)
        XCTAssertEqual(hs.weekResetsAt, wr)
    }
}
