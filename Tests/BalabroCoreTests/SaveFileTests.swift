import BalabroCore
import Foundation
import Testing

@Suite(.disabled("sketch: bodies not implemented"))
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

    @Test func halfWrittenFileIsIncomplete() {
        #expect(throws: SaveFileError.incomplete) { try SaveFile.decode(Fixture.save("02-hand").prefix(3000), profile: 1) }
    }

    @Test func plainLuaTextIsAccepted() throws {
        // STR_PACK's own output shapes: shuffled indices, %q escapes, LuaJIT's `inf`.
        let lua = #"return {["STATE"]=1,["VERSION"]="1.0.1o-FULL",["x"]="a\"b",["n"]={[2]=inf,[1]=1e+15,},}"#
        #expect(throws: SaveFileError.unexpectedShape(path: "GAME")) { try SaveFile.decode(Data(lua.utf8), profile: 1) }
    }

    static func short(_ c: HandCard) -> String {
        guard case .faceUp(let p) = c else { return "?" }
        let rank = ["Jack": "J", "Queen": "Q", "King": "K", "Ace": "A"][p.rank.rawValue] ?? p.rank.rawValue
        return rank + String(p.suit.symbol)
    }
}
