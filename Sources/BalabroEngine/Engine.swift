import BalabroCore
import Foundation

/// The setup both apps share. A face supplies only the screenshot.
@MainActor
public final class Engine {
    public let coach: CoachRuntime
    public let pilot: PilotRuntime
    public let game: GameInstall?
    public let text: GameText
    public let machine: Machine
    public let runs: RunStore
    private let scorer: Scorer?
    private let watching: Task<Void, Never>

    private init(coach: CoachRuntime, pilot: PilotRuntime, game: GameInstall?, text: GameText, machine: Machine, runs: RunStore, scorer: Scorer?, watching: Task<Void, Never>) {
        (self.coach, self.pilot, self.game, self.text, self.machine, self.runs) = (coach, pilot, game, text, machine, runs)
        (self.scorer, self.watching) = (scorer, watching)
    }

    /// Watches `savesRoot` from the moment it returns. `capture` is a PNG of the game's window, or nil when there's none.
    public static func start(savesRoot: URL, capture: @escaping @Sendable () async -> Data?) async -> Engine {
        let machine = Machine.load()
        let shared = await machine.open()
        let runs = RunStore(files: shared)
        let game = GameInstall.find()
        let text = await game?.loadText() ?? .missing
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: CoachRuntime.conversations)
        let scorer = Scorer(game: game, lua: Platform.botLua)
        let coach = CoachRuntime(
            coach: Coach(text: text, machine: machine.id, scoreWait: scorer == nil ? nil : .seconds(8)), store: runs, settings: shared, claude: claude, scorer: scorer, capture: capture)
        let pilot = PilotRuntime(pilot: Pilot(text: text), results: PilotResults(files: shared), claude: claude, game: game)
        let watching = Task { await coach.start(watching: savesRoot) }
        return Engine(coach: coach, pilot: pilot, game: game, text: text, machine: machine, runs: runs, scorer: scorer, watching: watching)
    }

    /// Stops watching the saves, ends the claude turns and waits for their processes to exit, and closes the bot's
    /// copies of the game now, rather than when they notice their stdin has closed.
    public func shutdown() async {
        watching.cancel()
        await coach.shutdown()
        await pilot.shutdown()
        await scorer?.shutdown()
    }
}
