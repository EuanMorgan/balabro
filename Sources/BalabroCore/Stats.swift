import Foundation

/// The game's all-time totals from `profile.jkr`, which go back further than Balabro does.
public struct CareerStats: Sendable, Equatable {
    public struct Count: Sendable, Equatable {
        public var name: String
        public var count: Int
        public init(name: String, count: Int) { (self.name, self.count) = (name, count) }
    }

    public var wins = 0
    public var losses = 0
    public var rounds = 0
    public var handsPlayed = 0
    public var bestHand = 0.0
    public var mostMoney = 0
    public var furthestAnte = 0
    public var furthestRound = 0
    /// Most used first, with the game's display names.
    public var hands: [Count] = []
    /// Most used first, by joker key (`j_flower_pot`).
    public var jokers: [Count] = []

    public init() {}

    public var runs: Int { wins + losses }
}

/// One run as Balabro last saw it. The game forgets a run when it ends, so this is the only record of it.
public struct RunSummary: Sendable, Hashable, Codable {
    public var deck: CenterKey
    public var stake: Int
    public var ante: Int
    public var round: Int
    public var won: Bool
    /// Means the save was removed, which also happens when a run is abandoned, so it doesn't mean a loss.
    public var ended: Bool
    public var bestHand: Double
    public var peakDollars: Int
    public var mostPlayedHand: String?
    public var jokers: [CenterKey]

    public init(deck: CenterKey, stake: Int, ante: Int, round: Int, won: Bool, ended: Bool, bestHand: Double, peakDollars: Int, mostPlayedHand: String?, jokers: [CenterKey]) {
        (self.deck, self.stake, self.ante, self.round, self.won, self.ended) = (deck, stake, ante, round, won, ended)
        (self.bestHand, self.peakDollars, self.mostPlayedHand, self.jokers) = (bestHand, peakDollars, mostPlayedHand, jokers)
    }

    init(_ snapshot: RunSnapshot, previous: RunSummary?) {
        self.init(
            deck: snapshot.identity.deck, stake: snapshot.identity.stake, ante: snapshot.ante, round: snapshot.round,
            won: snapshot.won, ended: false, bestHand: snapshot.bestHandScore,
            peakDollars: max(previous?.peakDollars ?? 0, snapshot.dollars),
            mostPlayedHand: snapshot.pokerHands.filter { $0.timesPlayed > 0 }.max { $0.timesPlayed < $1.timesPlayed }?.name,
            jokers: snapshot.jokers.map(\.key))
    }
}
