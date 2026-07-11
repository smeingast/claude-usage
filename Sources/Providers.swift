import Foundation

// Provider-generic usage models. Package 1 introduces these as a seam ONLY: the
// live app still fetches Claude, adapts its `UsageSnapshot` into a
// `ProviderUsageSnapshot` here, and renders byte-for-byte what it did before. A
// second provider (Codex) fills the Codex-flavored fields in later packages. Kept
// dependency-free (Foundation only) and `Sendable` so they cross the actor
// boundary between the detached fetch and the @MainActor UI exactly like the
// Claude types they wrap.

/// Which backing tool a snapshot describes. `String`-backed so it can key
/// persisted settings and window ids without a separate mapping.
enum UsageProviderKind: String, CaseIterable, Sendable {
    case claude, codex
}

/// One rate-limit window, provider-agnostic. The Claude adapter fills these from
/// the five-hour / weekly / weekly-Opus / weekly-Sonnet API windows; Codex fills
/// them from `token_count` events. `title`/`windowMinutes` are carried for the
/// data-driven labels later packages render, and are inert in package 1 (no
/// consumer reads them yet).
struct UsageWindow: Sendable {
    var id: String               // "primary" / "secondary" / "opus" / "sonnet" / …
    var title: String            // data-driven label, e.g. "5-hour" / "Weekly"
    var utilization: Double      // percent, as observed (may exceed 100)
    var windowMinutes: Int?      // 300 = 5-hour, 10080 = weekly; nil if unknown
    var resetsAt: Date?
}

/// How trustworthy a snapshot's numbers are right now. Claude snapshots are always
/// `.live` (a server round-trip completed this instant); Codex snapshots are
/// `.observed(eventTime)` and derive their displayed value from that event time
/// and the window reset at render time (see `effectiveUtilization`).
enum SnapshotFreshness: Sendable {
    case live                    // fetched from the API just now
    case observed(Date)          // reconstructed from a local event at this time
}

/// A full utilization snapshot in provider-generic form. `primary`/`secondary`
/// are the two headline windows (Claude: five-hour / weekly); `extras` carries any
/// additional per-model windows (Claude: Opus then Sonnet weekly, ids "opus" /
/// "sonnet"; Codex: empty). `fetchedAt` is the poll wall-clock, used for throttles
/// and the "Updated HH:MM" line only, never for freshness inference.
struct ProviderUsageSnapshot: Sendable {
    var provider: UsageProviderKind
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var extras: [UsageWindow]
    var freshness: SnapshotFreshness
    var fetchedAt: Date
    var planType: String?        // Codex "plus" / "pro"; nil for Claude
}

extension ProviderUsageSnapshot {
    /// The extra window with this id, or nil. Claude uses "opus" / "sonnet".
    func extra(_ id: String) -> UsageWindow? { extras.first { $0.id == id } }
}

/// A live/recent session in provider-generic form: a superset of Claude's
/// `SessionInfo`. `pid` is Claude-registry only (nil for Codex, which has no
/// registry); `contextWindow` is stored (Codex reports it per event) rather than
/// derived; `sourceTag` records the Codex origin ("cli" / "exec") and is nil for
/// Claude. Defined here; first consumed by the Codex sessions work in a later
/// package.
struct ProviderSessionInfo: Sendable {
    var provider: UsageProviderKind
    var pid: Int32?              // Claude registry only; nil for Codex
    var sessionId: String
    var cwd: String
    var status: String           // "busy" / "idle" / "active" / "recent"
    var model: String?
    var contextTokens: Int?      // Codex: last_token_usage.total_tokens
    var contextWindow: Int?      // Codex: info.model_context_window
    var updatedAt: Date?         // newest event timestamp (UTC), or file mtime
    var sourceTag: String?       // Codex "cli" / "exec"; nil for Claude
}

/// Outcome of a Codex usage poll. Codex has no auth taxonomy (it is read-only
/// local file I/O), so its failure modes are DATA states, not error states:
/// `.notInstalled` (no `~/.codex`), `.noData` (installed but no usable event in
/// bounds), `.ok` (a snapshot was reconstructed). Defined here; produced by the
/// Codex data layer in a later package.
struct CodexUsageResult: Sendable {
    enum Status: Sendable { case ok, noData, notInstalled }
    var status: Status
    var snapshot: ProviderUsageSnapshot?
}

/// Result of a Codex sessions scan: the rows plus a count of today's `exec` runs
/// (summarized as a single row rather than listed). Defined here; produced by the
/// Codex sessions layer in a later package.
struct CodexSessionsSnapshot: Sendable {
    var rows: [ProviderSessionInfo]
    var execRunsToday: Int
}

/// The value the UI should show for a window right now, and whether it was
/// INFERRED to have rolled over. For `.live` snapshots the observed value always
/// stands (a server round-trip is ground truth, even just past a reset). For
/// `.observed` snapshots (point-in-time, no fresh event since): once `now` is at
/// or past the window's `resetsAt`, the window has rolled and the honest value is
/// 0, flagged so the UI can annotate it (a dashed ring) rather than assert a value
/// the account no longer holds. A window with no `resetsAt` cannot be judged
/// rolled over, so it passes through.
func effectiveUtilization(_ w: UsageWindow, freshness: SnapshotFreshness,
                          now: Date) -> (value: Double, inferredZero: Bool) {
    switch freshness {
    case .live:
        return (w.utilization, false)
    case .observed:
        if let reset = w.resetsAt, reset <= now { return (0, true) }
        return (w.utilization, false)
    }
}

// MARK: - Claude adapter

extension ProviderUsageSnapshot {
    /// Adapt Claude's `UsageSnapshot` into the provider-generic shape WITHOUT
    /// changing what any consumer renders. The compatibility contract, relied on
    /// by the golden tests and every downstream reader:
    ///
    /// - field PRESENCE is preserved exactly: `fiveHour` → `primary`,
    ///   `sevenDay` → `secondary`, `sevenDayOpus`/`sevenDaySonnet` → `extras` in
    ///   that order with ids "opus" / "sonnet". A nil window stays nil (an absent
    ///   extra is simply omitted); nothing is coerced to 0.
    /// - `utilization` and `resetsAt` are copied through unchanged.
    /// - `fetchedAt` is passed through (drives the "Updated HH:MM" line).
    /// - Claude is always `.live`, provider `.claude`, and has no `planType`.
    ///
    /// `title`/`windowMinutes` are the honest known constants for these windows
    /// (five-hour = 300, weekly = 10080). No package-1 consumer reads them; they
    /// exist for the data-driven labels later packages will render.
    init(claude s: UsageSnapshot) {
        func map(_ w: LimitWindow?, id: String, title: String, minutes: Int) -> UsageWindow? {
            guard let w else { return nil }
            return UsageWindow(id: id, title: title, utilization: w.utilization,
                               windowMinutes: minutes, resetsAt: w.resetsAt)
        }
        let opus = map(s.sevenDayOpus, id: "opus", title: "Weekly · Opus", minutes: 10080)
        let sonnet = map(s.sevenDaySonnet, id: "sonnet", title: "Weekly · Sonnet", minutes: 10080)
        self.init(
            provider: .claude,
            primary: map(s.fiveHour, id: "primary", title: "5-hour", minutes: 300),
            secondary: map(s.sevenDay, id: "secondary", title: "Weekly", minutes: 10080),
            extras: [opus, sonnet].compactMap { $0 },
            freshness: .live,
            fetchedAt: s.fetchedAt,
            planType: nil)
    }
}
