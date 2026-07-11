import Foundation

/// Backward (EOF-first) line scanner for the large JSONL transcripts Claude Code
/// and Codex append to. Factored out of `SessionsClient` so both the Claude case
/// (last matching line) and the Codex backfill case (all matching lines in a
/// recent run) share one carefully-bounded implementation.
///
/// The target line sits a few KB from EOF in practice, so the scan almost always
/// returns on the first window; the bounds guard the pathological whole-file walk:
/// fixed 256 KB windows are read high offset to low, a straddling line fragment is
/// carried across each boundary (so every byte is read at most once and no
/// complete line is ever split), and a 32 MB cap stops a runaway scan.
enum JSONLBackscan {
    private static let newline: UInt8 = 0x0A
    private static let chunk: UInt64 = 256 * 1024
    private static let scanCap: UInt64 = 32 * 1024 * 1024   // safety bound for a pathological tail

    /// The first line (raw bytes, newline excluded) from EOF for which `match`
    /// returns true, or nil if none is found within the scan cap. `match` is the
    /// caller's pre-filter-plus-validation hook (e.g. the "assistant message with
    /// a usage block" test); it is invoked on complete lines newest-first.
    static func lastLineBackward(url: URL, match: (Data) -> Bool) -> Data? {
        var result: Data?
        scanBackward(url: url) { line in
            if match(line) { result = line; return .stop }
            return .keepGoing
        }
        return result
    }

    /// All lines (raw bytes, newline excluded) for which `match` returns true,
    /// NEWEST-FIRST, walking backward from EOF and stopping as soon as
    /// `shouldContinue` returns false for a line. That is a take-while over the
    /// newest run: the stopping line and everything older than it are excluded.
    /// The Codex backfill uses `shouldContinue` as a timestamp gate ("event newer
    /// than the last one already stored") and `match` to keep only `token_count`
    /// events.
    ///
    /// The returned array is REVERSE-CHRONOLOGICAL; callers that need ascending
    /// time must re-sort. Kept newest-first here because that is the order the scan
    /// produces and the take-while gate reads most naturally against it.
    static func collectLinesBackward(url: URL,
                                     while shouldContinue: (Data) -> Bool,
                                     match: (Data) -> Bool) -> [Data] {
        var out: [Data] = []
        scanBackward(url: url) { line in
            guard shouldContinue(line) else { return .stop }
            if match(line) { out.append(line) }
            return .keepGoing
        }
        return out
    }

    // MARK: - Shared backward walk

    private enum Step { case keepGoing, stop }

    /// Deliver complete lines to `visit` newest-first, high offset to low, until
    /// `visit` returns `.stop`, byte 0 is reached, or the 32 MB cap trips. The
    /// carry holds a line's tail awaiting its head in the next (lower) window.
    private static func scanBackward(url: URL, visit: (Data) -> Step) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return }

        var pos = end
        var carry = Data()                       // a line's tail, awaiting its head lower down

        while pos > 0 {
            if end - pos > scanCap { return }
            let readLen = min(chunk, pos)
            let start = pos - readLen
            guard (try? handle.seek(toOffset: start)) != nil,
                  let buf = try? handle.read(upToCount: Int(readLen)) else { return }

            var data = buf
            if !carry.isEmpty { data.append(carry) }

            if let nl = data.firstIndex(of: newline) {
                // Everything after the first newline is complete lines (the appended
                // carry completes the highest one); visit them newest-first.
                let after = Data(data[data.index(after: nl)...])
                for line in after.split(separator: newline, omittingEmptySubsequences: true).reversed() {
                    if case .stop = visit(Data(line)) { return }
                }
                carry = Data(data[..<nl])        // head fragment continues into the next window
            } else {
                carry = data                     // no newline yet — keep accumulating downward
            }
            pos = start
        }
        // Reached byte 0: the remaining carry is the file's first (complete) line.
        if !carry.isEmpty { _ = visit(carry) }
    }
}
