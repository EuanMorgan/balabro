import Foundation

/// What Claude decided at one question. A plan has one `ending` and it's always last, so nothing can follow a move
/// that changes the board.
public struct Plan: Sendable, Hashable {
    public var why: String
    /// Run in order. Every position refers to the state Claude was shown.
    public var moves: [String]
    public var ending: Ending

    public enum Ending: Sendable, Hashable {
        case next(BlindChoice)
        case reroll
        case openPack(Int)
    }
    public enum BlindChoice: String, Sendable, Hashable { case play, skip }

    public init(why: String, moves: [String], ending: Ending) { (self.why, self.moves, self.ending) = (why, moves, ending) }

    /// For when Claude has failed: spend nothing and carry on.
    public static let moveOn = Plan(why: "Claude didn't answer, so the bot moved on without spending.", moves: [], ending: .next(.play))

    /// Claude's reply, line by line. Checks the shape only. Whether a move is legal is the game's to say, so no game
    /// rule is restated here. A reply with no ending line counts as `next play`.
    public static func parse(_ reply: String) -> Result<Plan, PlanProblem> {
        var why = "", moves: [String] = [], ending: Ending?
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`*"))
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("why:") {
                why = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                continue
            }
            let lower = line.lowercased()
            if ending != nil { return .failure(PlanProblem(line: line, reason: "nothing can follow the last line")) }
            if lower == "next play" { ending = .next(.play) }
            else if lower == "next skip" { ending = .next(.skip) }
            else if lower == "reroll" { ending = .reroll }
            else if let match = lower.wholeMatch(of: /open pack (\d+)/), let position = Int(match.1) { ending = .openPack(position) }
            else if let move = wireMove(lower) { moves.append(move) }
            else { return .failure(PlanProblem(line: line, reason: "it isn't one of the allowed lines")) }
        }
        return .success(Plan(why: why, moves: moves, ending: ending ?? .next(.play)))
    }

    private static func wireMove(_ line: String) -> String? {
        if let match = line.wholeMatch(of: /buy and use card (\d+)/) { return "buyuse card \(match.1)" }
        if line.wholeMatch(of: /buy (card|voucher) \d+/) != nil { return line }
        if line.wholeMatch(of: /sell (joker|consumable) \d+/) != nil { return line }
        if line.wholeMatch(of: /use consumable \d+( on hand( \d+)+)?/) != nil { return line }
        if line.wholeMatch(of: /take pick \d+( on hand( \d+)+)?/) != nil { return line }
        return nil
    }

    /// What the bot reads: `plan|12|why:...|buy card 2|end:next play`. The why is last-minute text for the panel only.
    func line(question: QuestionID) -> String {
        let end = switch ending {
        case .next(let choice): "next \(choice.rawValue)"
        case .reroll: "reroll"
        case .openPack(let position): "open \(position)"
        }
        return (["plan", String(question.value), "why:" + why.replacingOccurrences(of: "|", with: "/")] + moves + ["end:" + end])
            .joined(separator: "|")
    }

    /// The why so far, from a reply still being written.
    public static func partialWhy(_ partial: String) -> String? {
        guard let line = partial.split(whereSeparator: \.isNewline).first, line.lowercased().hasPrefix("why:") else { return nil }
        return line.dropFirst(4).trimmingCharacters(in: .whitespaces)
    }
}

public struct PlanProblem: Error, Sendable, Hashable {
    public var line: String
    public var reason: String
    var feedback: String {
        "Your last reply couldn't be read, because of the line \"\(line)\": \(reason). Reply again with only the allowed lines."
    }
}
