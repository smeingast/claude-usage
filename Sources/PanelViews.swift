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
    // Two-provider additions (package 4b). Defaults reproduce the v0.8 Claude header
    // byte-for-byte: `provider == .claude` keeps coral, `inferred*` false keeps solid
    // rings. Only the two-provider instrument sets these to render Codex / a rolled
    // window; the Claude-only path never touches them.
    var provider: UsageProviderKind = .claude
    var inferredFive: Bool = false
    var inferredWeek: Bool = false
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

    /// Ring geometry now lives in the shared `PanelRings.draw` so the two-provider
    /// instrument and the compact strip match this header exactly. With the model's
    /// defaults (`provider == .claude`, no inferred windows) the output is
    /// byte-identical to the v0.8 header: `StatusRenderer.color` with the default
    /// provider is the same call this used to make, and the rO/rI rings never overlap
    /// so the reordered draw sequence paints the same pixels.
    private func drawRings(in rect: NSRect, _ m: PanelHeaderModel) {
        PanelRings.draw(in: rect, five: m.five, week: m.week, projected: m.projected,
                        mode: Settings.colorMode, provider: m.provider,
                        inferredFive: m.inferredFive, inferredWeek: m.inferredWeek,
                        signedOut: m.signedOut)
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
    // Two-provider additions (package 4b). A row renders one of: a Claude session
    // (`info`), a Codex session (`codexInfo`), the overflow tail (`overflowCount`),
    // or the muted Codex-exec summary (`execCount`). Every configure resets the
    // others so a reused row never mixes states.
    private var codexInfo: ProviderSessionInfo?
    private var execCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    func configure(_ s: SessionInfo) {
        info = s; overflowCount = 0; codexInfo = nil; execCount = 0
        var label = "\(s.projectName), \(s.status)"
        if let m = s.shortModel { label += ", \(m)" }
        setAccessibilityLabel(label)
        needsDisplay = true
        displayIfNeeded()
    }

    func configureOverflow(_ count: Int) {
        info = nil; overflowCount = count; codexInfo = nil; execCount = 0
        setAccessibilityLabel("and \(count) more sessions")
        needsDisplay = true
        displayIfNeeded()
    }

    /// A Codex interactive ("cli") session row: teal (active) / gray (recent) dot,
    /// project, model chip, a context bar against the true per-turn window, and the
    /// active/recent tag (words that describe the log, never a live process).
    func configure(codex s: ProviderSessionInfo) {
        codexInfo = s; info = nil; overflowCount = 0; execCount = 0
        let project = (s.cwd as NSString).lastPathComponent
        setAccessibilityLabel("\(project.isEmpty ? s.cwd : project), \(s.status), Codex")
        needsDisplay = true
        displayIfNeeded()
    }

    /// The single muted summary row for today's `codex exec` automation runs; the
    /// individual runs are never listed.
    func configureExec(_ count: Int) {
        execCount = count; info = nil; codexInfo = nil; overflowCount = 0
        setAccessibilityLabel("plus \(count) Codex exec runs today")
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        if execCount > 0 { renderExec(); return }
        if let c = codexInfo { renderCodex(c, nameFont: nameFont); return }
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

    /// A Codex "cli" session row. Same right-to-left layout as the Claude row
    /// (count, bar, chip, name), but with the teal/gray liveness dot, the true
    /// per-turn context window ("103K/353K"), and the active/recent tag. The tag and
    /// chip both use the Codex teal so the row reads as Codex at a glance.
    private func renderCodex(_ s: ProviderSessionInfo, nameFont: NSFont) {
        let card = NSRect(x: PanelStyle.margin, y: 0,
                          width: bounds.width - 2 * PanelStyle.margin, height: Self.height - 6)
        let active = s.status == "active"
        let dot = NSRect(x: card.minX + 9, y: card.midY - 4, width: 8, height: 8)
        (active ? StatusRenderer.codexTeal : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: dot).fill()

        // Context "tokens/window" on the right (window is the real per-turn window).
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        var rightEdge = card.maxX - 9
        let count = s.contextWindow != nil
            ? "\(contextLabel(s.contextTokens))/\(contextLabel(s.contextWindow))"
            : contextLabel(s.contextTokens)
        let countW = PanelStyle.size(count, font: countFont).width
        PanelStyle.draw(count, at: NSPoint(x: rightEdge - countW, y: card.midY - 6),
                        font: countFont, color: .secondaryLabelColor)
        rightEdge -= countW + 8

        if let tokens = s.contextTokens, let window = s.contextWindow, window > 0 {
            let barW: CGFloat = 56
            let bar = NSRect(x: rightEdge - barW, y: card.midY - 2, width: barW, height: 4)
            PanelStyle.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            let frac = min(1, Double(tokens) / Double(window))
            if frac > 0.01 {
                let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height)
                (frac > 0.75 ? NSColor.systemOrange : StatusRenderer.codexTeal.withAlphaComponent(0.5)).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            rightEdge -= barW + 10
        }

        var chipEdge = rightEdge
        if let model = s.model, !model.isEmpty {
            let chipFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let tw = PanelStyle.size(model, font: chipFont).width
            let chip = NSRect(x: chipEdge - tw - 12, y: card.midY - 8, width: tw + 12, height: 16)
            StatusRenderer.codexTeal.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            PanelStyle.draw(model, at: NSPoint(x: chip.minX + 6, y: chip.minY + 2),
                            font: chipFont, color: .secondaryLabelColor)
            chipEdge = chip.minX - 8
        }

        // active / recent tag, left of the chip.
        let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let tw = ceil(PanelStyle.size(s.status, font: tagFont).width)
        PanelStyle.draw(s.status, at: NSPoint(x: chipEdge - tw, y: card.midY - 6),
                        font: tagFont, color: StatusRenderer.codexTeal)
        chipEdge -= tw + 8

        let nameX = dot.maxX + 8
        let project = (s.cwd as NSString).lastPathComponent
        let name = (project.isEmpty ? s.cwd : project) as NSString
        let nameRect = NSRect(x: nameX, y: card.midY - 8, width: max(0, chipEdge - nameX), height: 16)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        name.draw(with: nameRect, options: [.usesLineFragmentOrigin],
                  attributes: [.font: nameFont, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: para])
    }

    /// The muted Codex-exec summary row: "+ N Codex exec runs today", with a small
    /// square teal marker and an "automation" caption.
    private func renderExec() {
        let card = NSRect(x: PanelStyle.margin, y: 0,
                          width: bounds.width - 2 * PanelStyle.margin, height: Self.height - 6)
        let marker = NSRect(x: card.minX + 9, y: card.midY - 4, width: 8, height: 8)
        StatusRenderer.codexTeal.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: marker, xRadius: 2, yRadius: 2).fill()
        let label = "+ \(execCount) Codex exec runs today"
        PanelStyle.draw(label, at: NSPoint(x: marker.maxX + 8, y: card.midY - 7),
                        font: NSFont.systemFont(ofSize: 11.5), color: .tertiaryLabelColor)
        let capFont = NSFont.systemFont(ofSize: 10.5)
        PanelStyle.drawRight("automation \u{00B7} summarized", rightEdge: card.maxX - 9,
                             y: card.midY - 6, font: capFont, color: .tertiaryLabelColor)
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
