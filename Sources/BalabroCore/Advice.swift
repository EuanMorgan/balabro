import Foundation

/// Claude's answer split into the blocks the overlay styles differently.
///
/// Parsing is lenient on purpose: a partial stream or an answer that ignores the format still renders,
/// with whatever didn't match landing in `rest` as markdown.
public struct Advice: Sendable, Equatable {
    public var doNow: [String]
    public var score: [ScoreLine]
    /// One line on what this is building towards, shown while `why` is folded away.
    public var goal: String?
    public var why: [String]
    public var lesson: Lesson?
    public var rest: String

    public init(doNow: [String], score: [ScoreLine] = [], goal: String? = nil, why: [String], lesson: Lesson?, rest: String) {
        (self.doNow, self.score, self.goal, self.why, self.lesson, self.rest) = (doNow, score, goal, why, lesson, rest)
    }

    /// What a hand scores, such as "Two Pair: 46 x 2 = 92". A line in any other form has only a `label`.
    public struct ScoreLine: Sendable, Equatable {
        public var label: String
        public var sum: Sum?
        /// The hand the player might have chosen, shown for comparison.
        public var isAlternative: Bool

        public struct Sum: Sendable, Equatable {
            public var chips: String
            public var mult: String
            public var total: String
            /// The total rests on chance, such as Misprint's random mult, so it's an average.
            public var isEstimate: Bool
            public init(chips: String, mult: String, total: String, isEstimate: Bool = false) {
                (self.chips, self.mult, self.total, self.isEstimate) = (chips, mult, total, isEstimate)
            }
        }

        public enum Outcome: Sendable, Equatable {
            case clears
            case clearsOnAverage
            case leaves(String)
            case leavesAbout(String)
        }

        /// What this hand does to the blind, given the score still needed. nil when the total isn't a number.
        public func outcome(chipsNeeded: Double) -> Outcome? {
            guard let sum, let total = sum.total == "naneinf" ? .infinity : Double(sum.total.replacing(",", with: "")) else { return nil }
            let left = Prompt.chips(chipsNeeded - total)
            return total >= chipsNeeded ? (sum.isEstimate ? .clearsOnAverage : .clears) : (sum.isEstimate ? .leavesAbout(left) : .leaves(left))
        }

        public init(label: String, sum: Sum? = nil, isAlternative: Bool = false) {
            (self.label, self.sum, self.isAlternative) = (label, sum, isAlternative)
        }

        init(line: String) {
            var text = line.replacing("**", with: "")
            let isAlternative = text.lowercased().hasPrefix("instead")
            if isAlternative { text = "Instead: " + text.dropFirst("instead".count).drop { ",: ".contains($0) } }
            guard let match = text.wholeMatch(of: /(.*?)[:\s]*([\d,.]+(?:e\+?\d+)?)\s*[x×]\s*([\d,.]+(?:e\+?\d+)?)\s*(=|≈|~=|~)\s*(naneinf|[\d,]+(?:\.\d+)?(?:e\+?\d+)?)\.?/) else {
                self.init(label: text, isAlternative: isAlternative)
                return
            }
            self.init(label: String(match.1), sum: Sum(chips: String(match.2), mult: String(match.3), total: String(match.5), isEstimate: match.4 != "="), isAlternative: isAlternative)
        }
    }

    public struct Lesson: Sendable, Equatable {
        public var number: Int?
        public var title: String
        public var body: String
        public init(number: Int?, title: String, body: String) { (self.number, self.title, self.body) = (number, title, body) }

        public var heading: String { number.map { "Lesson \($0)" } ?? "Lesson" }
    }

    /// Splits on the `**Do this now:**`, `**Score:**`, `**Goal:**`, `**Why:**` and `**Lesson N: ...**` headings (case-insensitive,
    /// bold optional). Numbered and bulleted lines become items; a half-streamed last line is kept as is.
    public init(markdown: String) {
        (doNow, score, goal, why, lesson) = ([], [], nil, [], nil)
        var scoreLines: [String] = []
        var goalLines: [String] = []
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
                if !remainder.isEmpty { Self.add(remainder, to: heading, doNow: &doNow, score: &scoreLines, goal: &goalLines, why: &why, lessonBody: &lessonBody) }
                continue
            }
            guard let section else {
                rest.append(String(rawLine))
                continue
            }
            if !line.isEmpty { Self.add(line, to: section, doNow: &doNow, score: &scoreLines, goal: &goalLines, why: &why, lessonBody: &lessonBody) }
        }
        score = scoreLines.map(ScoreLine.init(line:))
        goal = goalLines.isEmpty ? nil : goalLines.joined(separator: " ")
        if lesson != nil { lesson?.body = lessonBody.joined(separator: " ") }
        self.rest = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A last line such as `2` or `**Wh` is the start of a list marker or heading, not text. Showing it would
    /// append it to the item above for a moment, then jump.
    private static func isStillStreaming(_ line: String) -> Bool {
        (!line.isEmpty && line.allSatisfy(\.isNumber)) || line == "-" || (line.hasPrefix("**") && heading(line) == nil && !line.dropFirst(2).contains("**"))
    }

    private enum Section {
        case doNow, score, goal, why
        case lesson(number: Int?, title: String)
    }

    private static func add(
        _ line: String, to section: Section, doNow: inout [String], score: inout [String], goal: inout [String], why: inout [String],
        lessonBody: inout [String]
    ) {
        switch section {
        case .doNow: addItem(line, to: &doNow)
        case .score: addItem(line, to: &score)
        case .goal: goal.append(line)
        case .why: addItem(line, to: &why)
        case .lesson: lessonBody.append(line)
        }
    }

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

    /// `**Do this now:**`, `**Score:**`, `## Why`, `Why:`, `Lesson 12: title`, and a bold heading cut off mid-stream such as `**Do this now:`.
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
        }
        let label = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let remainderText = remainder.trimmingCharacters(in: .whitespaces)
        switch label.lowercased() {
        case "do this now": return (.doNow, remainderText)
        case "score": return (.score, remainderText)
        case "goal": return (.goal, remainderText)
        case "why": return (.why, remainderText)
        default: break
        }
        guard label.lowercased().hasPrefix("lesson") else { return nil }
        let afterWord = label.dropFirst("lesson".count)
        let digits = afterWord.drop { $0 == " " }.prefix { $0.isNumber }
        let titleStart = afterWord.drop { $0 == " " }.dropFirst(digits.count)
        guard digits.isEmpty ? (titleStart.first == ":" || titleStart.isEmpty) : true else { return nil }
        let title = titleStart.trimmingCharacters(in: CharacterSet(charactersIn: ":-–— "))
        return (.lesson(number: Int(digits), title: title), remainderText)
    }
}
