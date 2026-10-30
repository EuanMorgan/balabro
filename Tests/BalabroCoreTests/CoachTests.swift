import BalabroCore
import Foundation
import Testing

/// The coaching policy, event by event, through `Coach.reduce` only.
@Suite
struct CoachTests {
    let coach = Coach(text: .missing)
    func snap(_ name: String) throws -> RunSnapshot { try SaveFile.decode(Fixture.save(name), profile: 1) }
    /// Everything but `.save`, which follows each change to the run's progress counters.
    func actions(_ effects: [CoachEffect]) -> [CoachEffect] {
        effects.filter { if case .save = $0 { false } else { true } }
    }
    func starts(_ effects: [CoachEffect]) -> [TurnRequest] {
        effects.compactMap { if case .startTurn(let r) = $0 { r } else { nil } }
    }

    @Test func firstHandStartsANewConversation() throws {
        var state = CoachState(restoring: [])
        let effects = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(starts(effects).map(\.forkFrom) == [nil])
    }

    @Test func sameSaveTwiceStartsOneTurn() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(starts(coach.reduce(&state, .saveWritten(try snap("02-hand")))).isEmpty)
    }

    @Test func newDecisionCancelsTheOneInFlight() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let effects = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(effects.contains(.cancelTurn(TurnID(0))))
        #expect(starts(effects).map(\.id) == [TurnID(1)])
    }

    @Test func onlyACompletedTurnMovesTheHead() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("late", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("ok", SessionID(rawValue: "S1"))))
        let next = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        #expect(starts(next).map(\.forkFrom) == [SessionID(rawValue: "S1")])
    }

    @Test func decisionWaitsForThePlayersQuestion() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("advice", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .ask("why keep the 6?", withScreenshot: false))
        let during = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(!during.contains(.cancelTurn(TurnID(1))))
        #expect(starts(during).isEmpty)
        let after = coach.reduce(&state, .turnOutput(TurnID(1), .done("because", SessionID(rawValue: "S1"))))
        #expect(starts(after).map(\.forkFrom) == [SessionID(rawValue: "S1")])
    }

    @Test func packOpeningCapturesThenStartsWithTheImage() throws {
        var state = CoachState(restoring: [])
        let effects = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        #expect(effects.contains(.captureGameWindow(CaptureID(0), after: .milliseconds(1800))))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let started = coach.reduce(&state, .screenshot(CaptureID(0), png: png))
        #expect(starts(started).map(\.message.screenshotPNG) == [png])
    }

    @Test func restartDoesNotRecoachACoachedMoment() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let saved = coach.reduce(&state, .turnOutput(TurnID(0), .done("advice", SessionID(rawValue: "S0"))))
        let records = saved.compactMap { if case .save(let r) = $0 { r } else { nil } }
        var restarted = CoachState(restoring: records)
        #expect(starts(coach.reduce(&restarted, .saveWritten(try snap("02-hand")))).isEmpty)
    }

    @Test func progressGoingBackwardsIsANewRun() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("advice", SessionID(rawValue: "S0"))))
        let replay = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(starts(replay).map(\.forkFrom) == [nil])
    }

    func done(_ id: Int, _ session: String) -> CoachEvent { .turnOutput(TurnID(id), .done("advice \(id)", SessionID(rawValue: session))) }

    @Test func newestWaitingDecisionWins() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("04-round-eval")))
        _ = coach.reduce(&state, .ask("what next?", withScreenshot: false))
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, .saveWritten(try snap("06-shop-reroll")))
        let after = starts(coach.reduce(&state, done(0, "S0")))
        #expect(after.count == 1)
        #expect(after.first?.message.text.contains("$95.") == true)
    }

    @Test func questionsAskedWhileBusyAreJoinedAndRunBeforeAWaitingDecision() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = coach.reduce(&state, .ask("why keep the 6?", withScreenshot: false))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(starts(coach.reduce(&state, .ask("and the 5?", withScreenshot: false))).isEmpty)
        #expect(starts(coach.reduce(&state, .ask("what about the King?", withScreenshot: false))).isEmpty)
        #expect(state.view.queuedQuestion == "and the 5?\nwhat about the King?")

        let question = starts(coach.reduce(&state, done(1, "S1")))
        #expect(question.map(\.message.text) == ["PLAYER QUESTION: and the 5?\nwhat about the King?"])
        #expect(question.map(\.forkFrom) == [SessionID(rawValue: "S1")])

        let decision = starts(coach.reduce(&state, done(2, "S2")))
        #expect(decision.first?.message.text.contains("Hand (left to right): A♣ 8♣ 6♣ 5♥ 3♠ 3♦ 2♠ 2♦") == true)
        #expect(decision.map(\.forkFrom) == [SessionID(rawValue: "S2")])
    }

    @Test func failedTurnWaitsForRetryAndKeepsTheHead() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .failed(.notLoggedIn)))
        #expect(state.view.problem == .turnFailed(.notLoggedIn))
        #expect(state.view.canRetry)
        #expect(starts(coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))).isEmpty)

        let retried = starts(coach.reduce(&state, .retry))
        #expect(retried.map(\.forkFrom) == [SessionID(rawValue: "S0")])
        #expect(retried.first?.message.text.contains("discards 3") == true)
        #expect(!state.view.canRetry)
    }

    @Test func deniedScreenshotStillCoachesAndAsksForTheCards() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        let started = starts(coach.reduce(&state, .screenshot(CaptureID(0), png: nil)))
        #expect(started.count == 1)
        #expect(started.first?.message.screenshotPNG == nil)
        #expect(started.first?.message.text.contains("ask the player to list them") == true)
        #expect(state.view.problem == .screenRecordingDenied)
    }

    @Test func screenshotForAPackThePlayerClosedIsIgnored() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        let tagPack = try SaveFile.decode(Fixture.save("09-blind-select", holdingTags: ["tag_buffoon"]), profile: 1)
        #expect(actions(coach.reduce(&state, .saveWritten(tagPack))) == [.captureGameWindow(CaptureID(1), after: .milliseconds(1800))])
        #expect(starts(coach.reduce(&state, .screenshot(CaptureID(0), png: Data([0x89])))).isEmpty)
        #expect(starts(coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89])))).count == 1)
    }

    @Test func decisionWaitsForTheScreenshotOfThePlayersQuestion() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = coach.reduce(&state, .ask("is this pack worth it?", withScreenshot: true))
        #expect(actions(coach.reduce(&state, .saveWritten(try snap("06-shop-reroll")))).isEmpty)
        let question = starts(coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89]))))
        #expect(question.map(\.message.text) == ["PLAYER QUESTION: is this pack worth it?"])
        #expect(starts(coach.reduce(&state, done(2, "S2"))).first?.message.text.contains("$95.") == true)
    }

    @Test func nothingStartsOnItsOwnAfterAFailure() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = coach.reduce(&state, .ask("why keep the 6?", withScreenshot: false))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(starts(coach.reduce(&state, .turnOutput(TurnID(1), .failed(.rateLimited(resetsAt: nil))))).isEmpty)
        #expect(starts(coach.reduce(&state, .retry)).map(\.message.text) == ["PLAYER QUESTION: why keep the 6?"])
        #expect(starts(coach.reduce(&state, done(2, "S2"))).first?.message.text.contains("discards 3") == true)
    }

    @Test func questionWithScreenshotCapturesAtOnce() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, done(0, "S0"))
        #expect(coach.reduce(&state, .ask("is this pack worth it?", withScreenshot: true)) == [.captureGameWindow(CaptureID(1), after: .zero)])
    }

    @Test func deletedSaveEndsTheRun() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(coach.reduce(&state, .saveRemoved(profile: 1)) == [.cancelTurn(TurnID(0))])
        #expect(state.view.status == .waitingForRun)
        #expect(coach.reduce(&state, .ask("hello?", withScreenshot: false)).isEmpty)
        #expect(state.view.problem == .noRun)
    }

    @Test func saveOnAnotherProfileDoesNotEndTheRun() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(coach.reduce(&state, .saveRemoved(profile: 2)).isEmpty)
        #expect(state.view.status == .thinking)
    }

    @Test func streamedTextShowsAsItArrives() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .text("**Do this now:**\n1. Discard 7♠")))
        #expect(state.view.status == .answering)
        #expect(state.view.headline == "Ante 1 · bl_small · 4 hands, 4 discards")
        #expect(state.view.advice?.doNow == ["Discard 7♠"])
    }

    func stateWithPlan() throws -> CoachState {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done(
            "**Do this now:**\n1. Discard 7♠.\n\n**Why:**\n- It pairs with nothing.\n\n**Lesson 1: Discards are free**\nUse them.",
            SessionID(rawValue: "S0"))))
        return state
    }

    @Test func questionRepliesUnderThePlanAndKeepsTheHeadline() throws {
        var state = try stateWithPlan()
        _ = coach.reduce(&state, .ask("why the 7?", withScreenshot: false))
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "", changedSteps: false)])
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .text("It pairs")))
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "It pairs", changedSteps: false)])
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("It pairs with nothing.", SessionID(rawValue: "S1"))))
        _ = coach.reduce(&state, .ask("and the King?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("Keep it.", SessionID(rawValue: "S2"))))

        #expect(state.view.headline == "Ante 1 · bl_small · 4 hands, 4 discards")
        #expect(state.view.advice?.doNow == ["Discard 7♠."])
        #expect(state.view.advice?.why == ["It pairs with nothing."])
        #expect(state.view.thread == [
            .init(question: "why the 7?", reply: "It pairs with nothing.", changedSteps: false),
            .init(question: "and the King?", reply: "Keep it.", changedSteps: false),
        ])
    }

    @Test func replyWithNewStepsReplacesThePlansStepsAndReasons() throws {
        var state = try stateWithPlan()
        _ = coach.reduce(&state, .ask("keep the 7?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done(
            "Yes, I missed the straight.\n\n**Do this now:**\n1. Play 7♠ 6♠ 5♠ 4♠ 3♠.\n\n**Why:**\n- It beats the blind.",
            SessionID(rawValue: "S1"))))

        #expect(state.view.advice?.doNow == ["Play 7♠ 6♠ 5♠ 4♠ 3♠."])
        #expect(state.view.advice?.why == ["It beats the blind."])
        #expect(state.view.advice?.lesson?.title == "Discards are free")
        #expect(state.view.thread == [.init(question: "keep the 7?", reply: "Yes, I missed the straight.", changedSteps: true)])
    }

    @Test func replyInTheDecisionShapeWithoutNewStepsStillShowsItsReason() throws {
        var state = try stateWithPlan()
        _ = coach.reduce(&state, .ask("why the 7?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("**Why:**\n- No pair.\n- No flush.", SessionID(rawValue: "S1"))))

        #expect(state.view.advice?.why == ["It pairs with nothing."])
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "No pair. No flush.", changedSteps: false)])
    }

    @Test func nextDecisionClearsTheThread() throws {
        var state = try stateWithPlan()
        _ = coach.reduce(&state, .ask("why the 7?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("No pair.", SessionID(rawValue: "S1"))))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(state.view.thread.isEmpty)
        #expect(state.view.advice == nil)

        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S2"))))
        #expect(state.view.thread.isEmpty)
        #expect(state.view.advice?.doNow == ["Play."])
    }

    @Test func failedQuestionStaysOnScreenForTheRetry() throws {
        var state = try stateWithPlan()
        _ = coach.reduce(&state, .ask("why the 7?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .failed(.notLoggedIn)))
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "", changedSteps: false)])
        #expect(state.view.canRetry)
    }

    @Test func recordSavedBeforeQuestionsWereMarkedStillLoads() throws {
        let json = #"{"title":"Ante 1","advice":"**Do this now:**"}"#
        let exchange = try JSONDecoder().decode(Exchange.self, from: Data(json.utf8))
        #expect(exchange.title == "Ante 1")
        #expect(!exchange.isQuestion)
    }

    @Test func standingComesFromTheNewestSave() throws {
        var state = CoachState(restoring: [])
        #expect(state.view.standing == nil)
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(state.view.standing == .init(score: "0 / 300", dollars: 4))
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        #expect(state.view.standing == .init(score: nil, dollars: 4))
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        #expect(state.view.standing == .init(score: "0 / 450", dollars: 86))
        _ = coach.reduce(&state, .saveRemoved(profile: 1))
        #expect(state.view.standing == nil)
    }

    @Test func replyWithNewStepsDropsTheOldScore() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done(
            "**Do this now:**\n1. Play K♥ K♣.\n\n**Score:**\n- Pair: 30 x 2 = 60", SessionID(rawValue: "S0"))))
        #expect(state.view.advice?.score == [.init(label: "Pair", sum: .init(chips: "30", mult: "2", total: "60"))])
        _ = coach.reduce(&state, .ask("discard instead?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("Yes.\n\n**Do this now:**\n1. Discard 7♠.", SessionID(rawValue: "S1"))))
        #expect(state.view.advice?.score == [])
    }

    @Test func waitingNamesTheDecisionUntilTheFirstWordsArrive() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        #expect(state.view.waitingOn == .shop)
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .text("**Do")))
        #expect(state.view.waitingOn == nil)
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Leave.", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .ask("why?", withScreenshot: false))
        #expect(state.view.waitingOn == nil)
    }

    @Test func waitingCoversThePackScreenshot() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        #expect(state.view.status == .lookingAtPack)
        guard case .openPack? = state.view.waitingOn else {
            Issue.record("expected a pack, got \(String(describing: state.view.waitingOn))")
            return
        }
    }

    @Test func roundEndSaysNothing() throws {
        var state = CoachState(restoring: [])
        #expect(starts(coach.reduce(&state, .saveWritten(try snap("04-round-eval")))).isEmpty)
        #expect(state.view.status == .ready)
    }
}
