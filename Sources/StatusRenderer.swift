import AppKit

/// How the two utilization values are drawn in the menu bar.
enum DisplayStyle: String, CaseIterable {
    case concentric, percentages, bars, rings, arcs, pie, pips

    var title: String {
        switch self {
        case .concentric:  return "Concentric rings"
        case .percentages: return "Percentages"
        case .bars:        return "Bars"
        case .rings:       return "Twin rings"
        case .arcs:        return "Gauges"
        case .pie:         return "Pie slices"
        case .pips:        return "Segments"
        }
    }
}

/// How color is applied to the readout.
enum ColorMode: String, CaseIterable {
    case thresholds, monochrome, heatmap, accent

    var title: String {
        switch self {
        case .thresholds: return "Thresholds (orange / red)"
        case .monochrome: return "Monochrome"
        case .heatmap:    return "Heatmap (green → red)"
        case .accent:     return "System accent"
        }
    }
}

/// Persisted user choices (UserDefaults). Defaults match the app's original look:
/// percentages with orange/red thresholds.
enum Settings {
    private static let d = UserDefaults.standard

    static var style: DisplayStyle {
        get { DisplayStyle(rawValue: d.string(forKey: "displayStyle") ?? "") ?? .concentric }
        set { d.set(newValue.rawValue, forKey: "displayStyle") }
    }
    static var colorMode: ColorMode {
        get { ColorMode(rawValue: d.string(forKey: "colorMode") ?? "") ?? .monochrome }
        set { d.set(newValue.rawValue, forKey: "colorMode") }
    }
}

/// Draws the status-bar readout. Left gauge = 5-hour, right gauge = weekly.
enum StatusRenderer {
    static let barHeight: CGFloat = 18

    /// Color for a single utilization value under the chosen mode.
    static func color(_ v: Double, _ mode: ColorMode) -> NSColor {
        switch mode {
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

    /// Apply the readout to the status button (text for percentages, image otherwise).
    static func apply(to button: NSStatusBarButton, five: Double?, week: Double?,
                      style: DisplayStyle, color mode: ColorMode, font: NSFont) {
        if style == .percentages {
            button.image = nil
            button.attributedTitle = percentText(five, week, mode, font)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = image(five: five, week: week, style: style, mode: mode)
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
        return image(five: 78, week: 36, style: style, mode: .monochrome, height: 15)
    }

    // MARK: - Image rendering

    static func image(five: Double?, week: Double?, style: DisplayStyle, mode: ColorMode,
                      height: CGFloat = barHeight) -> NSImage {
        let template = (mode == .monochrome)
        let track = template ? NSColor(white: 0, alpha: 0.26) : NSColor.tertiaryLabelColor

        // Concentric rings: a single glyph, exactly like the app icon
        // (outer ring = weekly, inner ring = 5-hour).
        if style == .concentric {
            let d = height - 2
            let img = NSImage(size: NSSize(width: d, height: height), flipped: false) { _ in
                let c = CGPoint(x: d / 2, y: height / 2)
                let lw = d * 0.125
                let outerR = d / 2 - lw / 2 - 0.4
                let innerR = outerR - lw - 1.0
                // outer ring = 5-hour (watched most), inner ring = weekly
                drawRing(center: c, radius: outerR, width: lw, value: five, mode: mode, template: template, track: track)
                drawRing(center: c, radius: innerR, width: lw, value: week, mode: mode, template: template, track: track)
                return true
            }
            img.isTemplate = template
            return img
        }

        let values = [five ?? 0, week ?? 0]
        let (gaugeW, gap): (CGFloat, CGFloat)
        switch style {
        case .bars, .pips:        (gaugeW, gap) = (7, 5)
        case .rings, .arcs, .pie: (gaugeW, gap) = (height - 2, 4)
        case .percentages, .concentric: (gaugeW, gap) = (0, 0)
        }
        let size = NSSize(width: gaugeW * 2 + gap, height: height)

        let img = NSImage(size: size, flipped: false) { _ in
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (gaugeW + gap)
                let rect = CGRect(x: x, y: 1, width: gaugeW, height: height - 2)
                let fill = template ? NSColor.black : color(v, mode)
                drawGauge(style, value: CGFloat(min(max(v / 100, 0), 1)), in: rect, fill: fill, track: track)
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

    private static func drawGauge(_ style: DisplayStyle, value: CGFloat, in rect: CGRect,
                                  fill: NSColor, track: NSColor) {
        switch style {
        case .percentages, .concentric:    // handled elsewhere (text / single glyph)
            break

        case .bars:
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

        case .pips:
            let n = 5
            let segGap: CGFloat = 1.6
            let segH = (rect.height - segGap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((value * CGFloat(n)).rounded())
            for k in 0..<n {
                let y = rect.minY + CGFloat(k) * (segH + segGap)
                let r = CGRect(x: rect.minX, y: y, width: rect.width, height: segH)
                (k < lit ? fill : track).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }

        case .rings:
            let lw = rect.width * 0.27
            let radius = (min(rect.width, rect.height) - lw) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            stroke(arcCenter: c, radius: radius, from: 0, to: 360, clockwise: false, width: lw, color: track)
            if value > 0 {
                stroke(arcCenter: c, radius: radius, from: 90, to: 90 - 360 * value, clockwise: true, width: lw, color: fill)
            }

        case .arcs:
            let lw = rect.width * 0.24
            let radius = (min(rect.width, rect.height) - lw) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.06)
            // 270° gauge, open at the bottom
            stroke(arcCenter: c, radius: radius, from: -45, to: 225, clockwise: false, width: lw, color: track)
            if value > 0 {
                stroke(arcCenter: c, radius: radius, from: 225, to: 225 - 270 * value, clockwise: true, width: lw, color: fill)
            }

        case .pie:
            let radius = min(rect.width, rect.height) / 2 - 0.5
            let c = CGPoint(x: rect.midX, y: rect.midY)
            track.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
            if value > 0 {
                let wedge = NSBezierPath()
                wedge.move(to: c)
                wedge.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * value, clockwise: true)
                wedge.close()
                fill.setFill()
                wedge.fill()
            }
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
