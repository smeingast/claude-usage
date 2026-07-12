import XCTest
@testable import ClaudeUsageCore

/// The Codex data layer: status mapping, the newest-usable-event usage scan with its
/// mtime ordering and file cap, the tolerant `token_count` decode (labels, epoch
/// resets, observed freshness, plan type), the backfill collector with its noise-safe
/// take-while gate, and the greedy history decimator. All fixtures are synthetic
/// rollout trees under a scratch dir; no real `~/.codex` data is read.
final class CodexUsageClientTests: ScratchTestCase {

    // MARK: - Fixture builders

    /// A synthetic `~/.codex` root inside the per-test scratch dir.
    private func codexRoot() -> URL { dir.appendingPathComponent(".codex", isDirectory: true) }

    /// Write one `sessions/<day>/rollout-<name>.jsonl` with the given lines and mtime.
    /// The date dir names are LOCAL-time strings by convention; the client must order
    /// by the mtime we stamp here, never by these names.
    @discardableResult
    private func writeRollout(_ root: URL, day: String = "2026/07/11", name: String,
                             lines: [String], mtime: Date = Date()) throws -> URL {
        let dayDir = root.appendingPathComponent("sessions/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let url = dayDir.appendingPathComponent("rollout-\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// A `rate_limits.primary`/`.secondary` object, or nil to omit the window.
    private func window(used: Double, minutes: Int?, resets: Int?) -> String {
        var parts = ["\"used_percent\":\(used)"]
        if let m = minutes { parts.append("\"window_minutes\":\(m)") }
        if let r = resets { parts.append("\"resets_at\":\(r)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func rateLimits(primary: String? = nil, secondary: String? = nil,
                            plan: String? = "plus") -> String {
        var parts: [String] = []
        if let p = primary { parts.append("\"primary\":\(p)") }
        if let s = secondary { parts.append("\"secondary\":\(s)") }
        if let pl = plan { parts.append("\"plan_type\":\"\(pl)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// A full `event_msg`/`token_count` line. `rateLimits == nil` writes a literal
    /// `null`, the "usage-less event" case the scan must skip.
    private func tokenCount(ts: String, rateLimits: String?) -> String {
        let rl = rateLimits ?? "null"
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400},"rate_limits":\#(rl)}}"#
    }

    /// A non-`token_count` line that carries a top-level timestamp (session_meta,
    /// response_item, ...): the noise the backward walk must step over.
    private func noise(ts: String, type: String = "response_item") -> String {
        #"{"timestamp":"\#(ts)","type":"\#(type)","payload":{"role":"assistant"}}"#
    }

    /// A noise line with NO timestamp at all: the take-while gate must keep going.
    private func untimedNoise() -> String {
        #"{"type":"response_item","payload":{"content":"chatter"}}"#
    }

    // MARK: - Representative decode

    func testRepresentativeTokenCountDecodesFully() throws {
        let root = codexRoot()
        let ts = "2026-07-11T15:56:35.604Z"
        let line = tokenCount(ts: ts, rateLimits: rateLimits(
            primary: window(used: 61, minutes: 300, resets: 1_783_790_640),
            secondary: window(used: 21, minutes: 10080, resets: 1_784_359_082),
            plan: "plus"))
        try writeRollout(root, name: "a", lines: [line])

        let result = CodexUsageClient(root: root).fetch()
        XCTAssertEqual(result.status, .ok)
        let snap = try XCTUnwrap(result.snapshot)

        XCTAssertEqual(snap.provider, .codex)
        XCTAssertTrue(snap.extras.isEmpty)
        XCTAssertEqual(snap.planType, "plus")

        XCTAssertEqual(snap.primary?.id, "primary")
        XCTAssertEqual(snap.primary?.title, "5-hour")
        XCTAssertEqual(snap.primary?.utilization, 61)
        XCTAssertEqual(snap.primary?.windowMinutes, 300)
        XCTAssertEqual(snap.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_790_640))

        XCTAssertEqual(snap.secondary?.title, "Weekly")
        XCTAssertEqual(snap.secondary?.utilization, 21)
        XCTAssertEqual(snap.secondary?.resetsAt, Date(timeIntervalSince1970: 1_784_359_082))

        guard case let .observed(obs) = snap.freshness else { return XCTFail("expected .observed") }
        XCTAssertEqual(obs, ISO.parse(ts))
    }

    func testPrimaryOnlyEventLeavesSecondaryNil() throws {
        let root = codexRoot()
        let line = tokenCount(ts: "2026-07-11T15:56:35.000Z", rateLimits: rateLimits(
            primary: window(used: 40, minutes: 300, resets: 1_783_790_640),
            secondary: nil))
        try writeRollout(root, name: "a", lines: [line])

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.utilization, 40)
        XCTAssertNil(snap.secondary)              // absent window stays nil, not coerced
    }

    func testWindowTitleLabels() {
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: 300), "5-hour")
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: 10080), "Weekly")
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: 120), "2-hour")
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: 2880), "2-day")
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: 45), "45-min")   // fallback
        XCTAssertEqual(CodexUsageClient.windowTitle(minutes: nil), "Window")  // fallback
    }

    func testUnknownWindowMinutesStillDecodesWithFallbackLabel() throws {
        let root = codexRoot()
        let line = tokenCount(ts: "2026-07-11T15:56:35.000Z", rateLimits: rateLimits(
            primary: window(used: 7, minutes: 45, resets: 1_783_790_640)))
        try writeRollout(root, name: "a", lines: [line])

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.windowMinutes, 45)
        XCTAssertEqual(snap.primary?.title, "45-min")
    }

    // MARK: - Scan policy: null skip, empty-file fall-through, ordering, cap

    func testNullRateLimitsWithinFileSkippedForOlderValidEvent() throws {
        let root = codexRoot()
        // Newest line is a usage-less (null rate_limits) event; the older one is valid.
        let lines = [
            tokenCount(ts: "2026-07-11T10:00:00.000Z",
                       rateLimits: rateLimits(primary: window(used: 55, minutes: 300, resets: 1_783_790_640))),
            noise(ts: "2026-07-11T10:30:00.000Z"),
            tokenCount(ts: "2026-07-11T11:00:00.000Z", rateLimits: nil),
        ]
        try writeRollout(root, name: "a", lines: lines)

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.utilization, 55)     // the older, valid event won
    }

    func testEmptyNewestFileFallsThroughToOlderFile() throws {
        let root = codexRoot()
        // Newest file (by mtime) has no token_count at all; older file carries one.
        try writeRollout(root, name: "empty", lines: [noise(ts: "2026-07-11T13:00:00.000Z")],
                         mtime: Date())
        try writeRollout(root, name: "hit", lines: [tokenCount(
            ts: "2026-07-11T09:00:00.000Z",
            rateLimits: rateLimits(primary: window(used: 33, minutes: 300, resets: 1_783_790_640)))],
                         mtime: Date().addingTimeInterval(-3600))

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.utilization, 33)
    }

    func testTwentyFiveEmptyFilesThenHitInFileTwentySix() throws {
        let root = codexRoot()
        let base = Date()
        // 25 newest files without a usable rate_limits, then a valid hit as the oldest.
        for i in 0..<25 {
            try writeRollout(root, name: "empty-\(i)",
                             lines: [tokenCount(ts: "2026-07-11T12:00:00.000Z", rateLimits: nil)],
                             mtime: base.addingTimeInterval(-Double(i)))
        }
        try writeRollout(root, name: "hit", lines: [tokenCount(
            ts: "2026-07-11T09:00:00.000Z",
            rateLimits: rateLimits(primary: window(used: 77, minutes: 300, resets: 1_783_790_640)))],
                         mtime: base.addingTimeInterval(-100))

        // Default cap (400) is far above 26: the scan falls through the 25 empties.
        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.utilization, 77)
    }

    func testFileCapStopsBeforeReachingAnOlderHit() throws {
        let root = codexRoot()
        let base = Date()
        // 5 newest empties, then a valid hit as the 6th-newest. With a cap of 5, the
        // scan stops before the hit and must report noData (the cap is doing its job).
        for i in 0..<5 {
            try writeRollout(root, name: "empty-\(i)",
                             lines: [noise(ts: "2026-07-11T12:00:00.000Z")],
                             mtime: base.addingTimeInterval(-Double(i)))
        }
        try writeRollout(root, name: "hit", lines: [tokenCount(
            ts: "2026-07-11T09:00:00.000Z",
            rateLimits: rateLimits(primary: window(used: 99, minutes: 300, resets: 1_783_790_640)))],
                         mtime: base.addingTimeInterval(-100))

        let result = CodexUsageClient(root: root, fileCap: 5).fetch()
        XCTAssertEqual(result.status, .noData)
        XCTAssertNil(result.snapshot)
    }

    func testMtimeWinsOverLocalDateDirName() throws {
        let root = codexRoot()
        let base = Date()
        // File A sits in an OLDER date dir but has the NEWER mtime and the newer
        // event; file B has the newer dir NAME but is older on both counts, with its
        // event > 15 min older so it stays outside the vote neighborhood. Walking by
        // dir name would find B first and show 11%; the mtime order must anchor on A.
        try writeRollout(root, day: "2026/07/10", name: "A", lines: [tokenCount(
            ts: "2026-07-10T23:00:00.000Z",
            rateLimits: rateLimits(primary: window(used: 61, minutes: 300, resets: 1_783_790_640)))],
                         mtime: base)
        try writeRollout(root, day: "2026/07/11", name: "B", lines: [tokenCount(
            ts: "2026-07-10T22:30:00.000Z",
            rateLimits: rateLimits(primary: window(used: 11, minutes: 300, resets: 1_783_790_640)))],
                         mtime: base.addingTimeInterval(-3600))

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch().snapshot)
        XCTAssertEqual(snap.primary?.utilization, 61)     // mtime wins
    }

    // MARK: - Status mapping

    func testMissingRootIsNotInstalled() {
        let root = codexRoot()   // never created
        XCTAssertEqual(CodexUsageClient(root: root).fetch().status, .notInstalled)
    }

    func testRootWithoutSessionsIsNoData() throws {
        let root = codexRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(CodexUsageClient(root: root).fetch().status, .noData)
    }

    func testEmptySessionsDirIsNoData() throws {
        let root = codexRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        XCTAssertEqual(CodexUsageClient(root: root).fetch().status, .noData)
    }

    // MARK: - Past reset -> inferred zero via effectiveUtilization

    func testPastResetInfersZeroOnMappedWindow() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let observed = now.addingTimeInterval(-6 * 3600)          // event well before now
        let reset = Int(now.timeIntervalSince1970) - 3600         // reset already passed
        let line = tokenCount(ts: iso(observed), rateLimits: rateLimits(
            primary: window(used: 42, minutes: 300, resets: reset)))
        try writeRollout(root, name: "a", lines: [line], mtime: observed)

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch(now: now).snapshot)
        let primary = try XCTUnwrap(snap.primary)
        let r = effectiveUtilization(primary, freshness: snap.freshness, now: now)
        XCTAssertEqual(r.value, 0)
        XCTAssertTrue(r.inferredZero)
    }

    // MARK: - Backfill

    func testBackfillNoiseDoesNotStopTheTakeWhileGate() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let cutoff = Date(timeIntervalSince1970: 1_783_785_600)   // between the meta line and events
        // Oldest -> newest: a session_meta at/below the cutoff (the stop line), then
        // token_counts interleaved with timed AND untimed noise. All three token_counts
        // are newer than the cutoff and must survive the walk.
        let lines = [
            noise(ts: iso(cutoff.addingTimeInterval(-60)), type: "session_meta"),
            tokenCount(ts: iso(cutoff.addingTimeInterval(600)),
                       rateLimits: rateLimits(primary: window(used: 10, minutes: 300, resets: 1_783_790_640))),
            noise(ts: iso(cutoff.addingTimeInterval(900))),
            tokenCount(ts: iso(cutoff.addingTimeInterval(1200)),
                       rateLimits: rateLimits(primary: window(used: 20, minutes: 300, resets: 1_783_790_640))),
            untimedNoise(),
            tokenCount(ts: iso(cutoff.addingTimeInterval(1800)),
                       rateLimits: rateLimits(primary: window(used: 30, minutes: 300, resets: 1_783_790_640))),
        ]
        try writeRollout(root, name: "a", lines: lines, mtime: now.addingTimeInterval(-3600))

        let events = CodexUsageClient(root: root).backfillEvents(after: cutoff, now: now)
        XCTAssertEqual(events.map { $0.primaryPercent }, [10, 20, 30])   // ascending, all three kept
    }

    func testBackfillReSortsNewestFirstScanOutputChronologically() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let cutoff = now.addingTimeInterval(-6 * 3600)
        // File A has the NEWER mtime but the LATER event; file B is older mtime with the
        // EARLIER event. The scanner visits A then B (newest-first), so the raw collect
        // order is descending; the result must be re-sorted ascending.
        try writeRollout(root, name: "A", lines: [tokenCount(
            ts: iso(now.addingTimeInterval(-1800)),
            rateLimits: rateLimits(primary: window(used: 30, minutes: 300, resets: 1_783_790_640)))],
                         mtime: now.addingTimeInterval(-600))
        try writeRollout(root, name: "B", lines: [tokenCount(
            ts: iso(now.addingTimeInterval(-3600)),
            rateLimits: rateLimits(primary: window(used: 10, minutes: 300, resets: 1_783_790_640)))],
                         mtime: now.addingTimeInterval(-1200))

        let events = CodexUsageClient(root: root).backfillEvents(after: cutoff, now: now)
        XCTAssertEqual(events.map { $0.primaryPercent }, [10, 30])       // ascending by time
        XCTAssertTrue(events[0].timestamp < events[1].timestamp)
    }

    func testBackfillHighWaterPreventsReprocessing() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let cutoff = now.addingTimeInterval(-6 * 3600)
        let lines = [
            tokenCount(ts: iso(now.addingTimeInterval(-3600)),
                       rateLimits: rateLimits(primary: window(used: 10, minutes: 300, resets: 1_783_790_640))),
            tokenCount(ts: iso(now.addingTimeInterval(-1800)),
                       rateLimits: rateLimits(primary: window(used: 20, minutes: 300, resets: 1_783_790_640))),
        ]
        try writeRollout(root, name: "a", lines: lines, mtime: now.addingTimeInterval(-600))
        let client = CodexUsageClient(root: root)

        let first = client.backfillEvents(after: cutoff, now: now)
        XCTAssertEqual(first.count, 2)
        // Second poll uses the newest seen as the new cutoff: nothing is newer.
        let newest = try XCTUnwrap(first.last?.timestamp)
        let second = client.backfillEvents(after: newest, now: now)
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - Decimator (pure, via AppDelegate.decimateCodex)

    private func event(_ secs: Double, five: Double? = 10, week: Double? = 5,
                       fiveReset: Date? = nil) -> CodexUsageClient.Event {
        CodexUsageClient.Event(timestamp: Date(timeIntervalSince1970: 1_783_800_000 + secs),
                               primaryPercent: five, secondaryPercent: week,
                               primaryResetsAt: fiveReset, secondaryResetsAt: nil)
    }

    func testDecimatorEnforcesMinimumSpacing() {
        let evs = [event(0), event(5), event(120), event(240), event(300), event(480)]
        let kept = AppDelegate.decimateCodex(events: evs, lastKept: .distantPast, minGap: 240)
        let offsets = kept.map { $0.t.timeIntervalSince1970 - 1_783_800_000 }
        XCTAssertEqual(offsets, [0, 240, 480])
        for i in 1..<kept.count {
            XCTAssertGreaterThanOrEqual(kept[i].t.timeIntervalSince(kept[i - 1].t), 240)
        }
    }

    func testDecimatorSeedSuppressesEventsTooCloseToLastStored() {
        // Seeded 100 s before the first event: it is dropped (< 240 s after lastKept),
        // and only the event 300 s later survives.
        let lastKept = Date(timeIntervalSince1970: 1_783_800_000 - 100)
        let kept = AppDelegate.decimateCodex(events: [event(0), event(300)],
                                             lastKept: lastKept, minGap: 240)
        XCTAssertEqual(kept.map { $0.t.timeIntervalSince1970 - 1_783_800_000 }, [300])
    }

    func testDecimatorKeepsEventExactlyAtBoundary() {
        // The spacing gate is `timestamp >= lastKept + minGap`: an event sitting EXACTLY
        // minGap after the seed is on the boundary and must be KEPT, pinning the `>=`
        // against a regression to a strict `>`.
        let lastKept = Date(timeIntervalSince1970: 1_783_800_000)
        let kept = AppDelegate.decimateCodex(events: [event(240)], lastKept: lastKept, minGap: 240)
        XCTAssertEqual(kept.map { $0.t.timeIntervalSince1970 - 1_783_800_000 }, [240])
    }

    func testDecimatorPassesValuesThroughAcrossAReset() {
        // A window reset between two kept samples: 90% then 5%. No rise math here, so
        // both values pass through untouched (the negative "rise" is a downstream
        // concern the decimator must not pre-empt).
        let r1 = Date(timeIntervalSince1970: 1_783_790_640)
        let evs = [event(0, five: 90, fiveReset: r1), event(300, five: 5, fiveReset: r1.addingTimeInterval(18000))]
        let kept = AppDelegate.decimateCodex(events: evs, lastKept: .distantPast, minGap: 240)
        XCTAssertEqual(kept.map { $0.five }, [90, 5])
        XCTAssertEqual(kept.first?.fiveResetsAt, r1)
    }

    // MARK: - Stray-anchor defense: snapshot vote (fixture-driven)

    func testStrayAsNewestCorrectedByVote() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let base = now.addingTimeInterval(-1200)
        let realAnchor = 1_783_790_640
        let strayAnchor = realAnchor + 18_000       // shifted by ~5 h: the exec-stray signature
        // Five events on the real anchor, then a stray as the FINAL (newest) event:
        // tiny percentage on the shifted anchor. Pre-defense, the stray would have
        // been the snapshot; the vote must pick the newest REAL-anchor event.
        var lines: [String] = []
        for i in 0..<5 {
            lines.append(tokenCount(ts: iso(base.addingTimeInterval(Double(i) * 60)),
                                    rateLimits: rateLimits(primary: window(
                                        used: Double(50 + i), minutes: 300, resets: realAnchor))))
        }
        lines.append(tokenCount(ts: iso(base.addingTimeInterval(300)),
                                rateLimits: rateLimits(primary: window(
                                    used: 6, minutes: 300, resets: strayAnchor))))
        try writeRollout(root, name: "a", lines: lines, mtime: now.addingTimeInterval(-600))

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch(now: now).snapshot)
        XCTAssertEqual(snap.primary?.utilization, 54)   // newest real-anchor event, not the 6% stray
        XCTAssertEqual(snap.primary?.resetsAt, Date(timeIntervalSince1970: TimeInterval(realAnchor)))
        guard case let .observed(obs) = snap.freshness else { return XCTFail("expected .observed") }
        XCTAssertEqual(obs, base.addingTimeInterval(240))
    }

    func testQuietAccountVoteDegradesToNewestWins() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let newTs = now.addingTimeInterval(-600)
        let oldTs = newTs.addingTimeInterval(-1200)     // 20 min earlier: outside the neighborhood
        // A quiet account: one lone event in the 15-min neighborhood. The older event
        // (different anchor) is out of the window, so the newest simply wins, exactly
        // the pre-defense behavior; no false "correction" from stale majorities.
        let lines = [
            tokenCount(ts: iso(oldTs), rateLimits: rateLimits(primary: window(
                used: 80, minutes: 300, resets: 1_783_790_640))),
            tokenCount(ts: iso(newTs), rateLimits: rateLimits(primary: window(
                used: 3, minutes: 300, resets: 1_783_808_640))),
        ]
        try writeRollout(root, name: "a", lines: lines, mtime: now.addingTimeInterval(-300))

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch(now: now).snapshot)
        XCTAssertEqual(snap.primary?.utilization, 3)    // neighborhood of one: newest wins
    }

    func testVotePoolNotStarvedByOneStrayHeavyFile() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let realAnchor = 1_783_790_640
        let strayAnchor = realAnchor + 18_000            // shifted ~5 h: the exec-stray signature
        let newestStray = now.addingTimeInterval(-300)   // the hit event; anchors the 15-min window

        // A stray-heavy exec file: 13 in-window token_counts, ALL on the stray anchor,
        // holding the NEWEST mtime so it is the hit file. Under the OLD file-by-file
        // fill this one file alone would pack all 12 vote slots and confirm its own
        // stray; the sort-then-prefix pool must instead survey the whole neighborhood.
        var strayLines: [String] = []
        for k in stride(from: 12, through: 0, by: -1) {          // ascending in file: the EOF line is newest
            strayLines.append(tokenCount(ts: iso(newestStray.addingTimeInterval(-30 * Double(k))),
                                         rateLimits: rateLimits(primary: window(
                                             used: 5, minutes: 300, resets: strayAnchor))))
        }
        try writeRollout(root, name: "stray", lines: strayLines, mtime: now)

        // A normal file: FEWER events (7) but the NEWEST in the window, all on the real
        // anchor. Its mtime is older (so the stray file stays the hit), but its events
        // are newer in EVENT time, so after the cross-file sort they take the top 7 of
        // the 12 seats and win the majority (7 real vs 5 stray).
        var normalLines: [String] = []
        for i in 0..<7 {
            normalLines.append(tokenCount(ts: iso(newestStray.addingTimeInterval(30 * Double(i + 1))),
                                          rateLimits: rateLimits(primary: window(
                                              used: Double(50 + i), minutes: 300, resets: realAnchor))))
        }
        try writeRollout(root, name: "normal", lines: normalLines, mtime: now.addingTimeInterval(-60))

        let snap = try XCTUnwrap(CodexUsageClient(root: root).fetch(now: now).snapshot)
        XCTAssertEqual(snap.primary?.resetsAt, Date(timeIntervalSince1970: TimeInterval(realAnchor)))
        XCTAssertEqual(snap.primary?.utilization, 56)   // newest real-anchor event, not a 5% stray
    }

    // MARK: - Stray-anchor defense: vote (pure)

    func testVoteRolloverInProgressPicksMajorityOldAnchor() {
        // A rollover just happened: 1 new-anchor event (newest) vs 11 still on the old
        // anchor. The vote lags one neighborhood behind and picks the newest OLD-anchor
        // event; the old window then renders as inferred zero via effectiveUtilization
        // (tested separately), which is honest.
        let old = Date(timeIntervalSince1970: 1_783_790_640)
        let new = old.addingTimeInterval(18_000)
        var evs: [CodexUsageClient.Event] = []
        for i in 0..<11 { evs.append(event(Double(i) * 30, five: Double(40 + i), fiveReset: old)) }
        evs.append(event(11 * 30, five: 1, fiveReset: new))
        XCTAssertEqual(CodexUsageClient.voteWinnerIndex(evs), 10)
    }

    func testVoteTieKeepsNewestEvent() {
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let evs = [event(0, fiveReset: a), event(60, fiveReset: a.addingTimeInterval(18_000))]
        XCTAssertEqual(CodexUsageClient.voteWinnerIndex(evs), 1)   // 1 vs 1: newest wins
    }

    func testVoteJitteredAnchorsAreOneAnchor() {
        // Two events on the same logical anchor 26 s apart (observed server jitter)
        // plus a newer stray: the jittered pair must cluster as ONE anchor (2 votes)
        // and beat the stray; the winner is the pair's newest member.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let evs = [event(0, fiveReset: a),
                   event(30, fiveReset: a.addingTimeInterval(26)),
                   event(60, five: 2, fiveReset: a.addingTimeInterval(18_000))]
        XCTAssertEqual(CodexUsageClient.voteWinnerIndex(evs), 1)
    }

    // MARK: - Stray-anchor defense: ingest stray-run filter (pure)

    func testSandwichDropsIsolatedStray() {
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let evs = [event(0, fiveReset: a), event(60, five: 3, fiveReset: s), event(120, fiveReset: a)]
        let out = CodexUsageClient.filterStrays(evs)
        XCTAssertEqual(out.map { $0.primaryPercent }, [10, 10])    // the 3% stray is gone
    }

    func testSandwichKeepsPersistentAnchorChange() {
        // A genuine rollover: the anchor changes and STAYS changed. No event sits
        // between two agreeing neighbors, so nothing is dropped.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let b = a.addingTimeInterval(18_000)
        let evs = [event(0, fiveReset: a), event(60, fiveReset: a),
                   event(120, five: 1, fiveReset: b), event(180, five: 2, fiveReset: b)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).count, 4)
    }

    func testSandwichKeepsBatchEdges() {
        // A stray-looking anchor at either batch edge has only one neighbor: not
        // enough evidence, keep it.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let leading = [event(0, five: 3, fiveReset: s), event(60, fiveReset: a), event(120, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(leading).count, 3)
        let trailing = [event(0, fiveReset: a), event(60, fiveReset: a), event(120, five: 3, fiveReset: s)]
        XCTAssertEqual(CodexUsageClient.filterStrays(trailing).count, 3)
    }

    func testSandwichJitterWithinToleranceIsNotAStray() {
        // 26 s of resets_at jitter between an event and its neighbors is the same
        // anchor, never a sandwich drop.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let evs = [event(0, fiveReset: a),
                   event(60, fiveReset: a.addingTimeInterval(26)),
                   event(120, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).count, 3)
    }

    func testSandwichKeepsNilAnchorEvent() {
        // No primary anchor: unjudgeable, kept (nil never matches anything).
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let evs = [event(0, fiveReset: a), event(60, five: nil, fiveReset: nil), event(120, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).count, 3)
    }

    func testStrayRunAASSADropsBothStrays() {
        // A,A,S,S,A: a CONSECUTIVE PAIR of exec strays inside a real-anchor span whose
        // cluster is strictly in the majority (3 real events vs 2 strays). A population
        // tie NEVER convicts (see testStrayRunTieNeverConvicts), so the contract case
        // carries a strict majority: both strays go, every real event stays.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let evs = [event(0, fiveReset: a), event(60, fiveReset: a),
                   event(120, five: 3, fiveReset: s), event(180, five: 4, fiveReset: s),
                   event(240, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).map { $0.primaryPercent }, [10, 10, 10])
    }

    func testStrayRunKeptWhenBoundingRunsDisagree() {
        // A,S,S,B: the bounding runs carry DIFFERENT anchors (a vs b), so they do not
        // agree with each other and cannot convict the middle run. All four are kept:
        // this shape is two back-to-back rollovers, not a stray sandwich.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let b = a.addingTimeInterval(36_000)
        let evs = [event(0, fiveReset: a), event(60, five: 3, fiveReset: s),
                   event(120, five: 4, fiveReset: s), event(180, five: 1, fiveReset: b)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).count, 4)
    }

    func testStrayRunTieNeverConvicts() {
        // A,S,S,A: 2 real events vs 2 strays is a POPULATION TIE. A tie is not
        // evidence, and the costs are asymmetric (a false keep is cheap, the vote and
        // decimator still stand; a false drop deletes real history), so the strict-<
        // rule convicts nothing and all four events are kept.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let evs = [event(0, fiveReset: a), event(60, five: 3, fiveReset: s),
                   event(120, five: 4, fiveReset: s), event(180, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).count, 4)
    }

    func testStrayRunsDifferingAnchorsBothDropped() {
        // A,S1,S2,A: two back-to-back strays on DIFFERENT ephemeral anchors, further
        // than the tolerance apart. The old bounded-run rule kept them (neither stray
        // was flanked by agreeing runs); the span rule convicts each on population:
        // the enclosing real cluster (2 events) strictly outweighs each singleton (1).
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s1 = a.addingTimeInterval(18_000)
        let s2 = a.addingTimeInterval(36_000)
        let evs = [event(0, fiveReset: a), event(60, five: 3, fiveReset: s1),
                   event(120, five: 4, fiveReset: s2), event(180, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).map { $0.primaryPercent }, [10, 10])
    }

    func testNilAnchorInsideConvictedSpanSurvives() {
        // A,S,nil,S,A,A (populations: real 3, stray 2): both stray runs inside the real
        // span are convicted, but the nil-anchor event between them is unjudgeable and
        // survives. Nil runs are never dropped, yet they sit inside the span
        // transparently: they do not shield the strays around them.
        let a = Date(timeIntervalSince1970: 1_783_790_640)
        let s = a.addingTimeInterval(18_000)
        let evs = [event(0, fiveReset: a), event(60, five: 3, fiveReset: s),
                   event(120, five: nil, fiveReset: nil), event(180, five: 4, fiveReset: s),
                   event(240, fiveReset: a), event(300, fiveReset: a)]
        XCTAssertEqual(CodexUsageClient.filterStrays(evs).map { $0.primaryPercent },
                       [10, nil, 10, 10])
    }

    func testInterleavedSparseStraysDoNotConvictRealRuns() {
        // The 2026-07-12 falsification regression: one long-lived exec session dripping
        // stray SINGLETONS (one shared ephemeral anchor) through hours of heavy real
        // traffic: R,R,R,S,R,R,R,S,R,R,R. The rev 5 bounded-run rule read every middle
        // REAL run as "bounded by agreeing stray runs" and convicted it (on live data:
        // 155 of 173 real events dropped), so this test MUST FAIL against that rule.
        // Population decides instead: the real cluster holds 9 events vs the strays' 2,
        // so only the strays drop and all nine real events survive.
        let r = Date(timeIntervalSince1970: 1_783_790_640)
        let s = r.addingTimeInterval(18_000)
        var evs: [CodexUsageClient.Event] = []
        for i in 0..<11 {
            let isStray = (i == 3 || i == 7)
            evs.append(event(Double(i) * 60,
                             five: isStray ? 3 : Double(40 + i),
                             fiveReset: isStray ? s : r))
        }
        let out = CodexUsageClient.filterStrays(evs)
        XCTAssertEqual(out.count, 9)
        XCTAssertTrue(out.allSatisfy { $0.primaryResetsAt == r })
    }

    // MARK: - lineTimestamp hardening

    func testLineTimestampRequiresTopLevelPrefix() {
        // A proper rollout line (timestamp is the first key) parses.
        let proper = Data(#"{"timestamp":"2026-07-11T12:00:00.000Z","type":"event_msg"}"#.utf8)
        XCTAssertEqual(CodexUsageClient.lineTimestamp(proper), ISO.parse("2026-07-11T12:00:00.000Z"))
        // A content line embedding a nested "timestamp" key mid-line must NOT be
        // trusted: rollout logs quote JSON about this very schema.
        let embedded = Data(#"{"type":"response_item","payload":{"item":{"timestamp":"2020-01-01T00:00:00Z","note":"nested"}}}"#.utf8)
        XCTAssertNil(CodexUsageClient.lineTimestamp(embedded))
    }

    func testBackfillEmbeddedOldTimestampDoesNotStopScan() throws {
        let root = codexRoot()
        let now = Date(timeIntervalSince1970: 1_783_800_000)
        let cutoff = now.addingTimeInterval(-6 * 3600)
        // Oldest -> newest: a token_count, then a content line whose nested JSON
        // carries an ANCIENT timestamp (2020) mid-line, then a newer token_count.
        // With first-occurrence matching the 2020 timestamp would read as "at or
        // below the cutoff" and stop the walk before the older token_count; the
        // prefix check must let the gate step over it.
        let lines = [
            tokenCount(ts: iso(now.addingTimeInterval(-3600)),
                       rateLimits: rateLimits(primary: window(used: 10, minutes: 300, resets: 1_783_790_640))),
            #"{"type":"response_item","payload":{"item":{"timestamp":"2020-01-01T00:00:00Z","note":"quoted schema"}}}"#,
            tokenCount(ts: iso(now.addingTimeInterval(-1800)),
                       rateLimits: rateLimits(primary: window(used: 20, minutes: 300, resets: 1_783_790_640))),
        ]
        try writeRollout(root, name: "a", lines: lines, mtime: now.addingTimeInterval(-600))

        let events = CodexUsageClient(root: root).backfillEvents(after: cutoff, now: now)
        XCTAssertEqual(events.map { $0.primaryPercent }, [10, 20])   // both survived the walk
    }
}
