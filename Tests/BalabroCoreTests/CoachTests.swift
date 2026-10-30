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
        #expect(actions(coach.reduce(&state, .saveWritten(tagPack))) == [.captureGameWindow(CaptureID(1), after: .milliseconds(3500))])
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
        #expect(actions(coach.reduce(&state, .saveRemoved(profile: 1))) == [.cancelTurn(TurnID(0)), .readProgress(after: coach.progressSettleDelay)])
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
        #expect(state.view.headline == "Ante 1 · bl_small")
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

        #expect(state.view.headline == "Ante 1 · bl_small")
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

    @Test func theSecondPackFromADoubledTagIsCoachedToo() throws {
        var state = CoachState(restoring: [])
        let first = Fixture.save("01-blind-select", holdingTags: ["tag_meteor", "tag_meteor"])
        #expect(actions(coach.reduce(&state, .saveWritten(try SaveFile.decode(first, profile: 1)))) == [.captureGameWindow(CaptureID(0), after: coach.tagPackSettleDelay)])
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: Data([1])))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("**Do this now:**\n1. Take Mercury.", SessionID(rawValue: "S0"))))
        let second = Data(Fixture.saveText("01-blind-select").replacingOccurrences(of: #"["STATE"]=7"#, with: #"["STATE"]=10"#).utf8)
        #expect(actions(coach.reduce(&state, .saveWritten(try SaveFile.decode(second, profile: 1)))) == [.captureGameWindow(CaptureID(2), after: coach.tagPackSettleDelay)])
    }

    @Test func refreshLooksAtTheScreenAndReplacesTheSteps() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))

        #expect(actions(coach.reduce(&state, .refresh)) == [.captureGameWindow(CaptureID(1), after: .zero)])
        let message = try #require(sentRequests(coach.reduce(&state, .screenshot(CaptureID(1), png: Data([1])))).first).message
        #expect(message.screenshotPNG == Data([1]))
        #expect(message.text.hasPrefix("DECISION: play or discard"))
        #expect(message.text.contains("THE PLAYER PRESSED REFRESH"))

        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("**Do this now:**\n1. Discard.", SessionID(rawValue: "S1"))))
        #expect(state.view.advice?.doNow == ["Discard."])
        #expect(state.view.sawScreen)
        #expect(actions(coach.reduce(&state, .saveWritten(try snap("02-hand")))).isEmpty)
    }

    @Test func refreshStopsATurnThatIsStillRunning() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .ask("why?", withScreenshot: false))
        #expect(actions(coach.reduce(&state, .refresh)) == [.cancelTurn(TurnID(0)), .captureGameWindow(CaptureID(1), after: .zero)])
        #expect(actions(coach.reduce(&state, .turnOutput(TurnID(0), .done("Too late.", SessionID(rawValue: "S0"))))).isEmpty)
    }

    @Test func refreshWorksWhenTheSaveIsNotADecision() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("04-round-eval")))
        #expect(actions(coach.reduce(&state, .refresh)) == [.captureGameWindow(CaptureID(0), after: .zero)])
        #expect(state.view.headline == "What's on your screen")
        let message = try #require(sentRequests(coach.reduce(&state, .screenshot(CaptureID(0), png: Data([1])))).first).message
        #expect(message.text.hasPrefix("THE PLAYER PRESSED REFRESH"))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("**Do this now:**\n1. Cash out.", SessionID(rawValue: "S0"))))
        #expect(state.view.advice?.doNow == ["Cash out."])
    }

    @Test func refreshLooksAgainIfAPackIsStillOpening() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("04-round-eval")))
        _ = coach.reduce(&state, .refresh)
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: Data([1])))
        #expect(actions(coach.reduce(&state, .turnOutput(TurnID(1), .done("PACK_NOT_READY", SessionID(rawValue: "S0"))))) == [.captureGameWindow(CaptureID(2), after: coach.packRetryDelay)])
        #expect(state.view.advice == nil)
    }

    @Test func aFailedRefreshRetriesWithANewScreenshot() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("04-round-eval")))
        _ = coach.reduce(&state, .refresh)
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: Data([1])))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .failed(.notLoggedIn)))
        #expect(actions(coach.reduce(&state, .retry)) == [.captureGameWindow(CaptureID(2), after: .zero)])
    }

    @Test func refreshWithoutARunSaysSo() {
        var state = CoachState(restoring: [])
        #expect(coach.reduce(&state, .refresh).isEmpty)
        #expect(state.view.problem == .noRun)
    }

    func sentRequests(_ effects: [CoachEffect]) -> [TurnRequest] {
        effects.compactMap { if case .startTurn(let request) = $0 { request } else { nil } }
    }

    let progress = PlayerProgress(
        career: CareerStats(), decks: [.init(key: CenterKey(rawValue: "b_blue"), highestWin: 1, wins: 1, losses: 5, highestStart: 2)],
        locked: [CenterKey(rawValue: "b_magic")])

    func wonSave() throws -> RunSnapshot {
        let text = Fixture.saveText("04-round-eval").replacingOccurrences(of: #"["won"]=false"#, with: #"["won"]=true"#)
        return try SaveFile.decode(Data(text.utf8), profile: 1)
    }

    @Test func theEndOfARunSuggestsTheNextOne() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))
        #expect(actions(coach.reduce(&state, .saveRemoved(profile: 1))) == [.readProgress(after: coach.progressSettleDelay)])

        let request = try #require(sentRequests(coach.reduce(&state, .progressRead(progress))).first)
        #expect(request.forkFrom == nil)
        #expect(request.message.text.hasPrefix("DECISION: which deck and stake"))
        #expect(request.message.text.contains("- b_blue. Won on stake_white at best, 5 losses. Can start on stakes up to stake_red."))
        #expect(request.message.text.contains("Decks still locked: b_magic (win with the Red Deck)"))
        #expect(state.view.waitingOn == .blindSelect)

        _ = coach.reduce(&state, .turnOutput(request.id, .done("**Do this now:**\n1. Start a run with the Blue Deck on Red Stake.", SessionID(rawValue: "N"))))
        #expect(state.view.headline == "Your next run")
        #expect(state.view.advice?.doNow == ["Start a run with the Blue Deck on Red Stake."])
    }

    @Test func winningSuggestsTheNextRunOnlyOnce() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("Play.", SessionID(rawValue: "S0"))))
        #expect(actions(coach.reduce(&state, .saveWritten(try wonSave()))) == [.readProgress(after: coach.progressSettleDelay)])
        #expect(actions(coach.reduce(&state, .saveWritten(try wonSave()))).isEmpty)
    }

    @Test func aRoundEndWithoutAWinDoesNotSuggestANextRun() throws {
        var state = CoachState(restoring: [])
        #expect(actions(coach.reduce(&state, .saveWritten(try snap("04-round-eval")))).isEmpty)
    }

    @Test func theNextRunsAdviceStaysOutOfTheRunsConversation() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("Play.", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .saveWritten(try wonSave()))
        let request = try #require(sentRequests(coach.reduce(&state, .progressRead(progress))).first)
        #expect(request.forkFrom == nil)
        _ = coach.reduce(&state, .turnOutput(request.id, .done("**Do this now:**\n1. Start a run.", SessionID(rawValue: "N"))))
        #expect(state.view.headline == "Your next run")

        let next = try #require(sentRequests(coach.reduce(&state, .saveWritten(try snap("05-shop")))).first)
        #expect(next.forkFrom == SessionID(rawValue: "S0"))
        #expect(state.view.headline != "Your next run")
    }

    @Test func aRunStartedInTheMeantimeCancelsTheSuggestion() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("Play.", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .saveRemoved(profile: 1))
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(sentRequests(coach.reduce(&state, .progressRead(progress))).isEmpty)
    }

    @Test func thePlayerCanAskForTheNextRunWithNoRunGoing() throws {
        var state = CoachState(restoring: [])
        #expect(coach.reduce(&state, .adviseNextRun) == [.readProgress(after: .zero)])
        let request = try #require(sentRequests(coach.reduce(&state, .progressRead(progress))).first)
        _ = coach.reduce(&state, .turnOutput(request.id, .failed(.notLoggedIn)))
        #expect(state.view.canRetry)
        #expect(sentRequests(coach.reduce(&state, .retry)).first?.message.text.hasPrefix("DECISION: which deck") == true)
    }

    @Test func noProfileMeansNoSuggestion() throws {
        var state = CoachState(restoring: [])
        #expect(coach.reduce(&state, .progressRead(nil)).isEmpty)
    }

    @Test func chipsNeededComesFromTheNewestSave() throws {
        var state = CoachState(restoring: [])
        #expect(state.view.chipsNeeded == nil)
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(state.view.chipsNeeded == 300)
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        #expect(state.view.chipsNeeded == nil)
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        #expect(state.view.chipsNeeded == 450)
        _ = coach.reduce(&state, .saveRemoved(profile: 1))
        #expect(state.view.chipsNeeded == nil)
    }

    /// A run saved by a version with different rules: it has a conversation but no record of the current rules.
    func runFromAnOlderVersion() throws -> RunRecord {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let effects = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))
        let saved = effects.compactMap { effect -> RunRecord? in if case .save(let record) = effect { record } else { nil } }
        var record = try #require(saved.last)
        record.rules = nil
        return record
    }

    func sentMessages(_ effects: [CoachEffect]) -> [String] {
        effects.compactMap { if case .startTurn(let request) = $0 { request.message.text } else { nil } }
    }

    let rulesNotice = "THE COACHING RULES HAVE CHANGED"

    @Test func aRunFromAnOlderVersionIsToldTheNewRulesOnce() throws {
        var state = CoachState(restoring: [try runFromAnOlderVersion()])
        let first = sentMessages(coach.reduce(&state, .saveWritten(try snap("05-shop"))))
        #expect(first.count == 1)
        #expect(first[0].hasPrefix(rulesNotice))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Leave.", SessionID(rawValue: "S1"))))
        let second = sentMessages(coach.reduce(&state, .saveWritten(try snap("10-hand"))))
        #expect(second.count == 1)
        #expect(!second[0].contains(rulesNotice))
    }

    @Test func aFailedTurnStillOwesTheNewRules() throws {
        var state = CoachState(restoring: [try runFromAnOlderVersion()])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .failed(.notLoggedIn)))
        let retried = sentMessages(coach.reduce(&state, .retry))
        #expect(retried.count == 1)
        #expect(retried[0].hasPrefix(rulesNotice))
    }

    @Test func aNewRunIsNotToldTheRulesAgain() throws {
        var state = CoachState(restoring: [])
        let first = sentMessages(coach.reduce(&state, .saveWritten(try snap("02-hand"))))
        #expect(first.count == 1)
        #expect(!first[0].contains(rulesNotice))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))
        let second = sentMessages(coach.reduce(&state, .saveWritten(try snap("05-shop"))))
        #expect(second.count == 1)
        #expect(!second[0].contains(rulesNotice))
    }

    @Test func replyWithNewStepsReplacesTheGoal() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Discard.\n\n**Goal:** Going for a Straight", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .ask("why?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("Because.", SessionID(rawValue: "S1"))))
        #expect(state.view.advice?.goal == "Going for a Straight")
        _ = coach.reduce(&state, .ask("flush instead?", withScreenshot: false))
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("Yes.\n\n**Do this now:**\n1. Keep hearts.\n\n**Goal:** Going for a Flush", SessionID(rawValue: "S2"))))
        #expect(state.view.advice?.goal == "Going for a Flush")
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

    @Test func viewSaysWhetherTheCoachSawTheScreen() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Discard.", SessionID(rawValue: "S0"))))
        #expect(!state.view.sawScreen)

        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        _ = coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89])))
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("**Do this now:**\n1. Pick.", SessionID(rawValue: "S2"))))
        #expect(state.view.sawScreen)
    }

    @Test func failedScreenshotDoesNotClaimTheCoachSawTheScreen() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: nil))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("**Do this now:**\n1. List them.", SessionID(rawValue: "S1"))))
        #expect(!state.view.sawScreen)
        #expect(state.view.problem == .screenRecordingDenied)
    }

    @Test func followUpSaysWhetherItsReplySawTheScreen() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Discard.", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .ask("what's this?", withScreenshot: true))
        _ = coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89])))
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("A joker.", SessionID(rawValue: "S2"))))
        #expect(state.view.thread == [.init(question: "what's this?", reply: "A joker.", changedSteps: false, sawScreen: true)])
        #expect(!state.view.sawScreen)
    }

    func savedSummaries(_ effects: [CoachEffect]) -> [RunSummary?] {
        effects.compactMap { if case .save(let record) = $0 { record.summary } else { nil } }
    }

    @Test func summaryFollowsTheRunAndKeepsThePeakMoney() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        var later = try snap("12-shop")
        later.dollars = 10
        let effects = coach.reduce(&state, .saveWritten(later))
        let summary = try #require(savedSummaries(effects).last ?? nil)
        #expect(summary.ante == 1)
        #expect(summary.stake == 1)
        #expect(summary.deck == CenterKey(rawValue: "b_red"))
        #expect(summary.jokers == [CenterKey(rawValue: "j_gluttenous_joker")])
        #expect(summary.peakDollars == 86)
        #expect(summary.bestHand == 16)
        #expect(!summary.won)
        #expect(!summary.ended)
    }

    @Test func removingTheSaveMarksTheRunEnded() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        let summary = try #require(savedSummaries(coach.reduce(&state, .saveRemoved(profile: 1))).last ?? nil)
        #expect(summary.ended)
    }

    @Test func recordSavedBeforeStatsStillLoads() throws {
        let json = #"""
            {"key":{"identity":{"profile":1,"seed":"S","deck":"b_red","stake":1},"replay":0},
             "progress":{"round":1,"handsPlayed":0,"cardsDiscarded":0,"rerolls":0,"purchases":0},"transcript":[]}
            """#
        #expect(try JSONDecoder().decode(RunRecord.self, from: Data(json.utf8)).summary == nil)
    }

    func bossSelect() throws -> RunSnapshot {
        var snapshot = try snap("09-blind-select")
        (snapshot.blindSelect.small, snapshot.blindSelect.big) = (.defeated, .defeated)
        #expect(snapshot.blindSelect.boss == .upcoming)
        return snapshot
    }

    @Test func onlyTheBossLeftNeedsNoTurn() throws {
        var state = CoachState(restoring: [])
        let effects = coach.reduce(&state, .saveWritten(try bossSelect()))
        #expect(starts(effects).isEmpty)
        #expect(state.view.status == .ready)
        #expect(state.view.advice?.doNow == ["Select the Boss Blind, \(try bossSelect().blindSelect.bossKey)."])
        #expect(state.view.advice?.why == ["It's the only blind left, and Boss Blinds can't be skipped."])
    }

    @Test func onlyTheBossLeftCancelsATurnInFlightAndKeepsTheHead() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("done", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .saveWritten(try snap("08-pack-closed")))
        let effects = coach.reduce(&state, .saveWritten(try bossSelect()))
        #expect(effects.contains(.cancelTurn(TurnID(1))))
        #expect(state.view.status == .ready)
        let next = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        #expect(starts(next).map(\.forkFrom) == [SessionID(rawValue: "S0")])
    }

    @Test func aQuestionInFlightStillFinishesFirst() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("done", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .ask("why?", withScreenshot: false))
        _ = coach.reduce(&state, .saveWritten(try bossSelect()))
        #expect(state.view.status == .thinking)
        let after = coach.reduce(&state, .turnOutput(TurnID(1), .done("because", SessionID(rawValue: "S1"))))
        #expect(starts(after).isEmpty)
        #expect(state.view.advice?.goal == "Beat the Boss Blind")
        #expect(state.view.thread.isEmpty)
    }

    @Test(arguments: ["v_directors_cut", "v_retcon"])
    func aBossRerollIsStillADecision(voucher: String) throws {
        var state = CoachState(restoring: [])
        var snapshot = try bossSelect()
        snapshot.vouchers.append(CenterKey(rawValue: voucher))
        #expect(starts(coach.reduce(&state, .saveWritten(snapshot))).count == 1)
    }

    @Test func luchadorIsStillADecision() throws {
        var state = CoachState(restoring: [])
        var snapshot = try bossSelect()
        snapshot.jokers[0].key = CenterKey(rawValue: "j_luchador")
        #expect(starts(coach.reduce(&state, .saveWritten(snapshot))).count == 1)
    }

    @Test func skippingTheBigBlindStillLeavesOnlyTheBoss() throws {
        var state = CoachState(restoring: [])
        var snapshot = try bossSelect()
        snapshot.blindSelect.big = .skipped
        #expect(starts(coach.reduce(&state, .saveWritten(snapshot))).isEmpty)
    }

    @Test func theBigBlindIsStillADecision() throws {
        var state = CoachState(restoring: [])
        #expect(starts(coach.reduce(&state, .saveWritten(try snap("09-blind-select")))).count == 1)
    }

    func packOpenedAndLookedAt(_ state: inout CoachState) throws {
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: Data([0x89])))
    }

    @Test func tooEarlyAScreenshotLooksAgainAndLeavesNoTrace() throws {
        var state = CoachState(restoring: [])
        try packOpenedAndLookedAt(&state)
        let again = coach.reduce(&state, .turnOutput(TurnID(1), .done("PACK_NOT_READY", SessionID(rawValue: "EARLY"))))
        #expect(again == [.captureGameWindow(CaptureID(2), after: .milliseconds(1500))])
        #expect(state.view.status == .lookingAtPack)

        let turn = starts(coach.reduce(&state, .screenshot(CaptureID(2), png: Data([0x89, 0x50]))))
        #expect(turn.map(\.forkFrom) == [nil])
        #expect(turn.map(\.message.screenshotPNG) == [Data([0x89, 0x50])])
        _ = coach.reduce(&state, .turnOutput(TurnID(3), .done("**Do this now:**\n1. Pick Jupiter.", SessionID(rawValue: "S3"))))
        #expect(state.view.advice?.doNow == ["Pick Jupiter."])
        #expect(state.view.sawScreen)
    }

    @Test func tooManyEarlyScreenshotsAsksThePlayerWithoutAPermissionWarning() throws {
        var state = CoachState(restoring: [])
        try packOpenedAndLookedAt(&state)
        var last: [CoachEffect] = []
        for look in 0..<coach.maxPackLooks {
            last = coach.reduce(&state, .turnOutput(TurnID(look * 2 + 1), .done("PACK_NOT_READY", SessionID(rawValue: "E"))))
            if look < coach.maxPackLooks - 1 {
                _ = coach.reduce(&state, .screenshot(CaptureID(look * 2 + 2), png: Data([0x89])))
            }
        }
        let turn = try #require(starts(last).first)
        #expect(turn.message.screenshotPNG == nil)
        #expect(turn.message.text.contains("could not be taken"))
        #expect(state.view.problem == nil)
    }

    @Test func aNewDecisionDuringALookStopsTheLooking() throws {
        var state = CoachState(restoring: [])
        try packOpenedAndLookedAt(&state)
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("PACK_NOT_READY", SessionID(rawValue: "E"))))
        _ = coach.reduce(&state, .saveWritten(try snap("08-pack-closed")))
        #expect(starts(coach.reduce(&state, .screenshot(CaptureID(2), png: Data([0x89])))).isEmpty)
        #expect(state.view.waitingOn == .shop)
    }

    @Test func thatReplyIsNeverShownAsAdvice() throws {
        var state = CoachState(restoring: [])
        try packOpenedAndLookedAt(&state)
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .text("PACK_NOT")))
        #expect(state.view.advice == nil)
        #expect(state.view.status == .thinking)
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .text("_READY")))
        #expect(state.view.advice == nil)
    }

    @Test func aTagPackWaitsLongerThanAShopPack() throws {
        var state = CoachState(restoring: [])
        let tagPack = try SaveFile.decode(Fixture.save("09-blind-select", holdingTags: ["tag_charm"]), profile: 1)
        #expect(actions(coach.reduce(&state, .saveWritten(tagPack))) == [.captureGameWindow(CaptureID(0), after: .milliseconds(3500))])
    }

    @Test func roundEndSaysNothing() throws {
        var state = CoachState(restoring: [])
        #expect(starts(coach.reduce(&state, .saveWritten(try snap("04-round-eval")))).isEmpty)
        #expect(state.view.status == .ready)
    }
}
