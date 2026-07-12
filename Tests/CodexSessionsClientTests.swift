import XCTest
@testable import ClaudeUsageCore

/// The Codex sessions layer: cli/exec filtering, the context-field choice
/// (`last_token_usage.total_tokens`, never `total_token_usage`), the active/recent
/// boundary driven by an injected clock and process check, the path-keyed header
/// cache (complete entries never re-read, incomplete entries re-read until complete),
/// and the exec-runs-today local-day boundary. All fixtures are synthetic rollout
/// trees under a scratch dir; no real `~/.codex` data is read.
final class CodexSessionsClientTests: ScratchTestCase {

    // MARK: - Fixture builders

    private func codexRoot() -> URL { dir.appendingPathComponent(".codex", isDirectory: true) }

    /// A deterministic "now" pinned to local noon of the current day, so the
    /// today/yesterday date-dir walk has a full 12 h margin on each side (no
    /// midnight-boundary flakiness) regardless of the machine's time zone.
    private func localNoon() -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: Date()))!
    }

    /// The `sessions/YYYY/MM/DD` component for a date, in the machine's LOCAL time zone
    /// exactly as the client computes it, so a file written for a given mtime lands in
    /// the dir the client will walk.
    private func dayDir(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy/MM/dd"
        return f.string(from: date)
    }

    /// Write one rollout file into the date dir implied by its LOCAL mtime, with the
    /// given lines and mtime. Returns the file URL (stable across rewrites, so the
    /// header-cache tests can rewrite in place).
    @discardableResult
    private func writeRollout(_ root: URL, name: String, lines: [String], mtime: Date) throws -> URL {
        let day = root.appendingPathComponent("sessions/\(dayDir(for: mtime))", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent("rollout-\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func sessionMeta(id: String, cwd: String, source: String,
                             provider: String = "openai") -> String {
        #"{"timestamp":"2026-07-11T12:00:00.000Z","type":"session_meta","payload":{"session_id":"\#(id)","cwd":"\#(cwd)","source":"\#(source)","model_provider":"\#(provider)"}}"#
    }

    private func turnContext(model: String) -> String {
        #"{"timestamp":"2026-07-11T12:00:01.000Z","type":"turn_context","payload":{"model":"\#(model)","effort":"high","cwd":"/x"}}"#
    }

    /// An `event_msg`/`token_count` line. `lastTotal` fills
    /// `info.last_token_usage.total_tokens` (the context number); `totalUsage` fills the
    /// cumulative `info.total_token_usage.total_tokens` that must NEVER be used.
    private func tokenCount(lastTotal: Int?, window: Int?, totalUsage: Int? = nil) -> String {
        var info: [String] = []
        if let w = window { info.append("\"model_context_window\":\(w)") }
        if let lt = lastTotal { info.append("\"last_token_usage\":{\"input_tokens\":1,\"total_tokens\":\(lt)}") }
        if let tu = totalUsage { info.append("\"total_token_usage\":{\"total_tokens\":\(tu)}") }
        let infoStr = "{" + info.joined(separator: ",") + "}"
        return #"{"timestamp":"2026-07-11T12:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":\#(infoStr),"rate_limits":null}}"#
    }

    /// A complete interactive (cli) rollout: session_meta + turn_context + a token_count.
    private func cliFile(id: String = "S1", cwd: String = "/Users/x/proj", model: String = "gpt-5.5",
                         lastTotal: Int? = 1000, window: Int? = 258400, totalUsage: Int? = nil) -> [String] {
        [sessionMeta(id: id, cwd: cwd, source: "cli"),
         turnContext(model: model),
         tokenCount(lastTotal: lastTotal, window: window, totalUsage: totalUsage)]
    }

    private func execFile(id: String) -> [String] {
        [sessionMeta(id: id, cwd: "/agent/worktree", source: "exec"),
         turnContext(model: "gpt-5.5"),
         tokenCount(lastTotal: 200, window: 258400)]
    }

    // MARK: - cli/exec filtering

    func testOnlyCliFilesBecomeRowsExecFeedsCount() throws {
        let root = codexRoot()
        let now = localNoon()
        try writeRollout(root, name: "cli-old", lines: cliFile(id: "A", cwd: "/Users/x/alpha"),
                         mtime: now.addingTimeInterval(-600))
        try writeRollout(root, name: "cli-new", lines: cliFile(id: "B", cwd: "/Users/x/beta"),
                         mtime: now.addingTimeInterval(-60))
        try writeRollout(root, name: "exec-1", lines: execFile(id: "E1"), mtime: now.addingTimeInterval(-120))
        try writeRollout(root, name: "exec-2", lines: execFile(id: "E2"), mtime: now.addingTimeInterval(-200))

        let snap = CodexSessionsClient(root: root, processAlive: { false }).fetch(now: now)
        // Only cli files are rows, newest mtime first.
        XCTAssertEqual(snap.rows.map { $0.sessionId }, ["B", "A"])
        XCTAssertTrue(snap.rows.allSatisfy { $0.sourceTag == "cli" && $0.provider == .codex && $0.pid == nil })
        XCTAssertEqual(snap.rows.first?.cwd, "/Users/x/beta")
        XCTAssertEqual(snap.execRunsToday, 2)
    }

    // MARK: - Context field choice

    func testContextUsesLastTokenUsageNotTotalTokenUsage() throws {
        let root = codexRoot()
        let now = localNoon()
        // last_token_usage (147971) and total_token_usage (2636875) DISAGREE; the row
        // must carry the per-turn last_token_usage number, not the cumulative total.
        try writeRollout(root, name: "c",
                         lines: cliFile(id: "C", lastTotal: 147971, window: 258400, totalUsage: 2636875),
                         mtime: now.addingTimeInterval(-30))
        let snap = CodexSessionsClient(root: root, processAlive: { true }).fetch(now: now)
        let row = try XCTUnwrap(snap.rows.first)
        XCTAssertEqual(row.contextTokens, 147971)
        XCTAssertEqual(row.contextWindow, 258400)
    }

    // MARK: - Active / recent boundary

    func testActiveRequiresAliveAndFreshMtime() throws {
        let root = codexRoot()
        let now = localNoon()
        try writeRollout(root, name: "s", lines: cliFile(id: "S"), mtime: now.addingTimeInterval(-60))
        let snap = CodexSessionsClient(root: root, processAlive: { true }).fetch(now: now)
        XCTAssertEqual(snap.rows.first?.status, "active")
    }

    func testActiveBoundaryExactlyTwoMinutesIsActive() throws {
        let root = codexRoot()
        let now = localNoon()
        // mtime EXACTLY 2 min old: the `<= 2 min` gate is inclusive, so still active.
        try writeRollout(root, name: "s", lines: cliFile(id: "S"), mtime: now.addingTimeInterval(-120))
        let snap = CodexSessionsClient(root: root, processAlive: { true }).fetch(now: now)
        XCTAssertEqual(snap.rows.first?.status, "active")
    }

    func testJustOverTwoMinutesIsRecent() throws {
        let root = codexRoot()
        let now = localNoon()
        try writeRollout(root, name: "s", lines: cliFile(id: "S"), mtime: now.addingTimeInterval(-121))
        let snap = CodexSessionsClient(root: root, processAlive: { true }).fetch(now: now)
        XCTAssertEqual(snap.rows.first?.status, "recent")
    }

    func testDeadProcessIsRecentEvenWithFreshMtime() throws {
        let root = codexRoot()
        let now = localNoon()
        // Maximally fresh mtime, but no codex process alive: liveness gates the tag.
        try writeRollout(root, name: "s", lines: cliFile(id: "S"), mtime: now)
        let snap = CodexSessionsClient(root: root, processAlive: { false }).fetch(now: now)
        XCTAssertEqual(snap.rows.first?.status, "recent")
    }

    // MARK: - Header cache

    func testCompleteHeaderNeverReRead() throws {
        let root = codexRoot()
        let now = localNoon()
        let client = CodexSessionsClient(root: root, processAlive: { false })
        let path = try writeRollout(root, name: "h",
                                    lines: cliFile(id: "ORIG", cwd: "/Users/x/orig", model: "gpt-5.5"),
                                    mtime: now.addingTimeInterval(-60))

        let first = client.fetch(now: now)
        XCTAssertEqual(first.rows.first?.sessionId, "ORIG")
        XCTAssertEqual(first.rows.first?.model, "gpt-5.5")

        // Rewrite the header lines with DIFFERENT values (still a valid cli file). A
        // complete cached header must be served as-is, ignoring the rewritten values.
        let changed = cliFile(id: "CHANGED", cwd: "/Users/x/changed", model: "gpt-9")
        try Data((changed.joined(separator: "\n") + "\n").utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)],
                                              ofItemAtPath: path.path)

        let second = client.fetch(now: now)
        XCTAssertEqual(second.rows.first?.sessionId, "ORIG")     // original header retained
        XCTAssertEqual(second.rows.first?.model, "gpt-5.5")
        XCTAssertEqual(second.rows.first?.cwd, "/Users/x/orig")
    }

    func testIncompleteHeaderReReadUntilComplete() throws {
        let root = codexRoot()
        let now = localNoon()
        let client = CodexSessionsClient(root: root, processAlive: { false })
        // First write: session_meta (cli) + a token_count, but NO turn_context yet.
        let path = try writeRollout(root, name: "i",
                                    lines: [sessionMeta(id: "J", cwd: "/Users/x/j", source: "cli"),
                                            tokenCount(lastTotal: 500, window: 258400)],
                                    mtime: now.addingTimeInterval(-120))

        let first = client.fetch(now: now)
        let r1 = try XCTUnwrap(first.rows.first)
        XCTAssertEqual(r1.sessionId, "J")
        XCTAssertNil(r1.model)                    // incomplete: model not written yet
        XCTAssertEqual(r1.contextTokens, 500)

        // Append the turn_context: the header now completes.
        try Data(([sessionMeta(id: "J", cwd: "/Users/x/j", source: "cli"),
                   turnContext(model: "gpt-5.5"),
                   tokenCount(lastTotal: 700, window: 258400)].joined(separator: "\n") + "\n").utf8)
            .write(to: path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)],
                                              ofItemAtPath: path.path)

        let second = client.fetch(now: now)
        let r2 = try XCTUnwrap(second.rows.first)
        XCTAssertEqual(r2.model, "gpt-5.5")       // incomplete header was re-read and completed
        XCTAssertEqual(r2.contextTokens, 700)     // context is always re-scanned fresh
    }

    // MARK: - exec-runs-today boundary

    func testExecYesterdayDoesNotCountTowardToday() throws {
        let root = codexRoot()
        let now = localNoon()
        try writeRollout(root, name: "exec-today", lines: execFile(id: "T"),
                         mtime: now.addingTimeInterval(-60))
        // Yesterday evening: within 24 h (so it IS a candidate) but before local
        // midnight, so it must not count toward today.
        try writeRollout(root, name: "exec-yday", lines: execFile(id: "Y"),
                         mtime: now.addingTimeInterval(-18 * 3600))
        // A yesterday cli file proves the candidate walk really reaches yesterday's dir.
        try writeRollout(root, name: "cli-yday", lines: cliFile(id: "CY", cwd: "/Users/x/y"),
                         mtime: now.addingTimeInterval(-20 * 3600))

        let snap = CodexSessionsClient(root: root, processAlive: { false }).fetch(now: now)
        XCTAssertEqual(snap.execRunsToday, 1)               // only today's exec counts
        XCTAssertEqual(snap.rows.map { $0.sessionId }, ["CY"])  // yesterday's cli IS a candidate row
    }

    // MARK: - Head read past 8 KB (real-data guard)

    func testLargeSessionMetaHeaderStillParses() throws {
        let root = codexRoot()
        let now = localNoon()
        // Real session_meta inlines a ~20 KB base_instructions blob, pushing its
        // terminated line and the following turn_context well past any 8 KB head; the
        // header read must still capture both. This pins the head cap above 8 KB.
        let padding = String(repeating: "x", count: 20_000)
        let bigMeta = #"{"timestamp":"2026-07-11T12:00:00.000Z","type":"session_meta","payload":{"session_id":"BIG","cwd":"/Users/x/big","source":"cli","model_provider":"openai","base_instructions":{"text":"\#(padding)"}}}"#
        try writeRollout(root, name: "big",
                         lines: [bigMeta, turnContext(model: "gpt-5.5"), tokenCount(lastTotal: 1234, window: 258400)],
                         mtime: now.addingTimeInterval(-30))

        let snap = CodexSessionsClient(root: root, processAlive: { true }).fetch(now: now)
        let row = try XCTUnwrap(snap.rows.first)
        XCTAssertEqual(row.sessionId, "BIG")
        XCTAssertEqual(row.model, "gpt-5.5")      // turn_context past the 8 KB mark was read
        XCTAssertEqual(row.contextTokens, 1234)
    }
}
