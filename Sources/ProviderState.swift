import Foundation

// Per-provider UI state derivation, kept PURE and nonisolated so the two-provider
// panel/pip/status copy is driven by tested functions, not by ad-hoc branching in
// the render methods. AppDelegate computes a `ClaudeDerived` / `CodexDerived` on
// each render and hands the fields straight to the views; every copy string,
// severity, freshness annotation, and inferred-ring flag originates here.
//
// The design source is `design/codex-support/handoff/` (the interactive concept's
// deriveClaude / deriveCodex) as amended by `handoff-amendments.md`. Copy strings
// are reproduced VERBATIM from the concept (they are user-facing product copy, and
// whatever punctuation they carry is intentional); the amendments overrule the
// concept where they conflict, most notably: freshness uses <= 5 min (amendment 2),
// the pip/dot severity follows amendment 5, inferred-zero is per-window and dashes
// only the rolled ring (amendment 9), and the Codex forecast gate is age-based, not
// process-liveness-based (amendment 2).

/// Which chain state a provider resolved to. The two providers share the tail
/// (red/pace/watch/normal) but head differently: Claude carries auth/staleness,
/// Codex carries install/log-truth states. `fresh`/`aged` is an orthogonal Codex
/// annotation carried on `CodexDerived`, not a chain member.
enum ClaudeStateKind: Equatable { case signedOut, stale, red, pace, watch, normal }
enum CodexStateKind: Equatable { case notInstalled, noData, inferredZero, red, pace, watch, normal }

/// The resolved Claude instrument state: the banner copy, the tag-row age line, the
/// red flag, and the corner-pip severity used when Claude is the secondary (pip)
/// provider. Only produced/consumed in two-provider mode; the Claude-only path is
/// the literal v0.8 panel (amendment 7) and never touches this.
struct ClaudeDerived {
    var kind: ClaudeStateKind
    var ageLine: String          // "Updated HH:MM" / "Updated 3m ago" / "Not signed in"
    var ageWarn: Bool            // amber age (stale)
    var msg: String              // honesty-banner copy
    var isRed: Bool
    var pip: PipSeverity
    var five: Double?
    var week: Double?
}

/// The resolved Codex instrument/strip state: effective (post-reset-zeroed) window
/// values, the per-window inferred-zero flags that dash the rolled ring, the
/// fresh/aged annotation, the "as of" age line, the banner copy, and the pip
/// severity. Built from a `CodexUsageResult` plus a Codex-history forecast.
struct CodexDerived {
    var kind: CodexStateKind
    var installed: Bool
    var hasData: Bool
    var fresh: Bool
    var aged: Bool
    var isRed: Bool
    var forecastActive: Bool     // draw the projection/forecast at all
    var inferredFive: Bool       // 5-hour window rolled -> dashed outer ring
    var inferredWeek: Bool       // weekly window rolled -> dashed inner ring
    var five: Double?            // EFFECTIVE 5-hour value (0 when inferredFive)
    var week: Double?            // EFFECTIVE weekly value (0 when inferredWeek)
    var rawFive: Double?         // the log's stale 5-hour figure (struck when inferredFive)
    var rawWeek: Double?         // the log's stale weekly figure (struck when inferredWeek)
    var planType: String?
    var fiveResetsAt: Date?      // NEXT 5-hour reset (future); nil when unknown
    var weekResetsAt: Date?
    var observedAt: Date?
    var ageLine: String          // "as of HH:MM" (+ " · Nh ago" when aged) / "No usage data yet"
    var ageWarn: Bool            // amber age (aged)
    var msg: String              // honesty-banner / strip copy
    var pip: PipSeverity
    var projFive: Double?        // forecast projection (for the ring ghost); nil when idle
    var crossTime: Date?         // when the projection reaches 100 (pace); nil otherwise
}

enum ProviderState {

    // MARK: - Small pure formatters

    /// Rounded integer percent (product copy interpolates whole numbers).
    nonisolated static func pctInt(_ v: Double?) -> Int { Int((v ?? 0).rounded()) }

    /// Reset-relative interval, matching the header's `AppDelegate.rel`: "2h 07m",
    /// "38m", "6 days". All banner uses are on sub-5-hour resets, where this and the
    /// concept's `rel` agree; kept identical to the header so the panel reads
    /// consistently.
    nonisolated static func rel(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s >= 48 * 3600 { return "\(Int((Double(s) / 86400).rounded())) days" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    /// Age of a point-in-time reading, matching the concept's `relAge`: "just now"
    /// under 90 s, "Nm ago" under an hour, "Hh MMm ago" under a day (two-digit
    /// minutes), else "Nd ago". Used for the Codex "as of ... · Nh ago" line and the
    /// Claude stale line.
    nonisolated static func relAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded()))m ago" }
        if s < 86400 {
            let h = s / 3600
            let m = Int((Double(s % 3600) / 60).rounded())
            return String(format: "%dh %02dm ago", h, m)
        }
        return "\(s / 86400)d ago"
    }

    // MARK: - Freshness / forecast gates

    /// Fresh = the newest Codex event is within one poll interval (amendment 2:
    /// "<= 5 min"). Beyond that the reading is annotated "aged" and no forecast is
    /// drawn. The concept's ~2 min value is overruled by amendment 2.
    static let freshWindow: TimeInterval = 5 * 60
    /// Forecast gate: the newest sample must be this recent (matches
    /// `Forecast.gapTolerance`). A stale log has no live burn rate to project.
    static let forecastMaxAge: TimeInterval = 12 * 60

    // MARK: - Codex visibility (Show Codex resolution)

    /// Whether the Codex surfaces are visible for a given setting. `auto` shows them
    /// only when the `~/.codex` root exists; `on`/`off` force the choice. Two-provider
    /// mode keys on this (AppDelegate additionally suppresses the degenerate
    /// on-without-an-install case, where the result is `.notInstalled`).
    nonisolated static func codexVisible(_ setting: ShowCodex, codexRootExists: Bool) -> Bool {
        switch setting {
        case .on:   return true
        case .off:  return false
        case .auto: return codexRootExists
        }
    }

    // MARK: - Claude derivation

    /// Resolve the Claude instrument state for two-provider mode. Chain (unchanged
    /// from v0.5): signedOut -> stale -> red -> pace -> watch -> normal. `staleError`
    /// is the app's "Stale -- <error>" condition (a later poll failed but the prior
    /// snapshot still stands); `observedAt` is that snapshot's fetch time, used for
    /// the stale age. `forecast` supplies pace crossing and the projected settle
    /// value. Copy is verbatim from the concept's deriveClaude.
    nonisolated static func deriveClaude(
        five: Double?, week: Double?,
        fiveResetsAt: Date?, weekResetsAt: Date?,
        signedOut: Bool, staleError: Bool,
        observedAt: Date?, forecast: Forecast?,
        now: Date, hm: DateFormatter) -> ClaudeDerived {

        let f = five ?? 0
        let crosses = forecast?.crosses ?? false
        let isRed = !signedOut && five != nil && f >= 90

        let kind: ClaudeStateKind = {
            if signedOut { return .signedOut }
            if staleError { return .stale }
            if isRed { return .red }
            if crosses { return .pace }
            if f >= 70 { return .watch }
            return .normal
        }()

        // Age line (tag row, top-right). Stale shows the age in amber; everything
        // else is a plain "Updated HH:MM" off the last good fetch.
        let ageSec = observedAt.map { now.timeIntervalSince($0) } ?? 0
        let ageLine: String
        switch kind {
        case .signedOut: ageLine = "Not signed in"
        case .stale:     ageLine = "Updated " + relAge(ageSec)
        default:         ageLine = "Updated " + hm.string(from: observedAt ?? now)
        }

        let projSettle = forecast.map { pctInt($0.projected) } ?? pctInt(five)
        let msg: String
        switch kind {
        case .signedOut:
            msg = "Signed out. Open Claude, sign in, then reopen \u{2014} the token isn\u{2019}t being shared."
        case .stale:
            msg = "Last reading \(relAge(ageSec)); your Mac may have slept. Refreshes on open and every ~5 min."
        case .red:
            let fr = fiveResetsAt
            msg = "Red zone \u{2014} \(100 - pctInt(five))% headroom left. Resets \(hmOrDash(fr, hm)), in \(relToDash(fr, now))."
        case .pace:
            let fr = fiveResetsAt
            let ct = forecast?.crossTime
            msg = "At this pace you reach 100% around \(hmOrDash(ct, hm)) \u{2014} \(relBetween(fr, ct)) before the \(hmOrDash(fr, hm)) reset. Ease off to coast in."
        case .watch:
            msg = "\(pctInt(five))% used, \(100 - pctInt(five)) to go. About \(projSettle)% by the \(hmOrDash(fiveResetsAt, hm)) reset \u{2014} still clear."
        case .normal:
            msg = "At this pace the 5-hour window settles near \(projSettle)% before it resets at \(hmOrDash(fiveResetsAt, hm)). Plenty of headroom."
        }

        let pip: PipSeverity = {
            switch kind {
            case .signedOut, .stale, .pace, .watch: return .amber
            case .red:                              return .red
            case .normal:                           return .calm(.claude)
            }
        }()

        return ClaudeDerived(kind: kind, ageLine: ageLine, ageWarn: kind == .stale,
                             msg: msg, isRed: isRed, pip: pip, five: five, week: week)
    }

    // MARK: - Codex derivation

    /// Resolve the Codex instrument/strip state. Chain: notInstalled -> noData ->
    /// inferredZero -> red -> pace -> watch -> normal, with fresh/aged layered on.
    /// `result` is the usage poll; `forecast` is computed over the Codex history and
    /// gated here (rate > 0 AND newest sample <= 12 min AND reset in the future) per
    /// the brief. Inferred-zero is per-window via `effectiveUtilization` (amendment
    /// 9). Copy is verbatim from the concept's deriveCodex.
    nonisolated static func deriveCodex(
        result: CodexUsageResult, forecast: Forecast?,
        now: Date, hm: DateFormatter) -> CodexDerived {

        // Not installed: hidden entirely (no pip, no strip). The concept's
        // "not installed" strip row is demo scaffolding only (amendment/handoff).
        guard result.status != .notInstalled else {
            return blankCodex(kind: .notInstalled, installed: false,
                              msg: "", ageLine: "", pip: .hidden)
        }
        // Installed but nothing logged yet.
        guard result.status == .ok, let snap = result.snapshot else {
            return blankCodex(
                kind: .noData, installed: true,
                msg: "Codex is installed but hasn\u{2019}t logged usage yet. Run a Codex session to populate this.",
                ageLine: "No usage data yet", pip: .muted)
        }

        let observedAt: Date? = { if case .observed(let t) = snap.freshness { return t }; return nil }()
        let ageSec = observedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let fresh = ageSec <= freshWindow

        // Per-window effective values: a rolled window reads 0 (inferred), and only
        // that window's ring is dashed / figure struck.
        let effFive = snap.primary.map { effectiveUtilization($0, freshness: snap.freshness, now: now) }
        let effWeek = snap.secondary.map { effectiveUtilization($0, freshness: snap.freshness, now: now) }
        let inferredFive = effFive?.inferredZero ?? false
        let inferredWeek = effWeek?.inferredZero ?? false
        let five: Double? = effFive?.value
        let week: Double? = effWeek?.value
        let rawFive = snap.primary?.utilization
        let rawWeek = snap.secondary?.utilization

        // The forecast is drawn only for a live, non-rolled 5-hour window with a
        // positive computed rate and a reset still ahead (amendment 2 / brief).
        let fiveResetsAt = snap.primary?.resetsAt
        let resetInFuture = fiveResetsAt.map { $0 > now } ?? false
        let rate = forecast?.ratePerHour ?? 0
        let forecastActive = !inferredFive && rate > 0 && ageSec <= forecastMaxAge && resetInFuture
        let crosses = forecastActive && (forecast?.crosses ?? false)
        let crossTime = forecastActive ? forecast?.crossTime : nil
        let projFive: Double? = forecastActive ? forecast?.projected : nil

        let f = five ?? 0
        let isRed = !inferredFive && f >= 90
        let kind: CodexStateKind = {
            if inferredFive { return .inferredZero }
            if isRed { return .red }
            if crosses { return .pace }
            if f >= 70 { return .watch }
            return .normal
        }()
        let aged = !fresh && !inferredFive

        // The NEXT 5-hour reset for the inferred-zero copy: the rolled window's
        // resets_at plus its own length (the observed reset already passed).
        let nextReset: Date? = {
            guard inferredFive, let passed = snap.primary?.resetsAt else { return fiveResetsAt }
            let len = snap.primary?.windowMinutes.map { TimeInterval($0 * 60) } ?? (5 * 3600)
            return passed.addingTimeInterval(len)
        }()

        // Age line: "as of HH:MM" (+ " · Nh ago" only when genuinely aged).
        let ageLine: String = {
            guard let obs = observedAt else { return "as of \u{2014}" }
            if inferredFive || fresh { return "as of " + hm.string(from: obs) }
            return "as of " + hm.string(from: obs) + " \u{00B7} " + relAge(ageSec)
        }()

        let projSettle = pctInt(projFive ?? five)
        var msg: String = {
            if inferredFive {
                let passed = snap.primary?.resetsAt
                return "No Codex activity since the window reset at \(hmOrDash(passed, hm)). The log still reads \(pctInt(rawFive))%; the honest value is 0% \u{2014} it starts fresh, resets \(hmOrDash(nextReset, hm))."
            }
            if !fresh {
                return "Reading is a snapshot from \(hmOrDash(observedAt, hm)) (\(relAge(ageSec))), when Codex last wrote. It\u{2019}s idle now, so there\u{2019}s no live burn rate to forecast."
            }
            switch kind {
            case .red:
                return "Red zone \u{2014} \(100 - pctInt(five))% headroom left on Codex\u{2019}s 5-hour window. Resets \(hmOrDash(fiveResetsAt, hm))."
            case .pace:
                return "At this pace Codex reaches 100% around \(hmOrDash(crossTime, hm)), before the \(hmOrDash(fiveResetsAt, hm)) reset."
            case .watch:
                return "\(pctInt(five))% used on Codex, \(100 - pctInt(five)) to go. About \(projSettle)% by the \(hmOrDash(fiveResetsAt, hm)) reset."
            default:
                return "Codex at \(pctInt(five))% of its 5-hour window, resets \(hmOrDash(fiveResetsAt, hm)) (in \(relToDash(fiveResetsAt, now))). Weekly \(pctInt(week))%."
            }
        }()
        // A weekly-only roll (amendment 9: inferred-zero is per-window) gets its own
        // sentence, appended to whichever base copy leads: the chain stays keyed on
        // the 5-hour window, but the rolled weekly window must still be named. When
        // BOTH windows rolled, the 5-hour inferred copy above already leads and the
        // weekly is visible as the struck figure + dashed ring.
        if inferredWeek && !inferredFive {
            let passedWeek = snap.secondary?.resetsAt
            msg += " No Codex activity since the weekly window reset at \(hmOrDash(passedWeek, hm)); the honest weekly value is 0%, not the logged \(pctInt(rawWeek))%."
        }

        // Pip / banner-dot severity (amendment 5): inferred-zero (EITHER window;
        // amendment 5 lists "Codex inferred-zero" unqualified) and watch/pace are
        // amber, a real >= 90 is red (winning over a weekly roll and over aged),
        // aged-idle is muted, a fresh calm reading is the Codex accent. This
        // overrules the concept's grey inferred dot in favor of amendment 5.
        let pip: PipSeverity = {
            if inferredFive { return .amber }
            if isRed { return .red }
            if kind == .pace || kind == .watch { return .amber }
            if inferredWeek { return .amber }
            if aged { return .muted }
            return .calm(.codex)
        }()

        return CodexDerived(
            kind: kind, installed: true, hasData: true, fresh: fresh, aged: aged,
            isRed: isRed, forecastActive: forecastActive,
            inferredFive: inferredFive, inferredWeek: inferredWeek,
            five: five, week: week, rawFive: rawFive, rawWeek: rawWeek,
            planType: snap.planType,
            fiveResetsAt: fiveResetsAt, weekResetsAt: snap.secondary?.resetsAt,
            observedAt: observedAt, ageLine: ageLine, ageWarn: aged, msg: msg,
            pip: pip, projFive: projFive, crossTime: crossTime)
    }

    private nonisolated static func blankCodex(kind: CodexStateKind, installed: Bool,
                                               msg: String, ageLine: String,
                                               pip: PipSeverity) -> CodexDerived {
        CodexDerived(kind: kind, installed: installed, hasData: false, fresh: false,
                     aged: false, isRed: false, forecastActive: false,
                     inferredFive: false, inferredWeek: false, five: nil, week: nil,
                     rawFive: nil, rawWeek: nil, planType: nil,
                     fiveResetsAt: nil, weekResetsAt: nil,
                     observedAt: nil, ageLine: ageLine, ageWarn: false, msg: msg,
                     pip: pip, projFive: nil, crossTime: nil)
    }

    // MARK: - Sessions split header (amendment 11)

    /// The sessions section header. Two-provider mode uses the split, per-provider
    /// copy "N active Claude \u{00B7} M Codex"; Claude-only keeps today's exact
    /// wording (the caller renders "No active Claude sessions" for the empty case).
    /// The exec-summary row is never counted here.
    nonisolated static func sessionsHeader(claudeCount: Int, codexCount: Int,
                                           twoProvider: Bool) -> String {
        if twoProvider {
            return "\(claudeCount) active Claude \u{00B7} \(codexCount) Codex"
        }
        if claudeCount == 0 { return "No active Claude sessions" }
        return claudeCount == 1 ? "1 active session" : "\(claudeCount) active sessions"
    }

    // MARK: - Status line (amendment 12)

    /// The Codex segment of the two-provider status line: "Codex as of HH:MM" plus
    /// the age ("\u{00B7} Nh ago") when aged. Returns nil when Codex has no reading
    /// to stamp (not installed / no data). The Claude segment is the app's existing
    /// `statusLineText`; the caller joins them with " \u{00B7} " and colors the
    /// codex age segment amber when `aged`.
    nonisolated static func codexStatusSegment(observedAt: Date?, aged: Bool,
                                               hm: DateFormatter, now: Date) -> String? {
        guard let obs = observedAt else { return nil }
        var s = "Codex as of " + hm.string(from: obs)
        if aged { s += " \u{00B7} " + relAge(now.timeIntervalSince(obs)) }
        return s
    }

    /// The full two-provider status line as a plain string (the attributed builder
    /// in AppDelegate colors the trailing age segment amber). `claudeText` is the
    /// app's existing status text ("Updated HH:MM" / "Stale -- ..."); the codex
    /// segment is appended after " \u{00B7} " when present.
    nonisolated static func twoProviderStatusLine(claudeText: String,
                                                  codexSegment: String?) -> String {
        guard let seg = codexSegment else { return claudeText }
        return claudeText + " \u{00B7} " + seg
    }

    // MARK: - Copy interpolation helpers

    /// "HH:MM" for a date, or an em-dash when absent (defensive; real copy paths
    /// always have the reset in hand).
    private nonisolated static func hmOrDash(_ d: Date?, _ f: DateFormatter) -> String {
        guard let d else { return "\u{2014}" }
        return f.string(from: d)
    }
    private nonisolated static func relToDash(_ d: Date?, _ now: Date) -> String {
        guard let d else { return "\u{2014}" }
        return rel(d.timeIntervalSince(now))
    }
    private nonisolated static func relBetween(_ later: Date?, _ earlier: Date?) -> String {
        guard let later, let earlier else { return "\u{2014}" }
        return rel(later.timeIntervalSince(earlier))
    }
}
