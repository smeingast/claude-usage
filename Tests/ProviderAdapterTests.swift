import XCTest
@testable import ClaudeUsageCore

/// The `UsageSnapshot` -> `ProviderUsageSnapshot` adapter and the pure
/// `effectiveUtilization` derivation. These pin the compatibility contract every
/// downstream consumer relies on: presence in, presence out; values and dates
/// bit-identical; nothing coerced.
final class ProviderAdapterTests: XCTestCase {
    private let fetched = utcDate(2026, 1, 2, 13, 40)
    private let fiveReset = utcDate(2026, 1, 2, 14, 0)
    private let weekReset = utcDate(2026, 1, 9, 3, 0)

    // MARK: - Adapter presence + values

    func testFullSnapshotMapsEveryWindow() {
        let s = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 42, resetsAt: fiveReset),
            sevenDay: LimitWindow(utilization: 61, resetsAt: weekReset),
            sevenDayOpus: LimitWindow(utilization: 12, resetsAt: weekReset),
            sevenDaySonnet: LimitWindow(utilization: 8, resetsAt: weekReset),
            fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)

        XCTAssertEqual(p.provider, .claude)
        XCTAssertEqual(p.fetchedAt, fetched)
        XCTAssertNil(p.planType)
        guard case .live = p.freshness else { return XCTFail("Claude must be .live") }

        XCTAssertEqual(p.primary?.id, "primary")
        XCTAssertEqual(p.primary?.utilization, 42)
        XCTAssertEqual(p.primary?.resetsAt, fiveReset)
        XCTAssertEqual(p.secondary?.id, "secondary")
        XCTAssertEqual(p.secondary?.utilization, 61)
        XCTAssertEqual(p.secondary?.resetsAt, weekReset)

        // Extras present in exactly the opus-then-sonnet order, keyed by id.
        XCTAssertEqual(p.extras.map(\.id), ["opus", "sonnet"])
        XCTAssertEqual(p.extra("opus")?.utilization, 12)
        XCTAssertEqual(p.extra("sonnet")?.utilization, 8)
        XCTAssertEqual(p.extra("opus")?.resetsAt, weekReset)
    }

    func testMissingWeeklyLeavesSecondaryNil() {
        let s = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 42, resetsAt: fiveReset),
            sevenDay: nil,
            sevenDayOpus: LimitWindow(utilization: 12, resetsAt: weekReset),
            sevenDaySonnet: LimitWindow(utilization: 8, resetsAt: weekReset),
            fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)
        XCTAssertNotNil(p.primary)
        XCTAssertNil(p.secondary)                       // nil stays nil, not coerced to 0
        XCTAssertEqual(p.extras.map(\.id), ["opus", "sonnet"])
    }

    func testMissingExtrasGivesEmptyExtras() {
        let s = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 42, resetsAt: fiveReset),
            sevenDay: LimitWindow(utilization: 61, resetsAt: weekReset),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)
        XCTAssertNotNil(p.primary)
        XCTAssertNotNil(p.secondary)
        XCTAssertTrue(p.extras.isEmpty)
        XCTAssertNil(p.extra("opus"))
        XCTAssertNil(p.extra("sonnet"))
    }

    func testOpusOnlyKeepsOrderAndDropsSonnet() {
        let s = UsageSnapshot(
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: LimitWindow(utilization: 12, resetsAt: weekReset),
            sevenDaySonnet: nil,
            fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)
        XCTAssertNil(p.primary)                         // fiveHour nil -> primary nil
        XCTAssertNil(p.secondary)
        XCTAssertEqual(p.extras.map(\.id), ["opus"])    // only the present extra, no sonnet placeholder
    }

    func testSonnetOnlyStillKeyedCorrectly() {
        let s = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 5, resetsAt: nil),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: LimitWindow(utilization: 8, resetsAt: weekReset),
            fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)
        XCTAssertEqual(p.extras.map(\.id), ["sonnet"])
        XCTAssertEqual(p.extra("sonnet")?.utilization, 8)
        XCTAssertNil(p.primary?.resetsAt)               // nil reset passed through as nil
    }

    func testValuesPassThroughWithoutCoercionOrClamping() {
        // The API can report >100; the adapter must not clamp or round.
        let s = UsageSnapshot(
            fiveHour: LimitWindow(utilization: 137.5, resetsAt: fiveReset),
            sevenDay: LimitWindow(utilization: 0, resetsAt: weekReset),
            sevenDayOpus: nil, sevenDaySonnet: nil, fetchedAt: fetched)
        let p = ProviderUsageSnapshot(claude: s)
        XCTAssertEqual(p.primary?.utilization, 137.5)
        XCTAssertEqual(p.secondary?.utilization, 0)     // a genuine 0, still present
    }

    // MARK: - effectiveUtilization

    private func window(_ util: Double, reset: Date?) -> UsageWindow {
        UsageWindow(id: "primary", title: "5-hour", utilization: util, windowMinutes: 300, resetsAt: reset)
    }

    func testLivePassesThroughEvenPastReset() {
        let now = utcDate(2026, 1, 2, 13, 40)
        let r = effectiveUtilization(window(42, reset: now.addingTimeInterval(-3600)),
                                     freshness: .live, now: now)
        XCTAssertEqual(r.value, 42)
        XCTAssertFalse(r.inferredZero)
    }

    func testObservedFutureResetPassesThrough() {
        let now = utcDate(2026, 1, 2, 13, 40)
        let r = effectiveUtilization(window(42, reset: now.addingTimeInterval(3600)),
                                     freshness: .observed(now.addingTimeInterval(-60)), now: now)
        XCTAssertEqual(r.value, 42)
        XCTAssertFalse(r.inferredZero)
    }

    func testObservedPastResetInfersZero() {
        let now = utcDate(2026, 1, 2, 13, 40)
        let r = effectiveUtilization(window(42, reset: now.addingTimeInterval(-3600)),
                                     freshness: .observed(now.addingTimeInterval(-4000)), now: now)
        XCTAssertEqual(r.value, 0)
        XCTAssertTrue(r.inferredZero)
    }

    func testObservedNilResetCannotBeJudgedRolledOver() {
        let now = utcDate(2026, 1, 2, 13, 40)
        let r = effectiveUtilization(window(42, reset: nil),
                                     freshness: .observed(now.addingTimeInterval(-60)), now: now)
        XCTAssertEqual(r.value, 42)
        XCTAssertFalse(r.inferredZero)
    }
}
