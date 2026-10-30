import BalabroCore
import Foundation
import Testing

@Suite(.disabled("sketch: bodies not implemented"))
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
        #expect(try decision("07-pack-opening")?.needsScreenshot == true)
    }
}
