import BalabroCore
import Foundation
import Testing

@Suite
struct DecisionTests {
    func decision(_ name: String) throws -> Decision? {
        Decision.detect(in: try SaveFile.decode(Fixture.save(name), profile: 1), text: .missing)
    }

    @Test(arguments: [
        ("01-blind-select", "blindSelect"), ("02-hand", "playHand"), ("03-hand-after-discard", "playHand"),
        ("04-round-eval", "none"), ("05-shop", "shop"), ("06-shop-reroll", "shop"),
        ("07-pack-opening", "openPack"), ("08-pack-closed", "shop"), ("09-blind-select", "blindSelect"),
        ("10-hand", "playHand"), ("11-round-eval", "none"), ("12-shop", "shop"),
    ])
    func kindOfEachSave(name: String, expected: String) throws {
        let kind: String = switch try decision(name)?.kind {
        case nil: "none"
        case .playHand: "playHand"
        case .shop: "shop"
        case .blindSelect: "blindSelect"
        case .openPack: "openPack"
        }
        #expect(kind == expected)
    }

    @Test func discardMakesANewDecision() throws {
        #expect(try decision("02-hand")?.fingerprint != decision("03-hand-after-discard")?.fingerprint)
    }

    @Test func rereadingTheSameSaveIsTheSameDecision() throws {
        #expect(try decision("05-shop")?.fingerprint == decision("05-shop")?.fingerprint)
    }

    @Test func packFromShopNeedsAScreenshot() throws {
        let d = try #require(try decision("07-pack-opening"))
        #expect(d.needsScreenshot)
        guard case .openPack(let pack, from: .shop) = d.kind else {
            Issue.record("expected a shop pack, got \(d.kind)")
            return
        }
        #expect(pack.key.rawValue == "p_buffoon_normal_2")
        #expect((pack.cardsShown, pack.picks) == (2, 1))
    }

    @Test func handPromptNamesTheCardsOnScreen() throws {
        let prompt = try #require(try decision("02-hand")?.prompt)
        #expect(prompt.contains("Hand (left to right): K♥ K♣ 7♠ 6♥ 5♠ 3♠ 3♦ 2♦"))
        #expect(prompt.contains("Target 300, scored 0. Hands 4, discards 4. $4."))
    }

    @Test func handTitle() throws {
        #expect(try decision("03-hand-after-discard")?.title == "Ante 1 · bl_small · 4 hands, 3 discards")
    }

    func blindSelect(holding tags: [String]) throws -> Decision? {
        Decision.detect(in: try SaveFile.decode(Fixture.save("01-blind-select", holdingTags: tags), profile: 1), text: .missing)
    }

    @Test func packTagOpensAPackAtBlindSelect() throws {
        let d = try #require(try blindSelect(holding: ["tag_buffoon"]))
        #expect(d.needsScreenshot)
        guard case .openPack(let pack, from: .skipTag(let tag)) = d.kind else {
            Issue.record("expected a pack from a tag, got \(d.kind)")
            return
        }
        #expect((tag.rawValue, pack.key.rawValue, pack.cardsShown, pack.picks) == ("tag_buffoon", "p_buffoon_mega_1", 4, 2))
    }

    @Test func olderBossTagFiresBeforeAPackTag() throws {
        #expect(try blindSelect(holding: ["tag_boss", "tag_buffoon"])?.kind == .blindSelect)
    }

    /// What the game writes when a pack closes and the next held tag opens another: the new pack's state, with its tag gone.
    func nextTagPack(state: Int) -> Data {
        Data(Fixture.saveText("01-blind-select").replacingOccurrences(of: #"["STATE"]=7"#, with: #"["STATE"]=\#(state)"#).utf8)
    }

    @Test func aPackOpenedByTheNextTagIsADecision() throws {
        let d = try #require(Decision.detect(in: try SaveFile.decode(nextTagPack(state: 10), profile: 1), text: .missing))
        guard case .openPack(let pack, from: .skipTag(let tag)) = d.kind else {
            Issue.record("expected a pack from a tag, got \(d.kind)")
            return
        }
        #expect((tag.rawValue, pack.key.rawValue, pack.cardsShown, pack.picks) == ("tag_meteor", "p_celestial_mega_1", 5, 2))
        #expect(d.needsScreenshot)
    }

    @Test func tagsThatDontFireOnABlindChoiceAreSkippedOver() throws {
        #expect(try blindSelect(holding: ["tag_handy", "tag_charm"])?.needsScreenshot == true)
    }

    @Test func shopPromptListsEachRowLeftToRight() throws {
        let prompt = try #require(try decision("05-shop")?.prompt)
        #expect(prompt.contains("Packs (left to right):\n- $4 Buffoon Pack: 2 cards, choose 1\n- $4 Arcana Pack: 3 cards, choose 1"))
        #expect(prompt.contains("Cards (left to right):\n- $3 "))
        #expect(prompt.contains("Vouchers (left to right):\n- $10 "))
    }

    func prompt(_ save: String, owning joker: String) throws -> String {
        var snapshot = try SaveFile.decode(Fixture.save(save), profile: 1)
        snapshot.jokers[0].key = CenterKey(rawValue: joker)
        return try #require(Decision.detect(in: snapshot, text: .missing)?.prompt)
    }

    @Test(arguments: [
        ("j_mail", "This round's rank: Ace."),
        ("j_idol", "This round's card: 2 of Diamonds."),
        ("j_ancient", "This round's suit: Hearts."),
        ("j_castle", "This round's suit: Diamonds."),
        ("j_fortune_teller", "Tarot cards used this run: 0."),
    ])
    func promptGivesWhatTheGameOnlyShowsOnHover(joker: String, fact: String) throws {
        #expect(try prompt("10-hand", owning: joker).contains(fact))
    }

    @Test func otherJokersGetNoRoundFact() throws {
        #expect(try !prompt("10-hand", owning: "j_joker").contains("This round's"))
    }

    @Test func theFoolSaysWhatItWouldCopy() throws {
        var snapshot = try SaveFile.decode(Fixture.save("10-hand"), profile: 1)
        snapshot.consumables = [Consumable(key: CenterKey(rawValue: "c_fool"))]
        #expect(try #require(Decision.detect(in: snapshot, text: .missing)?.prompt).contains("Would copy: nothing yet."))
        snapshot.lastTarotOrPlanet = CenterKey(rawValue: "c_mercury")
        #expect(try #require(Decision.detect(in: snapshot, text: .missing)?.prompt).contains("Would copy: c_mercury."))
    }
}
