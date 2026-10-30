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

    private static func label(_ kind: Decision.Kind) -> String {
        switch kind {
        case .playHand: "play hand"
        case .shop: "shop"
        case .blindSelect: "blind select"
        case .openPack(let pack, .shop): "open \(pack.key) from the shop"
        case .openPack(let pack, .skipTag(let tag)): "open \(pack.key) from \(tag.rawValue)"
        }
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
    private var overlay: OverlayPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private let updater = Updater()

    init(savesRoot: URL) { self.savesRoot = savesRoot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await launch() }
    }

    private func launch() async {
        let game = GameInstall.find()
        let text = await game?.loadText() ?? .missing
        _ = await game?.registerFont()
        let claude = await ClaudeLocator.resolve(override: nil, workingDirectory: Self.conversations)

        let runtime = CoachRuntime(coach: Coach(text: text), store: .default, claude: claude)
        let overlay = OverlayPanel(runtime: runtime, updater: updater)
        overlay.orderFrontRegardless()
        (self.runtime, self.overlay) = (runtime, overlay)
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Balabro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func showOverlay() { overlay?.orderFrontRegardless() }
}
