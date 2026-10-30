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
    func refresh() { send(.refresh) }

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
        case .captureGameWindow(let id, let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.screenshot(id, png: await GameWindow.capturePNG()))
            }
        case .save(let record):
            // Synchronous: a few KB, and the file order must match the state order.
            do { try store.save(record) } catch { Logger.balabro.error("Couldn't save run \(record.key, privacy: .public): \(error)") }
        }
    }
}
