import Foundation

/// Claude's answer split into the three blocks the overlay styles differently.
///
/// Parsing is lenient on purpose: a partial stream or an answer that ignores the format still renders,
/// with whatever didn't match landing in `rest` as markdown.
public struct Advice: Sendable, Equatable {
    public var doNow: [String]
    public var why: [String]
    public var lesson: Lesson?
    public var rest: String

    public struct Lesson: Sendable, Equatable {
        public var number: Int?
        public var title: String
        public var body: String
        public init(number: Int?, title: String, body: String) { (self.number, self.title, self.body) = (number, title, body) }
    }

    /// Splits on the `**Do this now:**`, `**Why:**` and `**Lesson N: ...**` headings (case-insensitive,
    /// bold optional). Numbered and bulleted lines become items; a half-streamed last line is kept as is.
    public init(markdown: String) {
        // TODO: line scanner, not regex soup. Heading match: trim, strip `*`, lowercase, hasPrefix.
        fatalError("not implemented")
    }
}
