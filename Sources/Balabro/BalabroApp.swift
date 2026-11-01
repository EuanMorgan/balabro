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
        await startEngine()
        _ = await engine?.game?.registerFont()
        hotKey = HotKey(HotKey.default) { [weak self] in self?.overlay?.focusQuestionField() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "suit.spade.fill", accessibilityDescription: "Balabro")
        statusItem?.menu = makeMenu()
        if let updater { Task { await updater.watch() } }
    }

    private func startEngine() async {
        let engine = await Engine.start(savesRoot: savesRoot, capture: GameWindow.capturePNG)
        let overlay = OverlayPanel(runtime: engine.coach, pilot: engine.pilot, updater: updater)
        overlay.orderFrontRegardless()
        (self.engine, self.overlay) = (engine, overlay)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show overlay", action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move overlay to the corner", action: #selector(moveOverlayToCorner), keyEquivalent: "").target = self
        menu.addItem(withTitle: StatsPage.menuTitle, action: #selector(showStats), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sync with another computer…", action: #selector(chooseSyncFolder), keyEquivalent: "").target = self
        if let folder = engine?.machine.syncFolder {
            let syncing = menu.addItem(withTitle: "Syncing through \(FileManager.default.displayName(atPath: folder.path))", action: nil, keyEquivalent: "")
            syncing.isEnabled = false
            menu.addItem(withTitle: "Stop syncing", action: #selector(stopSyncing), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Balabro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func showOverlay() { overlay?.orderFrontRegardless() }

    @objc private func moveOverlayToCorner() {
        overlay?.moveToCorner()
        overlay?.orderFrontRegardless()
    }

    @objc private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.canCreateDirectories) = (true, false, true)
        panel.message = "Choose a folder that iCloud Drive, OneDrive or Dropbox keeps the same on your other computer. Balabro keeps your runs in a Balabro folder inside it."
        panel.prompt = "Sync Here"
        let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        panel.directoryURL = engine?.machine.syncFolder ?? iCloudDrive
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await setSyncFolder(folder) }
    }

    @objc private func stopSyncing() { Task { await setSyncFolder(nil) } }

    /// A new engine, so nothing from the old place is left running.
    private func setSyncFolder(_ folder: URL?) async {
        guard let engine else { return }
        await engine.shutdown()
        do {
            _ = try await engine.machine.syncing(with: folder)
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        // The new panel can only take over the saved position once the old one gives up its name.
        overlay?.setFrameAutosaveName("")
        overlay?.orderOut(nil)
        overlay = nil
        statsWindow?.close()
        await startEngine()
        statusItem?.menu = makeMenu()
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
