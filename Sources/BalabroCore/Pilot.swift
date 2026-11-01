import Foundation

/// "Play for me" as a pure state machine, the same pattern as `Coach` but not the same machine: the bot in the game
/// owns the moves, and this owns the conversation with Claude, the clock and the result.
///
/// - At most one question is open. An answer can only close the open question, so a late answer is dropped.
/// - Every failed attempt forks from the same `head`, so a bad reply leaves no trace in the conversation.
/// - A question gets one retry, then the bot moves on without spending. Two such questions in a row stop the run, and
///   so does anything another try can't fix, such as a usage limit.
/// - Stop, the game exiting and an ending can all arrive in any order. The first records the result.
public struct Pilot: Sendable {
    public static let systemPrompt = Prompt.pilotSystem
    /// Over five runs each, the typical best hand went from about 15,000 to 38,000, for under a second more per decision.
    public static let effort = "xhigh"

    public let text: GameText
    /// Long enough for a slow plan, short enough that a hung turn can't eat a run.
    public var turnTimeout: Duration = .seconds(90)

    public init(text: GameText) { self.text = text }

    public func reduce(_ state: inout PilotState, _ event: PilotEvent) -> [PilotEffect] {
        switch event {
        case .start(let setup):
            guard !state.isRunning else { return [] }
            state.phase = .running(Flight(setup: setup))
            return [.launch(setup)]
        case .dismiss:
            guard case .finished = state.phase else { return [] }
            state.phase = .idle
            return []
        case .stop:
            return finish(&state, at: state.now, ending: .stopped)
        case .bot(let frame, let at):
            state.now = at
            return bot(frame, at: at, &state)
        case .botExited(let status, let at):
            state.now = at
            return finish(&state, at: at, ending: .failed("The game closed before the run ended (status \(status))."))
        case .decisionRead(let id, let result, let packCards):
            return decisionRead(id, result, packCards: packCards, &state)
        case .turnOutput(let id, let output):
            return turnOutput(id, output, &state)
        case .timedOut(let id):
            guard case .running(let flight) = state.phase, flight.question?.turn == id else { return [] }
            return retryOrMoveOn(&state, reason: "no answer after \(turnTimeout.components.seconds) s", feedback: nil, cancel: id)
        }
    }

    private func bot(_ frame: BotFrame, at: Date, _ state: inout PilotState) -> [PilotEffect] {
        guard case .running(var flight) = state.phase else { return [] }
        defer { if case .running = state.phase { state.phase = .running(flight) } }
        switch frame {
        case .ready(let version):
            flight.startedAt = at
            flight.gameVersion = version
        case .status(let status):
            flight.status = status
        case .decide(let id, let ask, let file, let brief):
            flight.question = OpenQuestion(id: id, ask: ask, brief: brief)
            return [.readDecision(id, file: file)]
        case .refused(_, let move, let reason):
            flight.refused.append("\(move) (\(reason))")
        case .played(_, let predicted, let actual):
            if let predicted {
                flight.predictionsChecked += 1
                if abs(actual - predicted) > abs(actual) * 1e-9 && !actual.isInfinite { flight.predictionsMissed += 1 }
            }
        case .ended(let ending):
            flight.status?.bestHand = ending.bestHand
            flight.status?.ante = ending.ante
            flight.status?.round = ending.round
            state.phase = .running(flight)
            let result: PilotResult.Ending = switch ending.outcome {
            case .won: .won
            case .naneinf: .naneinf
            case .lost: .lost
            }
            return finish(&state, at: at, ending: result)
        case .broken(let kind, let detail):
            state.phase = .running(flight)
            return finish(&state, at: at, ending: .failed(Self.explain(kind: kind, detail: detail)))
        }
        return []
    }

    private func decisionRead(_ id: QuestionID, _ result: Result<RunSnapshot, SaveFileError>, packCards: [ShopItem.Card], _ state: inout PilotState) -> [PilotEffect] {
        guard case .running(var flight) = state.phase, var question = flight.question, question.id == id else { return [] }
        guard case .success(let snapshot) = result else {
            return finish(&state, at: state.now, ending: .failed("Balabro couldn't read the bot's save, so the game may have changed."))
        }
        let asked: PilotQuestion = switch question.ask {
        case .shop: .shop
        case .blind: .blind
        case .hand: .hand
        case .pack(let picks): .pack(packCards, picks: picks)
        }
        question.prompt = Prompt.pilotDecision(asked, snapshot, text, goal: flight.setup.goal, refused: flight.refused) + "\n" + question.brief
        flight.refused = []
        flight.question = question
        state.phase = .running(flight)
        return startTurn(&state, text: question.prompt)
    }

    private func startTurn(_ state: inout PilotState, text: String) -> [PilotEffect] {
        guard case .running(var flight) = state.phase, var question = flight.question else { return [] }
        let id = TurnID(state.nextTurn)
        state.nextTurn += 1
        question.turn = id
        question.partial = ""
        flight.question = question
        state.phase = .running(flight)
        return [.startTurn(TurnRequest(id: id, forkFrom: flight.head, message: UserMessage(text: text))), .armTimeout(id, after: turnTimeout)]
    }

    private func turnOutput(_ id: TurnID, _ output: TurnOutput, _ state: inout PilotState) -> [PilotEffect] {
        guard case .running(var flight) = state.phase, var question = flight.question, question.turn == id else { return [] }
        switch output {
        case .started:
            return []
        case .text(let chunk):
            question.partial += chunk
            flight.question = question
            flight.why = Plan.partialWhy(question.partial) ?? flight.why
            state.phase = .running(flight)
            return []
        case .done(let answer, let session):
            switch Plan.parse(answer) {
            case .success(let plan):
                flight.head = session
                flight.failuresInARow = 0
                flight.why = plan.why
                flight.question = nil
                state.phase = .running(flight)
                return [.tell(plan.line(question: question.id))]
            case .failure(let problem):
                return retryOrMoveOn(&state, reason: "its reply had the line \"\(problem.line)\"", feedback: problem.feedback, cancel: nil)
            }
        case .failed(let failure):
            switch failure {
            case .notLoggedIn: return finish(&state, at: state.now, ending: .failed("Claude isn't logged in."))
            case .rateLimited: return finish(&state, at: state.now, ending: .failed("Claude's usage limit was reached."))
            case .cliNotFound: return finish(&state, at: state.now, ending: .failed("The claude command wasn't found."))
            case .exited(let status, let tail): return retryOrMoveOn(&state, reason: "claude exited with status \(status): \(tail)", feedback: nil, cancel: nil)
            case .malformedOutput: return retryOrMoveOn(&state, reason: "claude's output couldn't be read", feedback: nil, cancel: nil)
            }
        }
    }

    private func retryOrMoveOn(_ state: inout PilotState, reason: String, feedback: String?, cancel: TurnID?) -> [PilotEffect] {
        guard case .running(var flight) = state.phase, var question = flight.question else { return [] }
        let cancelling: [PilotEffect] = cancel.map { [.cancelTurn($0)] } ?? []
        if question.attempts == 0 {
            question.attempts = 1
            flight.question = question
            state.phase = .running(flight)
            return cancelling + startTurn(&state, text: feedback.map { question.prompt + "\n\n" + $0 } ?? question.prompt)
        }
        flight.failuresInARow += 1
        if flight.failuresInARow >= 2 {
            state.phase = .running(flight)
            return cancelling + finish(&state, at: state.now, ending: .failed("Claude failed on two decisions in a row. Last time: \(reason)."))
        }
        flight.why = Plan.moveOn.why
        flight.question = nil
        state.phase = .running(flight)
        return cancelling + [.tell(Plan.moveOn.line(question: question.id))]
    }

    private func finish(_ state: inout PilotState, at: Date, ending: PilotResult.Ending) -> [PilotEffect] {
        guard case .running(let flight) = state.phase else { return [] }
        let result = PilotResult(
            goal: flight.setup.goal.rawValue, deck: flight.setup.deck, stake: flight.setup.stake, ending: ending,
            ante: flight.status?.ante ?? 1, round: flight.status?.round ?? 0, bestHand: flight.status?.bestHand ?? 0,
            seconds: flight.startedAt.map { at.timeIntervalSince($0) } ?? 0, gameVersion: flight.gameVersion ?? "", finishedAt: at)
        state.results.append(result)
        state.phase = .finished(result)
        return (flight.question?.turn.map { [.cancelTurn($0)] } ?? []) + [.kill, .record(result)]
    }

    private static func explain(kind: String, detail: String) -> String {
        switch kind {
        case "gameChanged": "Balatro has changed, and the bot needs updating: \(detail)."
        case "stuck": "The game stopped responding while waiting for \(detail)."
        case "rehearsalLeak": "The bot's scoring check changed the game (\(detail)), so it stopped rather than play an unfair run."
        default: "The bot crashed: \(detail)"
        }
    }
}

/// No seed anywhere: the game picks a random one, because a known seed wouldn't be fair play.
public struct PilotSetup: Sendable, Hashable {
    public var goal: CoachGoal
    public var deck: CenterKey
    public var stake: Int

    /// Plasma Deck balances chips and Mult, which squares a score, so it's the deck that can reach naneinf.
    public static func standard(for goal: CoachGoal) -> PilotSetup {
        PilotSetup(goal: goal, deck: CenterKey(rawValue: goal == .naneinf ? "b_plasma" : "b_red"), stake: 1)
    }
}

public enum PilotQuestion: Sendable, Hashable {
    case shop, blind, hand
    case pack([ShopItem.Card], picks: Int)
}

public struct OpenQuestion: Sendable {
    var id: QuestionID
    var ask: BotAsk
    /// What the bot worked out in the game: the blinds' targets, and what each joker on offer would do.
    var brief: String
    var prompt = ""
    var turn: TurnID?
    var attempts = 0
    var partial = ""
}

public struct Flight: Sendable {
    var setup: PilotSetup
    var startedAt: Date?
    var gameVersion: String?
    var status: BotStatus?
    var why: String?
    /// The session after the last plan that parsed. It lasts only as long as the run, because a run can't resume.
    var head: SessionID?
    var question: OpenQuestion?
    var refused: [String] = []
    var failuresInARow = 0
    var predictionsChecked = 0
    var predictionsMissed = 0
}

public struct PilotState: Sendable {
    enum Phase: Sendable {
        case idle
        case running(Flight)
        case finished(PilotResult)
    }

    var phase = Phase.idle
    public var results: [PilotResult]
    var nextTurn = 0
    /// The last time the bot was heard from, for events that carry no time of their own.
    var now = Date.distantPast

    public init(restoring results: [PilotResult]) { self.results = results }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    public var view: PilotView {
        let best = bestTimes(in: results)
        switch phase {
        case .idle:
            return PilotView(status: .idle, bestTimes: best)
        case .finished(let result):
            return PilotView(status: .finished, result: result, bestTimes: best)
        case .running(let flight):
            let status: PilotView.Status = flight.startedAt == nil ? .preparing : flight.question != nil ? .askingClaude : .playing
            let warning = flight.predictionsMissed > 0
                ? "The score prediction missed \(flight.predictionsMissed) of \(flight.predictionsChecked) hands, so Balatro may have changed." : nil
            return PilotView(status: status, startedAt: flight.startedAt, goal: flight.setup.goal, run: flight.status, why: flight.why, bestTimes: best, warning: warning)
        }
    }
}

public enum PilotEvent: Sendable {
    case start(PilotSetup)
    case stop
    case dismiss
    /// `at` comes from the shell, so this stays pure.
    case bot(BotFrame, at: Date)
    case botExited(status: Int32, at: Date)
    case decisionRead(QuestionID, Result<RunSnapshot, SaveFileError>, packCards: [ShopItem.Card])
    case turnOutput(TurnID, TurnOutput)
    case timedOut(TurnID)
}

public enum PilotEffect: Sendable, Hashable {
    case launch(PilotSetup)
    case kill
    case tell(String)
    case readDecision(QuestionID, file: URL)
    case startTurn(TurnRequest)
    case cancelTurn(TurnID)
    case armTimeout(TurnID, after: Duration)
    case record(PilotResult)
}

/// One finished bot run. Kept apart from `RunRecord`, which feeds "Your stats", because those are the player's own runs.
public struct PilotResult: Sendable, Hashable, Codable {
    public enum Ending: Sendable, Hashable, Codable {
        case won, naneinf, lost, stopped
        case failed(String)
    }
    public var goal: String
    public var deck: CenterKey
    public var stake: Int
    public var ending: Ending
    public var ante: Int
    public var round: Int
    public var bestHand: Double
    public var seconds: Double
    public var gameVersion: String
    public var finishedAt: Date

    public init(goal: String, deck: CenterKey, stake: Int, ending: Ending, ante: Int, round: Int, bestHand: Double, seconds: Double, gameVersion: String, finishedAt: Date) {
        (self.goal, self.deck, self.stake, self.ending, self.ante, self.round) = (goal, deck, stake, ending, ante, round)
        (self.bestHand, self.seconds, self.gameVersion, self.finishedAt) = (bestHand, seconds, gameVersion, finishedAt)
    }
}

public struct BestTime: Sendable, Equatable {
    public var title: String
    public var seconds: Double

    public init(title: String, seconds: Double) { (self.title, self.seconds) = (title, seconds) }

    public var line: String { "\(title): \(PilotView.clock(seconds))" }
}

/// Only a win or a naneinf counts as a time, and each is best on its own.
public func bestTimes(in results: [PilotResult]) -> [BestTime] {
    func best(_ ending: PilotResult.Ending, _ title: String) -> BestTime? {
        results.filter { $0.ending == ending }.map(\.seconds).min().map { BestTime(title: title, seconds: $0) }
    }
    return [best(.won, "Fastest win"), best(.naneinf, "Fastest naneinf")].compactMap { $0 }
}

public struct PilotView: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable { case idle, preparing, playing, askingClaude, finished }
    public var status: Status
    /// The panel ticks from this, so no timer state exists.
    public var startedAt: Date?
    public var goal: CoachGoal = .win
    public var run: BotStatus?
    public var why: String?
    public var result: PilotResult?
    public var bestTimes: [BestTime] = []
    public var warning: String?

    public init(status: Status, startedAt: Date? = nil, goal: CoachGoal = .win, run: BotStatus? = nil, why: String? = nil, result: PilotResult? = nil, bestTimes: [BestTime] = [], warning: String? = nil) {
        (self.status, self.startedAt, self.goal, self.run, self.why) = (status, startedAt, goal, run, why)
        (self.result, self.bestTimes, self.warning) = (result, bestTimes, warning)
    }
}

extension PilotView {
    public var title: String {
        guard let result else { return goal == .naneinf ? "Chasing naneinf" : "Playing for you" }
        return switch result.ending {
        case .won: "Won"
        case .naneinf: "naneinf"
        case .lost: "Lost"
        case .stopped: "Stopped"
        case .failed: "Couldn't finish"
        }
    }

    /// Stands in for `run` until the bot reports its first status.
    public var startingLine: String? {
        guard status != .idle, run == nil, result == nil else { return nil }
        return status == .preparing ? "Opening the bot's own copy of the game" : "Starting the run"
    }

    public var choosingLine: String? { status == .askingClaude ? "Claude is choosing" : nil }

    /// The panel ticks a running clock from `startedAt` with this.
    public static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension BotStatus {
    public var bestHandText: String { Prompt.chips(bestHand) }
    public var lines: [String] { ["Ante \(ante), round \(round), $\(dollars)", "Best hand \(bestHandText)"] }
}

extension PilotResult {
    public var bestHandText: String { Prompt.chips(bestHand) }
    public var lines: [String] { ["Reached ante \(ante), round \(round)", "Best hand \(bestHandText)"] }
}
