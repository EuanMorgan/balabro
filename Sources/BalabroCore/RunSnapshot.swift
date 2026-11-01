import Foundation

/// One `save.jkr` write, as typed values. Built only by `SaveFile.decode`.
///
/// Holds what the player can see on screen, plus the joker and consumable numbers the screen
/// hides behind a hover. It deliberately cannot hold the two things the player can't see:
/// the draw order of the deck (`deck` is a count, not a list) and the faces of face-down cards
/// (`HandCard.faceDown` has no payload). Coaching on hidden information would be cheating,
/// and the type makes it impossible rather than a rule to remember.
public struct RunSnapshot: Sendable, Hashable, Codable {
    public var identity: RunIdentity
    public var progress: ProgressClock
    public var phase: Phase
    /// Set only when the game saved with `save_with_action`, which today means "a shop booster is opening".
    public var openingBooster: BoosterPack?
    public var gameVersion: String

    public var dollars: Int
    public var ante: Int
    public var round: Int
    public var blind: Blind?
    public var blindSelect: BlindSelect
    public var blindScale: BlindScale
    public var handsLeft: Int
    public var discardsLeft: Int
    public var handSize: Int
    /// Score so far against `blind.target` this round.
    public var chipsScored: Double
    /// Set once Ante 8 is beaten, and stays set through endless mode.
    public var won: Bool
    public var bestHandScore: Double

    /// Left to right, as on screen.
    public var hand: [HandCard]
    /// Left to right. Order matters for scoring (Blueprint, Brainstorm, xMult after +Mult).
    public var jokers: [Joker]
    public var jokerSlots: Int
    public var consumables: [Consumable]
    public var consumableSlots: Int
    public var shop: Shop?
    public var deck: DeckComposition
    public var pokerHands: [PokerHandLevel]
    /// Skip tags the player holds, oldest first. Unapplied pack tags signal an unseen booster.
    public var tags: [TagKey]
    public var vouchers: [CenterKey]
    /// What The Fool would copy.
    public var lastTarotOrPlanet: CenterKey?
    /// Fortune Teller's mult comes from this count, not from the joker's own values.
    public var tarotsUsed: Int
    public var roundTargets: RoundTargets
}

/// What the "changes every round" jokers want right now. The game only shows these on hover, and
/// reads them from `GAME.current_round`, not from the joker.
public struct RoundTargets: Sendable, Hashable, Codable {
    public var mailRank: Rank?
    public var idolRank: Rank?
    public var idolSuit: Suit?
    public var ancientSuit: Suit?
    public var castleSuit: Suit?
}

/// The game's `STATE` number, reduced to the cases the coach cares about.
public enum Phase: Sendable, Hashable, Codable {
    case selectingHand
    case shop
    case blindSelect
    case pack(PackKind)
    case roundEval
    case gameOver
    /// Any other `STATE`, kept rather than rejected so a game update degrades to "no coaching" instead of "crash".
    case other(Int)

    /// `globals.lua:284`.
    init(state: Int) {
        self = switch state {
        case 1: .selectingHand
        case 4: .gameOver
        case 5: .shop
        case 7: .blindSelect
        case 8: .roundEval
        case 9: .pack(.arcana)
        case 10: .pack(.celestial)
        case 15: .pack(.spectral)
        case 17: .pack(.standard)
        case 18: .pack(.buffoon)
        default: .other(state)
        }
    }
}

public enum PackKind: String, Sendable, Hashable, Codable {
    case arcana, celestial, spectral, standard, buffoon
}

/// A booster from `cardAreas.shop_booster`, or the pack a skip tag will open.
public struct BoosterPack: Sendable, Hashable, Codable {
    public var key: CenterKey          // p_arcana_normal_1, p_buffoon_mega_1, ...
    public var kind: PackKind
    /// From `ability.extra` (cards shown) and `ability.choose` (cards you may take).
    public var cardsShown: Int
    public var picks: Int

    public init(key: CenterKey, kind: PackKind, cardsShown: Int, picks: Int) {
        (self.key, self.kind, self.cardsShown, self.picks) = (key, kind, cardsShown, picks)
    }
}

public struct CenterKey: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct TagKey: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Tags whose `config.type` is `new_blind_choice` (`game.lua:234-240`): they open a pack
    /// right after the save that records them, so the save never shows the cards.
    public var opensPack: PackKind? {
        switch rawValue {
        case "tag_standard": .standard
        case "tag_charm": .arcana
        case "tag_meteor": .celestial
        case "tag_buffoon": .buffoon
        case "tag_ethereal": .spectral
        default: nil
        }
    }
}

public enum Suit: String, Sendable, Hashable, Codable, CaseIterable {
    case spades = "Spades", hearts = "Hearts", clubs = "Clubs", diamonds = "Diamonds"
    public var symbol: Character {
        switch self { case .spades: "♠"; case .hearts: "♥"; case .clubs: "♣"; case .diamonds: "♦" }
    }
}

public enum Rank: String, Sendable, Hashable, Codable, CaseIterable {
    case two = "2", three = "3", four = "4", five = "5", six = "6", seven = "7", eight = "8", nine = "9", ten = "10"
    case jack = "Jack", queen = "Queen", king = "King", ace = "Ace"
}

public enum Enhancement: String, Sendable, Hashable, Codable {
    case bonus = "m_bonus", mult = "m_mult", wild = "m_wild", glass = "m_glass", steel = "m_steel"
    case stone = "m_stone", gold = "m_gold", lucky = "m_lucky"
}

public enum Edition: String, Sendable, Hashable, Codable {
    case foil, holo, polychrome, negative
}

public enum Seal: String, Sendable, Hashable, Codable {
    case gold = "Gold", red = "Red", blue = "Blue", purple = "Purple"
}

public struct PlayingCard: Sendable, Hashable, Codable {
    public var rank: Rank
    public var suit: Suit
    public var enhancement: Enhancement?
    public var edition: Edition?
    public var seal: Seal?
    public var debuffed: Bool
    /// Hiker and similar add permanent chips; `ability.perma_bonus`.
    public var bonusChips: Int
}

/// `facing == "back"` (The House, The Mark, The Fish, Amber Acorn on jokers) becomes `.faceDown`, with nothing inside.
public enum HandCard: Sendable, Hashable, Codable {
    case faceUp(PlayingCard)
    case faceDown
}

public struct Joker: Sendable, Hashable, Codable {
    public var key: CenterKey
    public var edition: Edition?
    public var stickers: Set<Sticker>
    public var sellValue: Int
    public var debuffed: Bool
    /// The joker's live `ability` numbers, flattened to dotted paths ("extra.Xmult" -> "2.5").
    /// Claude fills the description template's `#1#` from these; we don't reimplement `card.lua`.
    public var liveValues: [String: String]
}

public enum Sticker: String, Sendable, Hashable, Codable {
    case eternal, perishable, rental
}

public struct Consumable: Sendable, Hashable, Codable {
    public var key: CenterKey
    public var edition: Edition?
    public var sellValue: Int

    public init(key: CenterKey, edition: Edition? = nil, sellValue: Int = 0) { (self.key, self.edition, self.sellValue) = (key, edition, sellValue) }
}

public struct Shop: Sendable, Hashable, Codable {
    public var cards: [ShopItem]
    public var vouchers: [ShopItem]
    public var boosters: [ShopItem]
    public var rerollCost: Int
}

public struct ShopItem: Sendable, Hashable, Codable {
    public enum Card: Sendable, Hashable, Codable {
        case joker(Joker)
        case consumable(Consumable)
        case playingCard(PlayingCard)
        case voucher(CenterKey)
        case booster(BoosterPack)
    }
    public var card: Card
    public var cost: Int
}

/// What's left to draw, as counts. There is no API to ask for an order, on purpose.
public struct DeckComposition: Sendable, Hashable, Codable {
    public var cards: [PlayingCard: Int]
    public var total: Int { cards.values.reduce(0, +) }
}

public struct PokerHandLevel: Sendable, Hashable, Codable {
    public var name: String   // "Two Pair"; the game's own key, which is also its English name
    public var level: Int
    public var chips: Int
    public var mult: Int
    public var timesPlayed: Int
}

public struct Blind: Sendable, Hashable, Codable {
    public var key: CenterKey   // bl_small, bl_big, bl_mouth, ...
    public var target: Double
    public var isBoss: Bool
}

public struct BlindSelect: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        case select = "Select", upcoming = "Upcoming", current = "Current", defeated = "Defeated", skipped = "Skipped"
    }
    public var small: State
    public var big: State
    public var boss: State
    public var bossKey: CenterKey
    /// The tag each skippable blind offers, from `round_resets.blind_tags`.
    public var smallSkipTag: TagKey?
    public var bigSkipTag: TagKey?
}
