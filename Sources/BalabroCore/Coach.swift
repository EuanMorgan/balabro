import Foundation

/// The whole coaching policy as a pure state machine: which saves start a turn, which are dropped,
/// when a run starts, what happens when the player moves on before Claude finishes, and when
/// to take a screenshot. The app shell feeds it events and performs the effects it returns.
///
/// Policy in one place, per the run's single conversation:
/// - At most one `claude` process at a time. `Activity` makes two impossible to represent.
/// - Every turn forks from `RunRecord.head`, the session after the last *completed* turn, and only
///   a completed turn moves `head`. So cancelling a turn, a crash mid-turn, or a quit leaves the
///   conversation exactly as it was. Nothing to repair, and every transition is safe to repeat.
/// - A new decision cancels an in-flight decision turn: its advice is about a board that no longer exists.
/// - A new decision never cancels a question the player typed. It waits, newest decision wins.
/// - Questions asked while Claude is busy are queued and joined, then run before any waiting decision.
public struct Coach: Sendable {
    public let text: GameText
    /// How long after a pack opens before the cards have finished flying in.
    public var packSettleDelay: Duration = .milliseconds(1800)
    /// A skip tag plays its own animation before the pack starts to open.
    public var tagPackSettleDelay: Duration = .milliseconds(3500)
    /// Claude says within seconds if the pack isn't up yet, so looking again costs little.
    public var packRetryDelay: Duration = .milliseconds(1500)
    public var maxPackLooks = 5
    /// The game writes `profile.jkr` at most every 5 s (`F_SAVE_TIMER`), so this waits for a run's result to reach it.
    public var progressSettleDelay: Duration = .seconds(6)
    /// How long a decision waits for exact scores before the coach does the sums itself. nil means there's no scorer.
    public var scoreWait: Duration?
    /// A pack waits longer, because without the reload its jokers have no names. A cold start of the scorer takes about 28 s.
    public var packScoreWait: Duration = .seconds(40)

    public init(text: GameText, scoreWait: Duration? = nil) { (self.text, self.scoreWait) = (text, scoreWait) }

    public func reduce(_ state: inout CoachState, _ event: CoachEvent) -> [CoachEffect] {
        switch event {
        case .saveWritten(let snapshot):
            var effects: [CoachEffect] = []
            let key = state.runKey(for: snapshot)
            if key != state.current {
                effects += state.abandonActivity()
                state.current = key
                (state.prediction, state.scoreNote) = (nil, nil)
            }
            var record = state.runs[key] ?? RunRecord(key: key, progress: snapshot.progress, head: nil, lastCoached: nil, transcript: [])
            if let outcome = state.prediction?.check(snapshot), outcome != .pending {
                state.prediction = nil
                if case .missed(let note) = outcome { state.scoreNote = note }
                record.predictions = (record.predictions ?? PredictionTally()).counting(outcome)
            }
            let justWon = snapshot.won && record.summary?.won != true
            record.progress = snapshot.progress
            record.summary = RunSummary(snapshot, previous: record.summary)
            if scoreWait != nil { effects.append(.warmScorer) }
            state.latestSnapshot = snapshot
            state.chipsNeeded = snapshot.phase == .selectingHand ? snapshot.blind.map { $0.target - snapshot.chipsScored } : nil
            if record != state.runs[key] {
                state.runs[key] = record
                effects.append(.save(record))
            }
            switch state.problem {
            case .noRun, .saveUnreadable: state.problem = nil
            default: break
            }
            guard let decision = decision(in: snapshot, state), decision.fingerprint != state.newestFingerprint else {
                return justWon ? effects + [.readProgress(after: progressSettleDelay)] : effects
            }
            return effects + consider(decision, &state)

        // The game deletes save.jkr on game over and when a new run replaces it.
        case .saveRemoved(let profile):
            guard state.current?.identity.profile == profile else { return [] }
            var effects = state.abandonActivity()
            if let key = state.current, var record = state.runs[key], record.summary != nil {
                record.summary?.ended = true
                state.runs[key] = record
                effects.append(.save(record))
            }
            state.current = nil
            state.latestSnapshot = nil
            state.chipsNeeded = nil
            state.nextRun = nil
            return effects + [.readProgress(after: progressSettleDelay)]

        case .saveUnreadable(_, let error):
            state.problem = .saveUnreadable(error)
            return []

        case .scored(let id, let facts, let packCards):
            guard case .scoring(id, let decision) = state.activity else { return [] }
            state.exactScores = facts
            state.packCards = packCards
            return afterScoring(decision, &state)

        case .screenshot(let id, let png):
            guard case .capturing(id, let purpose) = state.activity else { return [] }
            return start(purpose, screenshot: png, screenshotFailed: png == nil, &state)

        case .ask(let question):
            guard state.current != nil else {
                state.problem = .noRun
                return []
            }
            state.nextRun = nil
            guard case .idle = state.activity else {
                state.queuedQuestion = [state.queuedQuestion, question].compactMap { $0 }.joined(separator: "\n")
                return []
            }
            return begin(.question(question), &state)

        case .turnOutput(let id, let output):
            guard case .running(var turn) = state.activity, turn.id == id else { return [] }
            switch output {
            case .started:
                return []
            case .text(let delta):
                turn.partial += delta
                state.activity = .running(turn)
                return []
            case .done(let answer, let session):
                if case .nextRun = turn.purpose {
                    state.nextRun = answer
                    state.activity = .idle
                    return startNext(&state)
                }
                guard let key = state.current else { return [] }
                if turn.sawScreen, turn.purpose.canLookAgain, answer.contains(Prompt.packNotReady) {
                    // The session isn't kept, so this look leaves no trace in the conversation.
                    state.packLooks += 1
                    state.activity = .idle
                    if state.packLooks < maxPackLooks { return capture(turn.purpose, after: packRetryDelay, &state) }
                    return start(turn.purpose, packUnseen: true, &state)
                }
                if let decision = turn.purpose.decision {
                    state.prediction = ScorePrediction(advice: answer, at: decision.snapshot)
                } else if let snapshot = state.latestSnapshot, let prediction = ScorePrediction(advice: answer, at: snapshot) {
                    state.prediction = prediction
                }
                (state.scoreNote, state.exactScores) = (nil, nil)
                var record = state.runs[key]!
                record.head = session
                record.rules = Prompt.rulesVersion
                record.transcript.append(Exchange(title: turn.purpose.title, advice: answer, isQuestion: turn.purpose.isQuestion, sawScreen: turn.sawScreen))
                if let decision = turn.purpose.decision { record.lastCoached = decision.fingerprint }
                state.runs[key] = record
                state.activity = .idle
                return [.save(record)] + startNext(&state)
            // No automatic retry, and nothing queued starts: "not logged in" would fail again at once.
            case .failed(let failure):
                state.problem = .turnFailed(failure)
                state.retryable = turn.purpose
                state.activity = .idle
                return []
            }

        case .retry:
            guard case .idle = state.activity, let purpose = state.retryable else { return [] }
            return begin(purpose, &state)

        // The way out when the coach has missed a move or got stuck, so it overrides whatever is running.
        case .refresh:
            guard state.current != nil else {
                state.problem = .noRun
                return []
            }
            let effects: [CoachEffect] = if case .running(let turn) = state.activity { [.cancelTurn(turn.id)] } else { [] }
            return effects + begin(.refresh(state.latestSnapshot.flatMap { decision(in: $0, state) }), &state)

        case .setGoal(let goal):
            guard goal != state.goal else { return [] }
            state.goal = goal
            if let decision = state.latestSnapshot.flatMap({ decision(in: $0, state) }) { return consider(decision, &state) }
            // Advice on the next run depends on the goal, and nothing else is on screen to redo.
            if case .running(let turn) = state.activity, case .nextRun = turn.purpose {
                state.activity = .idle
                return [.cancelTurn(turn.id), .readProgress(after: .zero)]
            }
            guard state.nextRun != nil else { return [] }
            state.nextRun = nil
            return [.readProgress(after: .zero)]

        case .adviseNextRun:
            guard case .idle = state.activity, state.current == nil else { return [] }
            return [.readProgress(after: .zero)]

        // By now the player may have started another run or carried on into Endless Mode.
        case .progressRead(let progress):
            guard case .idle = state.activity, let progress else { return [] }
            let onWinScreen = state.latestSnapshot.map { $0.won && Decision.detect(in: $0, text: text) == nil } ?? false
            guard state.current == nil || onWinScreen else { return [] }
            if onWinScreen, state.goal == .naneinf, let key = state.current, var record = state.runs[key] {
                record.transcript.append(Exchange(title: "You won", advice: Prompt.keepGoing))
                state.runs[key] = record
                return [.save(record)]
            }
            return begin(.nextRun(prompt: Prompt.nextRun(progress, text, goal: state.goal)), &state)
        }
    }

    private func decision(in snapshot: RunSnapshot, _ state: CoachState) -> Decision? {
        Decision.detect(in: snapshot, text: text, goal: state.goal)
    }

    private func consider(_ decision: Decision, _ state: inout CoachState) -> [CoachEffect] {
        if state.activity.purpose?.isQuestion == true {
            state.waitingDecision = decision
            return []
        }
        let effects: [CoachEffect] = if case .running(let turn) = state.activity { [.cancelTurn(turn.id)] } else { [] }
        return effects + begin(.decision(decision), &state)
    }

    private func begin(_ purpose: CoachState.Purpose, _ state: inout CoachState) -> [CoachEffect] {
        state.nextRun = nil
        if case .decision(let decision) = purpose {
            state.waitingDecision = nil
            if let answer = decision.instantAnswer, let key = state.current, var record = state.runs[key] {
                record.transcript.append(Exchange(title: decision.title, advice: answer))
                record.lastCoached = decision.fingerprint
                state.runs[key] = record
                (state.activity, state.retryable, state.problem) = (.idle, nil, nil)
                return [.save(record)]
            }
            state.packLooks = 0
            (state.exactScores, state.packCards) = (nil, [])
            if let scoreWait, decision.canBeScored {
                let id = ScoreID(state.takeID())
                state.activity = .scoring(id, decision)
                return [.scoreSave(id, profile: decision.snapshot.identity.profile, within: decision.needsScreenshot ? packScoreWait : scoreWait)]
            }
            return afterScoring(decision, &state)
        }
        if case .refresh = purpose {
            state.waitingDecision = nil
            state.packLooks = 0
            return capture(purpose, after: .zero, &state)
        }
        // Moves inside a pack write no save, so the screen is the only way to know what the player has done.
        if case .question = purpose { return capture(purpose, after: .zero, &state) }
        return start(purpose, &state)
    }

    private func afterScoring(_ decision: Decision, _ state: inout CoachState) -> [CoachEffect] {
        if case .openPack(_, from: let source) = decision.kind, state.packCards.isEmpty {
            return capture(.decision(decision), after: source == .shop ? packSettleDelay : tagPackSettleDelay, &state)
        }
        return start(.decision(decision), &state)
    }

    private func capture(_ purpose: CoachState.Purpose, after delay: Duration, _ state: inout CoachState) -> [CoachEffect] {
        let id = CaptureID(state.takeID())
        state.activity = .capturing(id, purpose)
        return [.captureGameWindow(id, after: delay)]
    }

    private func start(
        _ purpose: CoachState.Purpose, screenshot: Data? = nil, screenshotFailed: Bool = false, packUnseen: Bool = false, _ state: inout CoachState
    ) -> [CoachEffect] {
        let record = state.current.flatMap { state.runs[$0] }
        if case .nextRun = purpose {} else if record == nil { return [] }
        let text = switch purpose {
        case .decision(let decision):
            [
                decision.prompt,
                state.packCards.isEmpty ? nil : Prompt.packCards(state.packCards, decision.snapshot, self.text),
                decision.needsScreenshot && screenshot != nil ? Prompt.packUnnamed : nil,
                state.exactScores,
                screenshotFailed || packUnseen ? Prompt.screenshotMissing : nil,
            ].compactMap { $0 }.joined(separator: "\n\n")
        case .question(let question): Prompt.question(question, packContentsUnknown: screenshotFailed)
        case .refresh(let decision):
            [decision?.prompt, Prompt.refresh, screenshotFailed || packUnseen ? Prompt.screenshotMissing : nil].compactMap { $0 }.joined(separator: "\n\n")
        case .nextRun(let prompt): prompt
        }
        // The next run's advice is a conversation of its own, because it isn't part of the run just played.
        let conversation = if case .nextRun = purpose { RunRecord?.none } else { record }
        let rules = conversation?.head != nil && conversation?.rules != Prompt.rulesVersion ? Prompt.rulesChanged : ""
        let note = conversation != nil ? state.scoreNote.map { $0 + "\n\n" } ?? "" : ""
        let id = TurnID(state.takeID())
        state.activity = .running(.init(id: id, purpose: purpose, partial: "", sawScreen: screenshot != nil))
        state.retryable = nil
        state.problem = screenshotFailed ? .screenRecordingDenied : nil
        return [.startTurn(TurnRequest(id: id, forkFrom: conversation?.head, message: UserMessage(text: rules + note + text, screenshotPNG: screenshot)))]
    }

    private func startNext(_ state: inout CoachState) -> [CoachEffect] {
        if let question = state.queuedQuestion {
            state.queuedQuestion = nil
            return begin(.question(question), &state)
        }
        if let decision = state.waitingDecision { return begin(.decision(decision), &state) }
        return []
    }
}

public struct CoachState: Sendable {
    var runs: [RunKey: RunRecord]
    var current: RunKey?
    var activity: Activity = .idle
    var waitingDecision: Decision?
    var queuedQuestion: String?
    var retryable: Purpose?
    var problem: Problem?
    var chipsNeeded: Double?
    /// The score the last steps gave for the hand they play, until a save shows what it really scored.
    var prediction: ScorePrediction?
    /// Set when that score was wrong. Goes with every turn until one completes, so a cancelled turn doesn't lose it.
    var scoreNote: String?
    /// The scorer's facts for the decision being coached.
    var exactScores: String?
    /// The open pack's cards, from the scorer's reload. Empty means only a screenshot can show them.
    var packCards: [ShopItem.Card] = []
    var latestSnapshot: RunSnapshot?
    /// Claude's advice on the next run, until a decision or question replaces it.
    var nextRun: String?
    var goal: CoachGoal
    var packLooks = 0
    var nextID = 0

    /// Starts from what `RunStore` saved. No in-flight state survives a restart, by design.
    public init(restoring records: [RunRecord], goal: CoachGoal = .win) {
        runs = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        self.goal = goal
    }

    /// Everything the overlay draws. Derived, never stored, so it can't drift from the state.
    public var view: CoachView {
        let status: CoachView.Status, partial: String, sawScreen: Bool
        switch activity {
        case .idle: (status, partial, sawScreen) = (current == nil ? .waitingForRun : .ready, "", false)
        case .scoring: (status, partial, sawScreen) = (.thinking, "", false)
        case .capturing: (status, partial, sawScreen) = (.lookingAtPack, "", true)
        case .running(let turn):
            // "PACK_NOT" is the start of asking for another look, not advice to show.
            let text = Prompt.packNotReady.hasPrefix(turn.partial) ? "" : turn.partial
            (status, partial, sawScreen) = (text.isEmpty ? .thinking : .answering, text, turn.sawScreen)
        }
        let canRetry = retryable != nil && activity.isIdle
        if let purpose = activity.purpose, !purpose.isQuestion {
            return CoachView(
                status: status, goal: goal, headline: purpose.title, chipsNeeded: chipsNeeded, waitingOn: partial.isEmpty ? purpose.waitingKind : nil,
                advice: partial.isEmpty ? nil : Advice(markdown: partial), sawScreen: sawScreen, thread: [],
                queuedQuestion: queuedQuestion, problem: problem, canRetry: canRetry)
        }
        if let nextRun {
            return CoachView(status: status, goal: goal, headline: Purpose.nextRunTitle, advice: Advice(markdown: nextRun), thread: [], queuedQuestion: queuedQuestion, problem: problem, canRetry: canRetry)
        }
        let history = current.flatMap { runs[$0] }?.transcript ?? []
        let planIndex = history.lastIndex { !$0.isQuestion }
        var plan = planIndex.map { Advice(markdown: history[$0].advice) }
        var thread = history[(planIndex.map { $0 + 1 } ?? 0)...].map { CoachView.FollowUp(question: $0.title, answer: $0.advice, plan: &plan) }
        if case .question(let question)? = activity.purpose ?? retryable {
            thread.append(CoachView.FollowUp(question: question, answer: partial, plan: &plan))
        }
        return CoachView(
            status: status,
            goal: goal,
            headline: planIndex.map { history[$0].title } ?? (current == nil ? "Start or continue a run" : "Waiting for your next move"),
            chipsNeeded: chipsNeeded, advice: plan, sawScreen: planIndex.map { history[$0].sawScreen } ?? false, thread: thread, queuedQuestion: queuedQuestion, problem: problem, canRetry: canRetry)
    }

    /// The decision this state last saw, so a duplicate write, or a reread after a restart, starts nothing.
    var newestFingerprint: Fingerprint? {
        activity.purpose?.decision?.fingerprint ?? waitingDecision?.fingerprint ?? retryable?.decision?.fingerprint
            ?? current.flatMap { runs[$0] }?.lastCoached
    }

    /// The newest run with this identity, unless a progress counter went backwards: then it's a replay of the seed.
    /// This is also how an app restart reattaches to its run.
    func runKey(for snapshot: RunSnapshot) -> RunKey {
        guard let latest = runs.values.filter({ $0.key.identity == snapshot.identity }).max(by: { $0.key.replay < $1.key.replay }) else {
            return RunKey(identity: snapshot.identity, replay: 0)
        }
        return snapshot.progress < latest.progress ? RunKey(identity: snapshot.identity, replay: latest.key.replay + 1) : latest.key
    }

    mutating func abandonActivity() -> [CoachEffect] {
        let effects: [CoachEffect] = if case .running(let turn) = activity { [.cancelTurn(turn.id)] } else { [] }
        activity = .idle
        waitingDecision = nil
        queuedQuestion = nil
        retryable = nil
        return effects
    }

    mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    enum Activity: Sendable {
        case idle
        case scoring(ScoreID, Decision)
        case capturing(CaptureID, Purpose)
        case running(Turn)

        var isIdle: Bool { purpose == nil }

        var purpose: Purpose? {
            switch self {
            case .idle: nil
            case .scoring(_, let decision): .decision(decision)
            case .capturing(_, let purpose): purpose
            case .running(let turn): turn.purpose
            }
        }
    }

    enum Purpose: Sendable, Hashable {
        case decision(Decision)
        case question(String)
        /// nil when the newest save isn't a decision the app recognises, so only the screenshot can say what's going on.
        case refresh(Decision?)
        case nextRun(prompt: String)

        static let nextRunTitle = "Your next run"

        var decision: Decision? {
            switch self {
            case .decision(let d), .refresh(let d?): d
            case .question, .refresh(nil), .nextRun: nil
            }
        }
        /// Picking a deck is closest to the cards being shuffled for a blind.
        var waitingKind: Decision.Kind? { if case .nextRun = self { .blindSelect } else { decision?.kind } }
        var isQuestion: Bool { if case .question = self { true } else { false } }
        var canLookAgain: Bool {
            switch self {
            case .decision(let d): d.needsScreenshot
            case .refresh: true
            case .question, .nextRun: false
            }
        }

        var title: String {
            switch self {
            case .decision(let d), .refresh(let d?): d.title
            case .question(let q): q
            case .refresh(nil): "What's on your screen"
            case .nextRun: Self.nextRunTitle
            }
        }
    }

    struct Turn: Sendable {
        var id: TurnID
        var purpose: Purpose
        var partial: String
        var sawScreen: Bool
    }
}

public enum CoachEvent: Sendable {
    case saveWritten(RunSnapshot)
    case saveRemoved(profile: Int)
    case saveUnreadable(profile: Int, SaveFileError)
    case scored(ScoreID, facts: String?, packCards: [ShopItem.Card] = [])
    case screenshot(CaptureID, png: Data?)
    case ask(String)
    case turnOutput(TurnID, TurnOutput)
    case retry
    case refresh
    case adviseNextRun
    case progressRead(PlayerProgress?)
    case setGoal(CoachGoal)
}

/// What the coach plays for. It lasts across runs, because reaching naneinf usually takes many.
public enum CoachGoal: String, Sendable {
    case win, naneinf
}

public enum CoachEffect: Sendable, Hashable {
    case startTurn(TurnRequest)
    /// Kill the process. Its forked session is simply never used again.
    case cancelTurn(TurnID)
    case warmScorer
    /// Answered by `.scored`, with nil if `within` runs out.
    case scoreSave(ScoreID, profile: Int, within: Duration)
    case captureGameWindow(CaptureID, after: Duration)
    case readProgress(after: Duration)
    case save(RunRecord)
}

public struct TurnID: Sendable, Hashable, Codable { public let value: Int; public init(_ value: Int) { self.value = value } }
public struct ScoreID: Sendable, Hashable { public let value: Int; public init(_ value: Int) { self.value = value } }
public struct CaptureID: Sendable, Hashable { public let value: Int; public init(_ value: Int) { self.value = value } }

public struct SessionID: RawRepresentable, Sendable, Hashable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One `claude -p` process.
public struct TurnRequest: Sendable, Hashable {
    public let id: TurnID
    /// nil on a run's first completed-turn-to-be: the CLI starts a new conversation.
    /// Otherwise `--resume <forkFrom> --fork-session`.
    public let forkFrom: SessionID?
    public let message: UserMessage

    public init(id: TurnID, forkFrom: SessionID?, message: UserMessage) {
        (self.id, self.forkFrom, self.message) = (id, forkFrom, message)
    }
}

public struct UserMessage: Sendable, Hashable {
    public var text: String
    /// Downscaled PNG of the Balatro window, sent as an image content block.
    public var screenshotPNG: Data?

    public init(text: String, screenshotPNG: Data? = nil) { (self.text, self.screenshotPNG) = (text, screenshotPNG) }
}

/// One run's coaching, as saved to `~/Library/Application Support/Balabro/runs/<key>.json`.
/// The only state that survives a restart. Written whole and atomically on every change.
public struct RunRecord: Sendable, Hashable, Codable {
    public let key: RunKey
    public var progress: ProgressClock
    /// The session after the last completed turn. The CLI holds the conversation; this points at it.
    public var head: SessionID?
    public var lastCoached: Fingerprint?
    /// Rebuilds the overlay's plan and follow-ups after a restart.
    public var transcript: [Exchange]
    /// nil for runs from before stats were recorded.
    public var summary: RunSummary?
    /// The version of `Prompt.system` this conversation has been told about.
    public var rules: Fingerprint?
    /// nil for runs from before this was counted.
    public var predictions: PredictionTally?
}

/// How the coach's Score lines held up against what the hands really scored.
public struct PredictionTally: Sendable, Hashable, Codable {
    public var matched = 0
    public var missed = 0

    public init(matched: Int = 0, missed: Int = 0) { (self.matched, self.missed) = (matched, missed) }

    func counting(_ outcome: ScorePrediction.Outcome) -> PredictionTally {
        var tally = self
        switch outcome {
        case .matched: tally.matched += 1
        case .missed: tally.missed += 1
        case .pending, .uncheckable: break
        }
        return tally
    }
}

extension RunRecord {
    /// JSON has no infinity, and a best hand of naneinf is one.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        self = try decoder.decode(RunRecord.self, from: json)
    }
}

public struct Exchange: Sendable, Hashable, Codable {
    public var title: String     // "Ante 3 · Big Blind", or the player's question
    public var advice: String    // Claude's markdown, verbatim
    public var isQuestion = false
    public var sawScreen = false
}

extension Exchange {
    /// Records saved before these flags existed have to keep loading, or the run loses its conversation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        advice = try container.decode(String.self, forKey: .advice)
        isQuestion = try container.decodeIfPresent(Bool.self, forKey: .isQuestion) ?? false
        sawScreen = try container.decodeIfPresent(Bool.self, forKey: .sawScreen) ?? false
    }
}

public enum Problem: Sendable, Hashable {
    case noRun
    case screenRecordingDenied
    case saveUnreadable(SaveFileError)
    case turnFailed(TurnFailure)
}

public struct CoachView: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case waitingForRun
        case lookingAtPack
        case thinking
        case answering
        case ready
    }
    public var status: Status
    public var goal: CoachGoal
    public var headline: String
    /// What's left to score in this blind, from the newest save. nil outside a hand.
    public var chipsNeeded: Double?
    /// The decision Claude is working on, until its first words arrive.
    public var waitingOn: Decision.Kind?
    /// The current plan, parsed even while partial so "Do this now" shows as soon as it streams.
    public var advice: Advice?
    /// Whether the plan came from a screenshot as well as the save.
    public var sawScreen: Bool
    /// The player's questions about the current decision. A new decision starts it empty.
    public var thread: [FollowUp]
    public var queuedQuestion: String?
    public var problem: Problem?
    public var canRetry: Bool

    public init(status: Status, goal: CoachGoal = .win, headline: String, chipsNeeded: Double? = nil, waitingOn: Decision.Kind? = nil, advice: Advice?, sawScreen: Bool = false, thread: [FollowUp], queuedQuestion: String?, problem: Problem?, canRetry: Bool) {
        self.goal = goal
        (self.status, self.headline, self.chipsNeeded, self.waitingOn, self.advice, self.sawScreen, self.thread) = (status, headline, chipsNeeded, waitingOn, advice, sawScreen, thread)
        (self.queuedQuestion, self.problem, self.canRetry) = (queuedQuestion, problem, canRetry)
    }

    public struct FollowUp: Sendable, Equatable {
        public var question: String
        public var reply: String
        public var changedSteps: Bool

        public init(question: String, reply: String, changedSteps: Bool) {
            (self.question, self.reply, self.changedSteps) = (question, reply, changedSteps)
        }

        /// New steps replace the plan's and take its score, goal and reasons with them, because those belong to the old steps.
        init(question: String, answer: String, plan: inout Advice?) {
            let parsed = Advice(markdown: answer)
            let changedSteps = !parsed.doNow.isEmpty
            if changedSteps {
                var updated = plan ?? Advice(doNow: [], why: [], lesson: nil, rest: "")
                (updated.doNow, updated.score, updated.goal, updated.why) = (parsed.doNow, parsed.score, parsed.goal, parsed.why)
                plan = updated
            }
            if let lesson = parsed.lesson { plan?.lesson = lesson }
            let reply = parsed.rest.isEmpty && !changedSteps ? parsed.why.joined(separator: " ") : parsed.rest
            self.init(question: question, reply: reply, changedSteps: changedSteps)
        }
    }
}
