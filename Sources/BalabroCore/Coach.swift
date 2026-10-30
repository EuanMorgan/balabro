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
        // TODO, by event:
        //
        // .saveWritten(s):
        //   key = runKey(for: s, in: state)        // see below
        //   if key != state.current { effects += abandonActivity(); state.current = key; state.runs[key] = .new(key, s.progress) }
        //   state.runs[key].progress = s.progress; effects += .save(record)
        //   guard let d = Decision.detect(in: s, text: text) else { return effects }
        //   guard d.fingerprint != (state.activity.decisionFingerprint ?? state.waitingDecision?.fingerprint
        //                           ?? record.lastCoached) else { return effects }      // duplicate write, or a restart
        //   switch state.activity {
        //     case .running(t) where t.purpose is .question: state.waitingDecision = d       // never cancel the player's question
        //     case .running(t): effects += .cancelTurn(t.id); fallthrough-ish to begin(d)
        //     case .capturing, .idle: begin(d)                                               // a stale capture is ignored by ID
        //   }
        //   begin(d): d.needsScreenshot ? capture(.decision(d)) : start(.decision(d))
        //
        // .saveRemoved(profile): the game deletes save.jkr on game over and when a new run replaces it.
        //   If it's the current run's profile: abandonActivity(), state.current = nil.
        //
        // .screenshot(id, png): ignore unless state.activity == .capturing(id, purpose).
        //   start(purpose, png). png == nil -> state.problem = .screenRecordingDenied, start anyway with text that
        //   tells Claude the pack contents are unknown so it asks the player to list them.
        //
        // .ask(q, withScreenshot): no current run -> problem = .noRun.
        //   idle -> withScreenshot ? capture(.question(q)) : start(.question(q)).
        //   busy -> state.queuedQuestion = [queued, q].joined("\n").
        //
        // .turnOutput(id, out): ignore unless state.activity == .running(t) with t.id == id.
        //   .started(session)  -> nothing to keep; head only moves on .done.
        //   .text(delta)       -> t.partial += delta.
        //   .done(text, sess)  -> record.head = sess; record.transcript.append(...);
        //                         if decision: record.lastCoached = fingerprint; effects += .save(record);
        //                         activity = .idle; startNext(): queuedQuestion first, then waitingDecision.
        //   .failed(f)         -> state.problem = .turnFailed(f); state.retryable = t.purpose; activity = .idle.
        //                         No automatic retry: "not logged in" would loop.
        //
        // .retry: start(state.retryable) if idle.
        //
        // runKey(for s): latest record with s.identity; if none -> replay 0;
        //   if s.progress < record.progress (a counter went backwards) -> replay + 1, a new run on the same seed;
        //   else that record's key (this is also how an app restart reattaches to its run).
        fatalError("not implemented")
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
    var nextID = 0

    /// Starts from what `RunStore` saved. No in-flight state survives a restart, by design.
    public init(restoring records: [RunRecord]) {
        runs = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Everything the overlay draws. Derived, never stored, so it can't drift from the state.
    public var view: CoachView { fatalError("not implemented") }

    enum Activity: Sendable {
        case idle
        case capturing(CaptureID, Purpose)
        case running(Turn)
    }

    enum Purpose: Sendable, Hashable {
        case decision(Decision)
        case question(String)
    }

    struct Turn: Sendable {
        var id: TurnID
        var purpose: Purpose
        var partial: String
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
    /// What the overlay shows when scrolled back, and after a restart.
    public var transcript: [Exchange]
}

public struct Exchange: Sendable, Hashable, Codable {
    public var title: String     // "Ante 3 · Big Blind · hand 2", or the player's question
    public var advice: String    // Claude's markdown, verbatim
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
    /// The current answer, parsed even while partial so "Do this now" shows as soon as it streams.
    public var advice: Advice?
    public var history: [Exchange]
    public var queuedQuestion: String?
    public var problem: Problem?
    public var canRetry: Bool
}
