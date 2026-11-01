#if DEBUG
import AppKit
import BalabroCore
import BalabroEngine
import SwiftUI

/// `Balabro --render-previews <dir>` (debug builds only) writes the overlay in five states as PNGs.
@MainActor
enum Previews {
    static func render(to directory: URL) async -> Int32 {
        _ = await GameInstall.find()?.registerFont()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, CoachView, Bool, CGFloat, Updater.Status)] = [
            ("waiting", CoachView(status: .waitingForRun, headline: "", advice: nil, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .none),
            ("streaming", CoachView(status: .answering, headline: "Ante 1 · Big Blind", advice: streaming, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .none),
            ("finished", CoachView(status: .ready, headline: "Ante 1 · Big Blind", chipsNeeded: 450, advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), true, 560, .none),
            ("naneinf", CoachView(status: .ready, goal: .naneinf, headline: "Ante 26 · The Serpent", chipsNeeded: 3e184, advice: naneinf, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .none),
            ("estimate", CoachView(status: .ready, headline: "Ante 6 · Small Blind", chipsNeeded: 20000, advice: estimate, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), true, 420, .none),
            ("cash", CoachView(status: .ready, headline: "Ante 3 · Shop", advice: cash, thread: [], queuedQuestion: "Is $4 worth it?", problem: nil, canRetry: false), true, 520, .none),
            ("update", CoachView(status: .ready, headline: "Ante 1 · Big Blind", advice: finished, thread: [], queuedQuestion: nil, problem: nil, canRetry: false), false, 420, .available(release)),
            ("follow-up", CoachView(status: .ready, headline: "Ante 1 · Big Blind", advice: finished, thread: thread, queuedQuestion: nil, problem: nil, canRetry: false), false, 520, .none),
        ]
        for (name, view, showWhy, height, update) in states {
            let url = directory.appending(path: "overlay-\(name).png")
            guard let png = snapshot(OverlayContent(view: view, ask: { _ in }, retry: {}, update: update, showWhy: showWhy), height: height) else { return 1 }
            try? png.write(to: url)
            print(url.path)
        }
        let run = BotStatus(ante: 4, round: 11, dollars: 41, bestHand: 4420, doing: "Discarding 3 cards, 61% to reach 2,442")
        let result = PilotResult(goal: "win", deck: CenterKey(rawValue: "b_red"), stake: 1, ending: .won, ante: 8, round: 24, bestHand: 88_000, seconds: 412, gameVersion: "1.0.1o", finishedAt: .now)
        let pilots: [(String, PilotView)] = [
            ("playing", PilotView(status: .playing, startedAt: .now.addingTimeInterval(-136), run: run, why: "Hologram gives scaling XMult, which beats Sly Joker's flat chips, for $6.")),
            ("finished", PilotView(status: .finished, result: result, bestTimes: [BestTime(title: "Fastest win", seconds: 412)])),
        ]
        for (name, view) in pilots {
            let url = directory.appending(path: "pilot-\(name).png")
            guard let png = snapshot(PilotPanel(view: view, stop: {}, close: {}, again: {}), height: 300) else { return 1 }
            try? png.write(to: url)
            print(url.path)
        }
        let stats = StatsView(data: StatsData.load(savesRoot: Platform.defaultSavesRoot, store: .default), text: await GameInstall.find()?.loadText() ?? .missing)
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

    private static let finished = Advice(
        doNow: [
            "Discard 7♠ 6♥ 5♠ 2♦.",
            "Keep K♥ K♣ 3♠ 3♦. Any King or 3 makes a Full House.",
            "Play the Full House if it lands, otherwise play K-K-3-3.",
        ],
        score: [
            .init(label: "Full House, if you draw it", sum: .init(chips: "79", mult: "4", total: "316")),
            .init(label: "Instead: Two Pair", sum: .init(chips: "46", mult: "2", total: "92"), isAlternative: true),
        ],
        goal: "Going for a Full House",
        why: [
            "Big Blind needs 450. Two Pair K-K-3-3 scores (20 + 26) × 2 = **92**.",
            "A Full House K-K-K-3-3 scores (40 + 39) × 4 = **316**, more than three times as much.",
            "4 outs (2 Kings, 2 threes) in 44 cards. Drawing 4 hits about 1 time in 3.",
        ],
        lesson: Advice.Lesson(number: 3, title: "Two Pair is a draw, not a finish",
                              body: "Early in a blind, keep the pairs and throw the rest. You have hands to spare."),
        rest: "")

    private static let estimate = Advice(
        doNow: ["Play 7♦ 6♠ 4♠ 3♥ 3♣."],
        score: [
            .init(label: "Pair of 3s", sum: .init(chips: "226", mult: "49", total: "11,074", isEstimate: true)),
            .init(label: "Instead: High Card", sum: .init(chips: "205", mult: "35", total: "7,175", isEstimate: true), isAlternative: true),
        ],
        why: ["Misprint averages +11.5 Mult, but it can be anything from +0 to +23."],
        lesson: nil, rest: "")

    private static let cash = Advice(
        doNow: ["Buy Golden Joker (right, $6).", "Keep K♠ 3♦ for later, then reroll for $5, leaving $1,000, as planned."],
        goal: "Stay above $25",
        why: ["$25 earns the full $5 of interest."],
        lesson: Advice.Lesson(number: 2, title: "Spend what's above $25", body: "Money past the cap, such as the $7 here, earns nothing."),
        rest: "")

    private static let naneinf = Advice(
        doNow: ["Play K♠."],
        score: [
            .init(label: "High Card", sum: .init(chips: "1.2e150", mult: "3.5e157", total: "naneinf")),
            .init(label: "Instead: Pair of Kings", sum: .init(chips: "2.1e60", mult: "1.5e80", total: "3.2e140"), isAlternative: true),
        ],
        why: ["Every King held multiplies the mult, so the played hand hardly matters."],
        lesson: nil, rest: "")

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
