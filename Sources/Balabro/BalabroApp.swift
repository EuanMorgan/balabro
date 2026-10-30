import AppKit
import BalabroCore

/// Menu-bar-only app (`LSUIElement`), so the overlay can sit over Balatro's fullscreen Space
/// and clicking it never pulls the user out of the game.
@main
@MainActor
enum BalabroApp {
    static let updateFlag = "--update"

    static func main() async {
        // A claude process that dies before reading stdin must fail the write, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let save = value(after: "--print-prompt", in: arguments) {
            exit(await printPrompt(URL(filePath: save)))
        }
        if let root = value(after: "--print-next-run", in: arguments) {
            exit(await printNextRun(URL(filePath: root)))
        }
        if let goal = value(after: "--play-for-me", in: arguments).flatMap(CoachGoal.init) {
            exit(await playForMe(goal))
        }
        if arguments.contains("--locate-claude") {
            exit(await locateClaude())
        }
        if arguments.contains(updateFlag) {
            exit(await update())
        }
        #if DEBUG
        if let directory = value(after: "--render-previews", in: arguments) {
            exit(await Previews.render(to: URL(filePath: directory)))
        }
        #endif

        let app = NSApplication.shared
        let delegate = AppDelegate(savesRoot: value(after: "--saves-root", in: arguments).map { URL(filePath: $0) } ?? SaveWatcher.defaultRoot)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
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

    /// Prints what the coach is told when suggesting the next run, from a saves folder such as `~/Library/Application Support/Balatro`.
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
    private static func playForMe(_ goal: CoachGoal) async -> Int32 {
        setlinebuf(stdout)
        let game = GameInstall.find()
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: PilotRuntime.conversations)
        let pilot = PilotRuntime(pilot: Pilot(text: await game?.loadText() ?? .missing), results: .default, claude: claude, game: game)
        pilot.start(goal: goal)
        var last = ""
        while pilot.view.status != .finished {
            let run = pilot.view.run
            let line = "ante \(run?.ante ?? 0) round \(run?.round ?? 0) $\(run?.dollars ?? 0) best \(run?.bestHandText ?? "0") \(run?.doing ?? "") | \(pilot.view.status) | \(pilot.view.why ?? "")"
            if line != last { print(line) }
            last = line
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let result = pilot.view.result else { return 1 }
        print("RESULT \(result.ending) ante \(result.ante) round \(result.round) best \(result.bestHandText) in \(Int(result.seconds)) s")
        return 0
    }

    private static func update() async -> Int32 {
        guard let updater = Updater() else {
            print("Only a packaged Balabro.app can update itself.")
            return 1
        }
        await updater.check()
        guard case .available(let release) = updater.status else {
            print("Up to date.")
            return 0
        }
        print("Updating to \(release.version)")
        guard await updater.install() else {
            print("Update failed.")
            return 1
        }
        return 0
    }

    private static func locateClaude() async -> Int32 {
        guard let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: AppDelegate.conversations) else {
            print("claude not found")
            return 1
        }
        print("claude: \(claude.executable.path)\nCLAUDE_CONFIG_DIR: \(claude.configDir?.path ?? "(default)")\nPATH: \(claude.searchPath)")
        return 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--resume` only finds sessions filed under the cwd the CLI ran in, so every turn uses this one.
    static let conversations = URL.applicationSupportDirectory.appending(path: "Balabro/conversations")

    private let savesRoot: URL
    private var runtime: CoachRuntime?
    private var pilot: PilotRuntime?
    private var overlay: OverlayPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private var gameText = GameText.missing
    private var statsWindow: NSWindow?

    init(savesRoot: URL) { self.savesRoot = savesRoot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await launch() }
    }

    private func launch() async {
        let game = GameInstall.find()
        let text = await game?.loadText() ?? .missing
        gameText = text
        _ = await game?.registerFont()
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: Self.conversations)

        let runtime = CoachRuntime(coach: Coach(text: text), store: .default, claude: claude)
        let pilot = PilotRuntime(pilot: Pilot(text: text), results: .default, claude: claude, game: game)
        let overlay = OverlayPanel(runtime: runtime, pilot: pilot, updater: updater)
        overlay.orderFrontRegardless()
        (self.runtime, self.pilot, self.overlay) = (runtime, pilot, overlay)
        hotKey = HotKey(HotKey.default) { overlay.focusQuestionField() }
        statusItem = makeStatusItem()
        if let updater { Task { await updater.watch() } }
        await runtime.start(watching: savesRoot)
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "suit.spade.fill", accessibilityDescription: "Balabro")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show overlay", action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Your stats", action: #selector(showStats), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Balabro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func showOverlay() { overlay?.orderFrontRegardless() }

    @objc private func showStats() {
        statsWindow?.close()
        let window = makeStatsWindow(StatsData.load(savesRoot: savesRoot, store: .default), text: gameText)
        statsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
