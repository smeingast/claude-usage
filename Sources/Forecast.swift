import Foundation

/// Burn-rate forecast for the 5-hour window: the last hour's positive rise,
/// projected forward to the window's reset. Same lower-bound framing as
/// HistoryGraphView.rateBars (the reset-spanning undercount caveat applies).
///
/// The sampling window is clipped at the CURRENT 5-hour window's start
/// (resetsAt − 5 h): a plain "last hour" would count the pre-reset climb after
/// a reset and, with ~5 fresh hours to project across, fire spurious pace
/// warnings for up to an hour after every reset that follows heavy use.
struct Forecast {
    var ratePerHour: Double          // %-points per hour, ≥ 0
    var projected: Double            // capped to 100, never below current
    var crosses: Bool                // projection reaches 100 before the reset
    var crossTime: Date?             // when it does (nil unless crosses)

    static let gapTolerance: TimeInterval = 12 * 60   // matches HistoryGraphView
    static let fiveWindow: TimeInterval = 5 * 3600

    static func compute(samples: [HistorySample], now: Date,
                        current: Double?, resetsAt: Date?) -> Forecast? {
        guard let current else { return nil }
        var windowStart = now.addingTimeInterval(-3600)
        if let resetsAt {
            windowStart = max(windowStart, resetsAt.addingTimeInterval(-fiveWindow))
        }
        let pts = samples.filter { $0.t > windowStart && $0.five != nil }

        var rise = 0.0
        for i in 1..<max(1, pts.count) {
            let dt = pts[i].t.timeIntervalSince(pts[i - 1].t)
            if dt > 0, dt <= gapTolerance {
                rise += max(0, pts[i].five! - pts[i - 1].five!)
            }
        }
        // Fold in the freshest reading: a fetch inside the sampling throttle
        // updates `current` without appending a sample, and a sharp burn in
        // that gap must not be invisible to the rate.
        var spanEnd = pts.last?.t
        if let last = pts.last, let lastFive = last.five {
            let dt = now.timeIntervalSince(last.t)
            if dt > 0, dt <= gapTolerance {
                rise += max(0, current - lastFive)
                spanEnd = now
            }
        }
        let span = (pts.first?.t).flatMap { first in spanEnd?.timeIntervalSince(first) } ?? 0
        // One poll interval of history minimum — a shorter baseline is noise.
        let rate = span >= 240 ? rise / span * 3600 : 0

        guard let resetsAt, resetsAt > now else {
            return Forecast(ratePerHour: rate, projected: current, crosses: false, crossTime: nil)
        }
        let toResetHr = resetsAt.timeIntervalSince(now) / 3600
        let uncapped = current + rate * toResetHr
        // `current` can legitimately exceed 100 (the API reports 100+): the
        // projection then holds at current, and "crossing" is meaningless.
        let projected = current >= 100 ? current : min(100, max(current, uncapped))
        let crosses = current < 100 && uncapped > 100 && rate > 0
        var crossTime: Date?
        if crosses {
            let frac = max(0, min(1, (100 - current) / (uncapped - current)))
            crossTime = now.addingTimeInterval(resetsAt.timeIntervalSince(now) * frac)
        }
        return Forecast(ratePerHour: rate, projected: projected, crosses: crosses, crossTime: crossTime)
    }
}
