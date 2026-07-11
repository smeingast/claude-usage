import XCTest

// Shared helpers for the golden and scanner tests. Kept here (Tests/), never under
// Sources/, so nothing test-only reaches the app build.

/// A fixed UTC instant, so date-formatted goldens do not depend on the machine's
/// locale or time zone.
func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

/// "HH:mm" in UTC with a fixed POSIX locale: deterministic across environments, so
/// the status-line and model-row goldens can assert exact strings.
func hmUTCFormatter() -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "HH:mm"
    return f
}

/// Base case with a private scratch directory (fresh per test, removed after) for
/// the file-backed scanner and parity tests.
class ScratchTestCase: XCTestCase {
    private(set) var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // @nonobjc: XCTestCase is an NSObject subclass, so these two overloads would
    // otherwise collide on the same Objective-C selector (writeFile:name:error:).
    @nonobjc @discardableResult
    func writeFile(_ data: Data, name: String = UUID().uuidString + ".jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @nonobjc @discardableResult
    func writeFile(_ text: String, name: String = UUID().uuidString + ".jsonl") throws -> URL {
        try writeFile(Data(text.utf8), name: name)
    }
}
