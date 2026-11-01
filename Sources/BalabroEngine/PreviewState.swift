import BalabroCore
import Foundation

/// The panel states both apps draw for side-by-side checks: the Mac's `--render-previews`, and the Windows app from
/// `balabro-engine --print-preview-views`.
public struct PreviewState: Sendable {
    public enum Panel: Sendable {
        case coach(CoachView)
        case pilot(PilotView)
    }

    /// The image's file name, without `.png`.
    public var name: String
    public var panel: Panel
    /// Every panel is 320 points wide.
    public var height: Double
    public var showsWhy = false
    public var update: AppRelease?

    public func line() throws -> Data { try jsonLine(self) }

    /// The pilot states come first, because their clocks run from `now` and must be drawn before it moves on.
    public static func all(now: Date) -> [PreviewState] {
        let run = BotStatus(ante: 4, round: 11, dollars: 41, bestHand: 4420, doing: "Discarding 3 cards, 61% to reach 2,442")
        let result = PilotResult(goal: "win", deck: CenterKey(rawValue: "b_red"), stake: 1, ending: .won, ante: 8, round: 24, bestHand: 88_000, seconds: 412, gameVersion: "1.0.1o", finishedAt: now)
        return [
            PreviewState(name: "pilot-playing", panel: .pilot(PilotView(status: .playing, startedAt: now.addingTimeInterval(-136), run: run, why: "Hologram gives scaling XMult, which beats Sly Joker's flat chips, for $6.")), height: 300),
            PreviewState(name: "pilot-finished", panel: .pilot(PilotView(status: .finished, result: result, bestTimes: [BestTime(title: "Fastest win", seconds: 412)])), height: 300),
            PreviewState(name: "overlay-waiting", panel: .coach(CoachView(status: .waitingForRun, headline: "", advice: nil, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 420),
            PreviewState(name: "overlay-streaming", panel: .coach(CoachView(status: .answering, headline: "Ante 1 · Big Blind", advice: streaming, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 420),
            PreviewState(name: "overlay-finished", panel: .coach(CoachView(status: .ready, headline: "Ante 1 · Big Blind", chipsNeeded: 450, advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 560, showsWhy: true),
            PreviewState(name: "overlay-naneinf", panel: .coach(CoachView(status: .ready, goal: .naneinf, headline: "Ante 26 · The Serpent", chipsNeeded: 3e184, advice: naneinf, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 420),
            PreviewState(name: "overlay-estimate", panel: .coach(CoachView(status: .ready, headline: "Ante 6 · Small Blind", chipsNeeded: 20000, advice: estimate, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 420, showsWhy: true),
            PreviewState(name: "overlay-cash", panel: .coach(CoachView(status: .ready, headline: "Ante 3 · Shop", advice: cash, thread: [], queuedQuestion: "Is $4 worth it?", problem: nil, canRetry: false)), height: 520, showsWhy: true),
            PreviewState(name: "overlay-update", panel: .coach(CoachView(status: .ready, headline: "Ante 1 · Big Blind", advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)), height: 420, update: release),
            PreviewState(name: "overlay-follow-up", panel: .coach(CoachView(status: .ready, headline: "Ante 1 · Big Blind", advice: finished, thread: thread, queuedQuestion: nil, problem: nil, canRetry: false)), height: 520),
            PreviewState(name: "overlay-thinking-hand", panel: .coach(thinking(.playHand, headline: "Ante 1 · Big Blind")), height: 420),
            PreviewState(name: "overlay-thinking-shop", panel: .coach(thinking(.shop, headline: "Ante 3 · Shop")), height: 420),
            PreviewState(name: "overlay-thinking-blind", panel: .coach(thinking(.blindSelect, headline: "Ante 2 · Choose a blind")), height: 420),
            PreviewState(name: "overlay-thinking-pack", panel: .coach(thinking(.openPack(arcana, from: .shop), headline: "Ante 2 · Arcana Pack")), height: 420),
        ]
    }

    private static let arcana = BoosterPack(key: CenterKey(rawValue: "p_arcana_normal_1"), kind: .arcana, cardsShown: 3, picks: 1)

    private static func thinking(_ kind: Decision.Kind, headline: String) -> CoachView {
        CoachView(status: .thinking, headline: headline, waitingOn: kind, advice: nil, thread: [], queuedQuestion: nil, problem: nil, canRetry: false)
    }

    private static let finished = Advice(
        doNow: [
            "Discard 7♠ 6♥ 5♠ 2♦.",
            "Keep K♥ K♣ 3♠ 3♦. Any King or 3 makes a Full House.",
            "Play the Full House if it lands, otherwise play K-K-3-3.",
        ],
        score: [
            .init(label: "Full House, if you draw it", sum: .init(chips: "79", mult: "4", total: "316")),
            .init(label: "Instead: Two Pair", sum: .init(chips: "46", mult: "2", total: "92"), isAlternative: true),
        ],
        goal: "Going for a Full House",
        why: [
            "Big Blind needs 450. Two Pair K-K-3-3 scores (20 + 26) × 2 = **92**.",
            "A Full House K-K-K-3-3 scores (40 + 39) × 4 = **316**, more than three times as much.",
            "4 outs (2 Kings, 2 threes) in 44 cards. Drawing 4 hits about 1 time in 3.",
        ],
        lesson: Advice.Lesson(number: 3, title: "Two Pair is a draw, not a finish",
                              body: "Early in a blind, keep the pairs and throw the rest. You have hands to spare."),
        rest: "")

    private static let estimate = Advice(
        doNow: ["Play 7♦ 6♠ 4♠ 3♥ 3♣."],
        score: [
            .init(label: "Pair of 3s", sum: .init(chips: "226", mult: "49", total: "11,074", isEstimate: true)),
            .init(label: "Instead: High Card", sum: .init(chips: "205", mult: "35", total: "7,175", isEstimate: true), isAlternative: true),
        ],
        why: ["Misprint averages +11.5 Mult, but it can be anything from +0 to +23."],
        lesson: nil, rest: "")

    private static let cash = Advice(
        doNow: ["Buy Golden Joker (right, $6).", "Keep K♠ 3♦ for later, then reroll for $5, leaving $1,000, as planned."],
        goal: "Stay above $25",
        why: ["$25 earns the full $5 of interest."],
        lesson: Advice.Lesson(number: 2, title: "Spend what's above $25", body: "Money past the cap, such as the $7 here, earns nothing."),
        rest: "")

    private static let naneinf = Advice(
        doNow: ["Play K♠."],
        score: [
            .init(label: "High Card", sum: .init(chips: "1.2e150", mult: "3.5e157", total: "naneinf")),
            .init(label: "Instead: Pair of Kings", sum: .init(chips: "2.1e60", mult: "1.5e80", total: "3.2e140"), isAlternative: true),
        ],
        why: ["Every King held multiplies the mult, so the played hand hardly matters."],
        lesson: nil, rest: "")

    private static let release = AppRelease(
        version: AppVersion("0.2.0")!,
        download: URL(string: "https://github.com/EuanMorgan/balabro/releases/download/v0.2.0/Balabro-0.2.0.zip")!,
        page: URL(string: "https://github.com/EuanMorgan/balabro/releases/tag/v0.2.0")!)

    private static let thread = [
        CoachView.FollowUp(question: "Why not keep the 7♠?", reply: "It doesn't pair with anything, and K-K-3-3 only wants a King or a 3. Holding it costs you a draw at **4 outs**.", changedSteps: false),
        CoachView.FollowUp(question: "I'd rather keep the 2♦ for Hack", reply: "Fair, Hack retriggers it, so it adds chips to any hand it's in.", changedSteps: true),
    ]

    private static let streaming = Advice(
        doNow: ["Discard 7♠ 6♥ 5♠ 2♦.", "Keep K♥ K♣ 3♠ 3♦. Any King"],
        why: [], lesson: nil, rest: "")
}

extension PreviewState: Encodable {
    private enum CodingKeys: String, CodingKey { case name, type, view, height, showsWhy, update }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch panel {
        case .coach(let view):
            try container.encode("coach", forKey: .type)
            try container.encode(view, forKey: .view)
        case .pilot(let view):
            try container.encode("pilot", forKey: .type)
            try container.encode(view, forKey: .view)
        }
        try container.encode(height, forKey: .height)
        try container.encode(showsWhy, forKey: .showsWhy)
        try container.encodeIfPresent(update, forKey: .update)
    }
}
