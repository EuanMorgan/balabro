import BalabroCore
import Foundation
import Observation
import os

/// The only owner of `CoachState`. Feeds events into `Coach.reduce` and performs the effects.
///
/// Everything runs on the main actor, so events are handled one at a time in arrival order and
/// there is no shared mutable state to lock. Background work (file reads, the claude process,
/// screen capture) happens in tasks that only ever report back through `send`.
@MainActor
@Observable
final class CoachRuntime {
    private(set) var view: CoachView
    @ObservationIgnored private var state: CoachState
    @ObservationIgnored private let coach: Coach
    @ObservationIgnored private let store: RunStore
    @ObservationIgnored private let claude: ClaudeInvocation?
    @ObservationIgnored private let scorer: Scorer?
    @ObservationIgnored private var turns: [TurnID: Task<Void, Never>] = [:]
    @ObservationIgnored private var savesRoot: URL?

    private static let goalKey = "goal"

    init(coach: Coach, store: RunStore, claude: ClaudeInvocation?, scorer: Scorer? = nil) {
        let goal = UserDefaults.standard.string(forKey: Self.goalKey).flatMap(CoachGoal.init) ?? .win
        let state = CoachState(restoring: store.loadAll(), goal: goal)
        (self.coach, self.store, self.claude, self.scorer, self.state, self.view) = (coach, store, claude, scorer, state, state.view)
    }

    /// Consumes save events until the app quits. The watcher's first events are the saves already on disk,
    /// which is how a restart reattaches to the run in progress (and drops it if already coached).
    func start(watching root: URL) async {
        savesRoot = root
        for await event in SaveWatcher(root: root).events() { send(event) }
    }

    func ask(_ question: String, withScreenshot: Bool) { send(.ask(question, withScreenshot: withScreenshot)) }
    func retry() { send(.retry) }
    func refresh() { send(.refresh) }
    func adviseNextRun() { send(.adviseNextRun) }
    func setGoal(_ goal: CoachGoal) {
        UserDefaults.standard.set(goal.rawValue, forKey: Self.goalKey)
        send(.setGoal(goal))
    }

    private func send(_ event: CoachEvent) {
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
                for await output in ClaudeProcess.run(request, with: claude) { send(.turnOutput(request.id, output)) }
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
            Task { send(.scored(id, facts: await scorer.score(save: savesRoot.appending(path: "\(profile)/save.jkr"), within: limit))) }
        case .captureGameWindow(let id, let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.screenshot(id, png: await GameWindow.capturePNG()))
            }
        case .readProgress(let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.progressRead(savesRoot.flatMap(StatsData.progress)))
            }
        case .save(let record):
            // Synchronous: a few KB, and the file order must match the state order.
            do { try store.save(record) } catch { Logger.balabro.error("Couldn't save run \(record.key, privacy: .public): \(error)") }
        }
    }
}
