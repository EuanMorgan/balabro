#if DEBUG
import AppKit
import BalabroCore
import SwiftUI

/// `Balabro --render-previews <dir>` (debug builds only) writes the overlay in five states as PNGs.
@MainActor
enum Previews {
    static func render(to directory: URL) async -> Int32 {
        _ = await GameInstall.find()?.registerFont()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, CoachView, Bool, CGFloat, Updater.Status)] = [
            ("waiting", CoachView(status: .waitingForRun, headline: "", advice: nil, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .none),
            ("streaming", CoachView(status: .answering, headline: "Ante 1 · Big Blind · hand 1", advice: streaming, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .none),
            ("finished", CoachView(status: .ready, headline: "Ante 1 · Big Blind · hand 1", advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), true, 560, .none),
            ("update", CoachView(status: .ready, headline: "Ante 1 · Big Blind · hand 1", advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .available(release)),
            ("follow-up", CoachView(status: .ready, headline: "Ante 1 · Big Blind · hand 1", advice: finished, thread: thread, queuedQuestion: nil, problem: nil, canRetry: false), false, 520, .none),
        ]
        for (name, view, showWhy, height, update) in states {
            let url = directory.appending(path: "overlay-\(name).png")
            guard let png = snapshot(OverlayContent(view: view, ask: { _, _ in }, retry: {}, update: update, showWhy: showWhy), height: height) else { return 1 }
            try? png.write(to: url)
            print(url.path)
        }
        return 0
    }

    /// Through a window rather than `ImageRenderer`, which draws AppKit-backed views (the scroll view,
    /// the text field) as placeholders.
    private static func snapshot(_ content: some View, height: CGFloat) -> Data? {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 320, height: height), styleMask: .borderless, backing: .buffered, defer: false)
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

    private static let finished = Advice(
        doNow: [
            "Discard 7♠ 6♥ 5♠ 2♦.",
            "Keep K♥ K♣ 3♠ 3♦. Any King or 3 makes a Full House.",
            "Play the Full House if it lands, otherwise play K-K-3-3.",
        ],
        why: [
            "Big Blind needs 450. Two Pair K-K-3-3 scores (20 + 26) × 2 = **92**.",
            "A Full House K-K-K-3-3 scores (40 + 39) × 4 = **316**, more than three times as much.",
            "4 outs (2 Kings, 2 threes) in 44 cards. Drawing 4 hits about 1 time in 3.",
        ],
        lesson: Advice.Lesson(number: 3, title: "Two Pair is a draw, not a finish",
                              body: "Early in a blind, keep the pairs and throw the rest. You have hands to spare."),
        rest: "")

    private static let release = AppRelease(
        version: AppVersion("0.2.0")!,
        download: URL(filePath: "/dev/null"), page: URL(filePath: "/dev/null"))

    private static let thread = [
        CoachView.FollowUp(question: "Why not keep the 7♠?", reply: "It doesn't pair with anything, and K-K-3-3 only wants a King or a 3. Holding it costs you a draw at **4 outs**.", changedSteps: false),
        CoachView.FollowUp(question: "I'd rather keep the 2♦ for Hack", reply: "Fair, Hack retriggers it, so it adds chips to any hand it's in.", changedSteps: true),
    ]

    private static let streaming = Advice(
        doNow: ["Discard 7♠ 6♥ 5♠ 2♦.", "Keep K♥ K♣ 3♠ 3♦. Any King"],
        why: [], lesson: nil, rest: "")
}
#endif
