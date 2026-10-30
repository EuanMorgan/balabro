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
        ("07-pack-opening", "openPack"), ("08-pack-closed", "shop"), ("11-round-eval", "none"),
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

    @Test func firstHandAfterTheShopIsANewDecision() throws {
        #expect(try decision("10-hand")?.kind == .playHand)
        #expect(try decision("02-hand")?.fingerprint != decision("10-hand")?.fingerprint)
    }

    @Test func handPromptNamesTheCardsOnScreen() throws {
        let prompt = try #require(try decision("02-hand")?.prompt)
        #expect(prompt.contains("Hand (left to right): K♥ K♣ 7♠ 6♥ 5♠ 3♠ 3♦ 2♦"))
        #expect(prompt.contains("Target 300, scored 0. Hands 4, discards 4. $4."))
    }

    @Test func handTitle() throws {
        #expect(try decision("03-hand-after-discard")?.title == "Ante 1 · bl_small · 4 hands, 3 discards")
    }

    /// The driver run never skipped a blind, so these give the blind-select save the tags a skip would leave.
    func blindSelect(holding tags: [String]) throws -> Decision? {
        let list = tags.enumerated().map { #"[\#($0 + 1)]={["key"]="\#($1)",["tally"]=\#($0),["ability"]={},},"# }.joined()
        let text = Fixture.saveText("01-blind-select").replacingOccurrences(of: #"["tags"]={},"#, with: #"["tags"]={\#(list)},"#)
        return Decision.detect(in: try SaveFile.decode(Data(text.utf8), profile: 1), text: .missing)
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

    @Test func tagsThatDontFireOnABlindChoiceAreSkippedOver() throws {
        #expect(try blindSelect(holding: ["tag_handy", "tag_charm"])?.needsScreenshot == true)
    }
}
