import BalabroCore
import Foundation

/// The modes that check one part of the engine from a terminal, before any panel is involved.
///
/// On the main actor, so a call that matches no mode returns without suspending. The Mac app must reach
/// `NSApplication.run` before its first suspension, or the run loop runs inside a main-queue job and no main-actor task runs again.
@MainActor
public enum EngineCommand {
    /// The exit status of the mode `arguments` name, or nil when they name none.
    public static func run(_ arguments: [String]) async -> Int32? {
        if let save = value(after: "--print-prompt", in: arguments) { return await printPrompt(URL(filePath: save)) }
        if let save = value(after: "--print-exact-scores", in: arguments) { return await printExactScores(URL(filePath: save)) }
        if let root = value(after: "--print-next-run", in: arguments) { return await printNextRun(URL(filePath: root)) }
        if let goal = value(after: "--play-for-me", in: arguments).flatMap(CoachGoal.init) { return await playForMe(goal) }
        if arguments.contains("--locate-claude") { return await locateClaude() }
        if arguments.contains("--print-preview-views") { return printPreviewViews() }
        return nil
    }

    public static func savesRoot(_ arguments: [String]) -> URL {
        value(after: "--saves-root", in: arguments).map { URL(filePath: $0) } ?? Platform.defaultSavesRoot
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// Prints the decision kind, title and prompt for one save, so a save from a real run can be
    /// checked without starting the overlay. The profile comes from the folder name, as in the game.
    private static func printPrompt(_ url: URL) async -> Int32 {
        let profile = Int(url.deletingLastPathComponent().lastPathComponent).flatMap { SaveWatcher.profiles.contains($0) ? $0 : nil } ?? 1
        let snapshot: RunSnapshot
        switch await SaveWatcher.decodeSettled(at: url, profile: profile) {
        case .success(let decoded): snapshot = decoded
        case .failure(let error):
            FileHandle.standardError.write(Data("Couldn't decode \(url.path): \(error)\n".utf8))
            return 1
        }
        let text = await GameInstall.find()?.loadText() ?? .missing
        guard let decision = Decision.detect(in: snapshot, text: text) else {
            print("No decision (\(snapshot.phase))")
            return 0
        }
        var state = CoachState(restoring: [])
        _ = Coach(text: text).reduce(&state, .saveWritten(snapshot))
        print("Kind: \(label(decision.kind))\nTitle: \(state.view.headline)\n\n\(decision.prompt)")
        return 0
    }

    /// Prints what the scorer tells the coach about a save, so the scorer can be checked from a script.
    private static func printExactScores(_ save: URL) async -> Int32 {
        guard let scorer = Scorer(game: GameInstall.find(), lua: Platform.botLua) else {
            print("Only a packaged Balabro with Balatro installed can score a save.")
            return 1
        }
        let answer = await scorer.score(save: save, unlocks: save.deletingLastPathComponent().appending(path: "meta.jkr"), within: .seconds(60))
        guard let facts = answer.facts else {
            print("Nothing to work out, or the scorer failed.")
            return 1
        }
        if !answer.packCards.isEmpty { print(answer.packCards) }
        print(facts)
        return 0
    }

    /// Prints what the coach is told when suggesting the next run, from a saves folder such as `Platform.defaultSavesRoot`.
    private static func printNextRun(_ root: URL) async -> Int32 {
        var state = CoachState(restoring: [])
        let coach = Coach(text: await GameInstall.find()?.loadText() ?? .missing)
        guard case .startTurn(let request)? = coach.reduce(&state, .progressRead(StatsData.progress(savesRoot: root))).first else {
            print("No profile in \(root.path)")
            return 1
        }
        print(request.message.text)
        return 0
    }

    private static func label(_ kind: Decision.Kind) -> String {
        switch kind {
        case .playHand: "play hand"
        case .shop: "shop"
        case .blindSelect: "blind select"
        case .openPack(let pack, .shop): "open \(pack.key) from the shop"
        case .openPack(let pack, .skipTag(let tag)): "open \(pack.key) from \(tag.rawValue)"
        }
    }

    /// Plays one run without the overlay, printing what the panel would show, so a run can be measured from a script.
    /// Each line is written straight to stdout, because a pipe would otherwise hold them until the run ends.
    private static func playForMe(_ goal: CoachGoal) async -> Int32 {
        func say(_ line: String) { try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
        let game = GameInstall.find()
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: PilotRuntime.conversations)
        let pilot = PilotRuntime(pilot: Pilot(text: await game?.loadText() ?? .missing), results: .default, claude: claude, game: game)
        pilot.start(goal: goal)
        var last = ""
        while pilot.view.status != .finished {
            let run = pilot.view.run
            let line = "ante \(run?.ante ?? 0) round \(run?.round ?? 0) $\(run?.dollars ?? 0) best \(run?.bestHandText ?? "0") \(run?.doing ?? "") | \(pilot.view.status) | \(pilot.view.why ?? "")"
            if line != last { say(line) }
            last = line
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let result = pilot.view.result else { return 1 }
        say("RESULT \(result.ending) ante \(result.ante) round \(result.round) best \(result.bestHandText) in \(Int(result.seconds)) s")
        return 0
    }

    private static func printPreviewViews() -> Int32 {
        for state in PreviewState.all(now: .now) {
            guard let line = try? jsonLine(state) else { return 1 }
            try? FileHandle.standardOutput.write(contentsOf: line)
        }
        return 0
    }

    private static func locateClaude() async -> Int32 {
        guard let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: CoachRuntime.conversations) else {
            print("claude not found")
            return 1
        }
        print("claude: \(Platform.path(claude.executable))\nCLAUDE_CONFIG_DIR: \(claude.configDir.map(Platform.path) ?? "(default)")\nPATH: \(claude.searchPath)")
        return 0
    }
}
