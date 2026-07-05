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
enum ColorMode: String, CaseIterable {
    case claude, thresholds, monochrome, heatmap, accent

    var title: String {
        switch self {
        case .claude:     return "Claude"
        case .thresholds: return "Thresholds (orange / red)"
        case .monochrome: return "Monochrome"
        case .heatmap:    return "Heatmap (green → red)"
        case .accent:     return "System accent"
        }
    }
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
        get { ColorMode(rawValue: d.string(forKey: "colorMode") ?? "") ?? .claude }
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

    /// Color for a single utilization value under the chosen mode.
    static func color(_ v: Double, _ mode: ColorMode) -> NSColor {
        switch mode {
        case .claude:     return v >= 90 ? .systemRed : claudeCoral
        case .monochrome: return .labelColor
        case .accent:     return .controlAccentColor
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

    static func percentText(_ five: Double?, _ week: Double?, _ mode: ColorMode, _ font: NSFont) -> NSAttributedString {
        func chunk(_ v: Double?) -> NSAttributedString {
            let str = v == nil ? "—" : "\(Int(v!.rounded()))%"
            let col = v == nil ? NSColor.labelColor : color(v!, mode)
            return NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: col])
        }
        let s = NSMutableAttributedString()
        s.append(chunk(five))
        s.append(NSAttributedString(string: " / ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        s.append(chunk(week))
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
                      height: CGFloat = barHeight, projected: Double? = nil) -> NSImage {
        let template = (mode == .monochrome)
        let track = template ? NSColor(white: 0, alpha: 0.26) : NSColor.tertiaryLabelColor

        /// Faint projected arc under the value arc — visible only across the
        /// current→projected span. Amber when the projection reaches the cap.
        func ghostColor(_ current: Double) -> NSColor? {
            guard let projected, projected > current + 0.5 else { return nil }
            if template { return NSColor(white: 0, alpha: 0.35) }
            return projected >= 100 ? .systemOrange : color(current, mode).withAlphaComponent(0.30)
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
                stroke(arcCenter: c, radius: outerR, from: 0, to: 360, clockwise: false, width: lw, color: track)
                if let five, let ghost = ghostColor(five), let projected {
                    stroke(arcCenter: c, radius: outerR, from: 90,
                           to: 90 - 360 * min(1, projected / 100), clockwise: true, width: lw, color: ghost)
                }
                if let five, five > 0 {
                    let fill = template ? NSColor.black : color(five, mode)
                    stroke(arcCenter: c, radius: outerR, from: 90,
                           to: 90 - 360 * min(max(five / 100, 0), 1), clockwise: true, width: lw, color: fill)
                }
                drawRing(center: c, radius: innerR, width: lw, value: week, mode: mode, template: template, track: track)
                return true
            }
            img.isTemplate = template
            return img
        }

        // Single ring: the 5-hour window only, for people who watch just the
        // near term. Same ghost-arc treatment as concentric.
        if style == .single {
            let d = height - 2
            let img = NSImage(size: NSSize(width: d, height: height), flipped: false) { _ in
                let c = CGPoint(x: d / 2, y: height / 2)
                let lw = d * 0.16
                let r = d / 2 - lw / 2 - 0.4
                stroke(arcCenter: c, radius: r, from: 0, to: 360, clockwise: false, width: lw, color: track)
                if let five, let ghost = ghostColor(five), let projected {
                    stroke(arcCenter: c, radius: r, from: 90,
                           to: 90 - 360 * min(1, projected / 100), clockwise: true, width: lw, color: ghost)
                }
                if let five, five > 0 {
                    let fill = template ? NSColor.black : color(five, mode)
                    stroke(arcCenter: c, radius: r, from: 90,
                           to: 90 - 360 * min(max(five / 100, 0), 1), clockwise: true, width: lw, color: fill)
                }
                return true
            }
            img.isTemplate = template
            return img
        }

        // Bars: the only remaining style drawn as a side-by-side pair
        // (percentages is text and never reaches this path).
        let values = [five ?? 0, week ?? 0]
        let gaugeW: CGFloat = 7, gap: CGFloat = 5
        let size = NSSize(width: gaugeW * 2 + gap, height: height)

        let img = NSImage(size: size, flipped: false) { _ in
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (gaugeW + gap)
                let rect = CGRect(x: x, y: 1, width: gaugeW, height: height - 2)
                let fill = template ? NSColor.black : color(v, mode)
                drawBar(value: CGFloat(min(max(v / 100, 0), 1)), in: rect, fill: fill, track: track)
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    /// One activity-ring: faint full track + colored arc from the top, clockwise.
    private static func drawRing(center c: CGPoint, radius: CGFloat, width lw: CGFloat,
                                 value v: Double?, mode: ColorMode, template: Bool, track: NSColor) {
        stroke(arcCenter: c, radius: radius, from: 0, to: 360, clockwise: false, width: lw, color: track)
        let val = min(max((v ?? 0) / 100, 0), 1)
        if val > 0 {
            let fill = template ? NSColor.black : color(v ?? 0, mode)
            stroke(arcCenter: c, radius: radius, from: 90, to: 90 - 360 * val, clockwise: true, width: lw, color: fill)
        }
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
