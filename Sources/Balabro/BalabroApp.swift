import AppKit
import BalabroCore
import BalabroEngine

/// Menu-bar-only app (`LSUIElement`), so the overlay can sit over Balatro's fullscreen Space
/// and clicking it never pulls the user out of the game.
@main
@MainActor
enum BalabroApp {
    static let updateFlag = "--update"

    static func main() async {
        Platform.ignoreBrokenPipes()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let status = await EngineCommand.run(arguments) { exit(status) }
        if arguments.contains(updateFlag) {
            exit(await update())
        }
        #if DEBUG
        if let directory = arguments.firstIndex(of: "--render-previews").flatMap({ arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }) {
            exit(await Previews.render(to: URL(filePath: directory)))
        }
        #endif

        let app = NSApplication.shared
        let delegate = AppDelegate(savesRoot: EngineCommand.savesRoot(arguments))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let savesRoot: URL
    private var engine: Engine?
    private var overlay: OverlayPanel?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private let updater = Updater()
    private var statsWindow: NSWindow?

    init(savesRoot: URL) { self.savesRoot = savesRoot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await launch() }
    }

    private func launch() async {
        let engine = await Engine.start(savesRoot: savesRoot, capture: GameWindow.capturePNG)
        _ = await engine.game?.registerFont()
        let overlay = OverlayPanel(runtime: engine.coach, pilot: engine.pilot, updater: updater)
        overlay.orderFrontRegardless()
        (self.engine, self.overlay) = (engine, overlay)
        hotKey = HotKey(HotKey.default) { overlay.focusQuestionField() }
        statusItem = makeStatusItem()
        if let updater { Task { await updater.watch() } }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "suit.spade.fill", accessibilityDescription: "Balabro")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show overlay", action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move overlay to the corner", action: #selector(moveOverlayToCorner), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Your stats", action: #selector(showStats), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Balabro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }

    @objc private func showOverlay() { overlay?.orderFrontRegardless() }

    @objc private func moveOverlayToCorner() {
        overlay?.moveToCorner()
        overlay?.orderFrontRegardless()
    }

    @objc private func showStats() {
        statsWindow?.close()
        guard let engine else { return }
        let window = makeStatsWindow(engine.stats())
        statsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
