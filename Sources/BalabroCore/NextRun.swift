import Foundation

/// Which decks and stakes the player can start, from the game's `profile.jkr` and `meta.jkr`.
public struct PlayerProgress: Sendable, Equatable {
    public struct Deck: Sendable, Equatable {
        public var key: CenterKey
        /// 0 until the deck has won on any stake.
        public var highestWin: Int
        public var wins: Int
        public var losses: Int
        /// One above the highest stake won with this deck (`button_callbacks.lua:738`).
        public var highestStart: Int

        public init(key: CenterKey, highestWin: Int, wins: Int, losses: Int, highestStart: Int) {
            (self.key, self.highestWin, self.wins, self.losses, self.highestStart) = (key, highestWin, wins, losses, highestStart)
        }
    }

    public var career: CareerStats
    /// In the order the game lists them.
    public var decks: [Deck]
    public var locked: [CenterKey]

    public init(career: CareerStats, decks: [Deck], locked: [CenterKey]) {
        (self.career, self.decks, self.locked) = (career, decks, locked)
    }

    static let stakes = ["white", "red", "green", "black", "blue", "purple", "orange", "gold"].map { CenterKey(rawValue: "stake_\($0)") }

    /// `game.lua:628-642`, with what it takes to unlock each one.
    static let allDecks: [(key: CenterKey, unlock: String)] = [
        ("b_red", "always unlocked"),
        ("b_blue", "discover 20 items"),
        ("b_yellow", "discover 50 items"),
        ("b_green", "discover 75 items"),
        ("b_black", "discover 100 items"),
        ("b_magic", "win with the Red Deck"),
        ("b_nebula", "win with the Blue Deck"),
        ("b_ghost", "win with the Yellow Deck"),
        ("b_abandoned", "win with the Green Deck"),
        ("b_checkered", "win with the Black Deck"),
        ("b_zodiac", "win on Red Stake"),
        ("b_painted", "win on Green Stake"),
        ("b_anaglyph", "win on Black Stake"),
        ("b_plasma", "win on Blue Stake"),
        ("b_erratic", "win on Orange Stake"),
    ].map { (CenterKey(rawValue: $0.0), $0.1) }
}
