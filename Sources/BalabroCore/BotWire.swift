import Foundation

/// The bot's messages, one per line on the game's stdout. The game prints to stdout too, so anything without the
/// `@@` prefix isn't one of them. `bot/main.lua` and `bot/run.lua` are the other end of this format.
public enum BotFrame: Sendable, Hashable {
    case ready(gameVersion: String)
    case status(BotStatus)
    case decide(QuestionID, BotAsk, file: URL, brief: String)
    case refused(QuestionID, move: String, reason: String)
    /// `predicted` is nil when the hand depended on chance or on face-down cards, so there's nothing to compare.
    case played(hand: String, predicted: Double?, actual: Double)
    case ended(BotEnding)
    case broken(kind: String, detail: String)

    public init?(line: String) {
        guard line.hasPrefix("@@") else { return nil }
        let parts = line.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        func field(_ index: Int) -> String? { parts.indices.contains(index) ? parts[index] : nil }
        switch parts[0] {
        case "ready":
            self = .ready(gameVersion: field(1) ?? "")
        case "status":
            guard let ante = field(1).flatMap(Int.init), let round = field(2).flatMap(Int.init), let dollars = field(3).flatMap(Int.init),
                  let best = field(4).flatMap(Double.init) else { return nil }
            self = .status(BotStatus(ante: ante, round: round, dollars: dollars, bestHand: best, doing: parts.dropFirst(5).joined(separator: "|")))
        case "decide":
            guard let id = field(1).flatMap(Int.init), let kind = field(2), let picks = field(3).flatMap(Int.init), let path = field(4),
                  let ask = BotAsk(kind: kind, picks: picks) else { return nil }
            self = .decide(QuestionID(id), ask, file: URL(filePath: path), brief: parts.dropFirst(5).joined(separator: "|"))
        case "refused":
            guard let id = field(1).flatMap(Int.init), let move = field(2), let reason = field(3) else { return nil }
            self = .refused(QuestionID(id), move: move, reason: reason)
        case "played":
            guard let hand = field(1), let predicted = field(2), let actual = field(3).flatMap(Double.init) else { return nil }
            self = .played(hand: hand, predicted: Double(predicted), actual: actual)
        case "ended":
            guard let outcome = field(1).flatMap(BotEnding.Outcome.init), let ante = field(2).flatMap(Int.init),
                  let round = field(3).flatMap(Int.init), let best = field(4).flatMap(Double.init) else { return nil }
            self = .ended(BotEnding(outcome: outcome, ante: ante, round: round, bestHand: best))
        case "broken":
            self = .broken(kind: field(1) ?? "crashed", detail: field(2) ?? "")
        default:
            return nil
        }
    }
}

public struct QuestionID: Sendable, Hashable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public enum BotAsk: Sendable, Hashable {
    case shop, blind, hand
    case pack(picks: Int)

    init?(kind: String, picks: Int) {
        switch kind {
        case "shop": self = .shop
        case "blind": self = .blind
        case "hand": self = .hand
        case "pack": self = .pack(picks: picks)
        default: return nil
        }
    }
}

public struct BotStatus: Sendable, Hashable {
    public var ante: Int
    public var round: Int
    public var dollars: Int
    public var bestHand: Double
    public var doing: String

    public init(ante: Int, round: Int, dollars: Int, bestHand: Double, doing: String) {
        (self.ante, self.round, self.dollars, self.bestHand, self.doing) = (ante, round, dollars, bestHand, doing)
    }
}

public struct BotEnding: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable { case won, naneinf, lost }
    public var outcome: Outcome
    public var ante: Int
    public var round: Int
    public var bestHand: Double

    public init(outcome: Outcome, ante: Int, round: Int, bestHand: Double) {
        (self.outcome, self.ante, self.round, self.bestHand) = (outcome, ante, round, bestHand)
    }
}
