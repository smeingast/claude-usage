import AppKit

/// How the two utilization values are drawn in the menu bar.
/// The four styles that survived the v0.5 trim: concentric is the identity,
/// single is its near-term-only variant, bars read fastest, percentages give
/// the exact digits. Twin rings, gauges, pie, and segments were retired — they
/// duplicated the concentric information at twice the width or lost resolution
/// at menu-bar size. A saved retired value no longer parses and falls back to
/// `.concentric` via the `Settings.style` getter, which is the intended
/// migration.
enum DisplayStyle: String, CaseIterable {
    case concentric, single, percentages, bars

    var title: String {
        switch self {
        case .concentric:  return "Concentric rings"
        case .single:      return "Single ring (5-hour)"
        case .percentages: return "Percentages"
        case .bars:        return "Bars"
        }
    }
}

/// How color is applied to the readout.
///
/// `brand` was named `claude` through v0.8 (rawValue "claude", title "Claude").
/// When Codex became a second provider the case was renamed to `brand` (rawValue
/// "brand", title "Brand"): this is the one mode where hue means "provider" (coral
/// = Claude, teal = Codex), so a provider-neutral name fits. The stored value is
/// migrated by the `Settings.colorMode` getter, which maps a stored "claude" (and
/// a missing value) to `.brand`. Downgrade note: an old app version that reads a
/// stored "brand" falls back to `.claude` via its own `?? .claude` default, which
/// is visually identical, so the migration is safe both directions.
enum ColorMode: String, CaseIterable {
    case brand, thresholds, monochrome, heatmap, accent

    var title: String {
        switch self {
        case .brand:      return "Brand"
        case .thresholds: return "Thresholds (orange / red)"
        case .monochrome: return "Monochrome"
        case .heatmap:    return "Heatmap (green → red)"
        case .accent:     return "System accent"
        }
    }
}

/// Which provider a rendered element represents in the two-provider hierarchy:
/// the user-chosen `primary` (full instrument / bar glyph) or the `secondary`
/// (compact strip / corner pip). Only the System-accent color mode dims the
/// secondary role by alpha (amendment 14); every other mode ignores it. The
/// default at every renderer entry point is `.primary`, so all pre-4a call sites
/// are unaffected. Dormant in 4a: no call site passes `.secondary` yet.
enum ProviderRole { case primary, secondary }

/// The menu-bar corner pip's state for the OTHER (secondary) provider, mapped to
/// a color by amendment 5. Dormant in 4a: no call site draws a pip yet.
enum PipSeverity {
    case red                        // a real >= 90 on that provider's own 5-hour window
    case amber                      // watch / pace, or an attention state:
                                    // Claude signed out, Claude stale, Codex inferred-zero
    case calm(UsageProviderKind)    // fresh and calm: the provider's own accent (coral / teal)
    case muted                      // Codex noData or aged-idle
    case hidden                     // provider not installed / hidden: no pip at all
}

/// Time span shown by the usage-history graph. Sub-hour spans are omitted: the 300 s
/// poll yields one point every 5 minutes, so anything shorter is too sparse to plot.
enum HistoryRange: String, CaseIterable {
    case last5h, last24h, last7d, last30d

    var title: String {
        switch self {
        case .last5h:  return "Last 5h"
        case .last24h: return "Last 24h"
        case .last7d:  return "Last 7d"
        case .last30d: return "Last 30d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .last5h:  return 5 * 3600
        case .last24h: return 24 * 3600
        case .last7d:  return 7 * 24 * 3600
        case .last30d: return 30 * 24 * 3600
        }
    }
}

/// How the history graph plots the two utilization series.
enum GraphMode: String, CaseIterable {
    case utilization, rate

    var title: String {
        switch self {
        case .utilization: return "Utilization"
        case .rate:        return "Consumption rate"
        }
    }
}

/// Persisted user choices (UserDefaults). Defaults: concentric rings, Claude coral,
/// 24-hour utilization graph.
enum Settings {
    private static let d = UserDefaults.standard

    static var style: DisplayStyle {
        get { DisplayStyle(rawValue: d.string(forKey: "displayStyle") ?? "") ?? .concentric }
        set { d.set(newValue.rawValue, forKey: "displayStyle") }
    }
    static var colorMode: ColorMode {
        // Migration [B10]: a stored "claude" (the pre-4a rawValue) and a missing
        // value both resolve to `.brand`. `ColorMode(rawValue: "claude")` is now
        // nil, so the `?? .brand` default catches both cases; the setter writes
        // "brand".
        get { ColorMode(rawValue: d.string(forKey: "colorMode") ?? "") ?? .brand }
        set { d.set(newValue.rawValue, forKey: "colorMode") }
    }
    static var historyRange: HistoryRange {
        get { HistoryRange(rawValue: d.string(forKey: "historyRange") ?? "") ?? .last24h }
        set { d.set(newValue.rawValue, forKey: "historyRange") }
    }
    static var graphMode: GraphMode {
        get { GraphMode(rawValue: d.string(forKey: "graphMode") ?? "") ?? .utilization }
        set { d.set(newValue.rawValue, forKey: "graphMode") }
    }

    // Two-provider groundwork (package 4a). Written and read only from tests for
    // now; no production code path reads these until package 4b wires the
    // two-provider UI. Defaults reproduce today's single-provider behavior.

    /// Which provider gets the full instrument / the bar glyph. Default: Claude.
    static var primaryProvider: UsageProviderKind {
        get { UsageProviderKind(rawValue: d.string(forKey: "primaryProvider") ?? "") ?? .claude }
        set { d.set(newValue.rawValue, forKey: "primaryProvider") }
    }
    /// What the menu-bar readout shows. Default: the primary provider's glyph
    /// (plus the dormant corner pip for the other provider).
    static var barShows: BarShows {
        get { BarShows(rawValue: d.string(forKey: "barShows") ?? "") ?? .primary }
        set { d.set(newValue.rawValue, forKey: "barShows") }
    }
    /// Whether the Codex surfaces appear. Default: Auto (show only when Codex is
    /// installed); On forces them, Off hides them entirely.
    static var showCodex: ShowCodex {
        get { ShowCodex(rawValue: d.string(forKey: "showCodex") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "showCodex") }
    }
}

/// What the menu-bar readout draws in two-provider mode. Dormant in 4a.
enum BarShows: String, CaseIterable {
    case primary, both, claude, codex

    var title: String {
        switch self {
        case .primary: return "Primary"
        case .both:    return "Both"
        case .claude:  return "Claude"
        case .codex:   return "Codex"
        }
    }
}

/// Codex visibility policy. Dormant in 4a. `auto` shows Codex only when the
/// `~/.codex` directory exists (resolved in 4b); `on`/`off` force the choice.
enum ShowCodex: String, CaseIterable {
    case auto, on, off

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .on:   return "On"
        case .off:  return "Off"
        }
    }
}

/// Draws the status-bar readout. Left gauge = 5-hour, right gauge = weekly.
enum StatusRenderer {
    static let barHeight: CGFloat = 18

    /// Anthropic's coral, tuned per menu-bar appearance: the app icon's warm
    /// coral on a dark bar, its deeper clay on a light one, so it stays legible
    /// on both. (The two tones are the icon gradient's endpoints; see
    /// tools/icongen/main.swift.)
    static let claudeCoral = NSColor(name: "ClaudeCoral") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.886, green: 0.545, blue: 0.392, alpha: 1)   // warm coral
            : NSColor(srgbRed: 0.745, green: 0.357, blue: 0.216, alpha: 1)   // deeper clay
    }

    /// Codex's accent: a brand-neutral teal (avoids OpenAI trade dress), tuned
    /// per menu-bar appearance exactly like `claudeCoral`. Light #2C7A8A, dark
    /// #66B4C4. Dormant in 4a; consumed in 4b for the Codex glyph / rings.
    static let codexTeal = NSColor(name: "CodexTeal") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.400, green: 0.706, blue: 0.769, alpha: 1)   // #66B4C4
            : NSColor(srgbRed: 0.173, green: 0.478, blue: 0.541, alpha: 1)   // #2C7A8A
    }

    /// Codex's weekly companion tint, the teal analog of coral's alpha-dimmed
    /// weekly ring (amendment 4: Brand mode uses the provider's weekly companion).
    /// Light #5E8B93, dark #79A6AE. Dormant in 4a.
    static let codexTealWeekly = NSColor(name: "CodexTealWeekly") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.475, green: 0.651, blue: 0.682, alpha: 1)   // #79A6AE
            : NSColor(srgbRed: 0.369, green: 0.545, blue: 0.576, alpha: 1)   // #5E8B93
    }

    /// The provider's Brand-mode accent (the color hue means "provider" in Brand
    /// mode only). Claude keeps coral; Codex is teal.
    static func providerAccent(_ provider: UsageProviderKind) -> NSColor {
        switch provider {
        case .claude: return claudeCoral
        case .codex:  return codexTeal
        }
    }

    /// The provider's Brand-mode weekly companion tint (amendment 4). Claude has
    /// no distinct named color (its weekly ring is coral dimmed to 0.5 alpha at
    /// the call site, unchanged from v0.8); Codex uses `codexTealWeekly`. Dormant
    /// in 4a. Returned undimmed; callers apply the weekly alpha as today.
    static func providerWeeklyAccent(_ provider: UsageProviderKind) -> NSColor {
        switch provider {
        case .claude: return claudeCoral
        case .codex:  return codexTealWeekly
        }
    }

    /// Alpha applied to the System-accent color for a secondary-role element
    /// (amendment 14: dim by role, not provider). Dormant in 4a (no call site
    /// passes `role: .secondary`); 4b may tune it. 0.55 keeps the dimmed accent
    /// clearly subordinate while still legible on both bar appearances.
    static let secondaryRoleDim: CGFloat = 0.55

    /// Color for a single utilization value under the chosen mode.
    ///
    /// `provider` and `role` are dormant additions for the two-provider work: with
    /// their defaults (`.claude` / `.primary`) this reproduces the pre-4a
    /// `color(_:_:)` output byte-for-byte, which the 320-cell parity test proves.
    /// - `provider` selects the Brand-mode hue (coral vs teal); the thresholds,
    ///   monochrome, and heatmap modes ignore it, so hue keeps meaning severity /
    ///   ink / intensity there regardless of provider (amendments 3-4).
    /// - `role` dims only the System-accent secondary role (amendment 14).
    static func color(_ v: Double, _ mode: ColorMode,
                      provider: UsageProviderKind = .claude,
                      role: ProviderRole = .primary) -> NSColor {
        switch mode {
        case .brand:
            // Red's >= 90 override wins in every mode, per provider (the one hard
            // color rule from v0.5). Below the cap, Brand hue encodes the provider.
            return v >= 90 ? .systemRed : providerAccent(provider)
        case .monochrome: return .labelColor
        case .accent:
            // Amendment 14: dim the SECONDARY provider role via alpha, never the
            // provider identity. Primary (the default) keeps the full OS accent.
            return role == .secondary
                ? NSColor.controlAccentColor.withAlphaComponent(secondaryRoleDim)
                : .controlAccentColor
        case .thresholds:
            if v >= 90 { return .systemRed }
            if v >= 70 { return .systemOrange }
            return .labelColor
        case .heatmap:
            let t = min(max(v / 100, 0), 1)
            let hue = (1 - t) * 0.34            // 0.34 ≈ green at 0%, 0.0 = red at 100%
            return NSColor(hue: hue, saturation: 0.85, brightness: 0.9, alpha: 1)
        }
    }

    /// Amendment 5's complete pip color mapping for the menu-bar corner pip.
    /// Returns `nil` for `.hidden` (draw no pip). Dormant in 4a.
    static func pipColor(_ severity: PipSeverity) -> NSColor? {
        switch severity {
        case .red:         return .systemRed
        case .amber:       return .systemOrange
        case .calm(let p): return providerAccent(p)
        case .muted:       return .tertiaryLabelColor
        case .hidden:      return nil
        }
    }

    /// Apply the readout to the status button (text for percentages, image
    /// otherwise). `projected` feeds the faint forecast ghost arc on the ring
    /// styles, so a glance at the bar previews "ease off" before opening the menu.
    static func apply(to button: NSStatusBarButton, five: Double?, week: Double?,
                      style: DisplayStyle, color mode: ColorMode, font: NSFont,
                      projected: Double? = nil) {
        if style == .percentages {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = percentText(five, week, mode, font)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = image(five: five, week: week, style: style, mode: mode,
                                 projected: projected)
            button.imagePosition = .imageOnly
        }
    }

    static func percentText(_ five: Double?, _ week: Double?, _ mode: ColorMode, _ font: NSFont,
                            pip: PipSeverity? = nil) -> NSAttributedString {
        func chunk(_ v: Double?) -> NSAttributedString {
            let str = v == nil ? "—" : "\(Int(v!.rounded()))%"
            let col = v == nil ? NSColor.labelColor : color(v!, mode)
            return NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: col])
        }
        let s = NSMutableAttributedString()
        s.append(chunk(five))
        s.append(NSAttributedString(string: " / ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        s.append(chunk(week))
        // Dormant trailing pip (amendment 6): the text style carries the second
        // provider's state as a colored "·" bullet. `pip == nil` (every pre-4a
        // call site) appends nothing, so the string is byte-identical to before.
        // Droppable in 4b if illegible at the bar font.
        if let pip, let pc = pipColor(pip) {
            s.append(NSAttributedString(string: " ·", attributes: [.font: font, .foregroundColor: pc]))
        }
        return s
    }

    /// Tiny live preview for a style's menu item (uses sample values, monochrome).
    static func previewImage(for style: DisplayStyle) -> NSImage? {
        if style == .percentages {
            let img = NSImage(size: NSSize(width: 28, height: 14), flipped: false) { _ in
                ("63%" as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
                return true
            }
            img.isTemplate = true
            return img
        }
        return image(five: 78, week: 36, style: style, mode: .monochrome, height: 15,
                     projected: style == .concentric || style == .single ? 94 : nil)
    }

    // MARK: - Image rendering

    static func image(five: Double?, week: Double?, style: DisplayStyle, mode: ColorMode,
                      height: CGFloat = barHeight, projected: Double? = nil,
                      provider: UsageProviderKind = .claude, role: ProviderRole = .primary,
                      pip: PipSeverity? = nil,
                      inferredFive: Bool = false, inferredWeek: Bool = false) -> NSImage {
        let template = (mode == .monochrome)
        let track = template ? NSColor(white: 0, alpha: 0.26) : NSColor.tertiaryLabelColor

        // Composite the dormant corner pip (amendment 6) onto a finished glyph.
        // With `pip == nil` (every pre-4a call site) this returns the glyph object
        // untouched, so the output is byte-identical to the pre-4a renderer.
        func finish(_ img: NSImage) -> NSImage {
            guard let pip, let pc = pipColor(pip) else { return img }
            let out = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                drawCornerPip(glyphSize: img.size, color: pc)
                return true
            }
            out.isTemplate = false      // the pip carries hue; do not template-tint it
            return out
        }

        /// Faint projected arc under the value arc — visible only across the
        /// current→projected span. Amber when the projection reaches the cap,
        /// but still translucent: heatmap/thresholds fill mid-range values in
        /// orange too, and a solid amber ghost would read as a full ring.
        func ghostColor(_ current: Double) -> NSColor? {
            guard let projected, projected > current + 0.5 else { return nil }
            if template { return NSColor(white: 0, alpha: 0.35) }
            return projected >= 100 ? NSColor.systemOrange.withAlphaComponent(0.45)
                                    : color(current, mode, provider: provider, role: role).withAlphaComponent(0.30)
        }

        // Concentric rings: a single activity-ring glyph in the app-icon style.
        // Outer ring = 5-hour (the limit watched most), inner ring = weekly.
        // (Note: the .icns app icon draws these reversed — outer = weekly; see
        // tools/icongen/main.swift.)
        if style == .concentric {
            let d = height - 2
            let img = NSImage(size: NSSize(width: d, height: height), flipped: false) { _ in
                let c = CGPoint(x: d / 2, y: height / 2)
                let lw = d * 0.125
                let outerR = d / 2 - lw / 2 - 0.4
                let innerR = outerR - lw - 1.0
                if inferredFive {
                    // Inferred-zero (amendment 9): dashed, fill-less outer track,
                    // marking a computed 0 rather than an observed value. Dormant.
                    strokeDashedTrack(center: c, radius: outerR, width: lw, color: track)
                } else {
                    stroke(arcCenter: c, radius: outerR, from: 0, to: 360, clockwise: false, width: lw, color: track)
                    if let five, let ghost = ghostColor(five), let projected {
                        stroke(arcCenter: c, radius: outerR, from: 90,
                               to: 90 - 360 * min(1, projected / 100), clockwise: true, width: lw, color: ghost)
                    }
                    if let five, five > 0 {
                        let fill = template ? NSColor.black : color(five, mode, provider: provider, role: role)
                        stroke(arcCenter: c, radius: outerR, from: 90,
                               to: 90 - 360 * min(max(five / 100, 0), 1), clockwise: true, width: lw, color: fill)
                    }
                }
                if inferredWeek {
                    strokeDashedTrack(center: c, radius: innerR, width: lw, color: track)
                } else {
                    drawRing(center: c, radius: innerR, width: lw, value: week, mode: mode,
                             template: template, track: track, provider: provider, role: role)
                }
                return true
            }
            img.isTemplate = template
            return finish(img)
        }

        // Single ring: the 5-hour window only, for people who watch just the
        // near term. Same ghost-arc treatment as concentric.
        if style == .single {
            let d = height - 2
            let img = NSImage(size: NSSize(width: d, height: height), flipped: false) { _ in
                let c = CGPoint(x: d / 2, y: height / 2)
                let lw = d * 0.16
                let r = d / 2 - lw / 2 - 0.4
                if inferredFive {
                    strokeDashedTrack(center: c, radius: r, width: lw, color: track)
                } else {
                    stroke(arcCenter: c, radius: r, from: 0, to: 360, clockwise: false, width: lw, color: track)
                    if let five, let ghost = ghostColor(five), let projected {
                        stroke(arcCenter: c, radius: r, from: 90,
                               to: 90 - 360 * min(1, projected / 100), clockwise: true, width: lw, color: ghost)
                    }
                    if let five, five > 0 {
                        let fill = template ? NSColor.black : color(five, mode, provider: provider, role: role)
                        stroke(arcCenter: c, radius: r, from: 90,
                               to: 90 - 360 * min(max(five / 100, 0), 1), clockwise: true, width: lw, color: fill)
                    }
                }
                return true
            }
            img.isTemplate = template
            return finish(img)
        }

        // Bars: the only remaining style drawn as a side-by-side pair
        // (percentages is text and never reaches this path). The inferred-zero
        // flags do not apply to the bar glyph; 4b renders that state with the
        // ring instrument, not the bar.
        let values = [five ?? 0, week ?? 0]
        let gaugeW: CGFloat = 7, gap: CGFloat = 5
        let size = NSSize(width: gaugeW * 2 + gap, height: height)

        let img = NSImage(size: size, flipped: false) { _ in
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (gaugeW + gap)
                let rect = CGRect(x: x, y: 1, width: gaugeW, height: height - 2)
                let fill = template ? NSColor.black : color(v, mode, provider: provider, role: role)
                drawBar(value: CGFloat(min(max(v / 100, 0), 1)), in: rect, fill: fill, track: track)
            }
            return true
        }
        img.isTemplate = template
        return finish(img)
    }

    /// Compose two glyphs into one side-by-side "Both" image (amendment /
    /// handoff: two 18 pt glyphs, 3 pt gap). Dormant in 4a; 4b builds `left` and
    /// `right` from per-provider `image(...)` calls. Non-template because the two
    /// glyphs may carry different provider hues.
    static func sideBySide(_ left: NSImage, _ right: NSImage, gap: CGFloat = 3) -> NSImage {
        let h = max(left.size.height, right.size.height)
        let w = left.size.width + gap + right.size.width
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            left.draw(in: NSRect(x: 0, y: 0, width: left.size.width, height: left.size.height))
            right.draw(in: NSRect(x: left.size.width + gap, y: 0,
                                  width: right.size.width, height: right.size.height))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// One activity-ring: faint full track + colored arc from the top, clockwise.
    /// `provider`/`role` default to `.claude`/`.primary`, so the pre-4a call path
    /// (concentric inner ring) is unchanged.
    private static func drawRing(center c: CGPoint, radius: CGFloat, width lw: CGFloat,
                                 value v: Double?, mode: ColorMode, template: Bool, track: NSColor,
                                 provider: UsageProviderKind = .claude, role: ProviderRole = .primary) {
        stroke(arcCenter: c, radius: radius, from: 0, to: 360, clockwise: false, width: lw, color: track)
        let val = min(max((v ?? 0) / 100, 0), 1)
        if val > 0 {
            let fill = template ? NSColor.black : color(v ?? 0, mode, provider: provider, role: role)
            stroke(arcCenter: c, radius: radius, from: 90, to: 90 - 360 * val, clockwise: true, width: lw, color: fill)
        }
    }

    /// Draw the bottom-right corner state pip into the CURRENT graphics context
    /// for a glyph of `glyphSize`, per amendment 6: first blend-clear a knockout
    /// gap (pip radius + 1 pt) so the pip separates from ring / track pixels on any
    /// menu-bar background, then fill a 5 pt circle. Callers composite this into a
    /// non-template NSImage so the pip keeps its hue. Dormant in 4a.
    static func drawCornerPip(glyphSize s: NSSize, color: NSColor) {
        let pipDiameter: CGFloat = 5
        let pipR = pipDiameter / 2
        let gapR = pipR + 1                     // knockout is pip radius + 1 pt
        // Sit the pip fully inside the glyph, hard into the bottom-right corner.
        let cx = s.width - pipR - 0.5
        let cy = pipR + 0.5
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear       // blend-clear the knockout gap
        NSColor.black.setFill()                 // fill color is irrelevant under .clear
        NSBezierPath(ovalIn: CGRect(x: cx - gapR, y: cy - gapR,
                                    width: gapR * 2, height: gapR * 2)).fill()
        ctx.restoreGraphicsState()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - pipR, y: cy - pipR,
                                    width: pipDiameter, height: pipDiameter)).fill()
    }

    /// Stroke a full-circle track with a dashed pattern and NO value fill: the
    /// inferred-zero ring (amendment 9), marking a value computed (window reset
    /// passed, no newer event) rather than observed. Dormant in 4a.
    private static func strokeDashedTrack(center c: CGPoint, radius: CGFloat, width lw: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        path.lineWidth = lw
        path.lineCapStyle = .round
        path.setLineDash([lw * 0.9, lw * 1.4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    /// One rounded fuel bar: faint full track, filled from the bottom.
    private static func drawBar(value: CGFloat, in rect: CGRect, fill: NSColor, track: NSColor) {
        let rad = rect.width / 2
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rad, yRadius: rad).fill()
        let h = rect.height * value
        if h > 0.5 {
            let fr = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            let r = min(rect.width / 2, h / 2)
            fill.setFill()
            NSBezierPath(roundedRect: fr, xRadius: r, yRadius: r).fill()
        }
    }

    private static func stroke(arcCenter c: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat,
                               clockwise: Bool, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: c, radius: radius, startAngle: from, endAngle: to, clockwise: clockwise)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}
