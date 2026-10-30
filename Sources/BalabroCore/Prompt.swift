import Foundation

/// Everything Claude is told. Plain text, deterministic for a given snapshot (sorted keys, fixed order),
/// because `Decision.fingerprint` hashes it. Nothing goes in that changes without the decision changing.
enum Prompt {
    /// Passed with `--system-prompt` on every turn. Replaces Claude Code's coding prompt entirely.
    static let system = """
        You are a Balatro coach sitting beside the player. You see their run through the game's save file. \
        Each message is either the game state at a decision, or a question from the player.

        Answer in this exact shape. The player reads it at a glance between moves, so keep it short:

        **Do this now:**
        1. One concrete action per step, in the order the player does them.
        2. Name cards exactly as written in the state, such as "Discard 7♣ 4♣ 2♠" or "Buy Gluttonous Joker ($5)".

        **Why:**
        - At most four bullets, one line each, no nested bullets.
        - Show the score maths against the blind target, such as "Pair of Kings: (10 + 10 + 10) x 2 = 60".
        - Count outs when a draw matters, such as "9 Clubs left in 39 cards".
        - Say when joker order or card order changes the score.

        **Lesson N: short title**
        One or two sentences. Add a lesson only when there is a real one. Number lessons across the whole run, \
        starting at 1, and never repeat one you already gave.

        Rules:
        - Lead with the action. No preamble, no recap of the state, no closing summary.
        - At a blind select, the whole answer is one step and one bullet, unless the Boss Blind's rule or a skip tag \
        changes the plan.
        - Keep a running plan for the run (the hand type to build, the jokers to look for). Mention it only when it changes.
        - Joker text has placeholders like #1#. Fill them from the joker's live values in [brackets].
        - The deck is given as counts because the draw order is hidden. Face-down cards are hidden from the player \
        and from you. Never guess at either.
        - If a booster pack's cards are not in the screenshot, or there is no screenshot, ask the player to list them.
        - When the player asks a question, answer it directly in the same shape. If the answer changes what to do, \
        the steps come first.
        """

    static func decision(_ kind: Decision.Kind, _ s: RunSnapshot, _ text: GameText) -> String {
        var lines: [String] = []
        switch kind {
        case .playHand:
            lines.append("DECISION: play or discard")
            lines.append(roundLine(s, text))
            lines.append("Hand (left to right): " + s.hand.map(card).joined(separator: " "))
        case .shop:
            lines.append("DECISION: shop")
            lines.append("Ante \(s.ante). $\(s.dollars).")
            lines += shopLines(s, text)
            lines += blindsLines(s, text)
        case .blindSelect:
            lines.append("DECISION: play or skip the next blind")
            lines.append("Ante \(s.ante). $\(s.dollars).")
            lines += blindsLines(s, text)
        case .openPack(let pack, let source):
            lines.append("DECISION: pick from a \(packName(pack)) (\(pack.cardsShown) cards, choose \(pack.picks))")
            switch source {
            case .shop: lines.append("Bought in the shop. The cards are in the attached screenshot of the game.")
            case .skipTag(let tag):
                lines.append("Opened by the \(name(tag, text)) from skipping a blind. The cards are in the attached screenshot of the game.")
            }
            lines.append("Ante \(s.ante). $\(s.dollars).")
            if !s.hand.isEmpty { lines.append("Hand (left to right): " + s.hand.map(card).joined(separator: " ")) }
        }
        lines += jokerLines(s, text)
        lines.append("Consumables (\(s.consumables.count)/\(s.consumableSlots)): "
            + (s.consumables.isEmpty ? "none" : s.consumables.map { describe($0.key, edition: $0.edition, text) }.joined(separator: "; ")))
        if !s.tags.isEmpty { lines.append("Skip tags held: " + s.tags.map { name($0, text) }.joined(separator: ", ")) }
        if !s.vouchers.isEmpty { lines.append("Vouchers redeemed: " + s.vouchers.map { name($0, text) }.joined(separator: ", ")) }
        lines.append("Poker hands: " + s.pokerHands.map(pokerHand).joined(separator: ", "))
        lines.append(deckLine(s.deck))
        return lines.joined(separator: "\n")
    }

    static func question(_ q: String, packContentsUnknown: Bool) -> String {
        var text = "PLAYER QUESTION: \(q)"
        if packContentsUnknown { text += "\n" + screenshotMissing }
        return text
    }

    static let screenshotMissing = """
        The screenshot of the game could not be taken, so you can't see the screen. \
        If the answer depends on cards the state doesn't list, such as a booster pack's contents, ask the player to list them.
        """

    /// "Ante 3 · Big Blind · 3 hands, 2 discards". The overlay's headline and the transcript title.
    static func title(_ kind: Decision.Kind, _ s: RunSnapshot, _ text: GameText) -> String {
        let detail = switch kind {
        case .playHand: "\(s.blind.map { name($0.key, text) } ?? "Blind") · \(s.handsLeft) hands, \(s.discardsLeft) discards"
        case .shop: "Shop"
        case .blindSelect: "Blind select"
        case .openPack(let pack, _): packName(pack)
        }
        return "Ante \(s.ante) · \(detail)"
    }

    static func card(_ c: HandCard) -> String {
        guard case .faceUp(let p) = c else { return "face-down" }
        let details = cardDetails(p)
        return rank(p.rank) + String(p.suit.symbol) + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
    }

    private static func cardDetails(_ p: PlayingCard) -> [String] {
        var details: [String] = []
        if let e = p.edition { details.append(e.rawValue.capitalized) }
        if let e = p.enhancement { details.append(enhancementNames[e]!) }
        if let seal = p.seal { details.append("\(seal.rawValue) seal") }
        if p.bonusChips > 0 { details.append("+\(p.bonusChips) chips") }
        if p.debuffed { details.append("debuffed") }
        return details
    }

    private static let enhancementNames: [Enhancement: String] = [
        .bonus: "Bonus", .mult: "Mult", .wild: "Wild", .glass: "Glass", .steel: "Steel", .stone: "Stone", .gold: "Gold", .lucky: "Lucky",
    ]

    private static func rank(_ r: Rank) -> String {
        switch r {
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        case .ace: "A"
        default: r.rawValue
        }
    }

    private static func roundLine(_ s: RunSnapshot, _ text: GameText) -> String {
        guard let blind = s.blind else {
            return "Ante \(s.ante). Hands \(s.handsLeft), discards \(s.discardsLeft). $\(s.dollars)."
        }
        var line = "Ante \(s.ante), \(name(blind.key, text))"
        if blind.isBoss, let rule = text[blind.key]?.text, !rule.isEmpty { line += " (\(rule.joined(separator: " ")))" }
        line += ". Target \(chips(blind.target)), scored \(chips(s.chipsScored)). Hands \(s.handsLeft), discards \(s.discardsLeft). $\(s.dollars)."
        line += " Hand size \(s.handSize)."
        return line
    }

    private static func blindsLines(_ s: RunSnapshot, _ text: GameText) -> [String] {
        let b = s.blindSelect
        func skip(_ tag: TagKey?) -> String {
            guard let tag else { return "" }
            let reward = text[CenterKey(rawValue: tag.rawValue)]?.text.joined(separator: " ") ?? ""
            return ". Skip reward: \(name(tag, text))" + (reward.isEmpty ? "" : ", \(reward)")
        }
        let bossRule = text[b.bossKey]?.text.joined(separator: " ") ?? ""
        return [
            "Small Blind: \(b.small.rawValue)\(b.small == .select || b.small == .upcoming ? skip(b.smallSkipTag) : "")",
            "Big Blind: \(b.big.rawValue)\(b.big == .select || b.big == .upcoming ? skip(b.bigSkipTag) : "")",
            "Boss Blind: \(b.boss.rawValue). \(name(b.bossKey, text))" + (bossRule.isEmpty ? "" : ": \(bossRule)"),
        ]
    }

    private static func shopLines(_ s: RunSnapshot, _ text: GameText) -> [String] {
        guard let shop = s.shop else { return [] }
        var lines = ["Shop (reroll $\(shop.rerollCost)):"]
        for item in shop.cards + shop.vouchers + shop.boosters {
            let description: String = switch item.card {
            case .joker(let j): joker(j, text, kind: "joker", sellValue: false)
            case .consumable(let c): describe(c.key, edition: c.edition, text)
            case .playingCard(let p): card(.faceUp(p)) + " (playing card)"
            case .voucher(let key): describe(key, edition: nil, text, kind: "voucher")
            case .booster(let pack): "\(packName(pack)): \(pack.cardsShown) cards, choose \(pack.picks)"
            }
            lines.append("- $\(item.cost) \(description)")
        }
        return lines
    }

    private static func jokerLines(_ s: RunSnapshot, _ text: GameText) -> [String] {
        let header = "Jokers (left to right, \(s.jokers.count)/\(s.jokerSlots)):"
        return s.jokers.isEmpty ? [header + " none"] : [header] + s.jokers.map { "- " + joker($0, text) }
    }

    private static func joker(_ j: Joker, _ text: GameText, kind: String? = nil, sellValue: Bool = true) -> String {
        var tags: [String] = kind.map { [$0] } ?? []
        if let e = j.edition { tags.append(e.rawValue.capitalized) }
        tags += j.stickers.map(\.rawValue.capitalized).sorted()
        if j.debuffed { tags.append("debuffed") }
        var line = name(j.key, text) + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))")
        line += template(j.key, text)
        if !j.liveValues.isEmpty {
            line += " [" + j.liveValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "]"
        }
        return sellValue ? line + " Sells for $\(j.sellValue)." : line
    }

    private static func describe(_ key: CenterKey, edition: Edition?, _ text: GameText, kind: String? = nil) -> String {
        let tags = [kind, edition?.rawValue.capitalized].compactMap { $0 }
        return name(key, text) + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))") + template(key, text)
    }

    /// ": text." with the template's lines joined, or "" when the game text isn't loaded.
    private static func template(_ key: CenterKey, _ text: GameText) -> String {
        guard let lines = text[key]?.text, !lines.isEmpty else { return "" }
        let joined = lines.joined(separator: " ")
        return ": " + joined + (joined.last.map { ".!?)".contains($0) } == true ? "" : ".")
    }

    private static func pokerHand(_ h: PokerHandLevel) -> String {
        "\(h.name) L\(h.level) (\(h.chips) x \(h.mult)" + (h.timesPlayed > 0 ? ", played \(h.timesPlayed)" : "") + ")"
    }

    /// "Deck (44 left): ♠ A K Q J 10 9 8 4 2 | ♥ ...". Grouped by suit, highest rank first.
    private static func deckLine(_ deck: DeckComposition) -> String {
        let groups = Suit.allCases.compactMap { suit -> String? in
            let entries = deck.cards.filter { $0.key.suit == suit }
                .map { (order: Rank.allCases.firstIndex(of: $0.key.rank)!, text: deckEntry($0.key, count: $0.value)) }
                .sorted { ($1.order, $0.text) < ($0.order, $1.text) }
                .map(\.text)
            guard !entries.isEmpty else { return nil }
            return "\(suit.symbol) " + entries.joined(separator: " ")
        }
        return "Deck (\(deck.total) left): " + groups.joined(separator: " | ")
    }

    private static func deckEntry(_ p: PlayingCard, count: Int) -> String {
        let details = cardDetails(p)
        return rank(p.rank) + (details.isEmpty ? "" : "(\(details.joined(separator: ", ")))") + (count > 1 ? " x\(count)" : "")
    }

    static func packName(_ pack: BoosterPack) -> String {
        let kind = pack.kind.rawValue.capitalized
        let size = pack.key.rawValue.contains("_mega_") ? "Mega " : pack.key.rawValue.contains("_jumbo_") ? "Jumbo " : ""
        return "\(size)\(kind) Pack"
    }

    private static func name(_ key: CenterKey, _ text: GameText) -> String { text[key]?.name ?? key.rawValue }
    private static func name(_ tag: TagKey, _ text: GameText) -> String { name(CenterKey(rawValue: tag.rawValue), text) }

    /// Matches the game's `number_format` (`misc_functions.lua:956`), so a score reads the same as on screen.
    private static func chips(_ n: Double) -> String {
        guard n.isFinite else { return "infinite" }
        guard n >= 1e11 else { return Int(n).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
        let exponent = Int(log10(n).rounded(.down))
        return String(format: "%.3fe%d", n / pow(10, Double(exponent)), exponent)
    }
}
