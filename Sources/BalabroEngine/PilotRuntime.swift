import BalabroCore
import Foundation
import Observation

/// The only owner of `PilotState`, and the same shape as `CoachRuntime`. The two run side by side: the coach can keep
/// watching the player's real game while the bot plays its own.
@MainActor
@Observable
public final class PilotRuntime {
    public private(set) var view: PilotView
    @ObservationIgnored private var state: PilotState
    @ObservationIgnored private let pilot: Pilot
    @ObservationIgnored private let results: PilotResults
    @ObservationIgnored private let claude: ClaudeInvocation?
    @ObservationIgnored private let game: GameInstall?
    @ObservationIgnored private var turns: [TurnID: Task<Void, Never>] = [:]
    @ObservationIgnored private var process: BotProcess?
    @ObservationIgnored private var shutDown = false

    /// `--resume` only finds sessions filed under the cwd, and the bot's conversations stay out of the coach's folder.
    static let conversations = Platform.dataFolder.appending(path: "pilot-conversations")

    init(pilot: Pilot, results: PilotResults, claude: ClaudeInvocation?, game: GameInstall?) {
        var claude = claude
        claude?.systemPrompt = Pilot.systemPrompt
        claude?.workingDirectory = Self.conversations
        claude?.effort = Pilot.effort
        let state = PilotState(restoring: results.load())
        (self.pilot, self.results, self.claude, self.game, self.state, self.view) = (pilot, results, claude, game, state, state.view)
    }

    public func start(goal: CoachGoal) { send(.start(.standard(for: goal))) }
    public func stop() { send(.stop) }
    public func dismiss() { send(.dismiss) }

    /// Closes the bot's game without recording a result, because Balabro is quitting rather than the player stopping,
    /// and ends the claude turns, waiting for their processes to exit.
    func shutdown() async {
        shutDown = true
        process?.kill()
        let running = Array(turns.values)
        turns = [:]
        running.forEach { $0.cancel() }
        for turn in running { await turn.value }
    }

    private func send(_ event: PilotEvent) {
        guard !shutDown else { return }
        let effects = pilot.reduce(&state, event)
        view = state.view
        effects.forEach(perform)
    }

    private func perform(_ effect: PilotEffect) {
        switch effect {
        case .launch(let setup):
            Task { await launch(setup) }
        case .kill:
            process?.kill()
            process = nil
        case .tell(let line):
            process?.tell(line)
        case .readDecision(let id, let file):
            Task {
                let bytes = (try? Data(contentsOf: file)) ?? Data()
                try? FileManager.default.removeItem(at: file)
                let result: Result<RunSnapshot, SaveFileError>
                do throws(SaveFileError) { result = .success(try SaveFile.decode(bytes, profile: 1)) } catch { result = .failure(error) }
                send(.decisionRead(id, result, packCards: (try? SaveFile.decodePackCards(bytes)) ?? []))
            }
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
        case .armTimeout(let id, let delay):
            Task {
                try? await Task.sleep(for: delay)
                send(.timedOut(id))
            }
        case .record:
            results.save(state.results)
        }
    }

    private func launch(_ setup: PilotSetup) async {
        guard let game else { return fail("Balatro isn't installed.") }
        guard let lua = Platform.botLua else { return fail("Only a packaged Balabro can play for you.") }
        do {
            let install = try await BotInstall.prepare(from: game, lua: lua)
            let (process, output) = try BotProcess.launch(install, settings: [
                "BALABRO_BOT_GOAL": setup.goal.rawValue, "BALABRO_BOT_DECK": setup.deck.rawValue, "BALABRO_BOT_STAKE": String(setup.stake),
            ])
            self.process = process
            for await item in output {
                switch item {
                case .line(let line):
                    if let frame = BotFrame(line: line) { send(.bot(frame, at: .now)) }
                case .exited(let status): send(.botExited(status: status, at: .now))
                }
            }
        } catch {
            fail("Couldn't prepare the bot's copy of the game: \(error.localizedDescription)")
        }
    }

    private func fail(_ detail: String) { send(.bot(.broken(kind: "setup", detail: detail), at: .now)) }
}
