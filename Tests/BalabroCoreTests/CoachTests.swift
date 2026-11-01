import BalabroCore
import Foundation
import Testing

/// The coaching policy, event by event, through `Coach.reduce` only.
@Suite
struct CoachTests {
    let coach = Coach(text: .missing, machine: MachineID(rawValue: "mac"))
    func snap(_ name: String) throws -> RunSnapshot { try SaveFile.decode(Fixture.save(name), profile: 1) }
    /// Everything but `.save`, which follows each change to the run's progress counters.
    func actions(_ effects: [CoachEffect]) -> [CoachEffect] {
        effects.filter { if case .save = $0 { false } else { true } }
    }
    func starts(_ effects: [CoachEffect]) -> [TurnRequest] {
        effects.compactMap { if case .startTurn(let r) = $0 { r } else { nil } }
    }
    /// Performs the screenshot a question asks for, or does nothing if the question was queued.
    func looking(_ state: inout CoachState, _ effects: [CoachEffect]) -> [CoachEffect] {
        for case .captureGameWindow(let id, _) in effects { return coach.reduce(&state, .screenshot(id, png: Data([0x89]))) }
        return effects
    }
    func asking(_ state: inout CoachState, _ question: String) -> [CoachEffect] {
        looking(&state, coach.reduce(&state, .ask(question)))
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
        _ = asking(&state, "why keep the 6?")
        let during = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(!during.contains(.cancelTurn(TurnID(2))))
        #expect(starts(during).isEmpty)
        let after = coach.reduce(&state, .turnOutput(TurnID(2), .done("because", SessionID(rawValue: "S1"))))
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
        _ = asking(&state, "what next?")
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, .saveWritten(try snap("06-shop-reroll")))
        let after = starts(coach.reduce(&state, done(1, "S0")))
        #expect(after.count == 1)
        #expect(after.first?.message.text.contains("$95.") == true)
    }

    @Test func questionsAskedWhileBusyAreJoinedAndRunBeforeAWaitingDecision() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = asking(&state, "why keep the 6?")
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(starts(asking(&state, "and the 5?")).isEmpty)
        #expect(starts(asking(&state, "what about the King?")).isEmpty)
        #expect(state.view.queuedQuestion == "and the 5?\nwhat about the King?")

        let question = starts(looking(&state, coach.reduce(&state, done(2, "S2"))))
        #expect(question.map(\.message.text) == ["PLAYER QUESTION: and the 5?\nwhat about the King?"])
        #expect(question.map(\.forkFrom) == [SessionID(rawValue: "S2")])

        let decision = starts(coach.reduce(&state, done(4, "S4")))
        #expect(decision.first?.message.text.contains("Hand (left to right): A♣ 8♣ 6♣ 5♥ 3♠ 3♦ 2♠ 2♦") == true)
        #expect(decision.map(\.forkFrom) == [SessionID(rawValue: "S4")])
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
        _ = coach.reduce(&state, .ask("is this pack worth it?"))
        #expect(actions(coach.reduce(&state, .saveWritten(try snap("06-shop-reroll")))).isEmpty)
        let question = starts(coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89]))))
        #expect(question.map(\.message.text) == ["PLAYER QUESTION: is this pack worth it?"])
        #expect(starts(coach.reduce(&state, done(2, "S2"))).first?.message.text.contains("$95.") == true)
    }

    @Test func nothingStartsOnItsOwnAfterAFailure() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, done(0, "S0"))
        _ = asking(&state, "why keep the 6?")
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(starts(coach.reduce(&state, .turnOutput(TurnID(2), .failed(.rateLimited(resetsAt: nil))))).isEmpty)
        #expect(starts(looking(&state, coach.reduce(&state, .retry))).map(\.message.text) == ["PLAYER QUESTION: why keep the 6?"])
        #expect(starts(coach.reduce(&state, done(4, "S4"))).first?.message.text.contains("discards 3") == true)
    }

    @Test func aQuestionLooksAtTheScreenAtOnce() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        _ = coach.reduce(&state, done(0, "S0"))
        #expect(coach.reduce(&state, .ask("is this pack worth it?")) == [.captureGameWindow(CaptureID(1), after: .zero)])
    }

    @Test func deletedSaveEndsTheRun() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(actions(coach.reduce(&state, .saveRemoved(profile: 1))) == [.cancelTurn(TurnID(0)), .readProgress(after: coach.progressSettleDelay)])
        #expect(state.view.status == .waitingForRun)
        #expect(asking(&state, "hello?").isEmpty)
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
        _ = asking(&state, "why the 7?")
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "", changedSteps: false)])
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .text("It pairs")))
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "It pairs", changedSteps: false)])
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("It pairs with nothing.", SessionID(rawValue: "S1"))))
        _ = asking(&state, "and the King?")
        _ = coach.reduce(&state, .turnOutput(TurnID(4), .done("Keep it.", SessionID(rawValue: "S2"))))

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
        _ = asking(&state, "keep the 7?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done(
            "Yes, I missed the straight.\n\n**Do this now:**\n1. Play 7♠ 6♠ 5♠ 4♠ 3♠.\n\n**Why:**\n- It beats the blind.",
            SessionID(rawValue: "S1"))))

        #expect(state.view.advice?.doNow == ["Play 7♠ 6♠ 5♠ 4♠ 3♠."])
        #expect(state.view.advice?.why == ["It beats the blind."])
        #expect(state.view.advice?.lesson?.title == "Discards are free")
        #expect(state.view.thread == [.init(question: "keep the 7?", reply: "Yes, I missed the straight.", changedSteps: true)])
    }

    @Test func replyInTheDecisionShapeWithoutNewStepsStillShowsItsReason() throws {
        var state = try stateWithPlan()
        _ = asking(&state, "why the 7?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("**Why:**\n- No pair.\n- No flush.", SessionID(rawValue: "S1"))))

        #expect(state.view.advice?.why == ["It pairs with nothing."])
        #expect(state.view.thread == [.init(question: "why the 7?", reply: "No pair. No flush.", changedSteps: false)])
    }

    @Test func nextDecisionClearsTheThread() throws {
        var state = try stateWithPlan()
        _ = asking(&state, "why the 7?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("No pair.", SessionID(rawValue: "S1"))))
        _ = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        #expect(state.view.thread.isEmpty)
        #expect(state.view.advice == nil)

        _ = coach.reduce(&state, .turnOutput(TurnID(3), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S2"))))
        #expect(state.view.thread.isEmpty)
        #expect(state.view.advice?.doNow == ["Play."])
    }

    @Test func failedQuestionStaysOnScreenForTheRetry() throws {
        var state = try stateWithPlan()
        _ = asking(&state, "why the 7?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .failed(.notLoggedIn)))
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
        _ = asking(&state, "why?")
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

    /// A run whose one completed turn, on 02-hand, ended in session S0 on `machine`, as `RunStore` loads it.
    func runCoached(on machine: String?) throws -> RunRecord {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let effects = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play the pair.", SessionID(rawValue: "S0"))))
        var record = try #require(effects.compactMap { effect -> RunRecord? in if case .save(let record) = effect { record } else { nil } }.last)
        record.headMachine = machine.map(MachineID.init)
        return record
    }

    /// Opens Balabro on `record` and asks a question about the save it was coached on.
    func asking(_ question: String, after record: RunRecord, _ state: inout CoachState) throws -> [TurnRequest] {
        state = CoachState(restoring: [record])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        return starts(asking(&state, question))
    }

    let pairRetold = """
        THE RUN SO FAR. This run was coached on the player's other computer, and that conversation isn't here. \
        These are your answers from it, oldest first. Carry on from them.

        Ante 1 · bl_small. You advised:
        **Do this now:**
        1. Play the pair.

        PLAYER QUESTION: why the pair?
        """

    @Test func aSessionMadeOnThisComputerIsResumed() throws {
        var state = CoachState(restoring: [])
        let turns = try asking("why the pair?", after: runCoached(on: "mac"), &state)
        #expect(turns.map(\.forkFrom) == [SessionID(rawValue: "S0")])
        #expect(turns.map(\.message.text) == ["PLAYER QUESTION: why the pair?"])
    }

    @Test func aRunFromBeforeSyncingIsResumedAsBefore() throws {
        var state = CoachState(restoring: [])
        let turns = try asking("why the pair?", after: runCoached(on: nil), &state)
        #expect(turns.map(\.forkFrom) == [SessionID(rawValue: "S0")])
        #expect(turns.map(\.message.text) == ["PLAYER QUESTION: why the pair?"])
    }

    @Test func aSessionMadeOnAnotherComputerStartsAfreshWithTheRunSoFar() throws {
        var state = CoachState(restoring: [])
        let turns = try asking("why the pair?", after: runCoached(on: "pc"), &state)
        #expect(turns.map(\.forkFrom) == [nil])
        #expect(turns.map(\.message.text) == [pairRetold])
    }

    @Test func aFreshConversationIsNotToldTheRulesChanged() throws {
        var state = CoachState(restoring: [])
        var here = try runCoached(on: "mac"), there = try runCoached(on: "pc")
        (here.rules, there.rules) = (nil, nil)
        #expect(try asking("why the pair?", after: here, &state).map { $0.message.text.hasPrefix(rulesNotice) } == [true])
        #expect(try asking("why the pair?", after: there, &state).map(\.message.text) == [pairRetold])
    }

    @Test func theFreshConversationBecomesThisComputers() throws {
        var state = CoachState(restoring: [])
        _ = try asking("why the pair?", after: runCoached(on: "pc"), &state)
        let saved = coach.reduce(&state, .turnOutput(TurnID(1), .done("It's the best hand.", SessionID(rawValue: "S1"))))
        let record = try #require(saved.compactMap { effect -> RunRecord? in if case .save(let record) = effect { record } else { nil } }.last)
        #expect(record.head == SessionID(rawValue: "S1"))
        #expect(record.headMachine == MachineID(rawValue: "mac"))
        let next = starts(asking(&state, "and then?"))
        #expect(next.map(\.forkFrom) == [SessionID(rawValue: "S1")])
        #expect(next.map(\.message.text) == ["PLAYER QUESTION: and then?"])
    }

    @Test func aLongRunRetellsOnlyItsNewestAnswers() throws {
        var state = CoachState(restoring: [])
        var record = try runCoached(on: "pc")
        let (a, b, c) = (String(repeating: "a", count: 5000), String(repeating: "b", count: 5000), String(repeating: "c", count: 5000))
        record.transcript = try JSONDecoder().decode([Exchange].self, from: Data("""
            [{"title":"Shop","advice":"\(a)"},{"title":"Blind","advice":"\(b)"},{"title":"why?","advice":"\(c)","isQuestion":true}]
            """.utf8))
        let turns = try asking("and now?", after: record, &state)
        #expect(turns.map(\.message.text) == ["""
            THE RUN SO FAR. This run was coached on the player's other computer, and that conversation isn't here. \
            These are your answers from it, oldest first, leaving out the 1 before them. Carry on from them.

            Blind. You advised:
            \(b)

            The player asked: why?
            You replied:
            \(c)

            PLAYER QUESTION: and now?
            """])
    }

    @Test func replyWithNewStepsReplacesTheGoal() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Discard.\n\n**Goal:** Going for a Straight", SessionID(rawValue: "S0"))))
        _ = asking(&state, "why?")
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("Because.", SessionID(rawValue: "S1"))))
        #expect(state.view.advice?.goal == "Going for a Straight")
        _ = asking(&state, "flush instead?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("Yes.\n\n**Do this now:**\n1. Keep hearts.\n\n**Goal:** Going for a Flush", SessionID(rawValue: "S2"))))
        #expect(state.view.advice?.goal == "Going for a Flush")
    }

    @Test func replyWithNewStepsDropsTheOldScore() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done(
            "**Do this now:**\n1. Play K♥ K♣.\n\n**Score:**\n- Pair: 30 x 2 = 60", SessionID(rawValue: "S0"))))
        #expect(state.view.advice?.score == [.init(label: "Pair", sum: .init(chips: "30", mult: "2", total: "60"))])
        _ = asking(&state, "discard instead?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .done("Yes.\n\n**Do this now:**\n1. Discard 7♠.", SessionID(rawValue: "S1"))))
        #expect(state.view.advice?.score == [])
    }

    @Test func waitingNamesTheDecisionUntilTheFirstWordsArrive() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("05-shop")))
        #expect(state.view.waitingOn == .shop)
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .text("**Do")))
        #expect(state.view.waitingOn == nil)
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Leave.", SessionID(rawValue: "S0"))))
        _ = asking(&state, "why?")
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

    @Test func aQuestionAskedWhileBusyStillLooksAtTheScreen() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .ask("why?"))
        #expect(actions(coach.reduce(&state, done(0, "S0"))) == [.captureGameWindow(CaptureID(1), after: .zero)])
        #expect(starts(coach.reduce(&state, .screenshot(CaptureID(1), png: Data([0x89])))).map(\.message.screenshotPNG) == [Data([0x89])])
    }

    @Test func aRetriedQuestionLooksAtTheScreenAgain() throws {
        var state = try stateWithPlan()
        _ = asking(&state, "why?")
        _ = coach.reduce(&state, .turnOutput(TurnID(2), .failed(.notLoggedIn)))
        #expect(actions(coach.reduce(&state, .retry)) == [.captureGameWindow(CaptureID(3), after: .zero)])
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
        _ = asking(&state, "why?")
        _ = coach.reduce(&state, .saveWritten(try bossSelect()))
        #expect(state.view.status == .thinking)
        let after = coach.reduce(&state, .turnOutput(TurnID(2), .done("because", SessionID(rawValue: "S1"))))
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

    /// Fixture 10 plays a High Card that scores 15 in fixture 11. Returns what the shop's turn is told.
    func shopMessageAfterPlaying(_ scoreLine: String) throws -> String {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play K♥.\n\n**Score:**\n- \(scoreLine)", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .saveWritten(try snap("11-round-eval")))
        return try #require(sentMessages(coach.reduce(&state, .saveWritten(try snap("12-shop")))).first)
    }

    @Test func aWrongScoreIsPointedOutInTheNextTurn() throws {
        #expect(try shopMessageAfterPlaying("High Card: 20 x 3 = 60").contains("said 20 x 3 = 60. It scored 15."))
    }

    @Test(arguments: ["High Card: 15 x 1 = 15", "Pair of Kings: 20 x 3 = 60", "High Card, if you draw it: 20 x 3 = 60"])
    func noCheckWhenTheScoreWasRightOrThatHandWasNotPlayed(scoreLine: String) throws {
        #expect(try !shopMessageAfterPlaying(scoreLine).contains("SCORE CHECK"))
    }

    @Test func theScoreCheckIsSentOnce() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Score:**\n- High Card: 20 x 3 = 60", SessionID(rawValue: "S0"))))
        _ = coach.reduce(&state, .saveWritten(try snap("11-round-eval")))
        _ = coach.reduce(&state, .saveWritten(try snap("12-shop")))
        _ = coach.reduce(&state, .turnOutput(TurnID(1), .done("advice", SessionID(rawValue: "S1"))))
        let next = sentMessages(asking(&state, "why?"))
        #expect(next.count == 1 && !next[0].contains("SCORE CHECK"))
    }

    @Test func missedAndMatchedScoresAreCounted() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Score:**\n- High Card: 20 x 3 = 60", SessionID(rawValue: "S0"))))
        let missed = coach.reduce(&state, .saveWritten(try snap("11-round-eval")))
        #expect(savedTallies(missed) == [PredictionTally(matched: 0, missed: 1)])

        state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("10-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Score:**\n- High Card: 15 x 1 = 15", SessionID(rawValue: "S0"))))
        let matched = coach.reduce(&state, .saveWritten(try snap("11-round-eval")))
        #expect(savedTallies(matched) == [PredictionTally(matched: 1, missed: 0)])
    }

    func savedTallies(_ effects: [CoachEffect]) -> [PredictionTally?] {
        effects.compactMap { if case .save(let record) = $0 { record.predictions } else { nil } }
    }

    var scoringCoach: Coach { Coach(text: .missing, machine: MachineID(rawValue: "mac"), scoreWait: .seconds(8)) }

    func scoreRequests(_ effects: [CoachEffect]) -> [ScoreID] {
        effects.compactMap { if case .scoreSave(let id, _, _) = $0 { id } else { nil } }
    }

    @Test func aHandWaitsForExactScoresAndTheyGoInThePrompt() throws {
        var state = CoachState(restoring: [])
        let asked = scoringCoach.reduce(&state, .saveWritten(try snap("02-hand")))
        #expect(starts(asked).isEmpty)
        #expect(asked.contains(.scoreSave(ScoreID(0), profile: 1, within: .seconds(8))))
        #expect(state.view.status == .thinking)
        let turn = try #require(starts(scoringCoach.reduce(&state, .scored(ScoreID(0), facts: "EXACT SCORES: Pair is 60."))).first)
        #expect(turn.message.text.hasSuffix("\n\nEXACT SCORES: Pair is 60."))
    }

    @Test func theCoachCarriesOnWithoutExactScores() throws {
        var state = CoachState(restoring: [])
        _ = scoringCoach.reduce(&state, .saveWritten(try snap("02-hand")))
        let turn = try #require(starts(scoringCoach.reduce(&state, .scored(ScoreID(0), facts: nil))).first)
        #expect(!turn.message.text.contains("EXACT SCORES"))
    }

    @Test func scoresForABoardThatMovedOnAreDropped() throws {
        var state = CoachState(restoring: [])
        _ = scoringCoach.reduce(&state, .saveWritten(try snap("02-hand")))
        let newer = scoringCoach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
        let id = try #require(scoreRequests(newer).first)
        #expect(id != ScoreID(0))
        #expect(scoringCoach.reduce(&state, .scored(ScoreID(0), facts: "EXACT SCORES: old")).isEmpty)
        let turn = try #require(starts(scoringCoach.reduce(&state, .scored(id, facts: "EXACT SCORES: new"))).first)
        #expect(turn.message.text.contains("EXACT SCORES: new") && !turn.message.text.contains("EXACT SCORES: old"))
    }

    @Test func aPackIsScoredBeforeItsScreenshot() throws {
        var state = CoachState(restoring: [])
        let asked = scoringCoach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        let id = try #require(scoreRequests(asked).first)
        let next = scoringCoach.reduce(&state, .scored(id, facts: "Score check: adding Joker."))
        guard case .captureGameWindow(let capture, _)? = next.first else {
            Issue.record("expected a screenshot, got \(next)")
            return
        }
        let turn = try #require(starts(scoringCoach.reduce(&state, .screenshot(capture, png: Data([1])))).first)
        #expect(turn.message.text.contains("Score check: adding Joker."))
    }

    func tagPack() throws -> RunSnapshot { try SaveFile.decode(Fixture.save("09-blind-select", holdingTags: ["tag_buffoon"]), profile: 1) }
    let packOf2: [ShopItem.Card] = [
        .consumable(Consumable(key: CenterKey(rawValue: "c_mercury"), edition: .negative)),
        .consumable(Consumable(key: CenterKey(rawValue: "c_saturn"))),
    ]

    @Test func aTagsPackIsReadFromAReloadAndWaitsLongerForIt() throws {
        var state = CoachState(restoring: [])
        let asked = scoringCoach.reduce(&state, .saveWritten(try tagPack()))
        #expect(asked.contains(.scoreSave(ScoreID(0), profile: 1, within: .seconds(40))))
    }

    @Test func aPackInItsOwnStateCantBeReloaded() throws {
        var snapshot = try tagPack()
        snapshot.phase = .pack(.buffoon)
        var state = CoachState(restoring: [])
        #expect(scoreRequests(scoringCoach.reduce(&state, .saveWritten(snapshot))).isEmpty)
    }

    @Test func aPackWithNamedCardsSkipsTheScreenshot() throws {
        var state = CoachState(restoring: [])
        _ = scoringCoach.reduce(&state, .saveWritten(try tagPack()))
        let turn = try #require(starts(scoringCoach.reduce(&state, .scored(ScoreID(0), facts: "Score check.", packCards: packOf2))).first)
        #expect(turn.message.screenshotPNG == nil)
        #expect(turn.message.text.contains("left to right, read from the game:\n1. c_mercury (Negative)\n2. c_saturn\n\nScore check."))
        #expect(!turn.message.text.contains("screenshot"))
    }

    @Test func aPackThatCouldntBeNamedSaysSoWithItsScreenshot() throws {
        var state = CoachState(restoring: [])
        _ = scoringCoach.reduce(&state, .saveWritten(try tagPack()))
        let capture = scoringCoach.reduce(&state, .scored(ScoreID(0), facts: nil))
        #expect(capture == [.captureGameWindow(CaptureID(1), after: .milliseconds(3500))])
        let turn = try #require(starts(scoringCoach.reduce(&state, .screenshot(CaptureID(1), png: Data([1])))).first)
        #expect(turn.message.text.hasSuffix("The game couldn't name them."))
    }

    @Test func aBlindSelectHasNothingToScore() throws {
        var state = CoachState(restoring: [])
        let effects = scoringCoach.reduce(&state, .saveWritten(try snap("01-blind-select")))
        #expect(scoreRequests(effects).isEmpty)
        #expect(starts(effects).count == 1)
    }

    @Test func aSavePreparesTheScorerSoTheFirstHandIsntLeftWaiting() throws {
        var state = CoachState(restoring: [])
        #expect(scoringCoach.reduce(&state, .saveWritten(try snap("01-blind-select"))).contains(.warmScorer))
        state = CoachState(restoring: [])
        #expect(!coach.reduce(&state, .saveWritten(try snap("01-blind-select"))).contains(.warmScorer))
    }

    func saveHoldingABestHandOfNaneinf() throws -> RunSnapshot {
        let text = Fixture.saveText("02-hand").replacingOccurrences(of: #"["hand"]={["amt"]=0,"#, with: #"["hand"]={["amt"]=inf,"#)
        return try SaveFile.decode(Data(text.utf8), profile: 1)
    }

    @Test func switchingGoalRedoesTheCurrentDecision() throws {
        var state = CoachState(restoring: [])
        let first = try #require(starts(coach.reduce(&state, .saveWritten(try snap("02-hand")))).first)
        #expect(first.message.text.hasPrefix("DECISION: play or discard"))

        let on = coach.reduce(&state, .setGoal(.naneinf))
        #expect(on.contains(.cancelTurn(first.id)))
        #expect(try #require(starts(on).first).message.text.hasPrefix("GOAL: naneinf. Best hand this run: 0.\nDECISION: play or discard"))
        #expect(state.view.goal == .naneinf)
        #expect(coach.reduce(&state, .setGoal(.naneinf)).isEmpty)

        let off = coach.reduce(&state, .setGoal(.win))
        #expect(try #require(starts(off).first).message.text.hasPrefix("DECISION: play or discard"))
    }

    @Test func switchingGoalWaitsForAQuestion() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))
        let question = try #require(starts(asking(&state, "why?")).first)

        #expect(coach.reduce(&state, .setGoal(.naneinf)).isEmpty)
        let after = coach.reduce(&state, .turnOutput(question.id, .done("Because.", SessionID(rawValue: "S1"))))
        #expect(try #require(starts(after).first).message.text.hasPrefix("GOAL: naneinf."))
    }

    @Test func aRestartOnTheSameGoalDoesNotCoachTheSameDecisionAgain() throws {
        var state = CoachState(restoring: [], goal: .naneinf)
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let done = coach.reduce(&state, .turnOutput(TurnID(0), .done("**Do this now:**\n1. Play.", SessionID(rawValue: "S0"))))
        let record = try #require(done.compactMap { if case .save(let r) = $0 { r } else { nil } }.first)

        var restarted = CoachState(restoring: [record], goal: .naneinf)
        #expect(starts(coach.reduce(&restarted, .saveWritten(try snap("02-hand")))).isEmpty)
    }

    @Test func aWinWhileChasingNaneinfPointsToEndlessMode() throws {
        var state = CoachState(restoring: [], goal: .naneinf)
        #expect(actions(coach.reduce(&state, .saveWritten(try wonSave()))) == [.readProgress(after: coach.progressSettleDelay)])
        #expect(starts(coach.reduce(&state, .progressRead(progress))).isEmpty)
        #expect(state.view.headline == "You won")
        #expect(state.view.advice?.doNow == ["Choose Endless Mode."])
    }

    @Test func switchingGoalRedoesTheNextRunAdvice() throws {
        var state = CoachState(restoring: [])
        let advice = try #require(starts(coach.reduce(&state, .progressRead(progress))).first)
        #expect(!advice.message.text.contains("naneinf"))

        #expect(coach.reduce(&state, .setGoal(.naneinf)) == [.cancelTurn(advice.id), .readProgress(after: .zero)])
        let redone = try #require(starts(coach.reduce(&state, .progressRead(progress))).first)
        #expect(redone.message.text.contains("The player wants to score naneinf"))

        _ = coach.reduce(&state, .turnOutput(redone.id, .done("**Do this now:**\n1. Start.", SessionID(rawValue: "N"))))
        #expect(coach.reduce(&state, .setGoal(.win)) == [.readProgress(after: .zero)])
        #expect(state.view.advice == nil)
    }

    @Test func aRunWithABestHandOfNaneinfKeepsSaving() throws {
        var state = CoachState(restoring: [], goal: .naneinf)
        let effects = coach.reduce(&state, .saveWritten(try saveHoldingABestHandOfNaneinf()))
        #expect(try #require(starts(effects).first).message.text.hasPrefix("GOAL: naneinf. Best hand this run: naneinf."))

        let record = try #require(effects.compactMap { if case .save(let r) = $0 { r } else { nil } }.first)
        #expect(try RunRecord(json: record.json()).summary?.bestHand == .infinity)
    }
}
