@testable import BalabroCore
import Foundation
import Testing

@Suite
struct PlanTests {
    @Test func readsAFullShopReply() throws {
        let reply = """
            Why: Baron needs Kings held in hand.
            buy card 2
            buy and use card 1
            sell joker 3
            use consumable 1 on hand 2 5
            open pack 1
            """
        let plan = try Plan.parse(reply).get()
        #expect(plan.why == "Baron needs Kings held in hand.")
        #expect(plan.moves == ["buy card 2", "buyuse card 1", "sell joker 3", "use consumable 1 on hand 2 5"])
        #expect(plan.ending == .openPack(1))
    }

    @Test func aMoveAfterTheEndingIsAProblem() {
        guard case .failure(let problem) = Plan.parse("reroll\nbuy card 1") else {
            Issue.record("expected a failure")
            return
        }
        #expect(problem.line == "buy card 1")
    }

    @Test func proseIsAProblem() {
        #expect(throws: PlanProblem.self) { try Plan.parse("I would buy the Baron here.").get() }
    }

    @Test func noEndingMeansPlayTheNextBlind() throws {
        #expect(try Plan.parse("buy card 1").get().ending == .next(.play))
    }

    @Test func theLineTheBotReads() throws {
        let plan = Plan(why: "A|B", moves: ["buy card 2"], ending: .next(.skip))
        #expect(plan.line(question: QuestionID(12)) == "plan|12|why:A/B|buy card 2|end:next skip")
    }

    @Test func partialWhyWaitsForTheWhyLine() {
        #expect(Plan.partialWhy("Why: Baron nee") == "Baron nee")
        #expect(Plan.partialWhy("buy card 1") == nil)
    }
}

@Suite
struct BotFrameTests {
    @Test func gameOutputIsNotAFrame() {
        #expect(BotFrame(line: "sandbox_extension_issue_file_to_process failed") == nil)
    }

    @Test func statusKeepsPipesInItsLastField() {
        let frame = BotFrame(line: "@@status|3|9|42|1480|Discarding 4|cards")
        #expect(frame == .status(BotStatus(ante: 3, round: 9, dollars: 42, bestHand: 1480, doing: "Discarding 4|cards")))
    }

    @Test func aDecisionCarriesThePicksForAPack() {
        let frame = BotFrame(line: "@@decide|7|pack|2|/tmp/decision-7.jkr|Score check.")
        #expect(frame == .decide(QuestionID(7), .pack(picks: 2), file: URL(filePath: "/tmp/decision-7.jkr"), brief: "Score check."))
    }

    @Test func theScorerAnswersWithFactsOrNothing() {
        #expect(ScorerFrame(line: "@@ready|1.0.1o") == .ready)
        #expect(ScorerFrame(line: "@@scored|4||EXACT SCORES: a|b") == .scored(ScoreID(4), packFile: nil, facts: "EXACT SCORES: a|b"))
        #expect(ScorerFrame(line: "@@scored|4||") == .scored(ScoreID(4), packFile: nil, facts: nil))
        #expect(ScorerFrame(line: "@@scored|4|/tmp/decision-pack.jkr|Score check.") == .scored(ScoreID(4), packFile: URL(filePath: "/tmp/decision-pack.jkr"), facts: "Score check."))
        #expect(ScorerFrame(line: "LONG DT @ 24: 0.1") == nil)
    }

    @Test func aHandWithChanceHasNoPrediction() {
        #expect(BotFrame(line: "@@played|Flush|-|1625.6") == .played(hand: "Flush", predicted: nil, actual: 1625.6))
    }

    @Test func infinityIsAScore() {
        #expect(BotFrame(line: "@@ended|naneinf|12|35|inf") == .ended(BotEnding(outcome: .naneinf, ante: 12, round: 35, bestHand: .infinity)))
    }
}

@Suite
struct PilotReducerTests {
    let pilot = Pilot(text: .missing)
    let start = Date(timeIntervalSince1970: 1000)
    let setup = PilotSetup.standard(for: .win)

    func running() -> PilotState {
        var state = PilotState(restoring: [])
        _ = pilot.reduce(&state, .start(setup))
        _ = pilot.reduce(&state, .bot(.ready(gameVersion: "1.0.1o"), at: start))
        return state
    }

    func asking(_ state: inout PilotState) throws -> TurnRequest {
        _ = pilot.reduce(&state, .bot(.decide(QuestionID(1), .shop, file: URL(filePath: "/tmp/d"), brief: "Score check."), at: start))
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        let effects = pilot.reduce(&state, .decisionRead(QuestionID(1), .success(snapshot), packCards: []))
        guard case .startTurn(let request)? = effects.first else {
            Issue.record("expected a turn")
            throw CocoaError(.featureUnsupported)
        }
        return request
    }

    @Test func aGoodReplyTellsTheBotAndMovesTheHead() throws {
        var state = running()
        let request = try asking(&state)
        #expect(request.forkFrom == nil)
        #expect(request.message.text.hasSuffix("\nScore check."))
        let effects = pilot.reduce(&state, .turnOutput(request.id, .done("Why: Cheap.\nbuy card 1\nnext play", SessionID(rawValue: "s1"))))
        #expect(effects == [.tell("plan|1|why:Cheap.|buy card 1|end:next play")])

        _ = pilot.reduce(&state, .bot(.decide(QuestionID(2), .shop, file: URL(filePath: "/tmp/d"), brief: "Score check."), at: start))
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        guard case .startTurn(let next)? = pilot.reduce(&state, .decisionRead(QuestionID(2), .success(snapshot), packCards: [])).first else {
            Issue.record("expected a turn")
            return
        }
        #expect(next.forkFrom == SessionID(rawValue: "s1"))
    }

    @Test func aBadReplyIsRetriedFromTheSameHeadThenMovesOn() throws {
        var state = running()
        let first = try asking(&state)
        let retry = pilot.reduce(&state, .turnOutput(first.id, .done("I'd buy the Baron", SessionID(rawValue: "bad"))))
        guard case .startTurn(let second)? = retry.first else {
            Issue.record("expected a retry")
            return
        }
        #expect(second.forkFrom == nil)
        #expect(second.message.text.contains("I'd buy the Baron"))
        let moved = pilot.reduce(&state, .turnOutput(second.id, .done("still prose", SessionID(rawValue: "bad2"))))
        #expect(moved == [.tell("plan|1|why:Claude didn't answer, so the bot moved on without spending.|end:next play")])
    }

    @Test func twoFailedQuestionsInARowEndTheRun() throws {
        var state = running()
        for question in 1...2 {
            _ = pilot.reduce(&state, .bot(.decide(QuestionID(question), .shop, file: URL(filePath: "/tmp/d"), brief: "Score check."), at: start))
            let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
            guard case .startTurn(let first)? = pilot.reduce(&state, .decisionRead(QuestionID(question), .success(snapshot), packCards: [])).first,
                  case .startTurn(let second)? = pilot.reduce(&state, .turnOutput(first.id, .failed(.malformedOutput))).first
            else {
                Issue.record("expected a turn and a retry")
                return
            }
            _ = pilot.reduce(&state, .turnOutput(second.id, .failed(.malformedOutput)))
        }
        #expect(state.view.status == .finished)
        #expect(state.view.result?.ending == .failed("Claude failed on two decisions in a row. Last time: claude's output couldn't be read."))
    }

    @Test func aUsageLimitEndsTheRunAtOnce() throws {
        var state = running()
        let request = try asking(&state)
        let effects = pilot.reduce(&state, .turnOutput(request.id, .failed(.rateLimited(resetsAt: nil))))
        #expect(state.view.result?.ending == .failed("Claude's usage limit was reached."))
        #expect(effects.contains(.kill))
    }

    @Test func anAnswerFromATimedOutTurnIsDropped() throws {
        var state = running()
        let request = try asking(&state)
        _ = pilot.reduce(&state, .timedOut(request.id))
        #expect(pilot.reduce(&state, .turnOutput(request.id, .done("reroll", SessionID(rawValue: "s2")))).isEmpty)
    }

    @Test func refusedMovesGoIntoTheNextPromptOnce() throws {
        var state = running()
        _ = pilot.reduce(&state, .bot(.refused(QuestionID(0), move: "buy card 1", reason: "not enough money"), at: start))
        let first = try asking(&state)
        #expect(first.message.text.contains("refused these moves from your last reply: buy card 1 (not enough money)"))
        _ = pilot.reduce(&state, .turnOutput(first.id, .done("next play", SessionID(rawValue: "s1"))))
        _ = pilot.reduce(&state, .bot(.decide(QuestionID(2), .shop, file: URL(filePath: "/tmp/d"), brief: "Score check."), at: start))
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        guard case .startTurn(let second)? = pilot.reduce(&state, .decisionRead(QuestionID(2), .success(snapshot), packCards: [])).first else {
            Issue.record("expected a turn")
            return
        }
        #expect(!second.message.text.contains("refused"))
    }

    @Test func theFirstEndingCountsAndTheGameExitingLaterDoesNothing() {
        var state = running()
        let end = start.addingTimeInterval(300)
        let effects = pilot.reduce(&state, .bot(.ended(BotEnding(outcome: .won, ante: 8, round: 24, bestHand: 5e4)), at: end))
        #expect(effects.contains(.kill))
        #expect(state.view.result?.seconds == 300)
        #expect(state.results.count == 1)
        #expect(pilot.reduce(&state, .botExited(status: 0, at: end.addingTimeInterval(1))).isEmpty)
        #expect(state.results.count == 1)
        #expect(state.view.result?.ending == .won)
    }

    @Test func aMissedPredictionWarns() {
        var state = running()
        _ = pilot.reduce(&state, .bot(.played(hand: "Flush", predicted: 100, actual: 100), at: start))
        #expect(state.view.warning == nil)
        _ = pilot.reduce(&state, .bot(.played(hand: "Flush", predicted: 100, actual: 90), at: start))
        #expect(state.view.warning == "The score prediction missed 1 of 2 hands, so Balatro may have changed.")
    }


    @Test func bestTimesAreKeptPerEnding() {
        func result(_ ending: PilotResult.Ending, _ seconds: Double) -> PilotResult {
            PilotResult(goal: "win", deck: CenterKey(rawValue: "b_red"), stake: 1, ending: ending, ante: 8, round: 24, bestHand: 0, seconds: seconds, gameVersion: "", finishedAt: .distantPast)
        }
        let results = [result(.won, 500), result(.won, 300), result(.lost, 60), result(.naneinf, 900)]
        #expect(bestTimes(in: results) == [BestTime(title: "Fastest win", seconds: 300), BestTime(title: "Fastest naneinf", seconds: 900)])
    }

}

@Suite
struct PilotPromptTests {
    @Test func aPackListsItsCardsWithNumbers() throws {
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        let cards: [ShopItem.Card] = [.consumable(Consumable(key: CenterKey(rawValue: "c_mercury"))), .voucher(CenterKey(rawValue: "v_overstock_norm"))]
        let prompt = Prompt.pilotDecision(.pack(cards, picks: 2), snapshot, .missing, goal: .win, refused: [])
        #expect(prompt.hasPrefix("DECISION: pick from an open pack. You may choose 2 of these, numbered from the left:\n1. "))
        #expect(prompt.contains("c_mercury"))
        #expect(!prompt.contains("screenshot"))
    }

    @Test func theCoachPromptIsUntouchedByThePilot() throws {
        let snapshot = try SaveFile.decode(Fixture.save("05-shop"), profile: 1)
        #expect(Prompt.pilotDecision(.shop, snapshot, .missing, goal: .win, refused: []) == Prompt.decision(.shop, snapshot, .missing, goal: .win))
    }

}
