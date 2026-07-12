import AppKit
import XCTest
@testable import ClaudeUsageCore

// Shared, non-XCTestCase support for the menu-bar render golden CAPTURE and the
// dormancy PARITY test. Lives under Tests/, never Sources/, so nothing here
// reaches the app build.
//
// WHY a shared file that must compile against BOTH the pre-4a and post-4a
// StatusRenderer: the goldens are captured once from the pre-4a renderer (commit
// 00c7d6a) and then the parity test re-renders each cell through the post-4a
// renderer and asserts pixel equality. For that to be a real proof, the exact
// same capture code path must run in both worlds. The only public renderer API
// this file touches is `StatusRenderer.image(...)` and
// `StatusRenderer.percentText(...)`, whose signatures package 4a keeps
// unchanged. The one thing that DOES change is the `ColorMode` case `.claude`
// being renamed to `.brand` (rawValue "claude" -> "brand"); we side-step that by
// never naming the case and resolving modes by their stable string key instead
// (see `colorMode(forKey:)`).

// MARK: - Grid

/// One cell of the render golden grid: a fully-specified input to the menu-bar
/// renderer plus the appearance it is pinned to. `id` is the fixture filename.
struct RenderCell {
    let style: DisplayStyle
    /// Stable color-mode key, invariant across the "claude" -> "brand" rename.
    /// One of: "brand", "thresholds", "monochrome", "heatmap", "accent".
    let modeKey: String
    let five: Double?
    let week: Double?
    let projected: Double?
    /// true = darkAqua, false = aqua. Pinned at render time so the dynamic
    /// NSColors (claudeCoral, systemRed, labelColor, ...) resolve deterministically.
    let dark: Bool

    var id: String {
        func f(_ v: Double?) -> String {
            guard let v else { return "nil" }
            // Every grid value is a whole number, so an integer string is exact
            // and stable; the defensive branch keeps a non-integral value legible.
            return v == v.rounded() ? String(Int(v)) : String(v).replacingOccurrences(of: ".", with: "p")
        }
        return "\(style.rawValue)_\(modeKey)_f\(f(five))_w\(f(week))_p\(f(projected))_\(dark ? "dark" : "aqua")"
    }
}

/// Stable color-mode keys. "brand" is the (renamed) provider-brand mode; the
/// other four keep their raw values across the rename.
let renderGoldenModeKeys = ["brand", "thresholds", "monochrome", "heatmap", "accent"]

/// The (five, week, projected) tuples that span the interesting thresholds.
/// Chosen to straddle both threshold edges (70 and 90) on both windows, exercise
/// the red >=90 override, the projected ghost arc, and the nil-window paths
/// (percentages "-" vs bars 0-coercion vs empty rings).
let renderGoldenValues: [(five: Double?, week: Double?, projected: Double?)] = [
    (nil, nil, nil),        // signed out / no data: empty rings, "-" text
    (0,   0,   nil),        // genuine zero (distinct from nil for the text style)
    (42,  21,  nil),        // calm, both well below 70
    (69,  55,  nil),        // five just below the 70 threshold edge
    (89,  80,  nil),        // five just below the 90 red edge; week in the 70-90 band
    (95,  91,  nil),        // both above 90: red override on both windows
    (60,  30,  100),        // projected to the cap: amber ghost arc (ring styles only)
    (42,  nil, nil),        // missing week: nil handling differs per style
]

/// The full styles x modes x values x appearances grid.
func renderGoldenCells() -> [RenderCell] {
    var cells: [RenderCell] = []
    for style in DisplayStyle.allCases {
        for modeKey in renderGoldenModeKeys {
            for v in renderGoldenValues {
                for dark in [false, true] {
                    cells.append(RenderCell(style: style, modeKey: modeKey,
                                            five: v.five, week: v.week, projected: v.projected,
                                            dark: dark))
                }
            }
        }
    }
    return cells
}

// MARK: - Mode resolution (rename-tolerant)

/// Resolve a stable mode key to the current `ColorMode`, tolerant of the
/// package-4a rename of case `.claude` (rawValue "claude") to `.brand`
/// (rawValue "brand").
///
/// - Pre-4a Sources: `ColorMode(rawValue: "brand")` is nil, so we fall back to
///   `ColorMode(rawValue: "claude")!`, which is `.claude`. The force-unwrap is
///   only ever evaluated in this world, where it is safe.
/// - Post-4a Sources: `ColorMode(rawValue: "brand")` is `.brand`; the `??`
///   short-circuits and "claude" (now unknown) is never looked up.
///
/// This is the single seam that lets one file compile and behave correctly on
/// both sides of the rename without ever naming the case.
func colorMode(forKey key: String) -> ColorMode {
    if key == "brand" { return ColorMode(rawValue: "brand") ?? ColorMode(rawValue: "claude")! }
    return ColorMode(rawValue: key)!
}

// MARK: - Pinned rendering

/// The font used for the percentages (text) style capture. Matches the app's
/// menu-bar `barFont` so the rasterized text is representative; the exact font
/// only has to be identical between capture and parity, which it is.
let renderGoldenBarFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

/// A raw pixel buffer: width x height sRGB RGBA (premultiplied), 8 bits/channel.
struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

/// Render `draw` into an explicit sRGB bitmap at a fixed 1x scale, under the
/// pinned appearance, and return the raw RGBA bytes.
///
/// WHY this exact method (pinned appearance, sRGB backing, raw bytes): it is the
/// comparison contract the brief fixes for package 4a [R4]. We build the backing
/// store ourselves as an sRGB CGContext so the byte values are colorspace-stable
/// and never routed through a TIFF/PNG container. Drawing happens inside
/// `performAsCurrentDrawingAppearance` so every dynamic NSColor resolves against
/// the pinned aqua / darkAqua appearance, exactly as the live views do.
func renderRGBA(width: Int, height: Int, dark: Bool, draw: () -> Void) -> RGBAImage {
    precondition(Thread.isMainThread, "AppKit drawing must run on the main thread")
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    buffer.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        // Pin the appearance for dynamic-color resolution; the graphics context
        // we just set stays current for the actual drawing.
        appearance.performAsCurrentDrawingAppearance { draw() }
        NSGraphicsContext.restoreGraphicsState()
    }
    return RGBAImage(width: width, height: height, bytes: buffer)
}

/// The percentages (text) style is rasterized onto a fixed canvas so the buffer
/// dimensions are stable across inputs. Wide enough for "100% / 100%" at the bar
/// font without clipping, tall enough for the bar glyph height.
private let percentCanvas = (width: 100, height: 18)

/// Render a single grid cell to raw sRGB RGBA bytes through the current renderer.
func renderCell(_ cell: RenderCell) -> RGBAImage {
    let mode = colorMode(forKey: cell.modeKey)
    if cell.style == .percentages {
        let text = StatusRenderer.percentText(cell.five, cell.week, mode, renderGoldenBarFont)
        return renderRGBA(width: percentCanvas.width, height: percentCanvas.height, dark: cell.dark) {
            // Draw at a small fixed inset; position is irrelevant to parity as
            // long as capture and re-render agree, which they do by construction.
            text.draw(at: NSPoint(x: 2, y: 2))
        }
    }
    // The three image styles. `image(...)` sizes the glyph itself (barHeight
    // tall); at 1x the point size equals the pixel size.
    let img = StatusRenderer.image(five: cell.five, week: cell.week, style: cell.style,
                                   mode: mode, projected: cell.projected)
    let w = Int(img.size.width.rounded())
    let h = Int(img.size.height.rounded())
    return renderRGBA(width: w, height: h, dark: cell.dark) {
        img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    }
}

// MARK: - Fixture IO

/// The golden fixture directory, resolved from this source file's location so it
/// is independent of the test process working directory.
func renderGoldensDir() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/render-goldens", isDirectory: true)
}

/// Fixture wire format: an 8-byte little-endian header (width, height as UInt32)
/// followed by the raw RGBA bytes. Compact, stable, and never a compressed
/// container, so a byte diff is a pixel diff.
func encodeFixture(_ img: RGBAImage) -> Data {
    var data = Data()
    func appendU32(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    appendU32(UInt32(img.width))
    appendU32(UInt32(img.height))
    data.append(contentsOf: img.bytes)
    return data
}

func decodeFixture(_ data: Data) -> RGBAImage {
    func u32(_ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset ..< offset + 4)
        }
        return UInt32(littleEndian: v)
    }
    let width = Int(u32(0))
    let height = Int(u32(4))
    let bytes = [UInt8](data[(data.startIndex + 8)...])
    return RGBAImage(width: width, height: height, bytes: bytes)
}
