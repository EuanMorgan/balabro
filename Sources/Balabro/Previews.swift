#if DEBUG
import AppKit
import BalabroCore
import BalabroEngine
import SwiftUI

/// `Balabro --render-previews <dir>` (debug builds only) writes each of `PreviewState.all` as a PNG, and the stats window.
@MainActor
enum Previews {
    static func render(to directory: URL) async -> Int32 {
        _ = await GameInstall.find()?.registerFont()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in PreviewState.all(now: .now) {
            let png = switch state.panel {
            case .coach(let view):
                snapshot(OverlayContent(view: view, ask: { _ in }, retry: {}, update: state.update.map(Updater.Status.available) ?? .none, showWhy: state.showsWhy), height: state.height)
            case .pilot(let view):
                snapshot(PilotPanel(view: view, stop: {}, close: {}, again: {}), height: state.height)
            }
            guard let png else { return 1 }
            let url = directory.appending(path: "\(state.name).png")
            try? png.write(to: url)
            print(url.path)
        }
        let stats = StatsView(page: StatsPage(StatsData.load(savesRoot: Platform.defaultSavesRoot, store: RunStore(files: await Machine.load().open())), text: await GameInstall.find()?.loadText() ?? .missing))
        try? snapshot(stats, width: 520, height: 900)?.write(to: directory.appending(path: "stats.png"))
        return 0
    }

    /// Through a window rather than `ImageRenderer`, which draws AppKit-backed views (the scroll view,
    /// the text field) as placeholders.
    private static func snapshot(_ content: some View, width: CGFloat = 320, height: CGFloat) -> Data? {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        RunLoop.main.run(until: .now + 0.3)
        defer { window.close() }
        guard let view = window.contentView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
