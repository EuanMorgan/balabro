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

    @Test func progressSaysWhichDecksAndStakesCanBeStarted() throws {
        let profile = """
            return {["deck_usage"]={["b_red"]={["count"]=1,["wins"]={},["losses"]={[1]=6,},},
            ["b_blue"]={["count"]=1,["wins"]={[1]=2,[2]=1,},["losses"]={[1]=5,[2]=1,},},},}
            """
        let meta = #"return {["unlocked"]={["b_blue"]=true,["b_nebula"]=true,["j_joker"]=true,["b_challenge"]=true,},["alerted"]={["b_ghost"]=true,},}"#
        let progress = try SaveFile.decodeProgress(profile: Data(profile.utf8), meta: Data(meta.utf8))
        #expect(progress.decks == [
            .init(key: CenterKey(rawValue: "b_red"), highestWin: 0, wins: 0, losses: 6, highestStart: 1),
            .init(key: CenterKey(rawValue: "b_blue"), highestWin: 2, wins: 1, losses: 6, highestStart: 3),
            .init(key: CenterKey(rawValue: "b_nebula"), highestWin: 0, wins: 0, losses: 0, highestStart: 1),
        ])
        #expect(progress.locked.count == 12)
        #expect(progress.locked.contains(CenterKey(rawValue: "b_ghost")))
        #expect(!progress.locked.contains(CenterKey(rawValue: "b_challenge")))
    }

    @Test func theTopStakeIsTheLimit() throws {
        let profile = #"return {["deck_usage"]={["b_red"]={["wins"]={[8]=1,},["losses"]={},},},}"#
        #expect(try SaveFile.decodeProgress(profile: Data(profile.utf8), meta: nil).decks.first?.highestStart == 8)
    }

    @Test func aProfileWithEverythingUnlockedCanStartAnything() throws {
        let progress = try SaveFile.decodeProgress(profile: Data(#"return {["all_unlocked"]=true,}"#.utf8), meta: nil)
        #expect(progress.locked.isEmpty)
        #expect(progress.decks.count == 15)
        #expect(progress.decks.allSatisfy { $0.highestStart == 8 })
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
