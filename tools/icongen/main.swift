import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Renders a 1024×1024 app icon: two concentric "activity rings" (the 5-hour and
// weekly limits) on a warm Claude-coral squircle. Output path is argv[1].
//
// Ring order matches the menu-bar glyph and README: outer = 5-hour (watched most,
// gets the bold pure-white ring), inner = weekly (warm cream).

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("context") }

ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Squircle background (Apple-style margins + continuous-ish corner radius).
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.886, green: 0.545, blue: 0.392, alpha: 1),   // warm coral (top)
    CGColor(red: 0.745, green: 0.357, blue: 0.216, alpha: 1),   // deeper clay (bottom)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
ctx.restoreGState()

// Concentric rings (Apple activity-ring style): full faint track + bold arc that
// starts at the top and sweeps clockwise for `fraction` of the circle.
let center = CGPoint(x: S / 2, y: S / 2)
let track = CGColor(red: 1, green: 1, blue: 1, alpha: 0.25)

func ring(_ r: CGFloat, width: CGFloat, fraction: CGFloat, fill: CGColor) {
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(track)
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(fill)
    let start = CGFloat.pi / 2                       // top (CG y-up)
    let end = start - fraction * .pi * 2             // clockwise
    ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
}

ring(258, width: 74, fraction: 0.66, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))            // outer = 5-hour
ring(150, width: 74, fraction: 0.40, fill: CGColor(red: 1, green: 0.93, blue: 0.86, alpha: 0.98))      // inner = weekly

guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("dest") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("wrote \(out.path)")
