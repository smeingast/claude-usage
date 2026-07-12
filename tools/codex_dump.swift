// codex_dump: a standalone, READ-ONLY probe of the live Codex data layer.
//
// Prints the current CodexUsageResult reconstructed from the real ~/.codex
// (status, both windows with label / utilization / reset, observed time, plan)
// and the 5 newest backfill events after a given ISO-8601 date. Meant to be
// eyeballed by the lead against the newest local token_count event.
//
// NEVER reads ~/.codex/auth.json (the client does not), never writes, no network.
//
// Compile and run (from the repo root). Providers.swift's Claude adapter pulls in
// UsageClient.swift, which pulls in Keychain.swift, so those two ride along even
// though this harness never calls them:
//
//   swiftc tools/codex_dump.swift \
//       Sources/CodexUsageClient.swift Sources/CodexSessionsClient.swift \
//       Sources/Providers.swift Sources/JSONLBackscan.swift \
//       Sources/UsageClient.swift Sources/Keychain.swift \
//       -o /tmp/codex_dump && /tmp/codex_dump [ISO8601-after-date]
//
// Example: /tmp/codex_dump 2026-07-11T00:00:00Z

import Foundation

// MARK: - Output formatting

func fmt(_ date: Date?) -> String {
    guard let date else { return "nil" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

func describe(_ w: UsageWindow?, _ name: String) {
    guard let w else { print("  \(name): (absent)"); return }
    print("  \(name): \(w.title), \(w.utilization)%, windowMinutes=\(w.windowMinutes.map(String.init) ?? "nil"), resets=\(fmt(w.resetsAt))")
}

// MARK: - Entry point
//
// A multi-file swiftc build allows top-level statements only in a `main.swift`, so
// the runnable logic lives in an `@main` type (the other Sources files carry only
// declarations). File-level `func`s above are fine either way.

@main
struct CodexDump {
    static func main() {
        let args = CommandLine.arguments
        let afterArg = args.count > 1 ? args[1] : nil
        let cutoff: Date = {
            if let s = afterArg, let d = ISO.parse(s) ?? ISO.parse(s + "Z") { return d }
            // Default: last 24 h, so a bare invocation still shows something useful.
            return Date().addingTimeInterval(-24 * 3600)
        }()

        let client = CodexUsageClient()          // real ~/.codex, read-only

        print("== Codex usage snapshot (live ~/.codex) ==")
        let result = client.fetch()
        switch result.status {
        case .notInstalled: print("status: notInstalled (no ~/.codex)")
        case .noData:       print("status: noData (no usable token_count in bounds)")
        case .ok:           print("status: ok")
        }
        if let snap = result.snapshot {
            print("  provider: \(snap.provider.rawValue)")
            print("  planType: \(snap.planType ?? "nil")")
            switch snap.freshness {
            case .live:            print("  freshness: live")
            case .observed(let t): print("  observedAt: \(fmt(t))")
            }
            print("  fetchedAt: \(fmt(snap.fetchedAt))")
            describe(snap.primary, "primary")
            describe(snap.secondary, "secondary")
            // Effective values now (post-reset inference for observed snapshots).
            let now = Date()
            if let p = snap.primary {
                let e = effectiveUtilization(p, freshness: snap.freshness, now: now)
                print("  primary effective now: \(e.value)% inferredZero=\(e.inferredZero)")
            }
            if let s = snap.secondary {
                let e = effectiveUtilization(s, freshness: snap.freshness, now: now)
                print("  secondary effective now: \(e.value)% inferredZero=\(e.inferredZero)")
            }
        }

        print("")
        print("== Newest backfill events after \(fmt(cutoff)) ==")
        let events = client.backfillEvents(after: cutoff)
        if events.isEmpty {
            print("  (none)")
        } else {
            // backfillEvents returns ascending; show the 5 newest, newest last.
            for ev in events.suffix(5) {
                let p = ev.primaryPercent.map { "\($0)%" } ?? "nil"
                let s = ev.secondaryPercent.map { "\($0)%" } ?? "nil"
                print("  \(fmt(ev.timestamp))  primary=\(p) (resets \(fmt(ev.primaryResetsAt)))  secondary=\(s) (resets \(fmt(ev.secondaryResetsAt)))")
            }
            print("  total events after cutoff: \(events.count)")
            // The same batch through the ingest-side stray-anchor sandwich filter,
            // so the exec-subagent strays the app would drop are visible here too.
            let cleaned = CodexUsageClient.filterStrays(events)
            print("  after sandwich filter: \(cleaned.count) (\(events.count - cleaned.count) stray(s) dropped)")
            for ev in cleaned.suffix(5) {
                let p = ev.primaryPercent.map { "\($0)%" } ?? "nil"
                print("    \(fmt(ev.timestamp))  primary=\(p) (resets \(fmt(ev.primaryResetsAt)))")
            }
        }

        print("")
        print("== Codex sessions (live ~/.codex) ==")
        // Real ~/.codex, read-only; the default process-alive scan runs, so a "codex"
        // process started for the check shows an interactive session as "active".
        let sessions = CodexSessionsClient().fetch()
        if sessions.rows.isEmpty {
            print("  (no cli rows in the last 24 h)")
        } else {
            for r in sessions.rows {
                let tail = (r.cwd as NSString).lastPathComponent
                let tok = r.contextTokens.map(String.init) ?? "nil"
                let win = r.contextWindow.map(String.init) ?? "nil"
                print("  [\(r.sourceTag ?? "?")] \(r.status)  model=\(r.model ?? "nil")  cwd=\(tail)  ctx=\(tok)/\(win)  updated=\(fmt(r.updatedAt))")
            }
        }
        print("  exec runs today: \(sessions.execRunsToday)")
    }
}
