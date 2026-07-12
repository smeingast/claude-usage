import AppKit

// Two-provider panel chrome (package 4b): the shared concentric-ring drawer, the
// provider tag row, the honesty banner, the compact secondary strip, and the graph
// provider pill. These render ONLY when Codex is visible; the Claude-only path is
// the literal v0.8 panel (amendment 7) and touches none of this. All copy is fed
// in pre-derived (see ProviderState); these views are dumb painters.
//
// Colors resolve at draw time inside performAsCurrentDrawingAppearance (same pattern
// as the rest of PanelViews), so light and dark both work.

// MARK: - Shared ring drawer

/// The concentric instrument rings (outer = 5-hour, inner = weekly), factored out of
/// PanelHeaderView so the two-provider instrument and the 40 pt strip share one
/// geometry. With `provider == .claude`, `inferredFive/Week == false`, and a Brand
/// weekly that resolves to coral, this reproduces the v0.8 header rings exactly
/// (PanelHeaderView still calls it for the Claude-only path). The value-arc accent
/// follows the Color mode via `StatusRenderer.color`; a rolled window (amendment 9)
/// draws a dashed, fill-less track instead of a solid arc.
enum PanelRings {
    static func draw(in rect: NSRect, five: Double?, week: Double?, projected: Double?,
                     mode: ColorMode, provider: UsageProviderKind, role: ProviderRole = .primary,
                     inferredFive: Bool = false, inferredWeek: Bool = false,
                     signedOut: Bool = false) {
        let size = rect.width
        let lw = size * 0.092
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let rO = size / 2 - lw / 2 - 1.2
        let rI = rO - lw - 2.8

        func arc(radius: CGFloat, frac: Double, color: NSColor) {
            guard frac > 0 else { return }
            let path = NSBezierPath()
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
        // Inferred-zero (amendment 9): a dashed, fill-less ring marks a value computed
        // from a passed reset rather than observed.
        func dashedTrack(_ radius: CGFloat) {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.setLineDash([lw * 0.9, lw * 1.4], count: 2, phase: 0)
            PanelStyle.track.setStroke()
            p.stroke()
        }

        // Signed out: empty tracks, no values (matches PanelHeaderView).
        if signedOut { trackRing(rO); trackRing(rI); return }

        // Outer ring (5-hour). rO and rI never overlap, so the inter-ring draw order
        // is immaterial; within the ring the order (track, ghost, value) matches v0.8.
        if inferredFive {
            dashedTrack(rO)
        } else {
            trackRing(rO)
            if let projected, let five, projected > five + 0.5 {
                let ghost = projected >= 100
                    ? NSColor.systemOrange.withAlphaComponent(0.45)
                    : StatusRenderer.color(five, mode, provider: provider, role: role).withAlphaComponent(0.30)
                arc(radius: rO, frac: projected / 100, color: ghost)
            }
            arc(radius: rO, frac: (five ?? 0) / 100,
                color: StatusRenderer.color(five ?? 0, mode, provider: provider, role: role))
        }

        // Inner ring (weekly). Brand mode uses the provider's weekly companion tint
        // (amendment 4: coral for Claude keeps v0.8 identity, teal-weekly for Codex);
        // the other modes keep their value-driven semantics.
        if inferredWeek {
            dashedTrack(rI)
        } else {
            trackRing(rI)
            let weekColor: NSColor = (mode == .brand && provider == .codex)
                ? StatusRenderer.codexTealWeekly.withAlphaComponent(0.5)
                : StatusRenderer.color(week ?? 0, mode, provider: provider, role: role).withAlphaComponent(0.5)
            arc(radius: rI, frac: (week ?? 0) / 100, color: weekColor)
        }
    }
}

// MARK: - Chip helpers

/// Small pill/chip painters shared by the tag row and strip. Each returns the drawn
/// width so callers can lay chips left-to-right.
enum PanelChip {
    /// The width `draw` will occupy, WITHOUT drawing. The chip rows measure against
    /// the age line's left edge before committing to a chip (amendment 21), so the
    /// width math must live in one place and stay identical to `draw`'s.
    static func width(_ text: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attrs[.kern] = kern }
        return ceil((text as NSString).size(withAttributes: attrs).width) + 12
    }

    @discardableResult
    static func draw(_ text: String, at x: CGFloat, midY: CGFloat, font: NSFont,
                     fill: NSColor?, textColor: NSColor, bordered: Bool = false,
                     kern: CGFloat = 0) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        if kern != 0 { attrs[.kern] = kern }
        let tw = (text as NSString).size(withAttributes: attrs).width
        let w = ceil(tw) + 12
        let h: CGFloat = 16
        let rect = NSRect(x: x, y: midY - h / 2, width: w, height: h)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
        if bordered {
            NSColor.quaternaryLabelColor.setStroke()
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            p.lineWidth = 1
            p.stroke()
        }
        (text as NSString).draw(at: NSPoint(x: rect.minX + 6, y: midY - font.pointSize / 2 + 1),
                                withAttributes: attrs)
        return w
    }
}

// MARK: - Provider tag row

/// The two-provider instrument's header row: the provider chip (+ Codex plan and
/// "local" chips), with the freshness age line right-aligned. Fixed height; shown
/// only in two-provider mode.
struct TagRowModel {
    var provider: UsageProviderKind
    var label: String            // "Claude" / "Codex"
    var planType: String?        // Codex plan chip
    var showLocalChip: Bool      // Codex "local" caveat
    var ageLine: String
    var ageWarn: Bool
}

@MainActor
final class TagRowView: NSView {
    static let height: CGFloat = 24
    private var model: TagRowModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    func configure(_ m: TagRowModel) {
        model = m
        setAccessibilityLabel("\(m.label), \(m.ageLine)")
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        guard let m = model else { return }
        let midY = bounds.height / 2
        let accent = StatusRenderer.providerAccent(m.provider)

        // The age line owns the right edge (amendment 21, seen live: a long "as of
        // HH:MM · Nm ago" drew over the local chip). Its left edge is computed FIRST,
        // and chips are then laid left-to-right only while they clear it by >= 8 pt.
        // Priority when space runs out: the local chip drops first, the plan chip
        // next, the provider chip last; the age line is never drawn over a chip.
        let ageFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let ageW = ceil(PanelStyle.size(m.ageLine, font: ageFont).width)
        let ageLeft = bounds.width - PanelStyle.margin - ageW
        let clearance: CGFloat = 8

        var x = PanelStyle.margin
        // Provider chip: uppercase, on a soft accent wash.
        let tagFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        if x + PanelChip.width(m.label.uppercased(), font: tagFont, kern: 0.4) <= ageLeft - clearance {
            x += PanelChip.draw(m.label.uppercased(), at: x, midY: midY, font: tagFont,
                                fill: accent.withAlphaComponent(0.14), textColor: accent, kern: 0.4)
            x += 5
        }
        if let plan = m.planType, !plan.isEmpty {
            let planFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            if x + PanelChip.width(plan, font: planFont) <= ageLeft - clearance {
                x += PanelChip.draw(plan, at: x, midY: midY, font: planFont,
                                    fill: PanelStyle.chip, textColor: .secondaryLabelColor)
                x += 5
            }
        }
        if m.showLocalChip {
            let localFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            if x + PanelChip.width("\u{24D8} local", font: localFont) <= ageLeft - clearance {
                PanelChip.draw("\u{24D8} local", at: x, midY: midY, font: localFont,
                               fill: nil, textColor: .tertiaryLabelColor, bordered: true)
            }
        }
        // Age line, right-aligned; amber when the reading is stale/aged.
        PanelStyle.drawRight(m.ageLine, rightEdge: bounds.width - PanelStyle.margin,
                             y: midY - ageFont.pointSize / 2 - 1, font: ageFont,
                             color: m.ageWarn ? .systemOrange : .tertiaryLabelColor)
    }
}

// MARK: - Honesty banner (model + height math)

/// A state-colored dot plus a wrapped message. The primary instrument banner that
/// used to render this was removed by amendment 24 ("this box should never
/// appear"), so no BannerView is instantiated anymore; the type stays because the
/// STRIP's compact sub-banner reuses `BannerModel` as its model and
/// `BannerView.height` as its height math (StripView draws the sub-banner itself).
struct BannerModel {
    var dotColor: NSColor
    var text: String
}

@MainActor
final class BannerView: NSView {
    private var model: BannerModel?
    private static let font = NSFont.systemFont(ofSize: 12.5)
    private static let hInset: CGFloat = 11
    private static let vInset: CGFloat = 9
    private static let dotGap: CGFloat = 9
    private static let dotSize: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    /// Text wrapping width inside the card, so height() and render() agree.
    private static func textWidth(_ viewWidth: CGFloat) -> CGFloat {
        viewWidth - 2 * PanelStyle.margin - 2 * hInset - dotSize - dotGap
    }

    /// The row height this banner needs for `text` at the panel width.
    static func height(for text: String, viewWidth: CGFloat) -> CGFloat {
        let r = (text as NSString).boundingRect(
            with: NSSize(width: textWidth(viewWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return ceil(r.height) + 2 * vInset + 6      // + top gap (matches the concept's 12px)
    }

    func configure(_ m: BannerModel) {
        model = m
        setAccessibilityLabel(m.text)
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        guard let m = model else { return }
        // An empty message means "no banner" (amendment 19). The row itself is hidden
        // per-open, but a mid-open state change can hand an allocated banner an empty
        // message; blank space beats an empty card with a lone dot until the next
        // open resolves the row away.
        guard !m.text.isEmpty else { return }
        let card = NSRect(x: PanelStyle.margin, y: 4,
                          width: bounds.width - 2 * PanelStyle.margin,
                          height: bounds.height - 6)
        PanelStyle.chip.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9).fill()

        let dot = NSRect(x: card.minX + Self.hInset, y: card.minY + Self.vInset + 2,
                         width: Self.dotSize, height: Self.dotSize)
        m.dotColor.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let textX = dot.maxX + Self.dotGap
        let textRect = NSRect(x: textX, y: card.minY + Self.vInset - 1,
                              width: card.maxX - Self.hInset - textX,
                              height: card.height - 2 * Self.vInset + 2)
        (m.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    }
}

// MARK: - Compact secondary strip

/// The secondary provider's compact strip: 40 pt rings, inline numbers, a reset line
/// (with compact Claude extras appended when Claude is secondary, amendment 8),
/// provider chips, a Lead button, and an inferred/aged honesty sub-banner. Height is
/// resolved at menu open (amendment 1); the Lead button swaps content in place.
struct StripModel {
    var provider: UsageProviderKind
    var label: String
    var planType: String?
    var showLocalChip: Bool
    var hasData: Bool
    var noDataMessage: String?    // shown in place of the numbers when !hasData
    var ageLine: String
    var ageWarn: Bool
    var five: Double?
    var week: Double?
    var mode: ColorMode
    var fiveIsRed: Bool
    var inferredFive: Bool
    var inferredWeek: Bool
    var rawFivePct: Int?          // struck prior 5-hour figure (inferred-zero, per window)
    var rawWeekPct: Int?          // struck prior weekly figure (inferred-zero, per window)
    var resetLine: String?        // "resets HH:MM \u{00B7} 4h 35m" (+ appended extras)
    var subBanner: BannerModel?   // inferred/aged sub-banner (drives the strip height)
    var otherLabel: String        // the provider Lead would promote (for the tooltip/a11y)
}

@MainActor
final class StripView: NSView {
    private var model: StripModel?
    private var leadRect: NSRect = .zero
    var onLead: (() -> Void)?

    static let mainRowHeight: CGFloat = 66

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
    override var isFlipped: Bool { true }

    /// The row height a strip needs, resolved at menu open: the fixed main row plus
    /// the sub-banner when the state is inferred/aged.
    static func height(for m: StripModel, viewWidth: CGFloat) -> CGFloat {
        var h = mainRowHeight
        if let sb = m.subBanner {
            h += BannerView.height(for: sb.text, viewWidth: viewWidth) - 4
        }
        return h + 11   // top gap (concept: margin-top:11)
    }

    func configure(_ m: StripModel) {
        model = m
        setAccessibilityLabel("\(m.label) \(m.ageLine)")
        needsDisplay = true
        displayIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.render() }
    }

    private func render() {
        guard let m = model else { return }
        // The strip renders BORDERLESS (amendment 22, Stefan's live feedback): no
        // rounded-rect around the card, visually consistent with the primary panel
        // content. `card` survives purely as the layout rectangle; the Lead button
        // keeps its own small border (it is a button) and the sub-banner keeps its
        // hairline separator.
        let card = NSRect(x: PanelStyle.margin, y: 11,
                          width: bounds.width - 2 * PanelStyle.margin,
                          height: bounds.height - 11)

        let mainMidY = card.minY + StripView.mainRowHeight / 2
        // 40 pt rings, left.
        let ringSize: CGFloat = 40
        let ringRect = NSRect(x: card.minX + 11, y: mainMidY - ringSize / 2,
                              width: ringSize, height: ringSize)
        PanelRings.draw(in: ringRect, five: m.hasData ? (m.five ?? 0) : nil,
                        week: m.hasData ? (m.week ?? 0) : nil, projected: nil,
                        mode: m.mode, provider: m.provider, role: .secondary,
                        inferredFive: m.inferredFive, inferredWeek: m.inferredWeek,
                        signedOut: !m.hasData)

        // Lead button, right. Drawn first so the text column knows its right edge.
        let leadFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let leadText = "\u{21C5} Lead"
        let leadW = ceil((leadText as NSString).size(withAttributes: [.font: leadFont]).width) + 16
        leadRect = NSRect(x: card.maxX - 11 - leadW, y: card.minY + 10, width: leadW, height: 22)
        NSColor.quaternaryLabelColor.setStroke()
        let leadPath = NSBezierPath(roundedRect: leadRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        leadPath.lineWidth = 1
        leadPath.stroke()
        (leadText as NSString).draw(at: NSPoint(x: leadRect.minX + 8, y: leadRect.midY - leadFont.pointSize / 2 - 1),
                                    withAttributes: [.font: leadFont, .foregroundColor: NSColor.secondaryLabelColor])

        let colX = ringRect.maxX + 11
        let colRight = leadRect.minX - 10

        // Chips + age line (top line of the column). The age line owns the right
        // edge (amendment 21): its left edge is computed FIRST, and chips draw
        // left-to-right only while they clear it by >= 8 pt. Priority when space
        // runs out: the local chip drops first, the plan chip next, the provider
        // chip last; the age line is never drawn over a chip.
        let chipMidY = card.minY + 14
        let accent = StatusRenderer.providerAccent(m.provider)
        let ageFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let ageW = ceil(PanelStyle.size(m.ageLine, font: ageFont).width)
        let ageLeft = colRight - ageW
        let clearance: CGFloat = 8

        var cx = colX
        let provFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        if cx + PanelChip.width(m.label.uppercased(), font: provFont, kern: 0.4) <= ageLeft - clearance {
            cx += PanelChip.draw(m.label.uppercased(), at: cx, midY: chipMidY,
                                 font: provFont, fill: nil, textColor: accent, kern: 0.4)
            cx += 4
        }
        if let plan = m.planType, !plan.isEmpty {
            let planFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
            if cx + PanelChip.width(plan, font: planFont) <= ageLeft - clearance {
                cx += PanelChip.draw(plan, at: cx, midY: chipMidY,
                                     font: planFont, fill: PanelStyle.chip,
                                     textColor: .secondaryLabelColor)
                cx += 4
            }
        }
        if m.showLocalChip {
            let localFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
            if cx + PanelChip.width("\u{24D8} local", font: localFont) <= ageLeft - clearance {
                PanelChip.draw("\u{24D8} local", at: cx, midY: chipMidY,
                               font: localFont, fill: nil, textColor: .tertiaryLabelColor,
                               bordered: true)
            }
        }
        PanelStyle.drawRight(m.ageLine, rightEdge: colRight, y: chipMidY - ageFont.pointSize / 2 - 1,
                             font: ageFont, color: m.ageWarn ? .systemOrange : .tertiaryLabelColor)

        // Values line.
        let valY = card.minY + 30
        if m.hasData {
            var vx = colX
            let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            let unitFont = NSFont.systemFont(ofSize: 11)
            let midFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            // A rolled window's stale figure is struck NEXT TO its own window's value
            // (amendment 9: only that window's figure is struck), so a weekly-only
            // roll never strikes anything near the 5-hour number and vice versa.
            let strikeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            func strike(_ raw: Int) {
                let s = "\(raw)%"
                let sw = ceil(PanelStyle.size(s, font: strikeFont).width)
                PanelStyle.draw(s, at: NSPoint(x: vx, y: valY + 4), font: strikeFont, color: .tertiaryLabelColor)
                NSColor.tertiaryLabelColor.setStroke()
                let sp = NSBezierPath()
                sp.lineWidth = 1
                sp.move(to: NSPoint(x: vx, y: valY + 4 + strikeFont.pointSize / 2))
                sp.line(to: NSPoint(x: vx + sw, y: valY + 4 + strikeFont.pointSize / 2))
                sp.stroke()
                vx += sw + 5
            }
            let fiveStr = m.five == nil ? "\u{2014}" : "\(Int(m.five!.rounded()))%"
            let fiveCol: NSColor = m.fiveIsRed ? .systemRed : .labelColor
            PanelStyle.draw(fiveStr, at: NSPoint(x: vx, y: valY), font: bigFont, color: fiveCol)
            vx += ceil(PanelStyle.size(fiveStr, font: bigFont).width) + 5
            PanelStyle.draw("5h", at: NSPoint(x: vx, y: valY + 4), font: unitFont, color: .tertiaryLabelColor)
            vx += 24
            if m.inferredFive, let raw = m.rawFivePct { strike(raw) }
            let weekStr = m.week == nil ? "\u{2014}" : "\(Int(m.week!.rounded()))%"
            PanelStyle.draw(weekStr, at: NSPoint(x: vx, y: valY + 2), font: midFont, color: .secondaryLabelColor)
            vx += ceil(PanelStyle.size(weekStr, font: midFont).width) + 5
            PanelStyle.draw("wk", at: NSPoint(x: vx, y: valY + 4), font: unitFont, color: .tertiaryLabelColor)
            vx += 22
            if m.inferredWeek, let raw = m.rawWeekPct { strike(raw) }
            if m.inferredFive || m.inferredWeek {
                PanelStyle.draw("inferred 0", at: NSPoint(x: vx, y: valY + 4),
                                font: NSFont.systemFont(ofSize: 10, weight: .semibold), color: .systemOrange)
            }
        } else if let msg = m.noDataMessage {
            PanelStyle.draw(msg, at: NSPoint(x: colX, y: valY + 2),
                            font: NSFont.systemFont(ofSize: 12), color: .tertiaryLabelColor)
        }

        // Reset line (+ appended extras when Claude is secondary).
        if let reset = m.resetLine {
            let rFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            PanelStyle.draw(reset, at: NSPoint(x: colX, y: card.minY + 48), font: rFont, color: .tertiaryLabelColor)
        }

        // Sub-banner (inferred / aged), separated by a hairline. Drawn only when the
        // FROZEN frame actually allocated space for it: the strip height is resolved
        // at menu open (amendment 1), so after a mid-open Lead swap the model can
        // carry a sub-banner the frame has no room for. NSView.clipsToBounds defaults
        // to false on modern macOS, so drawing past the frame edge would bleed over
        // the next menu row; instead the sub-banner simply waits for the next open.
        // Threshold: with no sub-banner the card is exactly mainRowHeight tall, and
        // the smallest real allocation (a one-line sub-banner via StripView.height)
        // adds ~35 pt, so 24 pt of extra card height cleanly separates "allocated"
        // from "not allocated" while leaving the dot (ends at sbTop + 16) and a text
        // line inside the frame.
        let subBannerAllocated = card.height >= StripView.mainRowHeight + 24
        if let sb = m.subBanner, subBannerAllocated {
            let sbTop = card.minY + StripView.mainRowHeight
            PanelStyle.chip.setStroke()
            let hair = NSBezierPath()
            hair.lineWidth = 1
            hair.move(to: NSPoint(x: card.minX, y: sbTop))
            hair.line(to: NSPoint(x: card.maxX, y: sbTop))
            hair.stroke()
            let dot = NSRect(x: card.minX + 11, y: sbTop + 10, width: 6, height: 6)
            sb.dotColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            let tFont = NSFont.systemFont(ofSize: 11.5)
            let tRect = NSRect(x: dot.maxX + 8, y: sbTop + 7,
                               width: card.maxX - 11 - (dot.maxX + 8), height: card.maxY - sbTop - 10)
            (sb.text as NSString).draw(with: tRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       attributes: [.font: tFont, .foregroundColor: NSColor.labelColor])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if leadRect.insetBy(dx: -3, dy: -3).contains(p) { onLead?() }
    }
}

// GraphProviderPillsView was removed by amendment 26: switching the graph between
// providers felt unnatural in live use, so two-provider mode stacks BOTH providers'
// graph cards (primary first) instead of toggling one plot.
