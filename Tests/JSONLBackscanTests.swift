import XCTest
@testable import ClaudeUsageCore

/// The factored backward scanner: newest-first delivery, the take-while stop, and
/// correct reassembly of a line that straddles a 256 KB window boundary.
final class JSONLBackscanTests: ScratchTestCase {

    private func contains(_ needle: String) -> (Data) -> Bool {
        { String(decoding: $0, as: UTF8.self).contains(needle) }
    }

    private func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - lastLineBackward

    func testLastLineBackwardReturnsNewestMatch() throws {
        let url = try writeFile("a\nMATCH first\nb\nMATCH second\nc\n")
        let line = JSONLBackscan.lastLineBackward(url: url, match: contains("MATCH"))
        XCTAssertEqual(line.map { String(decoding: $0, as: UTF8.self) }, "MATCH second")
    }

    func testLastLineBackwardReturnsNilWhenNoMatch() throws {
        let url = try writeFile("a\nb\nc\n")
        XCTAssertNil(JSONLBackscan.lastLineBackward(url: url, match: contains("MATCH")))
    }

    func testLastLineBackwardFindsFirstLineOfFile() throws {
        // The oldest line (reached only at byte 0) must still be considered.
        let url = try writeFile("MATCH only-line\nb\nc\n")
        let line = JSONLBackscan.lastLineBackward(url: url, match: contains("MATCH"))
        XCTAssertEqual(line.map { String(decoding: $0, as: UTF8.self) }, "MATCH only-line")
    }

    func testLastLineBackwardHandlesMissingTrailingNewline() throws {
        let url = try writeFile("a\nb\nMATCH tail")   // no final \n
        let line = JSONLBackscan.lastLineBackward(url: url, match: contains("MATCH"))
        XCTAssertEqual(line.map { String(decoding: $0, as: UTF8.self) }, "MATCH tail")
    }

    // MARK: - collectLinesBackward

    func testCollectLinesBackwardIsNewestFirst() throws {
        let url = try writeFile("m1\nx\nm2\nm3\n")
        let got = JSONLBackscan.collectLinesBackward(url: url, while: { _ in true },
                                                     match: contains("m"))
        XCTAssertEqual(strings(got), ["m3", "m2", "m1"])
    }

    func testCollectLinesBackwardStopsAtWhilePredicate() throws {
        // Take-while over the newest run: stop AT n2, excluding it and everything older.
        let url = try writeFile("n1\nn2\nn3\nn4\nn5\n")
        let got = JSONLBackscan.collectLinesBackward(
            url: url,
            while: { String(decoding: $0, as: UTF8.self) != "n2" },
            match: { _ in true })
        XCTAssertEqual(strings(got), ["n5", "n4", "n3"])
    }

    func testCollectLinesBackwardMatchFiltersWithinRun() throws {
        let url = try writeFile("keep1\nskip\nkeep2\nskip\n")
        let got = JSONLBackscan.collectLinesBackward(url: url, while: { _ in true },
                                                     match: contains("keep"))
        XCTAssertEqual(strings(got), ["keep2", "keep1"])
    }

    // MARK: - Straddling line across the 256 KB window boundary

    func testStraddlingLineReassembledByLastLineBackward() throws {
        // A single match line longer than one 256 KB window, flanked by short lines,
        // so the scan boundary cuts through it and the carry must rejoin it whole.
        let big = "MATCH_" + String(repeating: "A", count: 300 * 1024)
        let url = try writeFile("head line\n" + big + "\ntail line\n")
        let line = JSONLBackscan.lastLineBackward(url: url, match: contains("MATCH_"))
        XCTAssertEqual(line.map { String(decoding: $0, as: UTF8.self) }, big)
    }

    func testStraddlingLineReassembledByCollect() throws {
        let big = "MATCH_" + String(repeating: "B", count: 300 * 1024)
        let url = try writeFile("head line\n" + big + "\ntail line\n")
        let got = JSONLBackscan.collectLinesBackward(url: url, while: { _ in true },
                                                     match: contains("MATCH_"))
        XCTAssertEqual(strings(got), [big])
    }
}

/// Proves the refactored `SessionsClient` scan selects exactly the entry the
/// pre-refactor inline walk did: the last MAIN-CHAIN assistant message with a
/// usage block, skipping newer noise (a sidechain turn, a pre-filter-passing user
/// line, and a plain tool-result line).
final class ScannerParityTests: ScratchTestCase {

    func testLastAssistantUsageEntryPicksLastMainChainAssistant() throws {
        let lines = [
            // oldest: plain user line (fails the substring pre-filter)
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            // an older assistant/usage turn: a newer one exists, so this must NOT win
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            // THE expected entry: newest main-chain assistant with a usage block
            #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}"#,
            // newer but type=user, yet carries the quoted "assistant"/"usage" tokens so
            // it PASSES the substring pre-filter and must be rejected by the type check
            #"{"type":"user","assistant":true,"usage":true,"message":{"content":"x"}}"#,
            // newer assistant/usage but a sidechain: rejected by the isSidechain check
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4","usage":{"input_tokens":1,"output_tokens":1}}}"#,
            // newest: a tool-result user line (fails the pre-filter)
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"done"}]}}"#,
        ]
        let url = try writeFile(lines.joined(separator: "\n") + "\n")

        let obj = SessionsClient().lastAssistantUsageEntry(url)
        XCTAssertNotNil(obj)
        let msg = obj?["message"] as? [String: Any]
        XCTAssertEqual(msg?["model"] as? String, "claude-opus-4-8")
        let usage = msg?["usage"] as? [String: Any]
        XCTAssertEqual((usage?["input_tokens"] as? NSNumber)?.intValue, 100)
        XCTAssertEqual((usage?["output_tokens"] as? NSNumber)?.intValue, 50)
    }

    func testNoAssistantUsageEntryReturnsNil() throws {
        let url = try writeFile(#"{"type":"user","message":{"content":"just chatter"}}"# + "\n")
        XCTAssertNil(SessionsClient().lastAssistantUsageEntry(url))
    }
}
