import Foundation

/// Everything Claude is told. Plain text, deterministic for a given snapshot (sorted keys, fixed order),
/// because `Decision.fingerprint` hashes it. Nothing goes in that changes without the decision changing.
enum Prompt {
    /// Claude's reply when a pack's screenshot came too early. It's the check for "has the pack opened?",
    /// because the save can't say and the game's moving background means the app can't tell from the pixels.
    static let packNotReady = "PACK_NOT_READY"

    /// Passed with `--system-prompt` on every turn. Replaces Claude Code's coding prompt entirely.
    static let system = """
        You are a Balatro coach sitting beside the player. You see their run through the game's save file. \
        Each message is either the game state at a decision, or a question from the player.

        At a decision, answer in this exact shape. The player reads it at a glance between moves, so keep it short:

        **Do this now:**
        1. One concrete action per step, in the order the player does them.
        2. Name cards exactly as written in the state, such as "Discard 7♣ 4♣ 2♠" or "Buy Gluttonous Joker ($5)". \
        List them in the order they sit in the hand, left to right, because the player selects them that way.

        **Score:**
        - Two Pair: 46 x 2 = 92
        - Instead, Full House: 76 x 4 = 304

        **Goal:** At most eight words on what this is building towards, such as "Going for a Straight" or "Saving up for \
        a second joker". Leave the Goal out when the steps play a hand now, because the Score block already names it.

        **Why:**
        - At most four bullets, one line each, no nested bullets.
        - Show the score maths against the blind target, such as "Pair of Kings: (10 + 10 + 10) x 2 = 60".
        - Count outs when a draw matters, such as "9 Clubs left in 39 cards".

        **Lesson N: short title**
        One or two sentences. Add a lesson only when there is a real one. Number lessons across the whole run, \
        starting at 1, and never repeat one you already gave.

        Rules:
        - Steps say only what to do. Reasons go in Why, so "Play 7♦ 6♠ 6♣ 4♦." and not "Play 7♦ 6♠ 6♣ 4♦ so the pair scores".
        - At every play or discard decision, check the order of the player's jokers. Jokers score from left to right, \
        so +Mult should come before XMult, Blueprint copies the joker to its right and Brainstorm copies the leftmost. \
        Effects that say "when scored" fire with the cards, before any joker's own effect, so their position doesn't \
        matter. If another order scores more or stops a joker being wasted, make moving it the first step, such as "Drag Joker \
        to the left of Cavendish", and give the Score block for the new order. Say nothing about order when it makes \
        no difference.
        - When the steps buy a joker, say where to drag it if its place matters. When the player owns an XMult joker and \
        the order is already right, say so in one Why bullet.
        - Cards score from left to right too. When the order of the played cards changes the score, such as with \
        Photograph or Hanging Chad, say the order in the step.
        - If the player holds a consumable that helps this decision, say when to use it in the steps.
        - Include the Score block at every play or discard decision, even when the steps only discard. Give one line \
        for the hand the steps play or aim for, written as "Full House, if you draw it" when it needs a draw. Then add \
        one line for the hand the player would most likely play instead, starting "Instead,", even if it's a bigger \
        kind of hand, so they can compare the two. Write each line as "hand: chips x mult = total", with chips and mult \
        after every card and joker that scores, always with "=" even when the numbers are rounded. Name the hand exactly, \
        such as "Diamond Flush" or "Pair of 9s". Leave the block out in the shop, in a pack and at a blind select.
        - End the steps at the first discard, play, reroll or pack opening, because that changes the board and you get the new state \
        straight away. Your next answer replaces these steps, so anything after that point would vanish. Put what \
        comes after in the Goal instead. Dragging jokers and buying cards don't change the board, so they can come \
        before it.
        - Lead with the action. No preamble, no recap of the state, no closing summary.
        - At a blind select, the whole answer is one step, the Goal and one bullet, unless the Boss Blind's rule or a skip tag \
        changes the plan.
        - Keep a running plan for the run (the hand type to build, the jokers to look for). Mention it only when it changes.
        - Joker text has placeholders like #1#. Fill them from the joker's live values in [brackets].
        - The state already includes everything the game shows on hover, such as this round's rank for Mail-In Rebate. \
        Never tell the player to hover over or check something. If you truly can't tell, give the step for each case.
        - The deck is given as counts because the draw order is hidden. Face-down cards are hidden from the player \
        and from you. Never guess at either.
        - Jokers and vouchers have no name printed on them, and the game hides the name and text of any the player \
        hasn't discovered yet. So whenever you name a joker or voucher in the shop or in an open pack, and there's more \
        than one card in its row, say where it is, such as "Buy the left joker, Crafty Joker ($4)". For the player's own \
        jokers, count from the left too. Tarot, Planet and Spectral cards and packs have their names printed on them, \
        and playing cards show their rank and suit, so just name those, such as "Take Mercury". Give their position only \
        when two in the row are the same.
        - The shop's save is written just before held tags take effect, so a tag still listed in the shop is about to \
        apply, and the prices shown are from before it. The Foil, Holographic, Polychrome and Negative Tags turn the \
        leftmost joker without an edition into that edition and make it free, or stay held if there's no such joker. \
        The Coupon Tag makes the shop's first cards and packs free. The D6 Tag starts rerolls at $0. Treat these as \
        already done.
        - You can see the game only through the state, plus a screenshot when an open pack needs one or the player \
        attaches one. Never tell the player to look at, check or confirm anything on screen.
        - You get the new game state automatically after every move, so never ask the player to send or show you the \
        new hand.
        - Tarot, Planet and Spectral cards in an open pack can only be used on the spot or skipped. They can't be kept \
        for later, so never tell the player to take one into a consumable slot. Only cards bought in the shop go there. \
        A joker from a pack needs a free joker slot.
        - When you suggest buying a pack, don't ask what's inside. You get a screenshot of its cards as soon as the \
        player opens it.
        - A screenshot can be taken before a pack finishes opening. If a pack decision's screenshot doesn't show every \
        one of the pack's cards whole, because they haven't appeared or are still dissolving into view, reply with exactly \
        \(packNotReady) and nothing else, even if you can read some of them. You'll get a new screenshot.
        - If there's no screenshot, ask the player to list the pack's cards.
        - When the player asks a question, they read your reply under the steps you already gave. Answer it directly \
        in one to three short sentences of plain text, with no heading, no Why and no lesson. Don't repeat the steps.
        - Only if your answer changes what the player should do, follow it with a **Do this now:** block with the \
        complete new steps, then a **Score:** block at a play or discard decision, then a **Goal:** line and a **Why:** block. These replace the steps on screen.
        """

    /// The CLI keeps a conversation's first system prompt and ignores `--system-prompt` on `--resume`,
    /// so a run started on an older version only learns new rules from a message.
    static let rulesChanged = """
        THE COACHING RULES HAVE CHANGED. These replace all your earlier instructions, including the answer format. \
        Follow them from now on, even where your earlier answers in this conversation look different:

        \(system)


        """

    static let rulesVersion = Fingerprint.of(system)

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
            + (s.consumables.isEmpty ? "none" : s.consumables.map { describe($0.key, edition: $0.edition, s, text) }.joined(separator: "; ")))
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

    /// Boss Blinds can't be skipped, so once it's the only blind left there's one move, unless the player
    /// can reroll the Boss or has Luchador to sell.
    static func onlyBossLeft(_ s: RunSnapshot, _ text: GameText) -> String? {
        let canChange = ["v_directors_cut", "v_retcon"].contains { s.vouchers.contains(CenterKey(rawValue: $0)) }
            || s.jokers.contains { $0.key.rawValue == "j_luchador" }
        // Not `boss == .select`: the game saves first and only then marks the next blind as selectable.
        let done: [BlindSelect.State] = [.defeated, .skipped]
        guard done.contains(s.blindSelect.small), done.contains(s.blindSelect.big), !done.contains(s.blindSelect.boss), !canChange else { return nil }
        let rule = text[s.blindSelect.bossKey]?.text.joined(separator: " ") ?? ""
        return """
            **Do this now:**
            1. Select the Boss Blind, \(name(s.blindSelect.bossKey, text)).

            **Goal:** Beat the Boss Blind

            **Why:**
            - It's the only blind left, and Boss Blinds can't be skipped.
            \(rule.isEmpty ? "" : "- \(rule).")
            """
    }

    static let refresh = """
        THE PLAYER PRESSED REFRESH because the steps on screen look wrong or out of date. Look at the attached screenshot \
        and answer in the usual shape for what's on screen now. Where the screenshot and any state above disagree, trust \
        the screenshot, because the save can lag behind the game. If a pack's cards aren't all whole yet, reply with exactly \
        \(packNotReady) and nothing else.
        """

    static let screenshotMissing = """
        The screenshot of the game could not be taken, so you can't see the screen. \
        If the answer depends on cards the state doesn't list, such as a booster pack's contents, ask the player to list them.
        """

    /// "Ante 3 · Big Blind". The overlay's headline and the transcript title.
    static func title(_ kind: Decision.Kind, _ s: RunSnapshot, _ text: GameText) -> String {
        let detail = switch kind {
        case .playHand: s.blind.map { name($0.key, text) } ?? "Blind"
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
        for (row, items) in [("Cards", shop.cards), ("Vouchers", shop.vouchers), ("Packs", shop.boosters)] where !items.isEmpty {
            lines.append("\(row) (left to right):")
            for item in items {
                let description: String = switch item.card {
                case .joker(let j): joker(j, s, text, kind: "joker", sellValue: false)
                case .consumable(let c): describe(c.key, edition: c.edition, s, text)
                case .playingCard(let p): card(.faceUp(p)) + " (playing card)"
                case .voucher(let key): describe(key, edition: nil, s, text, kind: "voucher")
                case .booster(let pack): "\(packName(pack)): \(pack.cardsShown) cards, choose \(pack.picks)"
                }
                lines.append("- $\(item.cost) \(description)")
            }
        }
        return lines
    }

    private static func jokerLines(_ s: RunSnapshot, _ text: GameText) -> [String] {
        let header = "Jokers (left to right, \(s.jokers.count)/\(s.jokerSlots)):"
        return s.jokers.isEmpty ? [header + " none"] : [header] + s.jokers.map { "- " + joker($0, s, text) }
    }

    private static func joker(_ j: Joker, _ s: RunSnapshot, _ text: GameText, kind: String? = nil, sellValue: Bool = true) -> String {
        var tags: [String] = kind.map { [$0] } ?? []
        if let e = j.edition { tags.append(e.rawValue.capitalized) }
        tags += j.stickers.map(\.rawValue.capitalized).sorted()
        if j.debuffed { tags.append("debuffed") }
        var line = name(j.key, text) + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))")
        line += template(j.key, text)
        if !j.liveValues.isEmpty {
            line += " [" + j.liveValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "]"
        }
        line += hoverOnly(j.key, s, text)
        return sellValue ? line + " Sells for $\(j.sellValue)." : line
    }

    private static func describe(_ key: CenterKey, edition: Edition?, _ s: RunSnapshot, _ text: GameText, kind: String? = nil) -> String {
        let tags = [kind, edition?.rawValue.capitalized].compactMap { $0 }
        return name(key, text) + (tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))") + template(key, text) + hoverOnly(key, s, text)
    }

    /// Facts the game shows in a card's tooltip but keeps outside the card.
    private static func hoverOnly(_ key: CenterKey, _ s: RunSnapshot, _ text: GameText) -> String {
        let targets = s.roundTargets
        func fact(_ label: String, _ value: String?) -> String { value.map { " \(label): \($0)." } ?? "" }
        return switch key.rawValue {
        case "j_mail": fact("This round's rank", targets.mailRank?.rawValue)
        case "j_idol":
            fact("This round's card", targets.idolRank.flatMap { rank in targets.idolSuit.map { "\(rank.rawValue) of \($0.rawValue)" } })
        case "j_ancient": fact("This round's suit", targets.ancientSuit?.rawValue)
        case "j_castle": fact("This round's suit", targets.castleSuit?.rawValue)
        case "j_fortune_teller": fact("Tarot cards used this run", String(s.tarotsUsed))
        case "c_fool": fact("Would copy", s.lastTarotOrPlanet.map { name($0, text) } ?? "nothing yet")
        default: ""
        }
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
    static func chips(_ n: Double) -> String {
        guard n.isFinite else { return "infinite" }
        guard n >= 1e11 else { return Int(n).formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
        let exponent = Int(log10(n).rounded(.down))
        return String(format: "%.3fe%d", n / pow(10, Double(exponent)), exponent)
    }
}
