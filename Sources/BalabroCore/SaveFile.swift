import Foundation

/// The one boundary where Balatro's bytes become typed values.
///
/// Raw Lua never leaves this file and `LuaLiteral.swift`. Everything past `decode` sees `RunSnapshot`.
public enum SaveFile {
    /// Decodes `save.jkr` bytes. Accepts the raw DEFLATE the game writes and the plain
    /// `return {...}` text it also accepts on load (`get_compressed`), so tests can pass literals.
    ///
    /// Throws `.incomplete` for a file the game's save thread is still writing. That is normal;
    /// the caller retries. Every other error means the format isn't what we expect.
    public static func decode(_ bytes: Data, profile: Int) throws(SaveFileError) -> RunSnapshot {
        try RunSnapshot(lua: LuaLiteral.parse(text(of: bytes)), profile: profile)
    }

    /// Decodes `profile.jkr`, where the game keeps its all-time totals.
    public static func decodeCareer(_ bytes: Data) throws(SaveFileError) -> CareerStats {
        try CareerStats(lua: LuaLiteral.parse(text(of: bytes)))
    }

    /// `meta` is nil if the file couldn't be read.
    public static func decodeProgress(profile: Data, meta: Data?) throws(SaveFileError) -> PlayerProgress {
        let metaValue = meta.flatMap { try? LuaLiteral.parse(text(of: $0)) }
        return PlayerProgress(profile: try LuaLiteral.parse(text(of: profile)), meta: metaValue)
    }

    private static func text(of bytes: Data) throws(SaveFileError) -> String {
        bytes.starts(with: Data("return".utf8)) ? String(decoding: bytes, as: UTF8.self) : try inflateRaw(bytes)
    }
}

public enum SaveFileError: Error, Sendable, Hashable {
    /// Truncated DEFLATE stream or Lua text that ends mid-table. Retry shortly.
    case incomplete
    /// The file parsed but a key we rely on is missing or the wrong type. `path` is like `GAME.round_resets.ante`.
    case unexpectedShape(path: String)
    case notLua(offset: Int)
}

/// `.zlib` in Apple's Compression framework is raw DEFLATE (RFC 1951) with no zlib header,
/// which is exactly what LÖVE's `love.data.compress('string', 'deflate', ...)` writes.
func inflateRaw(_ bytes: Data) throws(SaveFileError) -> String {
    do {
        return String(decoding: try (bytes as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)
    } catch {
        throw .incomplete
    }
}

/// A Lua value plus the path it was read from, so a missing key names itself in the error.
private struct Node {
    let value: LuaValue
    let path: String

    func child(_ key: String) -> Node? {
        guard case .table(let t) = value, let v = t[key] else { return nil }
        return Node(value: v, path: path.isEmpty ? key : "\(path).\(key)")
    }

    func require(_ key: String) throws(SaveFileError) -> Node {
        guard let node = child(key) else { throw .unexpectedShape(path: path.isEmpty ? key : "\(path).\(key)") }
        return node
    }

    var table: LuaTable? { if case .table(let t) = value { t } else { nil } }
    var string: String? { if case .string(let s) = value { s } else { nil } }
    var number: Double? { if case .number(let n) = value { n } else { nil } }
    var bool: Bool? { if case .bool(let b) = value { b } else { nil } }

    func int(_ key: String) throws(SaveFileError) -> Int {
        let node = try require(key)
        guard let n = node.number, n.isFinite else { throw .unexpectedShape(path: node.path) }
        return Int(n)
    }

    func double(_ key: String) throws(SaveFileError) -> Double {
        let node = try require(key)
        guard let n = node.number else { throw .unexpectedShape(path: node.path) }
        return n
    }

    func string(_ key: String) throws(SaveFileError) -> String {
        let node = try require(key)
        guard let s = node.string else { throw .unexpectedShape(path: node.path) }
        return s
    }

    /// `ipairs` order, each element with its own path.
    var elements: [Node] {
        (table?.array ?? []).enumerated().map { Node(value: $1, path: "\(path)[\($0 + 1)]") }
    }
}

extension PlayerProgress {
    /// Lenient, like `CareerStats`: a missing `meta.jkr` only leaves out decks that haven't been played yet.
    init(profile: LuaValue, meta: LuaValue?) {
        let root = Node(value: profile, path: "")
        let usage = root.child("deck_usage")
        let unlocked = meta.flatMap { Node(value: $0, path: "").child("unlocked")?.table?.named } ?? [:]
        let everything = root.child("all_unlocked")?.bool == true
        var decks: [Deck] = []
        var locked: [CenterKey] = []
        for (key, _) in Self.allDecks {
            let played = usage?.child(key.rawValue)
            guard everything || key.rawValue == "b_red" || played != nil || unlocked[key.rawValue] == .bool(true) else {
                locked.append(key)
                continue
            }
            func tally(_ name: String) -> [Int: Double] {
                (played?.child(name)?.table?.indexed ?? [:]).compactMapValues { if case .number(let n) = $0 { n } else { nil } }
            }
            let wins = tally("wins")
            let highestWin = wins.filter { $0.value > 0 }.keys.max() ?? 0
            decks.append(Deck(
                key: key, highestWin: highestWin,
                // A win also counts on every lower stake (`set_deck_win`), so only the highest stake's count is real.
                wins: Int(wins[highestWin] ?? 0), losses: Int(tally("losses").values.reduce(0, +)),
                highestStart: everything ? Self.stakes.count : min(highestWin + 1, Self.stakes.count)))
        }
        (career, self.decks, self.locked) = (CareerStats(lua: profile), decks, locked)
    }
}

extension CareerStats {
    /// Lenient throughout: a missing total reads as 0, because no decision depends on it.
    init(lua root: LuaValue) {
        let root = Node(value: root, path: "")
        let career = root.child("career_stats")
        let best = root.child("high_scores")
        func total(_ key: String) -> Int { career?.child(key)?.number.map { Int($0) } ?? 0 }
        func high(_ key: String) -> Double { best?.child(key)?.child("amt")?.number ?? 0 }
        func usage(_ key: String, name: (String, Node) -> String) -> [Count] {
            guard let table = root.child(key)?.table else { return [] }
            return table.named.keys.compactMap { key2 -> Count? in
                guard let node = root.child(key)?.child(key2), let count = node.child("count")?.number else { return nil }
                return Count(name: name(key2, node), count: Int(count))
            }
            .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        }
        wins = total("c_wins")
        losses = total("c_losses")
        rounds = total("c_rounds")
        handsPlayed = total("c_hands_played")
        bestHand = high("hand")
        mostMoney = Int(high("most_money"))
        furthestAnte = Int(high("furthest_ante"))
        furthestRound = Int(high("furthest_round"))
        hands = usage("hand_usage") { _, node in node.child("order")?.string ?? "" }.filter { !$0.name.isEmpty && $0.count > 0 }
        jokers = usage("joker_usage") { key, _ in key }.filter { $0.count > 0 }
    }
}

extension RunSnapshot {
    /// Maps the top-level save table (`cardAreas`, `tags`, `GAME`, `STATE`, `ACTION`, `BLIND`, `BACK`, `VERSION`).
    ///
    /// Strict on keys that define a decision (STATE, hand, jokers, dollars), lenient on everything else:
    /// an unknown edition or seal string maps to nil instead of failing the whole snapshot.
    init(lua root: LuaValue, profile: Int) throws(SaveFileError) {
        let root = Node(value: root, path: "")
        let state = try root.int("STATE")
        let game = try root.require("GAME")
        let areas = try root.require("cardAreas")
        let resets = try game.require("round_resets")
        let current = try game.require("current_round")
        let scores = try game.require("round_scores")

        identity = RunIdentity(
            profile: profile,
            seed: try game.require("pseudorandom").string("seed"),
            deck: CenterKey(rawValue: try game.require("selected_back_key").string("key")),
            stake: try game.int("stake"))
        progress = ProgressClock(
            round: try game.int("round"),
            handsPlayed: try game.int("hands_played"),
            cardsDiscarded: (try? scores.require("cards_discarded").int("amt")) ?? 0,
            rerolls: (try? scores.require("times_rerolled").int("amt")) ?? 0,
            purchases: (try? scores.require("cards_purchased").int("amt")) ?? 0)
        phase = Phase(state: state)
        gameVersion = root.child("VERSION")?.string ?? ""

        dollars = try game.int("dollars")
        ante = try resets.int("ante")
        round = try game.int("round")
        handsLeft = try current.int("hands_left")
        discardsLeft = try current.int("discards_left")
        chipsScored = try game.double("chips")
        won = game.child("won")?.bool ?? false
        bestHandScore = scores.child("hand")?.child("amt")?.number ?? 0
        blind = try Self.blind(root.child("BLIND"))
        blindSelect = try Self.blindSelect(resets)

        let handArea = try areas.require("hand")
        hand = try handArea.require("cards").elements.map { node throws(SaveFileError) in
            node.child("facing")?.string == "back" ? .faceDown : .faceUp(try Self.playingCard(node))
        }
        handSize = try handArea.require("config").int("card_limit")

        let jokerArea = try areas.require("jokers")
        jokers = try jokerArea.require("cards").elements.map(Self.joker)
        jokerSlots = try jokerArea.require("config").int("card_limit")

        let consumableArea = try areas.require("consumeables")
        consumables = try consumableArea.require("cards").elements.map(Self.consumable)
        consumableSlots = try consumableArea.require("config").int("card_limit")

        var deckCounts: [PlayingCard: Int] = [:]
        for node in try areas.require("deck").require("cards").elements {
            deckCounts[try Self.playingCard(node), default: 0] += 1
        }
        deck = DeckComposition(cards: deckCounts)

        let boosterNodes = areas.child("shop_booster")?.child("cards")?.elements ?? []
        if let shopJokers = areas.child("shop_jokers") {
            shop = Shop(
                cards: try shopJokers.require("cards").elements.map(Self.shopItem),
                vouchers: try (areas.child("shop_vouchers")?.child("cards")?.elements ?? []).map(Self.shopItem),
                boosters: try boosterNodes.map(Self.shopItem),
                rerollCost: try current.int("reroll_cost"))
        } else {
            shop = nil
        }

        openingBooster = nil
        if let action = root.child("ACTION"), action.child("type")?.string == "use_card",
           let sortID = action.child("card")?.number,
           let node = boosterNodes.first(where: { $0.child("sort_id")?.number == sortID }) {
            openingBooster = try Self.booster(node)
        }

        pokerHands = try Self.pokerHands(try game.require("hands"))
        tags = root.child("tags")?.elements.compactMap { $0.child("key")?.string.map(TagKey.init) } ?? []
        vouchers = (game.child("used_vouchers")?.table?.named.filter { $0.value == .bool(true) }.keys.sorted() ?? [])
            .map(CenterKey.init)
        lastTarotOrPlanet = game.child("last_tarot_planet")?.string.map(CenterKey.init)
        tarotsUsed = game.child("consumeable_usage_total")?.child("tarot")?.number.map { Int($0) } ?? 0
        func rank(_ card: String) -> Rank? { current.child(card)?.child("rank")?.string.flatMap(Rank.init) }
        func suit(_ card: String) -> Suit? { current.child(card)?.child("suit")?.string.flatMap(Suit.init) }
        roundTargets = RoundTargets(
            mailRank: rank("mail_card"), idolRank: rank("idol_card"), idolSuit: suit("idol_card"),
            ancientSuit: suit("ancient_card"), castleSuit: suit("castle_card"))
    }

    private static func blind(_ node: Node?) throws(SaveFileError) -> Blind? {
        guard let node, let key = node.child("config_blind")?.string, !key.isEmpty else { return nil }
        return Blind(key: CenterKey(rawValue: key), target: try node.double("chips"), isBoss: node.child("boss")?.bool ?? false)
    }

    private static func blindSelect(_ resets: Node) throws(SaveFileError) -> BlindSelect {
        let states = try resets.require("blind_states")
        func state(_ key: String) throws(SaveFileError) -> BlindSelect.State {
            let node = try states.require(key)
            guard let s = node.string.flatMap(BlindSelect.State.init) else { throw .unexpectedShape(path: node.path) }
            return s
        }
        let tags = resets.child("blind_tags")
        return BlindSelect(
            small: try state("Small"), big: try state("Big"), boss: try state("Boss"),
            bossKey: CenterKey(rawValue: try resets.require("blind_choices").string("Boss")),
            smallSkipTag: tags?.child("Small")?.string.map(TagKey.init),
            bigSkipTag: tags?.child("Big")?.string.map(TagKey.init))
    }

    private static func playingCard(_ node: Node) throws(SaveFileError) -> PlayingCard {
        let base = try node.require("base")
        let suitNode = try base.require("suit"), valueNode = try base.require("value")
        guard let suit = suitNode.string.flatMap(Suit.init) else { throw .unexpectedShape(path: suitNode.path) }
        guard let rank = valueNode.string.flatMap(Rank.init) else { throw .unexpectedShape(path: valueNode.path) }
        let center = node.child("save_fields")?.child("center")?.string ?? "c_base"
        return PlayingCard(
            rank: rank, suit: suit,
            enhancement: Enhancement(rawValue: center),
            edition: edition(node),
            seal: node.child("seal")?.string.flatMap(Seal.init),
            debuffed: node.child("debuff")?.bool ?? false,
            bonusChips: Int(node.child("ability")?.child("perma_bonus")?.number ?? 0))
    }

    private static func edition(_ node: Node) -> Edition? {
        node.child("edition")?.child("type")?.string.flatMap(Edition.init)
    }

    private static func centerKey(_ node: Node) throws(SaveFileError) -> CenterKey {
        CenterKey(rawValue: try node.require("save_fields").string("center"))
    }

    private static func joker(_ node: Node) throws(SaveFileError) -> Joker {
        let ability = node.child("ability")
        return Joker(
            key: try centerKey(node),
            edition: edition(node),
            stickers: Set([Sticker.eternal, .perishable, .rental].filter { ability?.child($0.rawValue)?.bool == true }),
            sellValue: Int(node.child("sell_cost")?.number ?? 0),
            debuffed: node.child("debuff")?.bool ?? false,
            liveValues: ability?.table.map { liveValues($0) } ?? [:])
    }

    private static let bookkeepingAbilityKeys: Set<String> = [
        "name", "set", "effect", "type", "order", "hands_played_at_create", "eternal", "perishable", "rental",
    ]

    /// Every card carries ~15 zeroed fields (`h_mult=0`, `t_chips=0`) that would bury the one or two numbers
    /// the joker's text refers to, so top-level zeros are dropped. `mult` and `x_mult` stay even at their
    /// starting values, because scaling jokers (Ride the Bus, Hologram) report "Currently" from them.
    private static func liveValues(_ ability: LuaTable) -> [String: String] {
        let alwaysKept: Set<String> = ["mult", "x_mult"]
        var out: [String: String] = [:]
        func add(_ value: LuaValue, at path: String, depth: Int) {
            switch value {
            case .number(let n) where depth > 0 || n != 0 || alwaysKept.contains(path): out[path] = format(n)
            case .string(let s) where !s.isEmpty: out[path] = s
            case .bool(let b) where b: out[path] = "true"
            case .table(let t) where depth == 0:
                for (k, v) in t.named { add(v, at: "\(path).\(k)", depth: 1) }
                for (i, v) in t.indexed { add(v, at: "\(path).\(i)", depth: 1) }
            default: break
            }
        }
        for (key, value) in ability.named where !bookkeepingAbilityKeys.contains(key) {
            add(value, at: key, depth: 0)
        }
        return out
    }

    private static func format(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    private static func consumable(_ node: Node) throws(SaveFileError) -> Consumable {
        Consumable(key: try centerKey(node), edition: edition(node), sellValue: Int(node.child("sell_cost")?.number ?? 0))
    }

    private static func booster(_ node: Node) throws(SaveFileError) -> BoosterPack {
        let key = try centerKey(node)
        guard let kind = PackKind(boosterKey: key) else { throw .unexpectedShape(path: "\(node.path).save_fields.center") }
        return BoosterPack(
            key: key, kind: kind,
            cardsShown: Int(node.child("ability")?.child("extra")?.number ?? 0),
            picks: key.rawValue.contains("_mega_") ? 2 : 1)
    }

    private static func shopItem(_ node: Node) throws(SaveFileError) -> ShopItem {
        let set = node.child("ability")?.child("set")?.string
        let card: ShopItem.Card = switch set {
        case "Joker": .joker(try joker(node))
        case "Voucher": .voucher(try centerKey(node))
        case "Booster": .booster(try booster(node))
        case "Default", "Enhanced": .playingCard(try playingCard(node))
        default: .consumable(try consumable(node))
        }
        return ShopItem(card: card, cost: try node.int("cost"))
    }

    private static func pokerHands(_ hands: Node) throws(SaveFileError) -> [PokerHandLevel] {
        guard let table = hands.table else { throw .unexpectedShape(path: hands.path) }
        var ordered: [(order: Int, hand: PokerHandLevel)] = []
        for name in table.named.keys {
            let hand = try hands.require(name)
            guard hand.child("visible")?.bool != false else { continue }
            let level = PokerHandLevel(
                name: name, level: try hand.int("level"), chips: try hand.int("chips"),
                mult: try hand.int("mult"), timesPlayed: try hand.int("played"))
            ordered.append((try hand.int("order"), level))
        }
        return ordered.sorted { $0.order > $1.order }.map(\.hand)
    }
}

extension PackKind {
    /// `p_arcana_normal_1` -> `.arcana`.
    init?(boosterKey: CenterKey) {
        let parts = boosterKey.rawValue.split(separator: "_")
        guard parts.count >= 2, parts[0] == "p", let kind = PackKind(rawValue: String(parts[1])) else { return nil }
        self = kind
    }
}
