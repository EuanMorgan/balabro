import AppKit
import BalabroCore

/// Menu-bar-only app (`LSUIElement`), so the overlay can sit over Balatro's fullscreen Space
/// and clicking it never pulls the user out of the game.
@main
@MainActor
enum BalabroApp {
    static func main() {
        // TODO: `Balabro --print-prompt <save.jkr>` prints the decision kind, title and prompt text for one
        //       save and exits, so a save from a real run can be checked without starting the overlay.
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: CoachRuntime?
    private var overlay: OverlayPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TODO, in order:
        //   1. game = GameInstall.find(); text = await game?.loadText() ?? .missing; game?.registerFont()
        //   2. claude = await ClaudeLocator.resolve(override: Settings.claudeOverride)   // may fail -> overlay shows setup
        //   3. runtime = CoachRuntime(coach: Coach(text: text), store: RunStore.default, claude: claude)
        //   4. overlay = OverlayPanel(runtime: runtime); overlay.orderFrontRegardless()
        //   5. hotKey = HotKey(.default) { overlay.focusQuestionField() }
        //   6. statusItem menu: Show overlay, Claude settings..., Quit
        //   7. runtime.start()   // restores runs, then consumes SaveWatcher's events forever
        fatalError("not implemented")
    }
}
