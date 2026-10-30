import Foundation

/// The score the coach gave for the hand its steps play, held until a later save shows what that hand really scored.
/// The save doesn't name the hand just played, so it's found from the one poker hand whose play count went up.
struct ScorePrediction: Sendable {
    let line: Advice.ScoreLine
    let total: Double
    let before: RunSnapshot

    /// nil unless the advice plays a hand now with a numeric total. A discard's line says "if you draw it".
    init?(advice: String, at snapshot: RunSnapshot) {
        guard snapshot.phase == .selectingHand,
              let line = Advice(markdown: advice).score.first(where: { !$0.isAlternative }),
              !line.label.localizedCaseInsensitiveContains("if you draw"),
              let total = line.sum.flatMap({ Double($0.total.replacing(",", with: "")) }), total > 0
        else { return nil }
        (self.line, self.total, self.before) = (line, total, snapshot)
    }

    enum Outcome: Equatable {
        /// The hand hasn't been played yet.
        case pending
        /// Played, or no longer checkable. The note is set when the score was off by more than a tenth.
        case settled(note: String?)
    }

    func check(_ s: RunSnapshot) -> Outcome {
        guard s.identity == before.identity, s.round == before.round else { return .settled(note: nil) }
        if s.handsLeft == before.handsLeft { return .pending }
        // The score resets at cash out, so the shop's save can't say what the last hand scored.
        guard s.handsLeft == before.handsLeft - 1, s.phase == .selectingHand || s.phase == .roundEval,
              let played = playedHand(in: s), played == predictedHand
        else { return .settled(note: nil) }
        let actual = s.chipsScored - before.chipsScored
        guard abs(actual - total) > total / 10 else { return .settled(note: nil) }
        return .settled(note: Prompt.scoreCheck(line, actual: actual))
    }

    private func playedHand(in s: RunSnapshot) -> String? {
        let earlier = Dictionary(before.pokerHands.map { ($0.name, $0.timesPlayed) }, uniquingKeysWith: max)
        let raised = s.pokerHands.filter { $0.timesPlayed == (earlier[$0.name] ?? 0) + 1 }
        return raised.count == 1 ? raised[0].name : nil
    }

    /// The longest hand name in the label, so "Two Pair" isn't read as "Pair" and "Club Flush" is a Flush.
    private var predictedHand: String? {
        before.pokerHands.map(\.name).filter { line.label.localizedCaseInsensitiveContains($0) }.max { $0.count < $1.count }
    }
}

extension Prompt {
    static func scoreCheck(_ line: Advice.ScoreLine, actual: Double) -> String {
        let sum = line.sum.map { " \($0.chips) x \($0.mult) \($0.isEstimate ? "≈" : "=") \($0.total)" } ?? ""
        let chance = line.sum?.isEstimate == true ? "If chance explains the gap, carry on. Otherwise, find" : "Find"
        return """
            SCORE CHECK: Your last steps played \(line.label) and said\(sum). It scored \(chips(actual)). \
            \(chance) the rule or number you got wrong, use the right one from now on, and tell the player in one Why bullet.
            """
    }
}
