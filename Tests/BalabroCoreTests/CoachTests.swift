import BalabroCore
import Foundation
import Testing

/// The coaching policy, event by event, through `Coach.reduce` only.
@Suite(.disabled("sketch: bodies not implemented"))
struct CoachTests {
    let coach = Coach(text: .missing)
    func snap(_ name: String) throws -> RunSnapshot { try SaveFile.decode(Fixture.save(name), profile: 1) }
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
}
