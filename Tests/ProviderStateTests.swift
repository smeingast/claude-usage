import XCTest
import AppKit
@testable import ClaudeUsageCore

// The pure two-provider state derivation (package 4b): the Codex chain priority
// order, the fresh/aged annotation, the forecast gate, both providers' pip severity
// (amendment 5), the two-provider status line (amendment 12), the sessions split
// header (amendment 11), and Show Codex resolution. All copy strings are asserted
// character-for-character against the concept's deriveClaude / deriveCodex.
final class ProviderStateTests: XCTestCase {

    private let now = utcDate(2026, 1, 2, 12, 0, 0)
    private func hm() -> DateFormatter { hmUTCFormatter() }

    // MARK: - Builders

    private func codexResult(five: Double?, week: Double?,
                             fiveReset: Date?, weekReset: Date?,
                             observed: Date, plan: String? = "plus") -> CodexUsageResult {
        let snap = ProviderUsageSnapshot(
            provider: .codex,
            primary: five.map {
                UsageWindow(id: "primary", title: "5-hour", utilization: $0,
                            windowMinutes: 300, resetsAt: fiveReset)
            },
            secondary: week.map {
                UsageWindow(id: "secondary", title: "Weekly", utilization: $0,
                            windowMinutes: 10080, resetsAt: weekReset)
            },
            extras: [], freshness: .observed(observed), fetchedAt: observed, planType: plan)
        return CodexUsageResult(status: .ok, snapshot: snap)
    }

    /// A comfortably-future weekly reset so the weekly window never infers zero on
    /// its own while a test is exercising the 5-hour chain.
    private var weekFuture: Date { utcDate(2026, 1, 8, 12, 0) }

    private func fc(_ rate: Double, projected: Double, crosses: Bool = false,
                    crossTime: Date? = nil) -> Forecast {
        Forecast(ratePerHour: rate, projected: projected, crosses: crosses, crossTime: crossTime)
    }

    // MARK: - Codex chain priority

    func testCodexNotInstalledHiddenNoPip() {
        let d = ProviderState.deriveCodex(
            result: CodexUsageResult(status: .notInstalled, snapshot: nil),
            forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .notInstalled)
        XCTAssertFalse(d.installed)
        XCTAssertFalse(d.hasData)
        XCTAssertEqual(d.pip, .hidden)
    }

    func testCodexNoDataPrompt() {
        let d = ProviderState.deriveCodex(
            result: CodexUsageResult(status: .noData, snapshot: nil),
            forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .noData)
        XCTAssertTrue(d.installed)
        XCTAssertFalse(d.hasData)
        XCTAssertEqual(d.ageLine, "No usage data yet")
        XCTAssertEqual(d.msg, "Codex is installed but hasn\u{2019}t logged usage yet. Run a Codex session to populate this.")
        XCTAssertEqual(d.pip, .muted)
    }

    func testCodexInferredZeroWinsOverEverything() {
        // 5-hour reset passed 74 min ago, no newer event: the honest value is 0,
        // the rolled ring is dashed, and the old 71% is named in the copy.
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 71, week: 14,
                                fiveReset: utcDate(2026, 1, 2, 10, 46),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 17)),
            forecast: fc(20, projected: 100, crosses: true), now: now, hm: hm())
        XCTAssertEqual(d.kind, .inferredZero)
        XCTAssertTrue(d.inferredFive)
        XCTAssertFalse(d.inferredWeek)
        XCTAssertEqual(d.five, 0)
        XCTAssertEqual(d.week, 14)
        XCTAssertFalse(d.forecastActive)          // no forecast on a rolled window
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.ageLine, "as of 11:17")
        XCTAssertEqual(d.msg, "No Codex activity since the window reset at 10:46. The log still reads 71%; the honest value is 0% \u{2014} it starts fresh, resets 15:46.")
    }

    func testCodexRedZone() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 93, week: 58,
                                fiveReset: utcDate(2026, 1, 2, 12, 38),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 59)),
            forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .red)
        XCTAssertTrue(d.isRed)
        XCTAssertEqual(d.pip, .red)
        XCTAssertEqual(d.msg, "Red zone \u{2014} 7% headroom left on Codex\u{2019}s 5-hour window. Resets 12:38.")
    }

    func testCodexPace() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 64, week: 23,
                                fiveReset: utcDate(2026, 1, 2, 14, 30),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 58)),
            forecast: fc(22, projected: 100, crosses: true,
                         crossTime: utcDate(2026, 1, 2, 13, 0)),
            now: now, hm: hm())
        XCTAssertEqual(d.kind, .pace)
        XCTAssertTrue(d.forecastActive)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "At this pace Codex reaches 100% around 13:00, before the 14:30 reset.")
    }

    func testCodexWatch() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 76, week: 41,
                                fiveReset: utcDate(2026, 1, 2, 13, 35),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 58)),
            forecast: fc(11, projected: 84, crosses: false), now: now, hm: hm())
        XCTAssertEqual(d.kind, .watch)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "76% used on Codex, 24 to go. About 84% by the 13:35 reset.")
    }

    func testCodexNormalFresh() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 19, week: 14,
                                fiveReset: utcDate(2026, 1, 2, 16, 35),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 56)),
            forecast: fc(34, projected: 30, crosses: false), now: now, hm: hm())
        XCTAssertEqual(d.kind, .normal)
        XCTAssertTrue(d.fresh)
        XCTAssertFalse(d.aged)
        XCTAssertEqual(d.pip, .calm(.codex))
        XCTAssertEqual(d.ageLine, "as of 11:56")
        XCTAssertEqual(d.msg, "Codex at 19% of its 5-hour window, resets 16:35 (in 4h 35m). Weekly 14%.")
    }

    func testCodexAgedIdle() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 47, week: 22,
                                fiveReset: utcDate(2026, 1, 2, 13, 0),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 8, 47)),
            forecast: fc(0, projected: 47), now: now, hm: hm())
        XCTAssertFalse(d.fresh)
        XCTAssertTrue(d.aged)
        XCTAssertFalse(d.forecastActive)
        XCTAssertEqual(d.kind, .normal)           // aged is orthogonal to the chain
        XCTAssertEqual(d.pip, .muted)             // aged-idle -> gray (amendment 5)
        XCTAssertTrue(d.ageWarn)
        XCTAssertEqual(d.ageLine, "as of 08:47 \u{00B7} 3h 13m ago")
        XCTAssertEqual(d.msg, "Reading is a snapshot from 08:47 (3h 13m ago), when Codex last wrote. It\u{2019}s idle now, so there\u{2019}s no live burn rate to forecast.")
    }

    // MARK: - Weekly-only inferred zero (amendment 9: per-window, first-class)

    func testCodexWeeklyOnlyInferredKeepsChainAndGoesAmber() {
        // Only the weekly reset has passed: the chain stays keyed on the 5-hour
        // window (kind normal, no 5-hour strike), but the weekly window rolls to an
        // honest 0 with its raw figure carried for the strike, the pip goes amber
        // (amendment 5 lists "Codex inferred-zero" unqualified), and the copy names
        // the weekly reset.
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 19, week: 14,
                                fiveReset: utcDate(2026, 1, 2, 16, 35),
                                weekReset: utcDate(2026, 1, 2, 10, 46),   // passed
                                observed: utcDate(2026, 1, 2, 11, 56)),
            forecast: fc(34, projected: 30, crosses: false), now: now, hm: hm())
        XCTAssertEqual(d.kind, .normal)           // chain unchanged by a weekly roll
        XCTAssertFalse(d.inferredFive)
        XCTAssertTrue(d.inferredWeek)
        XCTAssertEqual(d.five, 19)
        XCTAssertEqual(d.week, 0)                 // effective weekly value
        XCTAssertEqual(d.rawWeek, 14)             // carried for the struck figure
        XCTAssertEqual(d.pip, .amber)
        XCTAssertTrue(d.forecastActive)           // the live 5-hour window still forecasts
        XCTAssertEqual(d.msg, "Codex at 19% of its 5-hour window, resets 16:35 (in 4h 35m). Weekly 0%. No Codex activity since the weekly window reset at 10:46; the honest weekly value is 0%, not the logged 14%.")
    }

    func testCodexBothInferredLeadsWithFiveCopy() {
        // Both windows rolled: the 5-hour inferred copy leads unchanged (the weekly
        // roll is visible as its dashed ring + struck figure); no appended sentence.
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 71, week: 14,
                                fiveReset: utcDate(2026, 1, 2, 10, 46),
                                weekReset: utcDate(2026, 1, 2, 9, 0),
                                observed: utcDate(2026, 1, 2, 8, 30)),
            forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .inferredZero)
        XCTAssertTrue(d.inferredFive)
        XCTAssertTrue(d.inferredWeek)
        XCTAssertEqual(d.rawWeek, 14)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "No Codex activity since the window reset at 10:46. The log still reads 71%; the honest value is 0% \u{2014} it starts fresh, resets 15:46.")
    }

    // MARK: - Fresh / aged boundary (amendment 2: fresh = age <= 5 min)

    func testFreshBoundaryAtExactlyFiveMinutes() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 30, week: 10,
                                fiveReset: utcDate(2026, 1, 2, 15, 0),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 55, 0)),   // exactly 5 min
            forecast: nil, now: now, hm: hm())
        XCTAssertTrue(d.fresh)
        XCTAssertFalse(d.aged)
    }

    func testAgedJustPastFiveMinutes() {
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 30, week: 10,
                                fiveReset: utcDate(2026, 1, 2, 15, 0),
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 54, 59)),  // 5 min 1 s
            forecast: nil, now: now, hm: hm())
        XCTAssertFalse(d.fresh)
        XCTAssertTrue(d.aged)
    }

    // MARK: - Forecast gate (rate > 0 AND age <= 12 min AND reset in future)

    private func forecastActive(observed: Date, rate: Double, fiveReset: Date?) -> Bool {
        ProviderState.deriveCodex(
            result: codexResult(five: 40, week: 10, fiveReset: fiveReset,
                                weekReset: weekFuture, observed: observed),
            forecast: fc(rate, projected: 60), now: now, hm: hm()).forecastActive
    }

    func testForecastNeedsPositiveRate() {
        let fresh = utcDate(2026, 1, 2, 11, 58)
        XCTAssertTrue(forecastActive(observed: fresh, rate: 5, fiveReset: utcDate(2026, 1, 2, 15, 0)))
        XCTAssertFalse(forecastActive(observed: fresh, rate: 0, fiveReset: utcDate(2026, 1, 2, 15, 0)))
    }

    func testForecastAgeBoundaryTwelveMinutes() {
        // 12 min exactly still forecasts; a second past it does not.
        XCTAssertTrue(forecastActive(observed: utcDate(2026, 1, 2, 11, 48, 0), rate: 5,
                                     fiveReset: utcDate(2026, 1, 2, 15, 0)))
        XCTAssertFalse(forecastActive(observed: utcDate(2026, 1, 2, 11, 47, 59), rate: 5,
                                      fiveReset: utcDate(2026, 1, 2, 15, 0)))
    }

    func testForecastSuppressedWhenResetInPast() {
        // A passed 5-hour reset infers zero, which never forecasts.
        let d = ProviderState.deriveCodex(
            result: codexResult(five: 40, week: 10,
                                fiveReset: utcDate(2026, 1, 2, 11, 0),   // already passed
                                weekReset: weekFuture,
                                observed: utcDate(2026, 1, 2, 11, 58)),
            forecast: fc(5, projected: 60, crosses: true), now: now, hm: hm())
        XCTAssertFalse(d.forecastActive)
        XCTAssertEqual(d.kind, .inferredZero)
    }

    // MARK: - Claude chain + pip severity (amendment 5)

    func testClaudeSignedOut() {
        let d = ProviderState.deriveClaude(
            five: nil, week: nil, fiveResetsAt: nil, weekResetsAt: nil,
            signedOut: true, staleError: false, observedAt: now, forecast: nil,
            now: now, hm: hm())
        XCTAssertEqual(d.kind, .signedOut)
        XCTAssertEqual(d.ageLine, "Not signed in")
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "Signed out. Open Claude, sign in, then reopen \u{2014} the token isn\u{2019}t being shared.")
    }

    func testClaudeStale() {
        let d = ProviderState.deriveClaude(
            five: 41, week: 23, fiveResetsAt: utcDate(2026, 1, 2, 14, 0),
            weekResetsAt: weekFuture, signedOut: false, staleError: true,
            observedAt: utcDate(2026, 1, 2, 11, 13), forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .stale)
        XCTAssertTrue(d.ageWarn)
        XCTAssertEqual(d.ageLine, "Updated 47m ago")
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "Last reading 47m ago; your Mac may have slept. Refreshes on open and every ~5 min.")
    }

    func testClaudeRed() {
        let d = ProviderState.deriveClaude(
            five: 93, week: 58, fiveResetsAt: utcDate(2026, 1, 2, 12, 38),
            weekResetsAt: weekFuture, signedOut: false, staleError: false,
            observedAt: now, forecast: nil, now: now, hm: hm())
        XCTAssertEqual(d.kind, .red)
        XCTAssertTrue(d.isRed)
        XCTAssertEqual(d.pip, .red)
        XCTAssertEqual(d.msg, "Red zone \u{2014} 7% headroom left. Resets 12:38, in 38m.")
    }

    func testClaudePace() {
        let d = ProviderState.deriveClaude(
            five: 64, week: 23, fiveResetsAt: utcDate(2026, 1, 2, 14, 30),
            weekResetsAt: weekFuture, signedOut: false, staleError: false,
            observedAt: now,
            forecast: fc(22, projected: 100, crosses: true, crossTime: utcDate(2026, 1, 2, 13, 0)),
            now: now, hm: hm())
        XCTAssertEqual(d.kind, .pace)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "At this pace you reach 100% around 13:00 \u{2014} 1h 30m before the 14:30 reset. Ease off to coast in.")
    }

    func testClaudeWatch() {
        let d = ProviderState.deriveClaude(
            five: 76, week: 41, fiveResetsAt: utcDate(2026, 1, 2, 13, 35),
            weekResetsAt: weekFuture, signedOut: false, staleError: false,
            observedAt: now, forecast: fc(11, projected: 84, crosses: false),
            now: now, hm: hm())
        XCTAssertEqual(d.kind, .watch)
        XCTAssertEqual(d.pip, .amber)
        XCTAssertEqual(d.msg, "76% used, 24 to go. About 84% by the 13:35 reset \u{2014} still clear.")
    }

    func testClaudeNormal() {
        let d = ProviderState.deriveClaude(
            five: 41, week: 23, fiveResetsAt: utcDate(2026, 1, 2, 14, 35),
            weekResetsAt: weekFuture, signedOut: false, staleError: false,
            observedAt: now, forecast: fc(14, projected: 55, crosses: false),
            now: now, hm: hm())
        XCTAssertEqual(d.kind, .normal)
        XCTAssertEqual(d.ageLine, "Updated 12:00")
        XCTAssertTrue(d.pip == .calm(.claude))
        XCTAssertEqual(d.msg, "At this pace the 5-hour window settles near 55% before it resets at 14:35. Plenty of headroom.")
    }

    // MARK: - Status line (amendment 12)

    func testStatusLineClaudeOnlyIsPlain() {
        XCTAssertEqual(ProviderState.twoProviderStatusLine(claudeText: "Updated 11:32",
                                                           codexSegment: nil),
                       "Updated 11:32")
    }

    func testStatusLineTwoProviderFresh() {
        let seg = ProviderState.codexStatusSegment(observedAt: utcDate(2026, 1, 2, 12, 58),
                                                   aged: false, hm: hm(),
                                                   now: utcDate(2026, 1, 2, 12, 58))
        XCTAssertEqual(seg, "Codex as of 12:58")
        XCTAssertEqual(ProviderState.twoProviderStatusLine(claudeText: "Updated 11:32",
                                                           codexSegment: seg),
                       "Updated 11:32 \u{00B7} Codex as of 12:58")
    }

    func testStatusLineTwoProviderAgedCarriesAge() {
        let statusNow = utcDate(2026, 1, 2, 12, 58)
        let seg = ProviderState.codexStatusSegment(observedAt: utcDate(2026, 1, 2, 9, 45),
                                                   aged: true, hm: hm(), now: statusNow)
        XCTAssertEqual(seg, "Codex as of 09:45 \u{00B7} 3h 13m ago")
        XCTAssertEqual(ProviderState.twoProviderStatusLine(claudeText: "Updated 11:32",
                                                           codexSegment: seg),
                       "Updated 11:32 \u{00B7} Codex as of 09:45 \u{00B7} 3h 13m ago")
    }

    func testStatusLineCodexSegmentNilWhenNoObservation() {
        XCTAssertNil(ProviderState.codexStatusSegment(observedAt: nil, aged: false,
                                                      hm: hm(), now: now))
    }

    // MARK: - Sessions split header (amendment 11)

    func testSessionsHeaderTwoProviderSplit() {
        XCTAssertEqual(ProviderState.sessionsHeader(claudeCount: 2, codexCount: 1, twoProvider: true),
                       "2 active Claude \u{00B7} 1 Codex")
        XCTAssertEqual(ProviderState.sessionsHeader(claudeCount: 0, codexCount: 0, twoProvider: true),
                       "0 active Claude \u{00B7} 0 Codex")
    }

    func testSessionsHeaderClaudeOnlyKeepsTodaysWording() {
        XCTAssertEqual(ProviderState.sessionsHeader(claudeCount: 0, codexCount: 0, twoProvider: false),
                       "No active Claude sessions")
        XCTAssertEqual(ProviderState.sessionsHeader(claudeCount: 1, codexCount: 0, twoProvider: false),
                       "1 active session")
        XCTAssertEqual(ProviderState.sessionsHeader(claudeCount: 3, codexCount: 2, twoProvider: false),
                       "3 active sessions")
    }

    // MARK: - Show Codex resolution

    func testShowCodexResolution() {
        XCTAssertTrue(ProviderState.codexVisible(.auto, codexRootExists: true))
        XCTAssertFalse(ProviderState.codexVisible(.auto, codexRootExists: false))
        XCTAssertTrue(ProviderState.codexVisible(.on, codexRootExists: false))
        XCTAssertTrue(ProviderState.codexVisible(.on, codexRootExists: true))
        XCTAssertFalse(ProviderState.codexVisible(.off, codexRootExists: true))
        XCTAssertFalse(ProviderState.codexVisible(.off, codexRootExists: false))
    }
}
