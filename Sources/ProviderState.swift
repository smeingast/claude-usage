import Foundation

// Per-provider UI state derivation, kept PURE and nonisolated so the two-provider
// panel/pip/status copy is driven by tested functions, not by ad-hoc branching in
// the render methods. AppDelegate computes a `ClaudeDerived` / `CodexDerived` on
// each render and hands the fields straight to the views; every copy string,
// severity, freshness annotation, and inferred-ring flag originates here.
//
// The design source is `design/codex-support/handoff/` (the interactive concept's
// deriveClaude / deriveCodex) as amended by `handoff-amendments.md`. The Claude
// warning copy is reproduced verbatim from the concept; the Codex copy is terse
// middot-joined fragments (amendment 20, overruling the concept's prose), and the
// calm normal state carries no banner message at all for either provider
// (amendment 19). The amendments also overrule the concept on: freshness <= 5 min
// (amendment 2), pip/dot severity (amendment 5), per-window inferred-zero with only
// the rolled ring dashed (amendment 9), and the age-based (not process-liveness)
// Codex forecast gate (amendment 2).

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

    // MARK: - Graph cards (amendment 26)

    /// The ordered provider list for the stacked graph cards. Claude-only mode is
    /// always the single Claude graph (the setting has no effect there, keeping the
    /// v0.8 path untouched); in two-provider mode the Graphs setting picks the cards,
    /// and Both orders them primary first to match the instrument/strip hierarchy.
    /// Pure so the visibility table is testable; AppDelegate uses the COUNT for the
    /// per-open row structure and the ORDER for per-render card content (a mid-open
    /// Lead swap reorders content without touching rows).
    nonisolated static func graphCards(_ setting: GraphsShown, twoProvider: Bool,
                                       primary: UsageProviderKind) -> [UsageProviderKind] {
        guard twoProvider else { return [.claude] }
        switch setting {
        case .claude: return [.claude]
        case .codex:  return [.codex]
        case .both:   return primary == .claude ? [.claude, .codex] : [.codex, .claude]
        }
    }

    // MARK: - Bar pip filter (amendment 23)

    /// The severity the BAR may draw as its corner pip / percentages bullet, or nil
    /// for no pip at all. Amendment 23 (Stefan's live feedback): the bar pip is a
    /// WARNING LIGHT only; a calm teal dot next to the rings reads as noise. Red and
    /// amber pass through; calm, muted, and hidden draw nothing. Amendment 5's full
    /// severity-to-color table is untouched: the panel banner/strip dots still render
    /// every state, so calm and muted stay visible where there is room for them.
    nonisolated static func barPip(_ s: PipSeverity) -> PipSeverity? {
        switch s {
        case .red, .amber:            return s
        case .calm, .muted, .hidden:  return nil
        }
    }

    // MARK: - Claude derivation

    /// Resolve the Claude instrument state for two-provider mode. Chain (unchanged
    /// from v0.5): signedOut -> stale -> red -> pace -> watch -> normal. `staleError`
    /// is the app's "Stale -- <error>" condition (a later poll failed but the prior
    /// snapshot still stands); `observedAt` is that snapshot's fetch time, used for
    /// the stale age. `forecast` supplies pace crossing and the projected settle
    /// value. The warning copy is verbatim from the concept's deriveClaude; the calm
    /// normal state returns an empty message (amendment 19: no banner).
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
            // Amendment 19: the calm normal state carries no banner at all. An empty
            // message is the "no banner row" signal to the panel layout.
            msg = ""
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
    /// 9). Copy is terse middot-joined fragments (amendment 20, overruling the
    /// concept's prose), and the fresh normal state carries no message at all
    /// (amendment 19).
    nonisolated static func deriveCodex(
        result: CodexUsageResult, forecast: Forecast?,
        now: Date, hm: DateFormatter) -> CodexDerived {

        // Not installed: hidden entirely (no pip, no strip). The concept's
        // "not installed" strip row is demo scaffolding only (amendment/handoff).
        guard result.status != .notInstalled else {
            return blankCodex(kind: .notInstalled, installed: false,
                              msg: "", ageLine: "", pip: .hidden)
        }
        // Installed but nothing logged yet (terse per amendment 20).
        guard result.status == .ok, let snap = result.snapshot else {
            return blankCodex(
                kind: .noData, installed: true,
                msg: "Installed, no usage logged yet \u{00B7} run a Codex session.",
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
        // Codex copy is TERSE (amendment 20): short middot-joined fragments, not
        // prose; the concept's verbatim sentences are overruled for Codex. A fresh
        // normal state returns "" (amendment 19: no banner in the calm state).
        var msg: String = {
            if inferredFive {
                let passed = snap.primary?.resetsAt
                return "Window reset \(hmOrDash(passed, hm)) passed idle \u{00B7} reads 0% until Codex runs \u{00B7} next reset \(hmOrDash(nextReset, hm))."
            }
            if !fresh {
                return "Idle since \(hmOrDash(observedAt, hm)) (\(relAge(ageSec))) \u{00B7} forecast paused."
            }
            switch kind {
            case .red:
                return "Red zone \u{00B7} \(100 - pctInt(five))% headroom \u{00B7} resets \(hmOrDash(fiveResetsAt, hm))."
            case .pace:
                return "On pace for 100% ~\(hmOrDash(crossTime, hm)) \u{00B7} resets \(hmOrDash(fiveResetsAt, hm))."
            case .watch:
                return "\(pctInt(five))% used \u{00B7} ~\(projSettle)% by the \(hmOrDash(fiveResetsAt, hm)) reset."
            default:
                return ""
            }
        }()
        // A weekly-only roll (amendment 9: inferred-zero is per-window) is appended
        // to whatever message is showing: the chain stays keyed on the 5-hour window,
        // but the rolled weekly window must still be named. On an empty base (fresh
        // normal, which shows no banner of its own) the fragment stands alone,
        // capitalized, so the weekly caveat still forces a banner (amendment 19
        // removes only the CALM banner, never an honesty caveat). When BOTH windows
        // rolled, the 5-hour inferred copy above leads and the weekly roll stays
        // visible as its dashed ring + struck figure.
        if inferredWeek && !inferredFive {
            if msg.isEmpty {
                msg = "Weekly reset passed, weekly reads 0%."
            } else {
                msg += " \u{00B7} weekly reset passed, weekly reads 0%."
            }
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

    // MARK: - Status line (amendments 12 and 25)

    /// The Claude segment of the TWO-PROVIDER status line, compact by design
    /// (amendment 25): NSMenu sizes itself to its widest text item, and the full
    /// error string ("Stale \u{2014} Server returned HTTP 429. \u{00B7} ...") forced
    /// the whole menu wider than the 360 pt panel. "Updated HH:MM" normally,
    /// "Stale \u{00B7} updated HH:MM" when a later poll failed but the snapshot
    /// stands, "Loading\u{2026}" before the first snapshot; the raw error string
    /// belongs in the status item's TOOLTIP, never in the line. Claude-only mode
    /// keeps the full `statusLineText` format untouched.
    nonisolated static func claudeStatusSegment(fetchedAt: Date?, stale: Bool,
                                                hm: DateFormatter) -> String {
        guard let fetchedAt else { return "Loading\u{2026}" }
        return stale
            ? "Stale \u{00B7} updated " + hm.string(from: fetchedAt)
            : "Updated " + hm.string(from: fetchedAt)
    }

    /// The Codex segment of the two-provider status line: "Codex as of HH:MM" plus
    /// the age ("\u{00B7} Nh ago") when aged. Returns nil when Codex has no reading
    /// to stamp (not installed / no data). The Claude segment is `claudeStatusSegment`
    /// above; the caller joins them with " \u{00B7} " and colors the codex age
    /// segment amber when `aged`.
    nonisolated static func codexStatusSegment(observedAt: Date?, aged: Bool,
                                               hm: DateFormatter, now: Date) -> String? {
        guard let obs = observedAt else { return nil }
        var s = "Codex as of " + hm.string(from: obs)
        if aged { s += " \u{00B7} " + relAge(now.timeIntervalSince(obs)) }
        return s
    }

    /// The full two-provider status line as a plain string (the attributed builder
    /// in AppDelegate colors the trailing age segment amber). `claudeText` is the
    /// compact `claudeStatusSegment` (amendment 25); the codex segment is appended
    /// after " \u{00B7} " when present.
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
