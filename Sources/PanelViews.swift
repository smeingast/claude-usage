import AppKit

/// Shared tokens for the custom menu rows. All colors resolve dynamically at
/// draw time (the views wrap rendering in performAsCurrentDrawingAppearance,
/// same pattern as HistoryGraphView), so light/dark both work.
enum PanelStyle {
    static let width: CGFloat = 360
    static let margin: CGFloat = 15

    /// Chrome accent for panel elements that don't encode a value (active
    /// pills, busy dot, context-bar fill, graph series). Follows the Color
    /// mode: coral for Claude, the user's macOS accent for System accent, and
    /// neutral label ink for monochrome/thresholds/heatmap — those modes
    /// reserve color for the data itself. Value-bearing elements (the header
    /// rings) use StatusRenderer.color(_:_:) directly instead, so the panel
    /// mirrors the glyph.
    static func accent(for mode: ColorMode) -> NSColor {
        switch mode {
        case .brand:                              return StatusRenderer.claudeCoral
        case .accent:                             return .controlAccentColor
        case .monochrome, .thresholds, .heatmap:  return .labelColor
        }
    }
    static var accent: NSColor { accent(for: Settings.colorMode) }
    static var accentHalf: NSColor { accent.withAlphaComponent(0.5) }

    /// True when the accent is a hue (coral / system accent) rather than
    /// neutral ink — gates the graph's area fill, which reads as smudge in gray.
    static func accentIsChromatic(_ mode: ColorMode) -> Bool {
        mode == .brand || mode == .accent
    }

    static var track: NSColor { .quaternaryLabelColor }
    static var chip: NSColor { .quaternaryLabelColor }
    static var pillOnText: NSColor { NSColor(srgbRed: 1, green: 0.965, blue: 0.945, alpha: 1) }

    /// Legible text on an accent-filled pill, picked by the fill's resolved
    /// luminance at draw time: a yellow system accent or the light ink of
    /// monochrome-in-dark-mode needs dark text; coral and the darker accents
    /// keep the warm off-white. Threshold 0.7 keeps dark-mode coral (0.63) on
    /// the light side, matching the pre-accent design.
    static func textOnAccent(_ fill: NSColor) -> NSColor {
        guard let c = fill.usingColorSpace(.sRGB) else { return pillOnText }
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.7 ? NSColor.black.withAlphaComponent(0.85) : pillOnText
    }

    static func draw(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
    static func size(_ s: String, font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }
    static func drawRight(_ s: String, rightEdge x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        let w = size(s, font: font).width
        draw(s, at: NSPoint(x: x - w, y: y), font: font, color: color)
    }
}

// MARK: - Header: rings + numbers + relative resets

struct PanelHeaderModel {
    var five: Double?
    var week: Double?
    var projected: Double?          // ghost arc; drawn only when > five + 0.5
    var fiveIsRed: Bool
    var fiveResetAbs: String?       // "resets 13:40"
    var fiveResetRel: String?       // "in 2h 07m"
    var weekResetAbs: String?       // "resets Sun 03:00"
    var weekResetRel: String?       // "in 7 days"
    var signedOut: Bool             // empty rings + em-dash values
}

/// The instrument: concentric rings (outer = 5-hour, inner = weekly, same
/// identity as the menu bar glyph) with the numbers beside them.
@MainActor
final class PanelHeaderView: NSView {
    static let height: CGFloat = 96
    private var model = PanelHeaderModel(five: nil, week: nil, projected: nil, fiveIsRed: false,
                                         fiveResetAbs: nil, fiveResetRel: nil,
                                         weekResetAbs: nil, weekResetRel: nil, signedOut: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    func configure(_ m: PanelHeaderModel) {
        model = m
        let five = m.five.map { "\(Int($0.rounded())) percent" } ?? "unknown"
        let week = m.week.map { "\(Int($0.rounded())) percent" } ?? "unknown"
        setAccessibilityLabel(m.signedOut ? "Signed out" : "5-hour \(five), weekly \(week)")
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        // Signed out is authoritative here: whatever stale values the model
        // still carries, the header shows em-dashes and no reset times.
        var m = model
        if m.signedOut {
            m.five = nil; m.week = nil; m.projected = nil; m.fiveIsRed = false
            m.fiveResetAbs = nil; m.fiveResetRel = nil
            m.weekResetAbs = nil; m.weekResetRel = nil
        }
        let size: CGFloat = 80
        let origin = NSPoint(x: PanelStyle.margin, y: (bounds.height - size) / 2)
        drawRings(in: NSRect(origin: origin, size: NSSize(width: size, height: size)), m)

        // Numbers column, two lines. Geometry per the design handoff.
        let x0 = origin.x + size + 15
        let rightEdge = bounds.width - PanelStyle.margin
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
        let midFont = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let resetBold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        func pct(_ v: Double?) -> String { v == nil ? "—" : "\(Int(v!.rounded()))%" }

        let line1Y: CGFloat = 16
        PanelStyle.draw("5-hour", at: NSPoint(x: x0, y: line1Y + 8), font: labelFont, color: .secondaryLabelColor)
        let fiveColor: NSColor = m.fiveIsRed ? .systemRed : .labelColor
        PanelStyle.draw(pct(m.five), at: NSPoint(x: x0 + 52, y: line1Y), font: bigFont, color: fiveColor)
        if let abs = m.fiveResetAbs {
            PanelStyle.drawRight(abs, rightEdge: rightEdge, y: line1Y + 2, font: resetFont, color: .tertiaryLabelColor)
        }
        if let rel = m.fiveResetRel {
            PanelStyle.drawRight(rel, rightEdge: rightEdge, y: line1Y + 16, font: resetBold, color: .secondaryLabelColor)
        }

        let line2Y: CGFloat = 54
        PanelStyle.draw("Weekly", at: NSPoint(x: x0, y: line2Y + 4), font: labelFont, color: .secondaryLabelColor)
        PanelStyle.draw(pct(m.week), at: NSPoint(x: x0 + 52, y: line2Y), font: midFont, color: .secondaryLabelColor)
        if let abs = m.weekResetAbs {
            PanelStyle.drawRight(abs, rightEdge: rightEdge, y: line2Y, font: resetFont, color: .tertiaryLabelColor)
        }
        if let rel = m.weekResetRel {
            PanelStyle.drawRight(rel, rightEdge: rightEdge, y: line2Y + 14, font: resetBold, color: .secondaryLabelColor)
        }
    }

    /// Ring geometry from the design handoff: lw = size·0.092, arc from 12
    /// o'clock, clockwise, round caps; ghost arc UNDER the value arc so only
    /// the current→projected span shows.
    private func drawRings(in rect: NSRect, _ m: PanelHeaderModel) {
        let size = rect.width
        let lw = size * 0.092
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let rO = size / 2 - lw / 2 - 1.2
        let rI = rO - lw - 2.8

        func arc(radius: CGFloat, frac: Double, color: NSColor) {
            guard frac > 0 else { return }
            let path = NSBezierPath()
            // Flipped coordinates: clockwise on screen is counterclockwise in
            // path space; start at 12 o'clock (angle -90 in flipped space).
            path.appendArc(withCenter: c, radius: radius, startAngle: -90,
                           endAngle: -90 + 360 * min(1, frac), clockwise: false)
            path.lineWidth = lw
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
        func trackRing(_ radius: CGFloat) {
            let p = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                                width: radius * 2, height: radius * 2))
            p.lineWidth = lw
            PanelStyle.track.setStroke()
            p.stroke()
        }
        trackRing(rO)
        trackRing(rI)
        guard !m.signedOut else { return }
        // Value arcs take the glyph's exact color function, so the rings track
        // the Color mode: coral (red ≥90) for Claude, orange/red warnings for
        // thresholds, the heat hue, the system accent, or plain ink.
        let mode = Settings.colorMode
        if let projected = m.projected, let five = m.five, projected > five + 0.5 {
            // At-cap amber matches the glyph's ghost: translucent, so it stays
            // separable from an orange heatmap/thresholds value arc.
            arc(radius: rO, frac: projected / 100,
                color: projected >= 100 ? NSColor.systemOrange.withAlphaComponent(0.45)
                                        : StatusRenderer.color(five, mode).withAlphaComponent(0.30))
        }
        arc(radius: rO, frac: (m.five ?? 0) / 100,
            color: StatusRenderer.color(m.five ?? 0, mode))
        arc(radius: rI, frac: (m.week ?? 0) / 100,
            color: StatusRenderer.color(m.week ?? 0, mode).withAlphaComponent(0.5))
    }
}


// MARK: - Session row

/// One live session: status dot, project name, model chip, context bar + count.
/// The bar is drawn only for model families with a known advertised context
/// window — for unknown families the exact count stands alone (never a bar,
/// never an amber warning, against a guessed window).
@MainActor
final class SessionRowView: NSView {
    static let height: CGFloat = 30
    private var info: SessionInfo?
    private var overflowCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    func configure(_ s: SessionInfo) {
        info = s; overflowCount = 0
        var label = "\(s.projectName), \(s.status)"
        if let m = s.shortModel { label += ", \(m)" }
        setAccessibilityLabel(label)
        needsDisplay = true
        displayIfNeeded()
    }

    func configureOverflow(_ count: Int) {
        info = nil; overflowCount = count
        setAccessibilityLabel("and \(count) more sessions")
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        if overflowCount > 0 {
            PanelStyle.draw("+ \(overflowCount) more",
                            at: NSPoint(x: PanelStyle.margin + 15, y: 7),
                            font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
            return
        }
        guard let s = info else { return }

        let card = NSRect(x: PanelStyle.margin, y: 0,
                          width: bounds.width - 2 * PanelStyle.margin, height: Self.height - 6)
        let dot = NSRect(x: card.minX + 9, y: card.midY - 4, width: 8, height: 8)
        (s.status.lowercased() == "busy" ? PanelStyle.accent : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: dot).fill()

        // Right side first, so the name knows how much room it has.
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        var rightEdge = card.maxX - 9
        let count = contextLabel(s.contextTokens)
        let countW = PanelStyle.size(count, font: countFont).width
        PanelStyle.draw(count, at: NSPoint(x: rightEdge - countW, y: card.midY - 6),
                        font: countFont, color: .secondaryLabelColor)
        rightEdge -= countW + 8

        if let tokens = s.contextTokens, let window = s.contextWindow {
            let barW: CGFloat = 56
            let bar = NSRect(x: rightEdge - barW, y: card.midY - 2, width: barW, height: 4)
            PanelStyle.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let frac = min(1, Double(tokens) / Double(window))
            if frac > 0.01 {
                let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height)
                (frac > 0.75 ? NSColor.systemOrange : PanelStyle.accentHalf).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            rightEdge -= barW + 10
        }

        var chipEdge = rightEdge
        if let short = s.shortModel {
            let chipFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let tw = PanelStyle.size(short, font: chipFont).width
            let chip = NSRect(x: chipEdge - tw - 12, y: card.midY - 8, width: tw + 12, height: 16)
            PanelStyle.chip.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            PanelStyle.draw(short, at: NSPoint(x: chip.minX + 6, y: chip.minY + 2),
                            font: chipFont, color: .secondaryLabelColor)
            chipEdge = chip.minX - 8
        }

        let nameX = dot.maxX + 8
        let name = s.projectName as NSString
        let nameRect = NSRect(x: nameX, y: card.midY - 8, width: max(0, chipEdge - nameX), height: 16)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        name.draw(with: nameRect, options: [.usesLineFragmentOrigin],
                  attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: para])
    }

    /// Compact token count, same buckets the text rows used.
    private func contextLabel(_ tokens: Int?) -> String {
        guard let t = tokens else { return "—" }
        if t < 1000 { return "\(t)" }
        let k = Double(t) / 1000
        return k < 10 ? String(format: "%.1fK", k) : "\(Int(k.rounded()))K"
    }
}

// MARK: - Range + mode pills

/// Inline replacements for the History Range and Graph submenus: one click,
/// menu stays open, the graph changes underneath. Custom menu-item views
/// receive mouse events; not calling cancelTracking keeps the menu up.
@MainActor
final class RangeModePillsView: NSView {
    static let height: CGFloat = 30
    var onChange: (() -> Void)?

    private var rangeRects: [(HistoryRange, NSRect)] = []
    private var modeRects: [(GraphMode, NSRect)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("History range and graph mode")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        rangeRects = []; modeRects = []
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let h: CGFloat = 20
        let y = (bounds.height - h) / 2
        var x = PanelStyle.margin
        let accent = PanelStyle.accent
        let onAccent = PanelStyle.textOnAccent(accent)

        for r in HistoryRange.allCases {
            let title = r.pillTitle
            let w = PanelStyle.size(title, font: font).width + 16
            let rect = NSRect(x: x, y: y, width: w, height: h)
            let active = r == Settings.historyRange
            (active ? accent : PanelStyle.chip).setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            PanelStyle.draw(title, at: NSPoint(x: rect.minX + 8, y: rect.minY + 3),
                            font: font, color: active ? onAccent : .secondaryLabelColor)
            rangeRects.append((r, rect))
            x = rect.maxX + 5
        }

        // Segmented Usage · Rate on the right.
        var rightX = bounds.width - PanelStyle.margin
        for g in GraphMode.allCases.reversed() {
            let title = g.pillTitle
            let w = PanelStyle.size(title, font: font).width + 16
            let rect = NSRect(x: rightX - w, y: y, width: w, height: h)
            let active = g == Settings.graphMode
            (active ? accent : PanelStyle.chip).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            PanelStyle.draw(title, at: NSPoint(x: rect.minX + 8, y: rect.minY + 3),
                            font: font, color: active ? onAccent : .secondaryLabelColor)
            modeRects.append((g, rect))
            rightX = rect.minX - 4
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, rect) in rangeRects where rect.insetBy(dx: -3, dy: -5).contains(p) {
            guard Settings.historyRange != r else { return }
            Settings.historyRange = r
            needsDisplay = true; displayIfNeeded()
            onChange?()
            return
        }
        for (g, rect) in modeRects where rect.insetBy(dx: -3, dy: -5).contains(p) {
            guard Settings.graphMode != g else { return }
            Settings.graphMode = g
            needsDisplay = true; displayIfNeeded()
            onChange?()
            return
        }
    }
}

extension HistoryRange {
    var pillTitle: String {
        switch self {
        case .last5h: return "5h"
        case .last24h: return "24h"
        case .last7d: return "7d"
        case .last30d: return "30d"
        }
    }
}

extension GraphMode {
    var pillTitle: String {
        switch self {
        case .utilization: return "Usage"
        case .rate: return "Rate"
        }
    }
}
