import Foundation
import Darwin   // sysctl / kinfo_proc, for the process-alive scan (same pattern as SessionsClient)

/// Reads OpenAI Codex CLI's local rollout logs to list the user-facing interactive
/// sessions (`source == "cli"`) with their model and context fill, and to summarize
/// how many `codex exec` subagent runs happened today. Strictly read-only, no
/// network, and NEVER reads `~/.codex/auth.json` (not even a stat).
///
/// A rollout file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) is append-only.
/// Its immutable HEADER lives at the top: line 0 is `session_meta` (session id, cwd,
/// source, model_provider) and a `turn_context` line a few records later carries the
/// model. Neither ever changes once written, so we cache the parsed header in memory
/// KEYED BY PATH and never re-read a file whose header is complete. The live
/// context-fill number is NOT immutable (it grows every turn), so it is tail-scanned
/// fresh on every fetch.
///
/// Why this is a `final class`, `@unchecked Sendable`, with an `NSLock`-guarded cache
/// (following `HistoryStore`'s pattern): the header cache is mutable state that
/// persists across polls, and `fetch()` runs from `Task.detached` off the main actor
/// in the app. The lock makes concurrent access sound; `@unchecked Sendable` is
/// justified because the ONLY mutable state is `headerCache`, always accessed under
/// `cacheLock`, while `root` and `processAlive` are immutable after init.
final class CodexSessionsClient: @unchecked Sendable {

    /// Immutable per-file header, parsed once from the top of a rollout file.
    /// `complete` means BOTH `session_meta` and the first `turn_context` (the model)
    /// were read; an incomplete header (a just-created session whose `turn_context`
    /// has not been written yet) is re-read on later polls until it completes. A
    /// header with no `source` means `session_meta` itself was not yet parseable and
    /// the file cannot even be classified `cli`/`exec`.
    struct Header: Sendable {
        var sessionId: String?
        var cwd: String?
        var source: String?          // "cli" (interactive) / "exec" (subagent run)
        var modelProvider: String?
        var model: String?           // from the first turn_context; nil until written
        var complete: Bool
    }

    let root: URL
    /// Injected liveness check (default: the `codex` process scan below). Tests pass a
    /// fixed closure to drive the active/recent boundary without a real process.
    private let processAlive: @Sendable () -> Bool

    private let cacheLock = NSLock()
    /// Header metadata keyed by ABSOLUTE PATH. A rollout file's header is immutable, so
    /// a path is a stable, sufficient key; complete entries are served from here
    /// without ever touching the file again.
    private var headerCache: [String: Header] = [:]

    /// A rollout header can reach ~42 KB on live data (2026-07-12, codex-cli 0.144.1):
    /// `session_meta` alone is ~17-22 KB because it inlines the full base_instructions
    /// system prompt, and the first `turn_context` lands a few records after it. The
    /// brief's nominal "8 KB head" predates that measurement and cannot capture either
    /// the terminated `session_meta` line or the `turn_context` model, so the head read
    /// is sized well above the observed maximum. It is a bounded HEAD read (never the
    /// multi-megabyte body) and, for a complete header, paid exactly once per file.
    private static let headByteCap = 128 * 1024

    /// A row is "active" only if a `codex` process is alive AND the file was written
    /// within this many seconds; otherwise "recent". Liveness is heuristic (Codex has
    /// no pid registry), so the wording stays conservative.
    static let activeMaxAge: TimeInterval = 2 * 60
    /// Candidate files must be no older (by mtime) than this. Combined with the
    /// today/yesterday date-dir walk below, it bounds the scan to the recent past.
    static let candidateMaxAge: TimeInterval = 24 * 3600

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".codex", isDirectory: true),
         processAlive: (@Sendable () -> Bool)? = nil) {
        self.root = root
        self.processAlive = processAlive ?? { CodexSessionsClient.anyCodexProcessAlive() }
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    // MARK: - Fetch

    /// Enumerate the interactive Codex sessions and summarize today's exec runs.
    ///
    /// Policy: gather rollout files from today's and yesterday's LOCAL date dirs (dir
    /// names are local time, so a file with mtime within 24 h can only sit in one of
    /// those two), keep those with mtime within `candidateMaxAge`, and order the whole
    /// set by mtime DESC. Order and recency come from mtime, NEVER from the local-time
    /// file names. For each file, read (or reuse the cached) header:
    /// - `source == "cli"` becomes a row: model from the header, context from the tail
    ///   `token_count`, status from liveness + mtime freshness.
    /// - `source == "exec"` feeds `execRunsToday` when its mtime falls in the local
    ///   today.
    func fetch(now: Date = Date()) -> CodexSessionsSnapshot {
        let cutoff = now.addingTimeInterval(-Self.candidateMaxAge)
        let candidates = candidateFiles(now: now)
            .filter { $0.mtime >= cutoff }
            .sorted { $0.mtime > $1.mtime }

        // The liveness scan is the same account-global answer for every row, so run it
        // once per fetch rather than per file.
        let alive = processAlive()
        let todayStart = Calendar.current.startOfDay(for: now)

        var rows: [ProviderSessionInfo] = []
        var execRunsToday = 0
        for file in candidates {
            let header = header(for: file.url)
            guard let source = header.source else { continue }   // session_meta not readable yet
            if source == "exec" {
                if file.mtime >= todayStart { execRunsToday += 1 }
                continue
            }
            guard source == "cli" else { continue }              // only interactive sessions are rows

            let (tokens, window) = tailContext(file.url)
            // active iff a codex process is alive AND the file was touched within the
            // freshness window; a dead process is "recent" no matter how fresh the mtime.
            let fresh = now.timeIntervalSince(file.mtime) <= Self.activeMaxAge
            let status = (alive && fresh) ? "active" : "recent"
            rows.append(ProviderSessionInfo(
                provider: .codex,
                pid: nil,                       // Codex has no pid registry
                sessionId: header.sessionId ?? "",
                cwd: header.cwd ?? "",
                status: status,
                model: header.model,            // nil while the header is still incomplete
                contextTokens: tokens,
                contextWindow: window,
                updatedAt: file.mtime,          // recency signal; mtime, per policy above
                sourceTag: source))
        }
        // `candidates` is already mtime-desc, so `rows` come out newest-first.
        return CodexSessionsSnapshot(rows: rows, execRunsToday: execRunsToday)
    }

    // MARK: - Header cache

    /// The header for a file, from cache when complete, otherwise (re-)read from disk.
    /// The file read happens OUTSIDE the lock so a slow head read never blocks another
    /// poll; a concurrent double-read is harmless (the header is immutable, last write
    /// wins on identical data).
    private func header(for url: URL) -> Header {
        let key = url.path
        cacheLock.lock()
        if let cached = headerCache[key], cached.complete {
            cacheLock.unlock()
            return cached                       // complete headers are never re-read
        }
        cacheLock.unlock()

        let fresh = readHeader(url)
        cacheLock.lock()
        headerCache[key] = fresh
        cacheLock.unlock()
        return fresh
    }

    /// Parse the header from a bounded HEAD read of the file. Only lines terminated by
    /// a newline inside the head buffer are parsed (a truncated trailing fragment is
    /// dropped), so partially-written records are never misread. The header is complete
    /// once `session_meta` and the first `turn_context` model are both in hand; the
    /// scan stops early at that point rather than parsing into the body.
    private func readHeader(_ url: URL) -> Header {
        var h = Header(sessionId: nil, cwd: nil, source: nil,
                       modelProvider: nil, model: nil, complete: false)
        guard let data = headBytes(url, cap: Self.headByteCap) else { return h }
        for line in Self.completeLines(data) {
            if h.source == nil, let meta = Self.sessionMeta(from: line) {
                h.sessionId = meta.sessionId
                h.cwd = meta.cwd
                h.source = meta.source
                h.modelProvider = meta.modelProvider
            } else if h.model == nil, let model = Self.turnContextModel(from: line) {
                h.model = model
            }
            if h.source != nil, h.model != nil { break }
        }
        h.complete = (h.source != nil) && (h.model != nil)
        return h
    }

    /// Read at most `cap` bytes from the START of the file. A bounded head read, never
    /// `Data(contentsOf:)` (which would pull the whole multi-megabyte body into memory).
    private func headBytes(_ url: URL, cap: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: cap)
    }

    /// The complete lines in a (possibly truncated) head buffer: everything up to and
    /// including the last newline, split on newlines. Any bytes after the final newline
    /// are an incomplete trailing record and are excluded. No newline at all means the
    /// first line did not terminate within the head (e.g. a pathological session_meta),
    /// so there are no complete lines.
    static func completeLines(_ data: Data) -> [Data] {
        guard let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        return data[...lastNL]
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    // MARK: - Line parsing (pure, static, testable)

    /// The immutable session fields from a `session_meta` line, or nil if the line is
    /// not a `session_meta` carrying at least session id, cwd, and source. A cheap
    /// substring pre-filter avoids JSON-parsing unrelated lines; the type check is
    /// authoritative (the base_instructions blob can quote arbitrary text).
    static func sessionMeta(from line: Data) -> (sessionId: String, cwd: String,
                                                 source: String, modelProvider: String?)? {
        guard let s = String(data: line, encoding: .utf8), s.contains("session_meta") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let sid = payload["session_id"] as? String,
              let cwd = payload["cwd"] as? String,
              let source = payload["source"] as? String else { return nil }
        return (sid, cwd, source, payload["model_provider"] as? String)
    }

    /// The `model` from a `turn_context` line, or nil if the line is not a
    /// `turn_context` (or carries no model).
    static func turnContextModel(from line: Data) -> String? {
        guard let s = String(data: line, encoding: .utf8), s.contains("turn_context") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "turn_context",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload["model"] as? String
    }

    /// Context fill (tokens, window) from one `token_count` line, or nil if the line is
    /// not a usable `token_count`. The context number is `last_token_usage.total_tokens`
    /// (the current turn's prompt size), NEVER `total_token_usage.total_tokens`, which
    /// accumulates across the whole session and compactions and wildly overstates the
    /// live context (781 K vs a 258 K window on live data). At least one of the two
    /// fields must be present for the line to count as a context anchor.
    static func context(from line: Data) -> (tokens: Int?, window: Int?)? {
        guard let s = String(data: line, encoding: .utf8), s.contains("token_count") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any] else { return nil }
        let window = (info["model_context_window"] as? NSNumber)?.intValue
        let last = info["last_token_usage"] as? [String: Any]
        let tokens = (last?["total_tokens"] as? NSNumber)?.intValue
        guard tokens != nil || window != nil else { return nil }
        return (tokens, window)
    }

    /// Tail-scan a rollout file for the newest `token_count` and return its context
    /// fill. `lastLineBackward` returns on the first EOF-ward match, so a file's older
    /// events are never touched.
    private func tailContext(_ url: URL) -> (tokens: Int?, window: Int?) {
        var result: (Int?, Int?) = (nil, nil)
        _ = JSONLBackscan.lastLineBackward(url: url) { line in
            guard let ctx = Self.context(from: line) else { return false }
            result = (ctx.tokens, ctx.window)
            return true
        }
        return result
    }

    // MARK: - Candidate files

    /// Rollout files from today's and yesterday's LOCAL date dirs, each with its mtime.
    /// Date dirs are named for the session's LOCAL start day, so these two dirs cover
    /// every session started within the last 24 h while avoiding a full-history walk;
    /// the caller's mtime filter and sort make the recency decision. Accepted residual
    /// (per the brief's candidate policy): a marathon session started before yesterday
    /// that is still being written lives in an older dir and is not listed. Directory
    /// reads only; no file bodies are opened here.
    private func candidateFiles(now: Date) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = Calendar.current.timeZone
        fmt.dateFormat = "yyyy/MM/dd"

        var dayPaths = Set<String>()
        dayPaths.insert(fmt.string(from: now))
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) {
            dayPaths.insert(fmt.string(from: yesterday))
        }

        var out: [(URL, Date)] = []
        for day in dayPaths {
            let dir = sessionsDir.appendingPathComponent(day, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.lastPathComponent.hasPrefix("rollout-")
                              && f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                out.append((f, m))
            }
        }
        return out
    }

    // MARK: - Process liveness (p_comm scan, same pattern as SessionsClient)

    /// True if ANY `codex` process is plausibly alive. Codex has no pid registry, so
    /// this is the whole liveness signal for the "active" tag. Mirrors
    /// `SessionsClient.anyProcessNamed` but is a private copy here so the Claude path is
    /// untouched.
    static func anyCodexProcessAlive() -> Bool { anyProcessNamed("codex") }

    /// Scan the kernel process table for a process. An exact (case-sensitive) p_comm
    /// match catches the native `codex` binary; npm installs are a #!-script whose
    /// p_comm is the INTERPRETER, so for those the argv of every node/bun process is
    /// checked for a "codex" entry. On any sysctl failure, report false: unlike the
    /// Claude rotation gate (which errs toward "alive" to avoid a logout), a false
    /// "alive" here would only mislabel a stale session "active", so the conservative
    /// answer is "not alive".
    private static func anyProcessNamed(_ name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return false }
        func commEquals(_ i: Int, _ s: String) -> Bool {
            withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return strncmp(base.assumingMemoryBound(to: CChar.self), s, raw.count) == 0
            }
        }
        var interpreters: [Int32] = []
        for i in 0..<(size / stride) {
            if commEquals(i, name) { return true }
            if commEquals(i, "node") || commEquals(i, "bun") {
                interpreters.append(procs[i].kp_proc.p_pid)
            }
        }
        for pid in interpreters where argvHasBasename(name, pid: pid) { return true }
        return false
    }

    /// True when one of the first few argv strings of `pid` has `name` as its last path
    /// component (the npm CLI shows up as "node .../bin/codex"). Only same-user
    /// processes are readable; failure means "can't tell" -> false.
    private static func argvHasBasename(_ name: String, pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let intSize = MemoryLayout<Int32>.size
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > intSize else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0, size > intSize else { return false }
        var i = intSize
        var seen = 0
        while i < size, seen < 4 {                      // exec path + argv[0...2]
            while i < size, buf[i] == 0 { i += 1 }      // skip the NUL padding runs
            guard i < size else { break }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            if (s as NSString).lastPathComponent == name { return true }
            seen += 1
        }
        return false
    }
}
