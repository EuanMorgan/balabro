import Foundation

/// What a run says about itself. Balatro has no run ID, so this is the closest thing:
/// a seed picked at `start_run` plus the deck and stake chosen with it.
///
/// Two runs can share an identity when the player replays a seed. `RunKey` tells those apart.
public struct RunIdentity: Sendable, Hashable, Codable {
    /// Which of the three save slots (`<profile>/save.jkr`). Comes from the file path, not the file.
    public var profile: Int
    public var seed: String          // GAME.pseudorandom.seed
    public var deck: CenterKey       // GAME.selected_back_key.key (selected_back itself saves as MANUAL_REPLACE)
    public var stake: Int

    public init(profile: Int, seed: String, deck: CenterKey, stake: Int) {
        (self.profile, self.seed, self.deck, self.stake) = (profile, seed, deck, stake)
    }
}

/// Counters the game only ever increases within one run. If a save with the same identity
/// shows any of them lower than the last save we saw, it's a new run on a replayed seed.
public struct ProgressClock: Sendable, Hashable, Codable, Comparable {
    public var round: Int               // GAME.round
    public var handsPlayed: Int         // GAME.hands_played
    public var cardsDiscarded: Int      // GAME.round_scores.cards_discarded.amt
    public var rerolls: Int             // GAME.round_scores.times_rerolled.amt
    public var purchases: Int           // GAME.round_scores.cards_purchased.amt

    /// Componentwise, not lexicographic: "earlier" means some counter went backwards.
    /// Not a total order, which is fine, because the only question asked is "did it go backwards?".
    public static func < (a: Self, b: Self) -> Bool {
        a.round < b.round || a.handsPlayed < b.handsPlayed || a.cardsDiscarded < b.cardsDiscarded
            || a.rerolls < b.rerolls || a.purchases < b.purchases
    }
}

/// The ID of one coached run. Stable across app restarts; the persisted `RunRecord` file name.
public struct RunKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public var identity: RunIdentity
    /// 0 for the first run on this identity, then 1, 2... for each replay of the same seed.
    public var replay: Int
    public var description: String { "p\(identity.profile)-\(identity.seed)-\(identity.deck)-s\(identity.stake)-\(replay)" }
}
