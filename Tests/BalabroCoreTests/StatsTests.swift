import BalabroCore
import Foundation
import Testing

@Suite
struct StatsTests {
    @Test func careerTotalsComeFromTheProfile() throws {
        let lua = """
            return {["career_stats"]={["c_wins"]=2,["c_losses"]=11,["c_rounds"]=111,["c_hands_played"]=340,},
            ["high_scores"]={["hand"]={["amt"]=32163,["label"]="Best Hand",},["most_money"]={["amt"]=83,},["furthest_ante"]={["amt"]=6,},["furthest_round"]={["amt"]=21,},},
            ["hand_usage"]={["Pair"]={["count"]=32,["order"]="Pair",},["TwoPair"]={["count"]=66,["order"]="Two Pair",},["FiveofaKind"]={["count"]=0,["order"]="Five of a Kind",},},
            ["joker_usage"]={["j_dusk"]={["count"]=4,["order"]=28,["wins"]={},},["j_odd_todd"]={["count"]=8,["order"]=40,["wins"]={},},},}
            """
        let career = try SaveFile.decodeCareer(Data(lua.utf8))
        #expect((career.wins, career.losses, career.runs) == (2, 11, 13))
        #expect((career.rounds, career.handsPlayed) == (111, 340))
        #expect((career.bestHand, career.mostMoney) == (32163, 83))
        #expect((career.furthestAnte, career.furthestRound) == (6, 21))
        #expect(career.hands == [.init(name: "Two Pair", count: 66), .init(name: "Pair", count: 32)])
        #expect(career.jokers == [.init(name: "j_odd_todd", count: 8), .init(name: "j_dusk", count: 4)])
    }

    @Test func realProfileFileDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/profiles/driver", withExtension: "jkr"))
        let career = try SaveFile.decodeCareer(Data(contentsOf: url))
        #expect(career.hands == [.init(name: "High Card", count: 2)])
        #expect(career.jokers == [.init(name: "j_gluttenous_joker", count: 1)])
    }

    @Test func profileMissingItsTotalsReadsAsZero() throws {
        let career = try SaveFile.decodeCareer(Data("return {}".utf8))
        #expect(career == CareerStats())
    }
}
