import XCTest
@testable import ClaudeUsageCore

// One-shot golden CAPTURE, gated behind an environment variable so an ordinary
// `swift test` run never regenerates the fixtures (that would silently rebase
// the parity test onto whatever code is currently checked in and prove nothing).
//
// To (re)capture the pre-4a renderer goldens:
//
//     CAPTURE_RENDER_GOLDENS=1 swift test --filter RenderGoldenCaptureTests
//
// The fixtures under Tests/Fixtures/render-goldens/ were produced this way while
// StatusRenderer.swift was still at commit 00c7d6a (pre-package-4a). See the
// README.md in that directory.
final class RenderGoldenCaptureTests: XCTestCase {

    func testCaptureGoldens() throws {
        guard ProcessInfo.processInfo.environment["CAPTURE_RENDER_GOLDENS"] == "1" else {
            throw XCTSkip("Set CAPTURE_RENDER_GOLDENS=1 to (re)capture render goldens.")
        }
        let dir = renderGoldensDir()
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let cells = renderGoldenCells()
        for cell in cells {
            let img = renderCell(cell)
            let url = dir.appendingPathComponent(cell.id + ".rgba")
            try encodeFixture(img).write(to: url)
        }
        // A trivially-true assertion keeps XCTest from flagging a "no assertion"
        // capture; the real proof lives in the parity test.
        XCTAssertEqual(cells.count, renderGoldenCells().count)
        NSLog("Captured \(cells.count) render goldens into \(dir.path)")
    }
}
