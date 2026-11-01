import BalabroCore
import Foundation
import Observation

/// The only owner of `CoachState`. Feeds events into `Coach.reduce` and performs the effects.
///
/// Everything runs on the main actor, so events are handled one at a time in arrival order and
/// there is no shared mutable state to lock. Background work (file reads, the claude process,
/// screen capture) happens in tasks that only ever report back through `send`.
@MainActor
@Observable
public final class CoachRuntime {
    public private(set) var view: CoachView
    @ObservationIgnored private var state: CoachState
    @ObservationIgnored private let coach: Coach
    @ObservationIgnored private let store: RunStore
    @ObservationIgnored private let claude: ClaudeInvocation?
    @ObservationIgnored private let scorer: Scorer?
    @ObservationIgnored private var turns: [TurnID: Task<Void, Never>] = [:]
    @ObservationIgnored private let capture: @Sendable () async -> Data?
    @ObservationIgnored private var savesRoot: URL?
    @ObservationIgnored private var shutDown = false

    private static let goalKey = "goal"
    /// `--resume` only finds sessions filed under the cwd the CLI ran in, so every turn uses this one.
    static let conversations = Platform.dataFolder.appending(path: "conversations")

    init(coach: Coach, store: RunStore, claude: ClaudeInvocation?, scorer: Scorer?, capture: @escaping @Sendable () async -> Data?) {
        let goal = UserDefaults.standard.string(forKey: Self.goalKey).flatMap(CoachGoal.init) ?? .win
        let state = CoachState(restoring: store.loadAll(), goal: goal)
        (self.coach, self.store, self.claude, self.scorer, self.capture, self.state, self.view) = (coach, store, claude, scorer, capture, state, state.view)
    }

    /// Consumes save events until the app quits. The watcher's first events are the saves already on disk,
    /// which is how a restart reattaches to the run in progress (and drops it if already coached).
    func start(watching root: URL) async {
        savesRoot = root
        for await event in SaveWatcher(root: root).events() { send(event) }
    }

    public func ask(_ question: String) { send(.ask(question)) }
    public func retry() { send(.retry) }
    public func refresh() { send(.refresh) }
    public func adviseNextRun() { send(.adviseNextRun) }
    public func setGoal(_ goal: CoachGoal) {
        UserDefaults.standard.set(goal.rawValue, forKey: Self.goalKey)
        send(.setGoal(goal))
    }

    /// Ends the claude turns and waits for their processes to exit, then ignores everything, because Balabro is quitting.
    func shutdown() async {
        shutDown = true
        let running = Array(turns.values)
        turns = [:]
        running.forEach { $0.cancel() }
        for turn in running { await turn.value }
    }

    private func send(_ event: CoachEvent) {
        guard !shutDown else { return }
        let effects = coach.reduce(&state, event)
        view = state.view
        effects.forEach(perform)
    }

    private func perform(_ effect: CoachEffect) {
        switch effect {
        case .startTurn(let request):
            guard let claude else {
                send(.turnOutput(request.id, .failed(.cliNotFound)))
                return
            }
            turns[request.id] = Task {
                let turn = ClaudeProcess.run(request, with: claude)
                for await output in turn.output { send(.turnOutput(request.id, output)) }
                await turn.ended.value
                turns[request.id] = nil
            }
        case .cancelTurn(let id):
            turns.removeValue(forKey: id)?.cancel()
        case .warmScorer:
            Task { await scorer?.warm() }
        case .scoreSave(let id, let profile, let limit):
            guard let scorer, let savesRoot else {
                send(.scored(id, facts: nil))
                return
            }
            Task {
                let folder = savesRoot.appending(path: "\(profile)")
                let answer = await scorer.score(save: folder.appending(path: "save.jkr"), unlocks: folder.appending(path: "meta.jkr"), within: limit)
                send(.scored(id, facts: answer.facts, packCards: answer.packCards))
            }
        case .captureGameWindow(let id, let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.screenshot(id, png: await capture()))
            }
        case .readProgress(let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.progressRead(savesRoot.flatMap(StatsData.progress)))
            }
        case .save(let record):
            // Synchronous: a few KB, and the file order must match the state order.
            do { try store.save(record) } catch { Platform.log("Couldn't save run \(record.key): \(error)") }
        }
    }
}
