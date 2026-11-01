import BalabroEngine
import Foundation
import Testing

@Suite
struct LineReaderTests {
    /// Only the reader's thread calls `next`, one call at a time.
    final class Chunks: @unchecked Sendable {
        private var remaining: [Data]
        init(_ chunks: [String]) { remaining = chunks.map { Data($0.utf8) } }
        func next() -> Data { remaining.isEmpty ? Data() : remaining.removeFirst() }
    }

    func lines(_ chunks: [String]) async -> [String] {
        let chunks = Chunks(chunks)
        return await LineReader.lines(reading: chunks.next).reduce(into: []) { $0.append($1) }
    }

    @Test func joinsALineSplitAcrossChunks() async {
        #expect(await lines(["@@sta", "tus|1|4\n@@rea", "dy|1.0\n"]) == ["@@status|1|4", "@@ready|1.0"])
    }

    @Test func dropsTheCarriageReturnOfWindowsLineEnds() async {
        #expect(await lines(["@@ready|1.0\r\n@@status|1\r", "\n"]) == ["@@ready|1.0", "@@status|1"])
    }

    @Test func keepsALastLineWithNoNewline() async {
        #expect(await lines(["{\"type\":\"result\"}\n", "Not logged in"]) == ["{\"type\":\"result\"}", "Not logged in"])
    }
}
