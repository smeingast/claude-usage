import Foundation

/// One persisted usage sample: the two headline utilizations (plus each window's
/// reset time) at a real fetch instant. Optionals are genuine gaps (window absent
/// from the response), never coerced to 0.
struct HistorySample: Sendable {
    let t: Date
    let five: Double?
    let week: Double?
    let fiveResetsAt: Date?
    let weekResetsAt: Date?
}

/// Append-only local history, one compact JSON line per successful poll, under
/// Application Support. Pure file I/O, all funneled through a private serial queue so
/// the 5-minute append can never race the occasional whole-file trim. Non-critical
/// telemetry: every failure is logged and swallowed, never thrown, so the UI is never
/// blocked on it. `@unchecked Sendable` is sound because the only shared state is the
/// serial queue and the immutable file URL; every file access goes through `queue`.
final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "eu.smeingast.claude-menubar-usage.history")
    private let fileURL: URL?

    /// Back a store with a specific filename in the shared Application Support
    /// directory. A second provider (Codex) uses this to keep its history in a
    /// separate file; the Claude path is unchanged (`init()` delegates here with
    /// "history.jsonl"). The two instances share a queue LABEL but are distinct
    /// serial queues, so their file I/O never interleaves.
    init(filename: String) {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
        fileURL = base?
            .appendingPathComponent("eu.smeingast.claude-menubar-usage", isDirectory: true)
            .appendingPathComponent(filename)
    }

    convenience init() { self.init(filename: "history.jsonl") }

    /// Append one sample as a compact JSON line. Serialized, fire-and-forget.
    func append(_ s: HistorySample) {
        guard let fileURL else { return }
        queue.async {
            var obj: [String: Any] = ["t": Int(s.t.timeIntervalSince1970.rounded())]
            if let v = s.five { obj["f"] = v }
            if let v = s.week { obj["w"] = v }
            if let d = s.fiveResetsAt { obj["fr"] = Int(d.timeIntervalSince1970.rounded()) }
            if let d = s.weekResetsAt { obj["wr"] = Int(d.timeIntervalSince1970.rounded()) }
            guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
            line.append(0x0A)
            do {
                let fm = FileManager.default
                let dir = fileURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                if !fm.fileExists(atPath: fileURL.path) {
                    fm.createFile(atPath: fileURL.path, contents: nil)
                }
                let h = try FileHandle(forWritingTo: fileURL)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } catch {
                NSLog("ClaudeUsage: history append failed: \(error)")
            }
        }
    }

    /// Load samples newer than `maxAge`, oldest-first. Tolerates a corrupt trailing line
    /// (a torn final append) the same way SessionsClient tolerates bad transcript lines.
    func load(maxAge: TimeInterval) -> [HistorySample] {
        guard let fileURL else { return [] }
        dispatchPrecondition(condition: .notOnQueue(queue))   // queue.sync from the queue would deadlock
        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let cutoff = Date().addingTimeInterval(-maxAge)
            var out: [HistorySample] = []
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let ts = (obj["t"] as? NSNumber)?.doubleValue else { continue }
                let t = Date(timeIntervalSince1970: ts)
                if t < cutoff { continue }
                func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
                func date(_ k: String) -> Date? {
                    (obj[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                }
                out.append(HistorySample(t: t, five: num("f"), week: num("w"),
                                         fiveResetsAt: date("fr"), weekResetsAt: date("wr")))
            }
            out.sort { $0.t < $1.t }
            return out
        }
    }

    /// Drop samples older than `maxAge` via Foundation's atomic write (temp + rename).
    /// Rare: launch and roughly once per day of uptime, never on the 5-minute hot path.
    func trim(maxAge: TimeInterval) {
        guard let fileURL else { return }
        queue.async {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL) else { return }
            let cutoff = Date().addingTimeInterval(-maxAge)
            var kept = Data()
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let ts = (obj["t"] as? NSNumber)?.doubleValue else { continue }
                if Date(timeIntervalSince1970: ts) < cutoff { continue }
                kept.append(Data(line)); kept.append(0x0A)
            }
            do {
                try kept.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("ClaudeUsage: history trim failed: \(error)")
            }
        }
    }
}
