import BalabroCore
import Foundation
import Testing

@Suite
struct SaveFileTests {
    @Test func handInScreenOrder() throws {
        let s = try SaveFile.decode(Fixture.save("02-hand"), profile: 1)
        #expect(s.identity == RunIdentity(profile: 1, seed: "BALABRO1", deck: CenterKey(rawValue: "b_red"), stake: 1))
        #expect(s.phase == .selectingHand)
        #expect(s.hand.map(Self.short) == ["K♥", "K♣", "7♠", "6♥", "5♠", "3♠", "3♦", "2♦"])
        #expect((s.handsLeft, s.discardsLeft, s.dollars, s.ante) == (4, 4, 4, 1))
        #expect(s.blind?.target == 300)
        #expect(s.deck.total == 44)
    }

    @Test func openingBoosterFromShop() throws {
        let s = try SaveFile.decode(Fixture.save("07-pack-opening"), profile: 1)
        // 07-pack-open.png, taken right after this save, shows a Buffoon Pack.
        #expect(s.openingBooster?.kind == .buffoon)
        #expect(s.openingBooster?.key == CenterKey(rawValue: "p_buffoon_normal_2"))
    }

    @Test(arguments: [1, 3000, 6379])
    func halfWrittenFileIsIncomplete(bytesMissing: Int) {
        #expect(throws: SaveFileError.incomplete) { try SaveFile.decode(Fixture.save("02-hand").dropLast(bytesMissing), profile: 1) }
    }

    @Test func plainLuaTextIsAccepted() throws {
        // STR_PACK's own output shapes: shuffled indices, %q escapes, LuaJIT's `inf`.
        let lua = #"return {["STATE"]=1,["VERSION"]="1.0.1o-FULL",["x"]="a\"b",["n"]={[2]=inf,[1]=1e+15,},}"#
        #expect(throws: SaveFileError.unexpectedShape(path: "GAME")) { try SaveFile.decode(Data(lua.utf8), profile: 1) }
    }

    @Test(arguments: [
        "01-blind-select", "02-hand", "03-hand-after-discard", "04-round-eval", "05-shop", "06-shop-reroll",
        "07-pack-opening", "08-pack-closed", "09-blind-select", "10-hand", "11-round-eval", "12-shop",
    ])
    func everyDriverSaveDecodes(name: String) throws {
        let s = try SaveFile.decode(Fixture.save(name), profile: 2)
        #expect(s.identity.seed == "BALABRO1")
        #expect(s.identity.profile == 2)
    }

    @Test func deckIsWhatIsLeftToDraw() throws {
        let s = try SaveFile.decode(Fixture.save("02-hand"), profile: 1)
        func count(_ rank: Rank, _ suit: Suit) -> Int {
            s.deck.cards.filter { $0.key.rank == rank && $0.key.suit == suit }.values.reduce(0, +)
        }
        #expect(count(.king, .hearts) == 0)
        #expect(count(.ace, .spades) == 1)
    }

    @Test func pokerHandsWeakestFirstWithoutSecretHands() throws {
        let s = try SaveFile.decode(Fixture.save("02-hand"), profile: 1)
        #expect(s.pokerHands.map(\.name) == [
            "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind", "Straight Flush",
        ])
        let pair = s.pokerHands[1]
        #expect((pair.level, pair.chips, pair.mult, pair.timesPlayed) == (1, 10, 2, 0))
    }

    @Test func shopItemsAndPrices() throws {
        let shop = try #require(try SaveFile.decode(Fixture.save("05-shop"), profile: 1).shop)
        #expect(shop.cards.map(\.cost) == [3, 2])
        guard case .consumable(let empress) = shop.cards[0].card, case .joker(let joker) = shop.cards[1].card else {
            Issue.record("expected The Empress then Joker, got \(shop.cards)")
            return
        }
        #expect((empress.key.rawValue, joker.key.rawValue) == ("c_empress", "j_joker"))
        #expect(shop.vouchers.map(\.card) == [.voucher(CenterKey(rawValue: "v_grabber"))])
        #expect(shop.vouchers.map(\.cost) == [10])
        #expect(shop.boosters.map(\.cost) == [4, 4])
        #expect(shop.rerollCost == 5)
    }

    @Test func noShopOutsideTheShop() throws {
        #expect(try SaveFile.decode(Fixture.save("02-hand"), profile: 1).shop == nil)
    }

    @Test func ownedJokerKeepsTheNumbersItsTextNeeds() throws {
        let s = try SaveFile.decode(Fixture.save("08-pack-closed"), profile: 1)
        #expect(s.jokers.map(\.key.rawValue) == ["j_gluttenous_joker"])
        #expect(s.jokers[0].liveValues == ["extra.suit": "Clubs", "extra.s_mult": "3", "mult": "0", "x_mult": "1"])
        #expect(s.jokers[0].sellValue == 2)
    }

    @Test func missingKeyNamesItsPath() throws {
        let broken = Fixture.saveText("02-hand").replacingOccurrences(of: #"["hands_left"]=4,"#, with: "")
        #expect(throws: SaveFileError.unexpectedShape(path: "GAME.current_round.hands_left")) {
            try SaveFile.decode(Data(broken.utf8), profile: 1)
        }
    }

    @Test func blindSelectOffersTheSkipTags() throws {
        let s = try SaveFile.decode(Fixture.save("01-blind-select"), profile: 1)
        let b = s.blindSelect
        #expect((b.small, b.big, b.boss) == (.select, .upcoming, .upcoming))
        #expect(b.bossKey.rawValue == "bl_hook")
        #expect((b.smallSkipTag?.rawValue, b.bigSkipTag?.rawValue) == ("tag_handy", "tag_garbage"))
        #expect(s.blind == nil)
    }

    static func short(_ c: HandCard) -> String {
        guard case .faceUp(let p) = c else { return "?" }
        let rank = ["Jack": "J", "Queen": "Q", "King": "K", "Ace": "A"][p.rank.rawValue] ?? p.rank.rawValue
        return rank + String(p.suit.symbol)
    }
}
