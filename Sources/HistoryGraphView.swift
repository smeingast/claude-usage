import AppKit

/// Immutable snapshot the graph view draws. Built on the main actor in AppDelegate and
/// never crossing an actor boundary, so it needs no Sendable conformance. `samples` is
/// already sliced to `range` and oldest-first.
struct GraphData {
    var samples: [HistorySample]
    var mode: GraphMode
    var range: HistoryRange
    var colorMode: ColorMode
    var now: Date
    var fiveNow: Double?
    var weekNow: Double?
    // Forecast overlay (utilization mode only): the right edge of the plot
    // becomes a look-ahead to the 5-hour reset, with a dotted projection.
    var fiveResetsAt: Date?
    var projected: Double?
    var crosses: Bool = false
    var crossTime: Date?
    // Two-provider additions (package 4b). `provider` tints the series in Brand mode
    // (coral / teal) and drives the "gaps = idle" legend; `forecastIdle` draws the
    // "forecast pauses (idle)" placeholder when the graphed Codex provider has no
    // live burn rate; `readoutPrefix` names the provider before the readout numbers
    // (amendment 26: two stacked cards must stay distinguishable in the non-Brand
    // color modes; nil in Claude-only mode keeps the readout byte-identical to
    // v0.8). All default to today's Claude behavior.
    var provider: UsageProviderKind = .claude
    var forecastIdle: Bool = false
    var readoutPrefix: String? = nil

    /// Cheap identity so the view can skip redraws when nothing meaningful changed
    /// (menuNeedsUpdate fires on every menu-tracking tick). The `now / 30` bucket lets a
    /// held-open menu's window edge advance at most twice a minute, not on every tick.
    /// Includes the current readout values, so a forced refresh inside the sampling
    /// throttle (no new sample) still repaints the "5h NN%" line.
    var signature: String {
        let last = samples.last.map { Int($0.t.timeIntervalSince1970) } ?? 0
        let f = fiveNow.map { Int($0.rounded()) } ?? -1
        let w = weekNow.map { Int($0.rounded()) } ?? -1
        let p = projected.map { Int($0.rounded()) } ?? -1
        let r = fiveResetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
        let ct = crossTime.map { Int($0.timeIntervalSince1970) / 60 } ?? -1
        return "\(last)|\(samples.count)|\(mode.rawValue)|\(range.rawValue)|\(colorMode.rawValue)|\(f)|\(w)|\(p)|\(crosses)|\(r)|\(ct)|\(provider.rawValue)|\(forecastIdle)|\(readoutPrefix ?? "")|\(Int(now.timeIntervalSince1970) / 30)"
    }
}

/// A passive sparkline of 5-hour (headline) and weekly utilization over time, shown as a
/// custom-view row inside the dropdown. Two modes: the raw utilization curve, or the
/// per-sample positive rise ("consumption rate"). Pure renderer: owns no fetch or storage.
@MainActor
final class HistoryGraphView: NSView {
    private var model: GraphData?

    // Hover scrubbing: sample positions from the last render, and the current
    // crosshair sample. Hover redraws bypass the signature (needsDisplay direct).
    private var hoverPoints: [(x: CGFloat, t: Date, five: Double?, week: Double?)] = []
    private var hover: (x: CGFloat, t: Date, five: Double?, week: Double?)?

    /// A normal step is the 300s poll; above this, treat two samples as a data gap (sleep
    /// or errors): break the utilization line and emit no rate bar across it. Generous
    /// enough that a single slightly-late poll does not fragment the line.
    private let gapTolerance: TimeInterval = 12 * 60

    // Templates, not literal formats: the axis hour follows the user's 12/24-hour
    // clock preference, and the day label follows the locale's month/day order.
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMd"); return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Fill the menu width if a longer text row makes the menu wider than our base size;
        // drawing is responsive to bounds.width either way (the session rows are unbounded,
        // so we cannot pin to "the longest row" at build time).
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Hover scrubbing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !hoverPoints.isEmpty else { return }
        let mx = convert(event.locationInWindow, from: nil).x
        var best = hoverPoints[0]
        for p in hoverPoints where abs(p.x - mx) < abs(best.x - mx) { best = p }
        if hover?.t != best.t {
            hover = best
            needsDisplay = true
            displayIfNeeded()   // menu tracking does not service needsDisplay alone
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hover != nil else { return }
        hover = nil
        needsDisplay = true
        displayIfNeeded()
    }

    /// Push fresh data; redraw only when the signature actually changed. displayIfNeeded()
    /// forces a synchronous repaint, since needsDisplay alone is not contractually serviced
    /// while a status-item menu is tracking.
    func update(_ d: GraphData) {
        guard d.signature != model?.signature else { return }
        hover = nil          // the old crosshair may not exist in the new model
        model = d
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // Resolve the dynamic ClaudeCoral (and label colors) against the menu bar's current
        // light/dark appearance at draw time.
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    // MARK: - Rendering

    private func render() {
        guard let m = model else { return }
        let b = bounds
        let leftGutter: CGFloat = 28, bottomAxis: CGFloat = 12, topPad: CGFloat = 5, rightPad: CGFloat = 8
        let plot = CGRect(x: b.minX + leftGutter, y: b.minY + bottomAxis,
                          width: max(1, b.width - leftGutter - rightPad),
                          height: max(1, b.height - bottomAxis - topPad))

        let fivePts = m.samples.compactMap { s in s.five.map { (s.t, $0) } }
        let weekPts = m.samples.compactMap { s in s.week.map { (s.t, $0) } }

        // Need at least two points in one drawable series; a lone sample (even with both
        // values) has nothing to connect, so keep showing the collecting state.
        if max(fivePts.count, weekPts.count) < 2 {
            hoverPoints = []; hover = nil
            drawCentered("Collecting history…", in: b, color: .secondaryLabelColor)
            return
        }

        let t0 = m.now.addingTimeInterval(-m.range.duration)

        // Forecast look-ahead (utilization mode only): the plot keeps ONE
        // continuous time axis that extends past "now" to the 5-hour reset, so
        // the projection's slope reads true against the history — a fixed-width
        // zone would stretch or squeeze the look-ahead depending on the range.
        // Proportionality also decides where the zone appears at all: in the
        // 7d/30d views (and for an imminent reset) it would be a sliver a few
        // points wide, so it only shows when it gets legible room.
        var fcActive = m.mode == .utilization && m.fiveNow != nil && m.projected != nil
            && (m.range == .last5h || m.range == .last24h)
            && (m.fiveResetsAt.map { $0 > m.now } ?? false)
        var histWidth = plot.width
        if fcActive, let reset = m.fiveResetsAt {
            let resetIn = reset.timeIntervalSince(m.now)
            let frac = CGFloat(m.range.duration / (m.range.duration + resetIn))
            if plot.width * (1 - frac) >= 24 {
                histWidth = plot.width * frac
            } else {
                fcActive = false        // too thin to read — draw plain history
            }
        } else {
            fcActive = false
        }
        let histMaxX = plot.minX + histWidth
        func X(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(max(0, min(1, t.timeIntervalSince(t0) / m.range.duration))) * histWidth
        }
        func FX(_ t: Date) -> CGFloat {
            guard fcActive, let reset = m.fiveResetsAt, reset > m.now else { return histMaxX }
            let frac = max(0, min(1, t.timeIntervalSince(m.now) / reset.timeIntervalSince(m.now)))
            return histMaxX + CGFloat(frac) * (plot.maxX - histMaxX)
        }

        // Series ink follows the panel accent: coral (Claude) / teal (Codex) in
        // Brand mode, the system accent in System accent mode, neutral otherwise
        // (tinting a whole time series by a single current value is not meaningful
        // for thresholds/heatmap). The readout still carries the colored cue in every
        // mode. `provider` only bites in Brand mode; every other mode keeps today's
        // Claude ink, so the Claude-only graph is unchanged.
        let chromatic = PanelStyle.accentIsChromatic(m.colorMode)
        let brandCodex = m.colorMode == .brand && m.provider == .codex
        let fiveColor = brandCodex ? StatusRenderer.codexTeal : PanelStyle.accent(for: m.colorMode)
        let weekColor = brandCodex ? StatusRenderer.codexTealWeekly.withAlphaComponent(0.5)
                                   : fiveColor.withAlphaComponent(0.5)

        hoverPoints = []
        if m.mode == .utilization {
            var peak = max(100.0, (fivePts + weekPts).map { $0.1 }.max() ?? 0)
            if fcActive, let p = m.projected { peak = max(peak, p) }
            func Y(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, peak) / peak) * plot.height }

            if fcActive {
                fiveColor.withAlphaComponent(0.05).setFill()
                NSBezierPath(rect: CGRect(x: histMaxX, y: plot.minY,
                                          width: plot.maxX - histMaxX, height: plot.height)).fill()
                strokeVLine(at: histMaxX, from: plot.minY, to: plot.maxY, color: .quaternaryLabelColor)
                strokeVLine(at: plot.maxX, from: plot.minY, to: plot.maxY,
                            color: .tertiaryLabelColor, dashed: true)
            }
            strokeHLine(at: Y(0), from: plot.minX, to: plot.maxX, color: .quaternaryLabelColor)
            strokeHLine(at: Y(100), from: plot.minX, to: plot.maxX, color: .tertiaryLabelColor, dashed: true)
            drawText("100", at: CGPoint(x: plot.minX - 26, y: Y(100) - 5), color: .tertiaryLabelColor)
            // weekly behind (thin line), 5-hour in front (line + faint fill)
            drawLine(weekPts, x: X, y: Y, color: weekColor, width: 1.0)
            drawLine(fivePts, x: X, y: Y, color: fiveColor, width: 1.5,
                     fillTo: chromatic ? plot.minY : nil, fillColor: fiveColor.withAlphaComponent(0.16))
            if fcActive { drawProjection(m, Y: Y, FX: FX, startX: histMaxX, fiveColor: fiveColor) }

            hoverPoints = m.samples.compactMap { s in
                (s.five == nil && s.week == nil) ? nil : (x: X(s.t), t: s.t, five: s.five, week: s.week)
            }
            drawHover(plot: plot, Y: Y)
        } else {
            let fiveBars = rateBars(fivePts)
            let weekBars = rateBars(weekPts)
            let peak = max(1.0, (fiveBars + weekBars).map { $0.1 }.max() ?? 1)
            func Y(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, peak) / peak) * plot.height }
            strokeHLine(at: plot.minY, from: plot.minX, to: plot.maxX, color: .quaternaryLabelColor)
            drawBars(weekBars, x: X, y: Y, baseY: plot.minY, color: weekColor, width: 1.0)
            drawBars(fiveBars, x: X, y: Y, baseY: plot.minY, color: fiveColor, width: 1.5)
        }

        drawReadout(m, in: b, leftAligned: fcActive, plot: plot)
        drawTimeAxis(m, plot: plot, t0: t0, fcActive: fcActive, histMaxX: histMaxX)
        drawCodexIdleLegends(m, plot: plot)
    }

    /// Codex-only honesty annotations (amendment 10). When the graphed Codex window
    /// is idle (no live rate) the forecast is not drawn; label its absence rather than
    /// imply a projection. The "gaps = idle" note only shows on the 5h/24h ranges,
    /// where the 48 h backfill makes real idle gaps meaningful (7d/30d gaps can be
    /// app-off periods). Neither draws for Claude.
    private func drawCodexIdleLegends(_ m: GraphData, plot: CGRect) {
        guard m.provider == .codex else { return }
        let f = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let shortRange = m.range == .last5h || m.range == .last24h
        if m.forecastIdle && m.mode == .utilization && shortRange {
            let s = "forecast pauses (idle)"
            let w = (s as NSString).size(withAttributes: [.font: f]).width
            drawText(s, at: CGPoint(x: plot.maxX - w, y: plot.midY - 5),
                     color: .tertiaryLabelColor, font: f)
        }
        if shortRange {
            let s = "gaps = idle"
            let w = (s as NSString).size(withAttributes: [.font: f]).width
            drawText(s, at: CGPoint(x: plot.maxX - w, y: plot.minY + 1),
                     color: .quaternaryLabelColor, font: f)
        }
    }

    /// Dotted projection from (now, current) toward the reset. If it crosses
    /// 100 before the reset: amber to the crossing, a small red dot there, and
    /// a faint run onward at the cap. Otherwise coral to (reset, projected).
    private func drawProjection(_ m: GraphData, Y: (Double) -> CGFloat, FX: (Date) -> CGFloat,
                                startX: CGFloat, fiveColor: NSColor) {
        guard let five = m.fiveNow, let projected = m.projected else { return }
        let start = CGPoint(x: startX, y: Y(five))
        func dotted(from a: CGPoint, to bPt: CGPoint, color: NSColor, width: CGFloat = 1.2) {
            let p = NSBezierPath()
            p.move(to: a); p.line(to: bPt)
            p.lineWidth = width
            p.setLineDash([2.5, 2.5], count: 2, phase: 0)
            p.lineCapStyle = .round
            color.setStroke(); p.stroke()
        }
        func dot(_ at: CGPoint, _ color: NSColor, r: CGFloat = 2.5) {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)).fill()
        }
        if m.crosses, let cross = m.crossTime, let reset = m.fiveResetsAt {
            let crossPt = CGPoint(x: FX(cross), y: Y(100))
            dotted(from: start, to: crossPt, color: .systemOrange)
            dot(crossPt, .systemRed)
            dotted(from: crossPt, to: CGPoint(x: FX(reset), y: Y(100)),
                   color: NSColor.systemOrange.withAlphaComponent(0.35))
        } else if let reset = m.fiveResetsAt {
            let end = CGPoint(x: FX(reset), y: Y(projected))
            dotted(from: start, to: end, color: fiveColor)
            dot(end, fiveColor, r: 2)
        }
    }

    /// Crosshair + dot on the 5-hour line + a compact value chip.
    private func drawHover(plot: CGRect, Y: (Double) -> CGFloat) {
        guard let h = hover, let m = model else { return }
        strokeVLine(at: h.x, from: plot.minY, to: plot.maxY, color: .tertiaryLabelColor)
        if let five = h.five {
            let p = CGPoint(x: h.x, y: Y(five))
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
        }
        let short = m.range == .last5h || m.range == .last24h
        let timeLabel = short
            ? Self.hmFormatter.string(from: h.t)
            : "\(Self.dayFormatter.string(from: h.t)) \(Self.hmFormatter.string(from: h.t))"
        func pct(_ v: Double?) -> String { v == nil ? "—" : "\(Int(v!.rounded()))%" }
        let label = "\(timeLabel)  5h \(pct(h.five))  wk \(pct(h.week))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let size = (label as NSString).size(withAttributes: [.font: font])
        var x = h.x + 7
        if x + size.width + 10 > plot.maxX { x = h.x - size.width - 17 }
        let chip = CGRect(x: x, y: plot.maxY - size.height - 8,
                          width: size.width + 10, height: size.height + 5)
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: CGPoint(x: chip.minX + 5, y: chip.minY + 2.5),
                                 withAttributes: [.font: font,
                                                  .foregroundColor: NSColor.windowBackgroundColor])
    }

    private func strokeVLine(at x: CGFloat, from y0: CGFloat, to y1: CGFloat,
                             color: NSColor, dashed: Bool = false) {
        let p = NSBezierPath(); p.lineWidth = 0.5
        if dashed { p.setLineDash([2, 2], count: 2, phase: 0) }
        p.move(to: CGPoint(x: x, y: y0)); p.line(to: CGPoint(x: x, y: y1))
        color.setStroke(); p.stroke()
    }

    /// Stroke a polyline (optionally filled to a baseline), broken into segments at data
    /// gaps so sleep/outage gaps are not bridged with a fake line.
    private func drawLine(_ pts: [(Date, Double)], x X: (Date) -> CGFloat, y Y: (Double) -> CGFloat,
                          color: NSColor, width: CGFloat, fillTo baseY: CGFloat? = nil,
                          fillColor: NSColor? = nil) {
        var seg: [(Date, Double)] = []
        func flush() {
            defer { seg = [] }
            guard seg.count >= 1 else { return }
            if let baseY, let fc = fillColor, seg.count >= 2 {
                let fill = NSBezierPath()
                fill.move(to: CGPoint(x: X(seg[0].0), y: baseY))
                for p in seg { fill.line(to: CGPoint(x: X(p.0), y: Y(p.1))) }
                fill.line(to: CGPoint(x: X(seg[seg.count - 1].0), y: baseY))
                fill.close()
                fc.setFill(); fill.fill()
            }
            let path = NSBezierPath()
            path.lineWidth = width; path.lineJoinStyle = .round; path.lineCapStyle = .round
            for (i, p) in seg.enumerated() {
                let pt = CGPoint(x: X(p.0), y: Y(p.1))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            color.setStroke(); path.stroke()
        }
        var prev: Date?
        for p in pts {
            if let pr = prev, p.0.timeIntervalSince(pr) > gapTolerance { flush() }
            seg.append(p); prev = p.0
        }
        flush()
    }

    /// Per-sample positive rise, normalized to "% points per ~5 min" so the unit is
    /// consistent across a short dt (Refresh Now) and across ranges. Suppressed across
    /// non-positive dt and gaps. A reset or aging produces a negative delta, which max(0,)
    /// discards, so no explicit reset detection is needed.
    ///
    /// Known, disclosed limitation: the single bar spanning a reset undercounts, because
    /// the rise is measured from the pre-reset value rather than from 0. Bounded and rare
    /// (weekly: once a week); fixing it cleanly needs the resets_at semantics we are
    /// instrumenting first, so it is deferred. Consistent with the lower-bound framing.
    private func rateBars(_ pts: [(Date, Double)]) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        guard pts.count >= 2 else { return out }
        for i in 1..<pts.count {
            let (pt, pv) = pts[i - 1]; let (ct, cv) = pts[i]
            let dt = ct.timeIntervalSince(pt)
            guard dt > 0, dt <= gapTolerance else { continue }
            out.append((ct, max(0, cv - pv) * 300 / dt))
        }
        return out
    }

    private func drawBars(_ bars: [(Date, Double)], x X: (Date) -> CGFloat, y Y: (Double) -> CGFloat,
                          baseY: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        for (t, v) in bars where v > 0 {
            let xx = X(t)
            let p = NSBezierPath()
            p.lineWidth = width; p.lineCapStyle = .round
            p.move(to: CGPoint(x: xx, y: baseY))
            p.line(to: CGPoint(x: xx, y: Y(v)))
            p.stroke()
        }
    }

    private func strokeHLine(at y: CGFloat, from x0: CGFloat, to x1: CGFloat,
                             color: NSColor, dashed: Bool = false) {
        let p = NSBezierPath(); p.lineWidth = 0.5
        if dashed { p.setLineDash([2, 2], count: 2, phase: 0) }
        p.move(to: CGPoint(x: x0, y: y)); p.line(to: CGPoint(x: x1, y: y))
        color.setStroke(); p.stroke()
    }

    private func drawReadout(_ m: GraphData, in rect: CGRect,
                             leftAligned: Bool = false, plot: CGRect = .zero) {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let s = NSMutableAttributedString()
        // Provider-name prefix (amendment 26): with two stacked cards, the readout
        // carries the provider in its accent so the cards stay distinguishable in
        // monochrome / thresholds / heatmap, where the series ink is neutral. Nil in
        // Claude-only mode: the readout stays byte-identical to v0.8.
        if let prefix = m.readoutPrefix {
            s.append(NSAttributedString(string: prefix + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: StatusRenderer.providerAccent(m.provider)]))
        }
        func add(_ label: String, _ v: Double?) {
            s.append(NSAttributedString(string: label,
                attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor]))
            let vs = v == nil ? "—" : "\(Int(v!.rounded()))%"
            let col = v == nil ? NSColor.secondaryLabelColor
                               : StatusRenderer.color(v!, m.colorMode, provider: m.provider)
            s.append(NSAttributedString(string: vs, attributes: [.font: f, .foregroundColor: col]))
        }
        add("5h ", m.fiveNow)
        s.append(NSAttributedString(string: "   ", attributes: [.font: f]))
        add("wk ", m.weekNow)
        let sz = s.size()
        // With the forecast zone active, the top-right corner belongs to the
        // projection (the 100%-crossing dot lands exactly there) — tuck the
        // readout into the top-left of the plot instead.
        let x = leftAligned ? plot.minX + 4 : rect.maxX - sz.width - 8
        s.draw(at: CGPoint(x: x, y: rect.maxY - sz.height - 1))
    }

    private func drawTimeAxis(_ m: GraphData, plot: CGRect, t0: Date,
                              fcActive: Bool, histMaxX: CGFloat) {
        let fmt = (m.range == .last5h || m.range == .last24h) ? Self.hmFormatter : Self.dayFormatter
        let f = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        drawText(fmt.string(from: t0), at: CGPoint(x: plot.minX, y: 0), color: .tertiaryLabelColor, font: f)
        if fcActive, let reset = m.fiveResetsAt {
            // "now" sits just left of the history/forecast divider; the reset
            // time labels the dashed tick at the right edge.
            let nowLbl = "now"
            let nw = (nowLbl as NSString).size(withAttributes: [.font: f]).width
            drawText(nowLbl, at: CGPoint(x: histMaxX - nw - 2, y: 0), color: .tertiaryLabelColor, font: f)
            let resetLbl = Self.hmFormatter.string(from: reset)
            let rw = (resetLbl as NSString).size(withAttributes: [.font: f]).width
            drawText(resetLbl, at: CGPoint(x: plot.maxX - rw, y: 0), color: .tertiaryLabelColor, font: f)
        } else {
            let right = "now"
            let rw = (right as NSString).size(withAttributes: [.font: f]).width
            drawText(right, at: CGPoint(x: plot.maxX - rw, y: 0), color: .tertiaryLabelColor, font: f)
        }
        let cap = (m.mode == .utilization ? "Utilization" : "Rise/5m") + " · " + m.range.title
        let cw = (cap as NSString).size(withAttributes: [.font: f]).width
        let capX = fcActive ? plot.minX + (histMaxX - plot.minX) / 2 - cw / 2 : plot.midX - cw / 2
        drawText(cap, at: CGPoint(x: capX, y: 0), color: .quaternaryLabelColor, font: f)
    }

    private func drawText(_ s: String, at p: CGPoint, color: NSColor, font: NSFont? = nil) {
        let f = font ?? NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
    }

    private func drawCentered(_ s: String, in rect: CGRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2),
                             withAttributes: attrs)
    }
}
