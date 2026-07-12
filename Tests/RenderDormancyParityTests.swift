import XCTest
@testable import ClaudeUsageCore

// The heart of package 4a's "dormant" acceptance [R4]: every new rendering
// parameter defaults to a value that reproduces the pre-4a output exactly. This
// re-renders each golden grid cell through the POST-4a renderer, using the OLD
// call-site signature (defaults only, exactly what `renderCell` does), with the
// same pinned method the goldens were captured under, and asserts RGBA equality
// within +/-1/255 per channel (the tolerance absorbs any antialiasing wobble;
// capture determinism was verified separately).
//
// The goldens were frozen from commit 00c7d6a (see
// Tests/Fixtures/render-goldens/README.md), so a green run here means the 4a
// additions (provider/role threading, the corner pip, "Both", the dashed track,
// the percentages bullet, and the ColorMode "claude" -> "brand" rename) changed
// not a single pixel of any existing call site.
final class RenderDormancyParityTests: XCTestCase {

    /// A channel diff strictly greater than this fails the cell.
    private let tolerance = 1

    func testEveryGoldenCellRendersPixelIdentically() throws {
        let dir = renderGoldensDir()
        let cells = renderGoldenCells()
        XCTAssertFalse(cells.isEmpty, "Grid is empty; the render golden definition is broken.")

        var missing: [String] = []
        var mismatches: [String] = []

        for cell in cells {
            let url = dir.appendingPathComponent(cell.id + ".rgba")
            guard let data = try? Data(contentsOf: url) else {
                missing.append(cell.id)
                continue
            }
            let golden = decodeFixture(data)
            let now = renderCell(cell)

            guard now.width == golden.width, now.height == golden.height,
                  now.bytes.count == golden.bytes.count else {
                mismatches.append("\(cell.id): size \(now.width)x\(now.height) vs golden \(golden.width)x\(golden.height)")
                continue
            }

            var worst = 0
            var offending = 0
            for i in 0 ..< now.bytes.count {
                let delta = abs(Int(now.bytes[i]) - Int(golden.bytes[i]))
                if delta > worst { worst = delta }
                if delta > tolerance { offending += 1 }
            }
            if offending > 0 {
                mismatches.append("\(cell.id): \(offending) channels off by > \(tolerance)/255 (worst \(worst))")
            }
        }

        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) golden fixtures missing (recapture with CAPTURE_RENDER_GOLDENS=1): \(missing.prefix(8))")
        XCTAssertTrue(mismatches.isEmpty,
                      "Dormancy broken: \(mismatches.count) of \(cells.count) cells drifted. First few: \(mismatches.prefix(8))")
    }
}
