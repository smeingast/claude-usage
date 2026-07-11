import Foundation
import Darwin   // sysctl / kinfo_proc, for the process-identity (anti-PID-reuse) check

/// One live, local Claude Code session: the registry entry plus the current
/// context fill read from the tail of its transcript.
struct SessionInfo: Sendable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var status: String          // "busy" / "idle" / …
    var model: String?          // e.g. "claude-opus-4-8"
    var contextTokens: Int?     // context fill as of the last assistant turn; nil if unknown
    var updatedAt: Date?

    /// Last path component of the working directory (the project name).
    var projectName: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    /// The model family, short: "Opus" / "Sonnet" / "Haiku" / "Fable" / … For an
    /// unknown family, derive it from the id ("claude-zephyr-5" → "Zephyr") so a
    /// future model never widens the menu with a raw model id; the raw id is the
    /// last resort only when nothing in the id looks like a family name.
    var shortModel: String? {
        guard let m = model else { return nil }
        let lower = m.lowercased()
        for family in ["opus", "sonnet", "haiku", "fable", "mythos"] where lower.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        let stem = lower.hasPrefix("claude-") ? lower.dropFirst(7) : lower[...]
        if let family = stem.split(separator: "-")
            .first(where: { $0.count >= 3 && $0.allSatisfy(\.isLetter) }) {
            let f = String(family)
            return f.prefix(1).uppercased() + f.dropFirst()
        }
        return m
    }

    /// Advertised context window for the model family, or nil for unknown
    /// families (per model catalog, 2026-07: Opus/Sonnet/Fable/Mythos 1M,
    /// Haiku 200K). Used only to scale the session row's context bar — the
    /// bar is approximate by design and never drawn for unknown families;
    /// the exact token count stays the source of truth.
    var contextWindow: Int? {
        guard let m = model?.lowercased() else { return nil }
        if m.contains("haiku") { return 200_000 }
        for family in ["opus", "sonnet", "fable", "mythos"] where m.contains(family) {
            return 1_000_000
        }
        return nil
    }
}

/// Reads Claude Code's local session registry (`~/.claude/sessions/<pid>.json`)
/// and the tail of each transcript to report live sessions and their context
/// fill. Pure local file I/O, no network, no auth. Undocumented internal state
/// of Claude Code — best-effort, and liable to change between CLI versions.
///
/// Empty struct so it is trivially `Sendable` and safe to call off the main actor.
struct SessionsClient: Sendable {
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var sessionsDir: URL { home.appendingPathComponent(".claude/sessions") }
    private var projectsDir: URL { home.appendingPathComponent(".claude/projects") }

    /// Enumerate live local sessions, most recently active first.
    func fetch() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }

        var out: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sid = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { continue }
            // Drop stale registry files: the PID must be alive AND still be the same
            // process that wrote this entry (guards against the OS reusing a dead
            // session's PID for an unrelated process).
            let startedAtMs = (obj["startedAt"] as? NSNumber)?.doubleValue
            guard isAlive(pid), isSameProcess(pid: pid, startedAtMs: startedAtMs) else { continue }

            let status = (obj["status"] as? String) ?? "—"
            let updatedAt = (obj["updatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let (model, ctx) = lastContext(sessionId: sid, cwd: cwd)

            out.append(SessionInfo(pid: pid, sessionId: sid, cwd: cwd, status: status,
                                   model: model, contextTokens: ctx, updatedAt: updatedAt))
        }
        out.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return out
    }

    /// True if ANY local Claude Code process is plausibly alive. This gates token
    /// rotation (see UsageClient): rotating the single-use refresh token while a
    /// Claude Code holds the old one in memory forces the user to /login again.
    /// Two layers, deliberately erring toward true — a false "alive" only delays a
    /// usage fetch, a false "dead" can log the user out:
    /// - the session registry (interactive sessions), liveness-checked but without
    ///   the transcript reads `fetch()` does, and
    /// - a process-table scan for anything literally named "claude", which also
    ///   catches headless `claude -p` runs that never join the registry.
    func anyClaudeAlive() -> Bool {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (obj["pid"] as? NSNumber)?.int32Value
                else { continue }
                let startedAtMs = (obj["startedAt"] as? NSNumber)?.doubleValue
                if isAlive(pid), isSameProcess(pid: pid, startedAtMs: startedAtMs) { return true }
            }
        }
        return anyProcessNamed("claude")
    }

    /// Scan the kernel process table for the CLI. An exact (case-sensitive)
    /// p_comm match catches native-binary installs ("claude"; the desktop app is
    /// "Claude" and does not share these credentials). npm installs are a
    /// #!-script, so their p_comm is the INTERPRETER — for those, check the argv
    /// of every node/bun process for a "claude" entry. On any sysctl failure,
    /// report true — the conservative answer for the rotation gate.
    private func anyProcessNamed(_ name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return true }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return true }
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

    /// True when one of the first few argv strings of `pid` has `name` as its
    /// last path component — the npm CLI shows up as "node …/bin/claude".
    /// KERN_PROCARGS2 layout: argc (Int32), the exec path, NUL padding, then the
    /// argv strings; only same-user processes are readable, which is exactly the
    /// population that shares our Keychain item. Failure means "can't tell" →
    /// false: the p_comm layers above keep their own conservative defaults, and
    /// erring true here would permanently block rotation on any Mac that runs an
    /// unrelated node process we cannot inspect.
    private func argvHasBasename(_ name: String, pid: Int32) -> Bool {
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

    // MARK: - Liveness

    /// True if `pid` is a running process. `kill(pid, 0)` sends no signal: it
    /// returns 0 when the process exists, or fails with EPERM when it exists but
    /// we may not signal it (still alive). ESRCH means no such process.
    private func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True if `pid` is still the process that recorded this session. The kernel's
    /// process start time must match the registry's `startedAt` (these agree within
    /// ~1s in practice; a reused PID is off by minutes or more, so 30s is a safe
    /// margin). If the start time can't be read, trust liveness rather than risk
    /// hiding a real session.
    private func isSameProcess(pid: Int32, startedAtMs: Double?) -> Bool {
        guard let startedAtMs, let actual = startTimeMillis(pid) else { return true }
        return abs(actual - startedAtMs) < 30_000
    }

    /// Kernel process start time (epoch ms) via sysctl, or nil if unavailable.
    private func startTimeMillis(_ pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }

    // MARK: - Context fill from the transcript tail

    /// (model, contextTokens) from the last main-chain assistant message.
    /// contextTokens ≈ the prompt that turn occupied (input + cache + output),
    /// which is robust to compaction: the latest message already reflects the
    /// post-compaction prompt size.
    private func lastContext(sessionId: String, cwd: String) -> (String?, Int?) {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
              let obj = lastAssistantUsageEntry(url),
              let msg = obj["message"] as? [String: Any]
        else { return (nil, nil) }

        let model = msg["model"] as? String
        guard let usage = msg["usage"] as? [String: Any] else { return (model, nil) }
        func tok(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let ctx = tok("input_tokens") + tok("cache_creation_input_tokens")
                + tok("cache_read_input_tokens") + tok("output_tokens")
        return (model, ctx)
    }

    /// Locate `<sessionId>.jsonl`. Claude Code encodes the project dir by
    /// replacing "/" and "." in the cwd with "-"; if that guess misses (unknown
    /// encoding rules), fall back to scanning the project directories.
    private func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let encoded = String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        let guess = projectsDir.appendingPathComponent(encoded)
                               .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: guess.path) { return guess }

        if let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let cand = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: cand.path) { return cand }
            }
        }
        return nil
    }

    /// The last main-chain assistant message carrying a `usage` block, found by
    /// scanning the transcript backward from EOF (see `JSONLBackscan`). The scan's
    /// `match` hook is the existing pre-filter-plus-validation, so the selected
    /// line, and therefore the result, is identical to the pre-refactor inline
    /// walk. The matched object is captured as the predicate parses it, so no line
    /// is parsed twice.
    ///
    /// Internal (not private) so the scanner-parity test can drive it against a
    /// fixture transcript; unused outside this type in the app build.
    func lastAssistantUsageEntry(_ url: URL) -> [String: Any]? {
        var entry: [String: Any]?
        _ = JSONLBackscan.lastLineBackward(url: url) { line in
            guard let obj = assistantUsageEntry(line) else { return false }
            entry = obj
            return true
        }
        return entry
    }

    /// Parse one JSONL line; return it only if it is a main-chain assistant message
    /// with a `usage` block. A cheap substring pre-filter avoids JSON-parsing the
    /// large tool-result / user lines that dominate a transcript.
    private func assistantUsageEntry(_ line: Data) -> [String: Any]? {
        guard let s = String(data: line, encoding: .utf8),
              s.contains("\"usage\""), s.contains("\"assistant\"") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              (obj["isSidechain"] as? Bool) != true,
              let msg = obj["message"] as? [String: Any],
              msg["usage"] is [String: Any] else { return nil }
        return obj
    }
}
