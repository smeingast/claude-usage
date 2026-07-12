import Foundation

/// Reads OpenAI Codex CLI's local rollout logs (`~/.codex/sessions/YYYY/MM/DD/
/// rollout-*.jsonl`) to reconstruct a usage snapshot and to backfill history,
/// strictly read-only. Codex has no usage API and no auth taxonomy for us: the
/// numbers are point-in-time server values that Codex appended to a session log
/// the last time it ran, so the failure modes are DATA states, not error states.
///
/// The relevant line is an `event_msg` whose `payload.type == "token_count"`; its
/// `payload.rate_limits.primary` / `.secondary` carry `used_percent`,
/// `window_minutes`, and `resets_at` (EPOCH SECONDS). Directory and file names are
/// LOCAL time while every internal `timestamp` is UTC ISO-8601 with fractional
/// seconds, so we order candidates by file mtime, never by name. Some sessions
/// have zero `token_count` events and `rate_limits` can be null; every field is
/// treated as optional and a malformed line or file is skipped, never fatal.
///
/// An empty `Sendable` struct (like `SessionsClient`) so it is safe to call off the
/// main actor from `Task.detached`. The base directory is injectable so tests can
/// point it at a synthetic fixture tree instead of the real `~/.codex`.
///
/// NEVER reads `~/.codex/auth.json` (not even a stat), never writes anything, never
/// touches the network.
struct CodexUsageClient: Sendable {
    /// One backfill data point: a `token_count` event's UTC time plus the two
    /// windows' observed percentages and resets. Carries only what the history
    /// samples need; the decimator downstream stamps samples with `timestamp`.
    struct Event: Sendable {
        var timestamp: Date
        var primaryPercent: Double?
        var secondaryPercent: Double?
        var primaryResetsAt: Date?
        var secondaryResetsAt: Date?
    }

    let root: URL
    /// How far back the usage scan looks for the newest usable event. A pure time
    /// bound; the file cap below guards the pathological I/O within it.
    let usageWindow: TimeInterval
    /// Backfill only reopens files whose mtime is this recent. Events older than the
    /// caller's cutoff are excluded by the scan's take-while regardless.
    let backfillWindow: TimeInterval
    /// Safety cap on files actually tail-scanned for the usage snapshot. 400
    /// consecutive `token_count`-less files would be a pathological workload;
    /// hitting the cap yields `.noData` plus an NSLog line (accepted residual).
    let fileCap: Int

    /// Stray-anchor defense bounds (see `fetch`): how far back the vote
    /// neighborhood reaches from the newest event, how many events at most vote,
    /// from how many contributing files, and when two primary anchors count as the
    /// same window. Observed server-side `resets_at` jitter is up to ~26 s; 120 s
    /// covers it with margin while staying far below any real window shift (hours).
    static let voteWindow: TimeInterval = 15 * 60
    static let voteCap = 12
    static let voteMaxFiles = 3
    static let anchorTolerance: TimeInterval = 120

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".codex", isDirectory: true),
         usageWindow: TimeInterval = 14 * 24 * 3600,
         backfillWindow: TimeInterval = 48 * 3600,
         fileCap: Int = 400) {
        self.root = root
        self.usageWindow = usageWindow
        self.backfillWindow = backfillWindow
        self.fileCap = fileCap
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    // MARK: - Usage snapshot

    /// Reconstruct the current usage snapshot from local data. Status mapping:
    /// `~/.codex` missing entirely -> `.notInstalled`; the root exists but
    /// `sessions/` is missing/empty or no usable `token_count` is found within the
    /// bounds -> `.noData`; otherwise `.ok` with the reconstructed snapshot.
    ///
    /// Policy: gather candidate rollout files across the date dirs, keep those with
    /// mtime inside `usageWindow`, order the whole set by mtime DESC (rate limits
    /// are account-global, so sub-minute skew between concurrent writers is
    /// immaterial and local-time dir names must not decide the order), then
    /// tail-scan each newest-first for the last `token_count` with a usable
    /// `rate_limits`. The first hit anchors a majority vote (below) that picks the
    /// event actually shown.
    ///
    /// STRAY-ANCHOR DEFENSE: ~4% of live events on the reference machine are stray
    /// readings written by `codex exec` subagent runs: tiny percentages on a primary
    /// anchor ≈ event time + window, both windows shifted together, likely an
    /// ephemeral per-agent limit bucket. Per-event they are indistinguishable from a
    /// genuine rollover, so the defense is statistical: gather the newest events
    /// (cap `voteCap`) not older than the newest event − `voteWindow`, from at most
    /// `voteMaxFiles` contributing files; the majority primary anchor wins and the
    /// newest event carrying it becomes the snapshot. A quiet account degrades to a
    /// neighborhood of one, i.e. plain newest-wins. A brief post-rollover majority
    /// lag is acceptable: the losing old window renders as inferred zero via
    /// `effectiveUtilization`, which is honest.
    func fetch(now: Date = Date()) -> CodexUsageResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return CodexUsageResult(status: .notInstalled, snapshot: nil)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return CodexUsageResult(status: .noData, snapshot: nil)
        }

        let cutoff = now.addingTimeInterval(-usageWindow)
        let inWindow = sessionFiles()
            .filter { $0.mtime >= cutoff }
            .sorted { $0.mtime > $1.mtime }
        // Bound the I/O: scan at most `fileCap` files. `truncated` distinguishes a
        // genuine no-data account from a pathological pile of empty sessions.
        let truncated = inWindow.count > fileCap
        let candidates = truncated ? Array(inWindow.prefix(fileCap)) : inWindow

        // The newest usable event, mtime-desc stop-at-first-hit. It anchors the vote
        // window; before the stray defense it would itself have been the snapshot.
        var hit: (index: Int, event: Event, line: Data)?
        for (i, file) in candidates.enumerated() {
            if let (ev, line) = newestUsableEvent(fromFile: file.url) {
                hit = (i, ev, line)
                break
            }
        }
        guard let hit else {
            if truncated {
                NSLog("ClaudeUsage: Codex usage scan hit the %d-file cap without a usable "
                      + "token_count; reporting noData", fileCap)
            }
            return CodexUsageResult(status: .noData, snapshot: nil)
        }

        var pool = voteNeighborhood(candidates: candidates, hitIndex: hit.index,
                                    newest: hit.event.timestamp)
        if pool.isEmpty { pool = [(hit.event, hit.line)] }   // defensive; the hit file re-yields it
        let winner = Self.voteWinnerIndex(pool.map(\.event)) ?? 0
        guard let snap = Self.snapshot(from: pool[winner].line, fetchedAt: now) else {
            // Unreachable in practice: every pool line was already validated by
            // event(from:), which applies the identical checks.
            return CodexUsageResult(status: .noData, snapshot: nil)
        }
        return CodexUsageResult(status: .ok, snapshot: snap)
    }

    /// Tail-scan one rollout file for the newest usable `token_count`, or nil if the
    /// file has none. `lastLineBackward` returns on the first EOF-ward line the
    /// mapping accepts, so a file's older events are never touched here.
    private func newestUsableEvent(fromFile url: URL) -> (event: Event, line: Data)? {
        var found: (Event, Data)?
        _ = JSONLBackscan.lastLineBackward(url: url) { line in
            guard let ev = Self.event(from: line) else { return false }
            found = (ev, line)
            return true
        }
        return found
    }

    /// The vote pool for the stray-anchor defense: usable events not older than
    /// `newest` − `voteWindow`, gathered from the candidate files (mtime desc)
    /// starting at the hit file, from at most `voteMaxFiles` contributing files. ALL
    /// qualifying events are gathered first, THEN sorted newest-first ACROSS files and
    /// only afterwards capped at `voteCap`. The cap is applied after the cross-file
    /// sort on purpose: filling it file-by-file (a review-caught defect) let one
    /// prolific stray-heavy exec file consume every slot and vote in its own stray, so
    /// the pool must be a prefix of the sorted union of the whole neighborhood, never a
    /// prefix of the first file's events. The take-while gate is timestamp-based with
    /// the same noise rule as the backfill: keep going on any line it cannot time.
    private func voteNeighborhood(candidates: [(url: URL, mtime: Date)], hitIndex: Int,
                                  newest: Date) -> [(event: Event, line: Data)] {
        let windowStart = newest.addingTimeInterval(-Self.voteWindow)
        var gathered: [(event: Event, line: Data)] = []
        var contributing = 0
        for (offset, file) in candidates[hitIndex...].enumerated() {
            // The hit file is always scanned (it holds the newest event by
            // construction). Later files stop the walk once their mtime predates the
            // window start: mtime bounds a file's newest event, and everything after
            // in mtime-desc order is older still.
            if offset > 0, file.mtime < windowStart { break }
            let lines = JSONLBackscan.collectLinesBackward(
                url: file.url,
                while: { line in
                    guard let ts = Self.lineTimestamp(line) else { return true }
                    return ts >= windowStart
                },
                match: { Self.isTokenCount($0) })
            var contributed = false
            for line in lines {
                guard let ev = Self.event(from: line), ev.timestamp >= windowStart else { continue }
                gathered.append((ev, line))
                contributed = true
            }
            if contributed { contributing += 1 }
            if contributing >= Self.voteMaxFiles { break }
        }
        // Cap only now, over the sorted union: newest `voteCap` events win a seat, no
        // matter which files they came from.
        return Array(gathered.sorted { $0.event.timestamp > $1.event.timestamp }.prefix(Self.voteCap))
    }

    /// Majority-primary-anchor vote over a neighborhood of events: the index of the
    /// event whose reading should be shown, i.e. the newest member of the winning
    /// anchor cluster. Two anchors are the same window when they differ by at most
    /// `tolerance` (server jitter); a nil anchor never matches anything and votes
    /// only for itself. Events are clustered newest-first, so on a tie the
    /// earliest-created cluster wins, which is exactly "keep the newest event".
    static func voteWinnerIndex(_ events: [Event],
                                tolerance: TimeInterval = CodexUsageClient.anchorTolerance) -> Int? {
        guard !events.isEmpty else { return nil }
        struct Cluster { let anchor: Date?; var votes: Int; let newestIndex: Int }
        var clusters: [Cluster] = []
        for i in events.indices.sorted(by: { events[$0].timestamp > events[$1].timestamp }) {
            let anchor = events[i].primaryResetsAt
            if let anchor,
               let j = clusters.firstIndex(where: { c in
                   guard let a = c.anchor else { return false }
                   return abs(a.timeIntervalSince(anchor)) <= tolerance
               }) {
                clusters[j].votes += 1
            } else {
                clusters.append(Cluster(anchor: anchor, votes: 1, newestIndex: i))
            }
        }
        var best = 0
        for j in clusters.indices where clusters[j].votes > clusters[best].votes { best = j }
        return clusters[best].newestIndex
    }

    /// Drop stray-anchor runs from a chronological backfill batch, BEFORE decimation,
    /// with the POPULATION-WEIGHTED SPAN rule (brief rev 6).
    ///
    /// Why not adjacency: the earlier bounded-run rule (drop a run bounded by two
    /// agreeing runs that disagree with it) was FALSIFIED on live data 2026-07-12. One
    /// long-lived `codex exec` session dripped sparse stray SINGLETONS, all sharing one
    /// ephemeral anchor, through four hours of heavy real traffic. The merged batch
    /// read R-run, S, R-run, S, R-run, ..., so every REAL run was itself "bounded by
    /// agreeing stray runs" and got convicted (155 of 173 real events dropped).
    /// Adjacency cannot tell the two shapes apart; population can: strays are rare by
    /// nature (~4% observed), so weight of numbers is the discriminating signal.
    ///
    /// The rule, on the raw chronological batch:
    /// 1. Cluster all non-nil primary anchors batch-wide by SINGLE-LINKAGE: sort the
    ///    distinct anchor times, a gap > `tolerance` between sorted neighbors starts a
    ///    new cluster. Canonical clustering, not pairwise chaining: pairwise "agree" is
    ///    not an equivalence relation (anchors at 0/100/200 s bridge ambiguously),
    ///    while the sorted-gap rule assigns every anchor to exactly one cluster. A
    ///    cluster's population is its EVENT count in the batch.
    /// 2. Group events into maximal consecutive same-cluster runs; a nil-anchor event
    ///    forms its own clusterless run.
    /// 3. For each pair of CONSECUTIVE runs of the same cluster C (no other C-run
    ///    between them), every anchored run strictly between the pair is dropped iff
    ///    its cluster population is STRICTLY smaller than C's. Strict on purpose: a
    ///    tie is not evidence, and the failure costs are asymmetric (a false keep is
    ///    cheap, the vote and the decimator still stand behind this filter; a false
    ///    drop deletes real history for good). Nil runs are never dropped, but they do
    ///    not shield their neighbors either: they sit inside a span transparently. A
    ///    run may be examined by more than one enclosing pair and is dropped if ANY
    ///    pair convicts it. Batch-edge runs are never strictly between a pair, so they
    ///    are automatically kept.
    ///
    /// A genuine rollover is safe by construction: after the roll the OLD cluster never
    /// recurs later in the batch, so no enclosing old-cluster pair exists around the
    /// new anchor's runs and nothing convicts them. Documented residuals, accepted, not
    /// defects: a chatty exec session that OUTNUMBERS the real events in a batch
    /// convicts the sparse real runs (inherent to any majority heuristic); strays in
    /// tiny live-poll batches (fewer than 3 events, or with no enclosing same-cluster
    /// pair) pass through unfiltered, as under every prior revision; a stale-cache
    /// A,B,A shape around a real rollover can briefly convict young-B events.
    static func filterStrays(_ events: [Event],
                             tolerance: TimeInterval = CodexUsageClient.anchorTolerance) -> [Event] {
        guard events.count >= 3 else { return events }

        // 1. Single-linkage clusters over the distinct anchors. Population counts
        //    EVENTS, not distinct anchor values: events carry the weight of evidence.
        let distinct = Set(events.compactMap { $0.primaryResetsAt }).sorted()
        var clusterOf: [Date: Int] = [:]
        var currentCluster = -1
        var previousAnchor: Date?
        for a in distinct {
            if previousAnchor == nil || a.timeIntervalSince(previousAnchor!) > tolerance {
                currentCluster += 1
            }
            clusterOf[a] = currentCluster
            previousAnchor = a
        }
        func cluster(_ e: Event) -> Int? { e.primaryResetsAt.flatMap { clusterOf[$0] } }
        var population: [Int: Int] = [:]
        for e in events { if let c = cluster(e) { population[c, default: 0] += 1 } }

        // 2. Runs are half-open index ranges over `events`. A run breaks on any cluster
        //    change; a nil on either side always breaks, so every nil-anchor event
        //    stands alone as its own clusterless run.
        struct Run { let cluster: Int?; let range: Range<Int> }
        var runs: [Run] = []
        var start = 0
        for i in 1..<events.count {
            let c = cluster(events[i])
            let p = cluster(events[i - 1])
            if c == nil || p == nil || c != p {
                runs.append(Run(cluster: cluster(events[start]), range: start..<i))
                start = i
            }
        }
        runs.append(Run(cluster: cluster(events[start]), range: start..<events.count))

        // 3. Spans: between each consecutive same-cluster pair, convict every anchored
        //    run whose cluster is strictly outnumbered by the enclosing cluster.
        var runsOfCluster: [Int: [Int]] = [:]
        for (i, r) in runs.enumerated() {
            if let c = r.cluster { runsOfCluster[c, default: []].append(i) }
        }
        var dropped = Set<Int>()
        for (c, indices) in runsOfCluster where indices.count >= 2 {
            let enclosingPop = population[c] ?? 0
            for k in 1..<indices.count {
                for mid in (indices[k - 1] + 1)..<indices[k] {
                    guard let mc = runs[mid].cluster else { continue }   // nil runs: never dropped
                    if (population[mc] ?? 0) < enclosingPop { dropped.insert(mid) }
                }
            }
        }
        var out: [Event] = []
        for (idx, run) in runs.enumerated() where !dropped.contains(idx) {
            out.append(contentsOf: events[run.range])
        }
        return out
    }

    // MARK: - Backfill events

    /// Collect `token_count` events strictly newer than `after`, from files whose
    /// mtime is within `backfillWindow`, returned in ASCENDING (chronological) order.
    ///
    /// The scan runs newest-first per file and stops at the take-while gate. The gate
    /// is the trap the brief calls out: it sees EVERY line, including non-token_count
    /// noise (session_meta, response_item, ...). It must KEEP GOING for any line it
    /// cannot read a timestamp from, and stop ONLY when a parseable event timestamp
    /// is at or below the cutoff. `match` alone filters for `token_count`, and the
    /// final `> after` check double-guards the boundary before a sample is emitted.
    func backfillEvents(after cutoff: Date, now: Date = Date()) -> [Event] {
        let winStart = now.addingTimeInterval(-backfillWindow)
        let files = sessionFiles()
            .filter { $0.mtime >= winStart }
            .sorted { $0.mtime > $1.mtime }

        var out: [Event] = []
        for file in files {
            let lines = JSONLBackscan.collectLinesBackward(
                url: file.url,
                while: { line in
                    // Keep scanning past noise we cannot time; stop only once a real
                    // line's timestamp has fallen back to or below the cutoff.
                    guard let ts = Self.lineTimestamp(line) else { return true }
                    return ts > cutoff
                },
                match: { Self.isTokenCount($0) })
            for line in lines {
                if let ev = Self.event(from: line), ev.timestamp > cutoff { out.append(ev) }
            }
        }
        // The scanner yields newest-first within and across files; history wants
        // ascending time, so re-sort the merged set.
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Candidate files

    /// All rollout files under `sessions/`, each with its mtime. The date dirs are
    /// walked newest-name-first purely as a cheap ordering hint; correctness comes
    /// from the caller's global mtime sort (names are LOCAL time and can disagree
    /// with the UTC event order). Directory reads only, no file bodies opened here.
    private func sessionFiles() -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        func subdirs(_ url: URL) -> [URL] {
            guard let items = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var out: [(URL, Date)] = []
        for year in subdirs(sessionsDir) {
            for month in subdirs(year) {
                for day in subdirs(month) {
                    guard let files = try? fm.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for f in files where f.lastPathComponent.hasPrefix("rollout-")
                                      && f.pathExtension == "jsonl" {
                        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        out.append((f, m))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Line mapping (pure, static, testable)

    /// Map one JSONL line to a Codex usage snapshot, or nil if it is not a usable
    /// `token_count` event. A cheap substring pre-filter avoids JSON-parsing the
    /// bulky content lines that dominate a rollout file.
    static func snapshot(from line: Data, fetchedAt: Date) -> ProviderUsageSnapshot? {
        guard let s = String(data: line, encoding: .utf8),
              s.contains("token_count"), s.contains("rate_limits") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return snapshot(fromEvent: obj, fetchedAt: fetchedAt)
    }

    /// Map an already-parsed event object to a snapshot. Requires the event type,
    /// a non-null `rate_limits`, a parseable UTC `timestamp` (freshness is
    /// load-bearing for a point-in-time provider, so an untimed event is not a
    /// usable hit), and at least one window with a `used_percent`.
    static func snapshot(fromEvent obj: [String: Any], fetchedAt: Date) -> ProviderUsageSnapshot? {
        guard (obj["type"] as? String) == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let rl = payload["rate_limits"] as? [String: Any],
              let observed = ISO.parse(obj["timestamp"] as? String) else { return nil }
        let primary = window(from: rl["primary"], id: "primary")
        let secondary = window(from: rl["secondary"], id: "secondary")
        guard primary != nil || secondary != nil else { return nil }
        return ProviderUsageSnapshot(
            provider: .codex,
            primary: primary,
            secondary: secondary,
            extras: [],
            freshness: .observed(observed),
            fetchedAt: fetchedAt,
            planType: rl["plan_type"] as? String)
    }

    /// Map one `rate_limits.primary` / `.secondary` object to a `UsageWindow`, or nil
    /// if it carries no `used_percent`. `resets_at` is EPOCH SECONDS.
    static func window(from any: Any?, id: String) -> UsageWindow? {
        guard let d = any as? [String: Any],
              let used = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (d["window_minutes"] as? NSNumber)?.intValue
        let resets = (d["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(id: id, title: windowTitle(minutes: minutes),
                           utilization: used, windowMinutes: minutes, resetsAt: resets)
    }

    /// Data-driven window label from `window_minutes`: the two observed values get
    /// their familiar names; day multiples read "N-day", hour multiples "N-hour".
    /// Anything else (including a missing value) falls back to a plain minute label
    /// so an unrecognized window is still shown honestly rather than mislabeled.
    static func windowTitle(minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "Window" }
        switch m {
        case 300:   return "5-hour"
        case 10080: return "Weekly"
        default:
            if m % 1440 == 0 { return "\(m / 1440)-day" }
            if m % 60 == 0 { return "\(m / 60)-hour" }
            return "\(m)-min"
        }
    }

    /// Map one JSONL line to a backfill `Event`, or nil if it is not a usable
    /// `token_count`. Same pre-filter and validation as the snapshot mapping.
    static func event(from line: Data) -> Event? {
        guard let s = String(data: line, encoding: .utf8),
              s.contains("token_count"), s.contains("rate_limits") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "event_msg",
              let ts = ISO.parse(obj["timestamp"] as? String),
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let rl = payload["rate_limits"] as? [String: Any] else { return nil }
        let primary = window(from: rl["primary"], id: "primary")
        let secondary = window(from: rl["secondary"], id: "secondary")
        guard primary != nil || secondary != nil else { return nil }
        return Event(timestamp: ts,
                     primaryPercent: primary?.utilization,
                     secondaryPercent: secondary?.utilization,
                     primaryResetsAt: primary?.resetsAt,
                     secondaryResetsAt: secondary?.resetsAt)
    }

    /// True when the line is an `event_msg`/`token_count` with a non-null
    /// `rate_limits`. Used as the backfill `match` filter.
    static func isTokenCount(_ line: Data) -> Bool {
        guard let s = String(data: line, encoding: .utf8),
              s.contains("token_count"), s.contains("rate_limits") else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              payload["rate_limits"] is [String: Any] else { return false }
        return true
    }

    /// The line's top-level UTC `timestamp`, extracted cheaply without JSON-parsing
    /// the whole line (the backward walk touches every line, some of them huge).
    ///
    /// Only a line that literally STARTS with `{"timestamp"` is trusted: rollout
    /// content lines can quote nested JSON containing a "timestamp" key (these logs
    /// literally contain coding sessions about this very schema), and taking the
    /// first occurrence anywhere would let an embedded old timestamp stop a backfill
    /// scan early. The rollout writer emits `timestamp` as the first key; if a future
    /// codex version reorders keys, every line returns nil, the take-while gates
    /// simply never stop early (the safe direction), and `match` still JSON-parses
    /// events properly, so only scan cost is affected, never correctness.
    static func lineTimestamp(_ line: Data) -> Date? {
        let prefix = "{\"timestamp\""
        guard let s = String(data: line, encoding: .utf8), s.hasPrefix(prefix) else { return nil }
        let afterKey = s[s.index(s.startIndex, offsetBy: prefix.count)...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let open = afterColon.firstIndex(of: "\"") else { return nil }
        let valStart = afterColon.index(after: open)
        guard let close = afterColon[valStart...].firstIndex(of: "\"") else { return nil }
        return ISO.parse(String(afterColon[valStart..<close]))
    }
}
