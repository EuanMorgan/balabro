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
        (doNow, why, lesson) = ([], [], nil)
        var rest: [String] = []
        var section: Section?
        var lessonBody: [String] = []
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if index == lines.count - 1, Self.isStillStreaming(line) { continue }
            if let (heading, remainder) = Self.heading(line) {
                section = heading
                if case .lesson(let number, let title) = heading {
                    lesson = Lesson(number: number, title: title, body: "")
                    lessonBody = []
                }
                if !remainder.isEmpty { Self.add(remainder, to: heading, doNow: &doNow, why: &why, lessonBody: &lessonBody) }
                continue
            }
            guard let section else {
                rest.append(String(rawLine))
                continue
            }
            if !line.isEmpty { Self.add(line, to: section, doNow: &doNow, why: &why, lessonBody: &lessonBody) }
        }
        if lesson != nil { lesson?.body = lessonBody.joined(separator: " ") }
        self.rest = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A last line such as `2` or `**Wh` is the start of a list marker or heading, not text. Showing it would
    /// append it to the item above for a moment, then jump.
    private static func isStillStreaming(_ line: String) -> Bool {
        (!line.isEmpty && line.allSatisfy(\.isNumber)) || line == "-" || (line.hasPrefix("**") && heading(line) == nil && !line.dropFirst(2).contains("**"))
    }

    private enum Section {
        case doNow, why
        case lesson(number: Int?, title: String)
    }

    private static func add(_ line: String, to section: Section, doNow: inout [String], why: inout [String], lessonBody: inout [String]) {
        switch section {
        case .doNow: addItem(line, to: &doNow)
        case .why: addItem(line, to: &why)
        case .lesson: lessonBody.append(line)
        }
    }

    /// A line with a list marker starts an item; a line without one continues the item above it.
    private static func addItem(_ line: String, to items: inout [String]) {
        if let item = listItem(line) {
            items.append(item)
        } else if let last = items.indices.last {
            items[last] += " " + line
        } else {
            items.append(line)
        }
    }

    /// `1. x`, `1) x`, `- x`, `* x`, `• x` -> `x`.
    private static func listItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        var body = line.dropFirst(digits.count)
        if !digits.isEmpty {
            guard let marker = body.first, marker == "." || marker == ")" else { return nil }
            body = body.dropFirst()
        } else {
            guard let marker = body.first, "-*•".contains(marker) else { return nil }
            body = body.dropFirst()
            if marker == "*", body.first == "*" { return nil }
        }
        guard body.isEmpty || body.first == " " else { return nil }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// `**Do this now:**`, `## Why`, `Lesson 12: title`, and a bold heading cut off mid-stream such as `**Do this now:`.
    /// Returns the text after the heading on the same line too, so `**Why:** because` keeps "because".
    private static func heading(_ line: String) -> (Section, remainder: String)? {
        var text = Substring(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)[...]
        var remainder = Substring("")
        if text.hasPrefix("**") {
            text = text.dropFirst(2)
            if let close = text.range(of: "**") {
                remainder = text[close.upperBound...]
                text = text[..<close.lowerBound]
            }
        } else if let colon = text.firstIndex(of: ":") {
            remainder = text[text.index(after: colon)...]
            text = text[..<colon]
        }
        let label = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let remainderText = remainder.trimmingCharacters(in: .whitespaces)
        switch label.lowercased() {
        case "do this now": return (.doNow, remainderText)
        case "why": return (.why, remainderText)
        default: break
        }
        guard label.lowercased().hasPrefix("lesson") else { return nil }
        let afterWord = label.dropFirst("lesson".count)
        let digits = afterWord.drop { $0 == " " }.prefix { $0.isNumber }
        let titleStart = afterWord.drop { $0 == " " }.dropFirst(digits.count)
        guard digits.isEmpty ? (titleStart.first == ":" || titleStart.isEmpty) : true else { return nil }
        let title = titleStart.trimmingCharacters(in: CharacterSet(charactersIn: ":-–— "))
        if title.isEmpty, !remainderText.isEmpty, !line.hasPrefix("**") {
            return (.lesson(number: Int(digits), title: remainderText), "")
        }
        return (.lesson(number: Int(digits), title: title), remainderText)
    }
}
