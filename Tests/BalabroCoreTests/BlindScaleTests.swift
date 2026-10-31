import Foundation
import Testing
@testable import BalabroCore

struct BlindScaleTests {
    @Test func targetsMatchTheGamesTables() {
        #expect(BlindScale(level: 1, deckMultiplier: 1).small(ante: 6) == 20000)
        #expect(BlindScale(level: 1, deckMultiplier: 1).big(ante: 6) == 30000)
        #expect(BlindScale(level: 2, deckMultiplier: 1).small(ante: 8) == 100000)
        #expect(BlindScale(level: 3, deckMultiplier: 1).small(ante: 7) == 110000)
        #expect(BlindScale(level: 1, deckMultiplier: 2).small(ante: 2) == 1600)
    }

    @Test func bossTargetsFollowEachBoss() {
        let scale = BlindScale(level: 1, deckMultiplier: 1)
        #expect(scale.boss(CenterKey(rawValue: "bl_hook"), ante: 1) == 600)
        #expect(scale.boss(CenterKey(rawValue: "bl_wall"), ante: 1) == 1200)
        #expect(scale.boss(CenterKey(rawValue: "bl_needle"), ante: 1) == 300)
        #expect(scale.boss(CenterKey(rawValue: "bl_final_vessel"), ante: 8) == 300000)
    }

    @Test func endlessAntesFollowTheGamesFormula() {
        #expect(BlindScale(level: 1, deckMultiplier: 1).small(ante: 9) == 110000)
    }

    @Test func theShopSaysWhatTheComingBlindsNeed() throws {
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        let lines = Prompt.decision(.shop, snapshot, .missing).components(separatedBy: "\n")
        #expect(lines.contains("Small Blind: Defeated"))
        #expect(lines.contains { $0.hasPrefix("Big Blind: Upcoming, needs 450.") })
        #expect(lines.contains { $0.hasPrefix("Boss Blind: Upcoming, needs 600.") })
        #expect(lines.contains("Next ante's Small Blind needs 800."))
    }
}
