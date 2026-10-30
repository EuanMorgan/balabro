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

    public init(text: GameText) { self.text = text }

    public func reduce(_ state: inout CoachState, _ event: CoachEvent) -> [CoachEffect] {
        switch event {
        case .saveWritten(let snapshot):
            var effects: [CoachEffect] = []
            let key = state.runKey(for: snapshot)
            if key != state.current {
                effects += state.abandonActivity()
                state.current = key
            }
            var record = state.runs[key] ?? RunRecord(key: key, progress: snapshot.progress, head: nil, lastCoached: nil, transcript: [])
            record.progress = snapshot.progress
            state.standing = CoachView.Standing(snapshot)
            if record != state.runs[key] {
                state.runs[key] = record
                effects.append(.save(record))
            }
            switch state.problem {
            case .noRun, .saveUnreadable: state.problem = nil
            default: break
            }
            guard let decision = Decision.detect(in: snapshot, text: text),
                  decision.fingerprint != state.newestFingerprint else { return effects }
            if state.activity.purpose?.isQuestion == true {
                state.waitingDecision = decision
                return effects
            }
            if case .running(let turn) = state.activity { effects.append(.cancelTurn(turn.id)) }
            return effects + begin(.decision(decision), &state)

        // The game deletes save.jkr on game over and when a new run replaces it.
        case .saveRemoved(let profile):
            guard state.current?.identity.profile == profile else { return [] }
            let effects = state.abandonActivity()
            state.current = nil
            state.standing = nil
            return effects

        case .saveUnreadable(_, let error):
            state.problem = .saveUnreadable(error)
            return []

        case .screenshot(let id, let png):
            guard case .capturing(id, let purpose) = state.activity else { return [] }
            return start(purpose, screenshot: png, screenshotFailed: png == nil, &state)

        case .ask(let question, let withScreenshot):
            guard state.current != nil else {
                state.problem = .noRun
                return []
            }
            guard case .idle = state.activity else {
                state.queuedQuestion = [state.queuedQuestion, question].compactMap { $0 }.joined(separator: "\n")
                return []
            }
            return withScreenshot ? capture(.question(question), after: .zero, &state) : start(.question(question), &state)

        case .turnOutput(let id, let output):
            guard case .running(var turn) = state.activity, turn.id == id, let key = state.current else { return [] }
            switch output {
            case .started:
                return []
            case .text(let delta):
                turn.partial += delta
                state.activity = .running(turn)
                return []
            case .done(let answer, let session):
                var record = state.runs[key]!
                record.head = session
                record.transcript.append(Exchange(title: turn.purpose.title, advice: answer, isQuestion: turn.purpose.isQuestion, sawScreen: turn.sawScreen))
                if case .decision(let decision) = turn.purpose { record.lastCoached = decision.fingerprint }
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
        }
    }

    private func begin(_ purpose: CoachState.Purpose, _ state: inout CoachState) -> [CoachEffect] {
        if case .decision(let decision) = purpose {
            state.waitingDecision = nil
            if decision.needsScreenshot { return capture(purpose, after: packSettleDelay, &state) }
        }
        return start(purpose, &state)
    }

    private func capture(_ purpose: CoachState.Purpose, after delay: Duration, _ state: inout CoachState) -> [CoachEffect] {
        let id = CaptureID(state.takeID())
        state.activity = .capturing(id, purpose)
        return [.captureGameWindow(id, after: delay)]
    }

    private func start(
        _ purpose: CoachState.Purpose, screenshot: Data? = nil, screenshotFailed: Bool = false, _ state: inout CoachState
    ) -> [CoachEffect] {
        guard let key = state.current, let record = state.runs[key] else { return [] }
        let text = switch purpose {
        case .decision(let decision): screenshotFailed ? decision.prompt + "\n\n" + Prompt.screenshotMissing : decision.prompt
        case .question(let question): Prompt.question(question, packContentsUnknown: screenshotFailed)
        }
        let id = TurnID(state.takeID())
        state.activity = .running(.init(id: id, purpose: purpose, partial: "", sawScreen: screenshot != nil))
        state.retryable = nil
        state.problem = screenshotFailed ? .screenRecordingDenied : nil
        return [.startTurn(TurnRequest(id: id, forkFrom: record.head, message: UserMessage(text: text, screenshotPNG: screenshot)))]
    }

    private func startNext(_ state: inout CoachState) -> [CoachEffect] {
        if let question = state.queuedQuestion {
            state.queuedQuestion = nil
            return start(.question(question), &state)
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
    var standing: CoachView.Standing?
    var nextID = 0

    /// Starts from what `RunStore` saved. No in-flight state survives a restart, by design.
    public init(restoring records: [RunRecord]) {
        runs = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Everything the overlay draws. Derived, never stored, so it can't drift from the state.
    public var view: CoachView {
        let status: CoachView.Status, partial: String, sawScreen: Bool
        switch activity {
        case .idle: (status, partial, sawScreen) = (current == nil ? .waitingForRun : .ready, "", false)
        case .capturing: (status, partial, sawScreen) = (.lookingAtPack, "", true)
        case .running(let turn): (status, partial, sawScreen) = (turn.partial.isEmpty ? .thinking : .answering, turn.partial, turn.sawScreen)
        }
        let canRetry = retryable != nil && activity.isIdle
        if let decision = activity.purpose?.decision {
            return CoachView(
                status: status, headline: decision.title, standing: standing, waitingOn: partial.isEmpty ? decision.kind : nil,
                advice: partial.isEmpty ? nil : Advice(markdown: partial), sawScreen: sawScreen, thread: [],
                queuedQuestion: queuedQuestion, problem: problem, canRetry: canRetry)
        }
        let history = current.flatMap { runs[$0] }?.transcript ?? []
        let planIndex = history.lastIndex { !$0.isQuestion }
        var plan = planIndex.map { Advice(markdown: history[$0].advice) }
        var thread = history[(planIndex.map { $0 + 1 } ?? 0)...].map { CoachView.FollowUp(question: $0.title, answer: $0.advice, sawScreen: $0.sawScreen, plan: &plan) }
        if case .question(let question)? = activity.purpose ?? retryable {
            thread.append(CoachView.FollowUp(question: question, answer: partial, sawScreen: sawScreen, plan: &plan))
        }
        return CoachView(
            status: status,
            headline: planIndex.map { history[$0].title } ?? (current == nil ? "Start or continue a run" : "Waiting for your next move"),
            standing: standing, advice: plan, sawScreen: planIndex.map { history[$0].sawScreen } ?? false, thread: thread, queuedQuestion: queuedQuestion, problem: problem, canRetry: canRetry)
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
        case capturing(CaptureID, Purpose)
        case running(Turn)

        var isIdle: Bool { purpose == nil }

        var purpose: Purpose? {
            switch self {
            case .idle: nil
            case .capturing(_, let purpose): purpose
            case .running(let turn): turn.purpose
            }
        }
    }

    enum Purpose: Sendable, Hashable {
        case decision(Decision)
        case question(String)

        var decision: Decision? { if case .decision(let d) = self { d } else { nil } }
        var isQuestion: Bool { decision == nil }

        var title: String {
            switch self {
            case .decision(let d): d.title
            case .question(let q): q
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
    case screenshot(CaptureID, png: Data?)
    case ask(String, withScreenshot: Bool)
    case turnOutput(TurnID, TurnOutput)
    case retry
}

public enum CoachEffect: Sendable, Hashable {
    case startTurn(TurnRequest)
    /// Kill the process. Its forked session is simply never used again.
    case cancelTurn(TurnID)
    case captureGameWindow(CaptureID, after: Duration)
    case save(RunRecord)
}

public struct TurnID: Sendable, Hashable, Codable { public let value: Int; public init(_ value: Int) { self.value = value } }
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
}

public struct Exchange: Sendable, Hashable, Codable {
    public var title: String     // "Ante 3 · Big Blind · hand 2", or the player's question
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
    public var headline: String
    /// Read from the newest save, so it's right even while Claude is still answering.
    public var standing: Standing?
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

    public init(status: Status, headline: String, standing: Standing? = nil, waitingOn: Decision.Kind? = nil, advice: Advice?, sawScreen: Bool = false, thread: [FollowUp], queuedQuestion: String?, problem: Problem?, canRetry: Bool) {
        (self.status, self.headline, self.standing, self.waitingOn, self.advice, self.sawScreen, self.thread) = (status, headline, standing, waitingOn, advice, sawScreen, thread)
        (self.queuedQuestion, self.problem, self.canRetry) = (queuedQuestion, problem, canRetry)
    }

    public struct Standing: Sendable, Equatable {
        /// "92 / 300" during a hand, nil outside one.
        public var score: String?
        public var dollars: Int

        public init(score: String?, dollars: Int) { (self.score, self.dollars) = (score, dollars) }

        init(_ snapshot: RunSnapshot) {
            let score = snapshot.blind.flatMap { snapshot.phase == .selectingHand ? "\(Prompt.chips(snapshot.chipsScored)) / \(Prompt.chips($0.target))" : nil }
            self.init(score: score, dollars: snapshot.dollars)
        }
    }

    public struct FollowUp: Sendable, Equatable {
        public var question: String
        public var reply: String
        public var changedSteps: Bool
        public var sawScreen: Bool

        public init(question: String, reply: String, changedSteps: Bool, sawScreen: Bool = false) {
            (self.question, self.reply, self.changedSteps, self.sawScreen) = (question, reply, changedSteps, sawScreen)
        }

        /// New steps replace the plan's and take its score, goal and reasons with them, because those belong to the old steps.
        init(question: String, answer: String, sawScreen: Bool, plan: inout Advice?) {
            let parsed = Advice(markdown: answer)
            let changedSteps = !parsed.doNow.isEmpty
            if changedSteps {
                var updated = plan ?? Advice(doNow: [], why: [], lesson: nil, rest: "")
                (updated.doNow, updated.score, updated.goal, updated.why) = (parsed.doNow, parsed.score, parsed.goal, parsed.why)
                plan = updated
            }
            if let lesson = parsed.lesson { plan?.lesson = lesson }
            let reply = parsed.rest.isEmpty && !changedSteps ? parsed.why.joined(separator: " ") : parsed.rest
            self.init(question: question, reply: reply, changedSteps: changedSteps, sawScreen: sawScreen)
        }
    }
}
