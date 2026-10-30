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
final class CoachRuntime {
    private(set) var view: CoachView
    @ObservationIgnored private var state: CoachState
    @ObservationIgnored private let coach: Coach
    @ObservationIgnored private let store: RunStore
    @ObservationIgnored private let claude: ClaudeInvocation?
    @ObservationIgnored private var turns: [TurnID: Task<Void, Never>] = [:]

    init(coach: Coach, store: RunStore, claude: ClaudeInvocation?) {
        let state = CoachState(restoring: store.loadAll())
        (self.coach, self.store, self.claude, self.state, self.view) = (coach, store, claude, state, state.view)
    }

    /// Consumes save events until the app quits. The watcher's first events are the saves already on disk,
    /// which is how a restart reattaches to the run in progress (and drops it if already coached).
    func start(watching root: URL) async {
        for await event in SaveWatcher(root: root).events() { send(event) }
    }

    func ask(_ question: String, withScreenshot: Bool) { send(.ask(question, withScreenshot: withScreenshot)) }
    func retry() { send(.retry) }

    private func send(_ event: CoachEvent) {
        let effects = coach.reduce(&state, event)
        view = state.view
        effects.forEach(perform)
    }

    private func perform(_ effect: CoachEffect) {
        switch effect {
        case .startTurn(let request):
            // TODO: turns[request.id] = Task { for await out in ClaudeProcess.run(request, claude) { send(.turnOutput(id, out)) } }
            //       claude == nil -> send(.turnOutput(id, .failed(.cliNotFound))) at once.
            fatalError("not implemented")
        case .cancelTurn(let id):
            turns.removeValue(forKey: id)?.cancel()
        case .captureGameWindow(let id, let delay):
            // TODO: Task { try? await Task.sleep(for: delay); send(.screenshot(id, png: await GameWindow.capturePNG())) }
            fatalError("not implemented")
        case .save(let record):
            // TODO: try store.save(record); log on failure. Synchronous: a few KB, and ordering must match state.
            fatalError("not implemented")
        }
    }
}
