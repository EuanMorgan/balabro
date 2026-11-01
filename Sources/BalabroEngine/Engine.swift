import BalabroCore
import Foundation

/// The setup both apps share. A face supplies only the screenshot.
@MainActor
public final class Engine {
    public let coach: CoachRuntime
    public let pilot: PilotRuntime
    public let game: GameInstall?
    public let text: GameText
    private let scorer: Scorer?
    private let watching: Task<Void, Never>

    private init(coach: CoachRuntime, pilot: PilotRuntime, game: GameInstall?, text: GameText, scorer: Scorer?, watching: Task<Void, Never>) {
        (self.coach, self.pilot, self.game, self.text, self.scorer, self.watching) = (coach, pilot, game, text, scorer, watching)
    }

    /// Watches `savesRoot` from the moment it returns. `capture` is a PNG of the game's window, or nil when there's none.
    public static func start(savesRoot: URL, capture: @escaping @Sendable () async -> Data?) async -> Engine {
        let game = GameInstall.find()
        let text = await game?.loadText() ?? .missing
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: CoachRuntime.conversations)
        let scorer = Scorer(game: game, lua: Platform.botLua)
        let coach = CoachRuntime(
            coach: Coach(text: text, machine: Machine.load().id, scoreWait: scorer == nil ? nil : .seconds(8)), store: .default, claude: claude, scorer: scorer, capture: capture)
        let pilot = PilotRuntime(pilot: Pilot(text: text), results: .default, claude: claude, game: game)
        let watching = Task { await coach.start(watching: savesRoot) }
        return Engine(coach: coach, pilot: pilot, game: game, text: text, scorer: scorer, watching: watching)
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
