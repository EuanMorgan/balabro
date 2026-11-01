import AppKit
import BalabroCore
import BalabroEngine
import SwiftUI

/// Same window level and Spaces as the overlay, so it opens over Balatro in fullscreen.
@MainActor
func makeStatsWindow(_ data: StatsData, text: GameText) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Balabro stats"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.backgroundColor = NSColor(Theme.felt)
    window.contentView = NSHostingView(rootView: StatsView(data: data, text: text))
    window.center()
    return window
}

struct StatsView: View {
    let data: StatsData
    let text: GameText

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let career = data.career, career.rounds > 0 {
                    totals(career)
                }
                if data.runs.count >= 2 {
                    AnteChart(runs: Array(data.runs.prefix(20).reversed()), deckName: name)
                }
                if let career = data.career {
                    if !career.hands.isEmpty {
                        BarList(title: "Hands you play most", items: Array(career.hands.prefix(9)))
                    }
                    if !career.jokers.isEmpty {
                        BarList(title: "Jokers you use most", items: career.jokers.prefix(8).map { .init(name: name(CenterKey(rawValue: $0.name)), count: $0.count) })
                    }
                }
                recentRuns
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Theme.felt)
    }

    private func name(_ key: CenterKey) -> String { text[key]?.name ?? key.rawValue }

    private func totals(_ career: CareerStats) -> some View {
        Section("All time") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                Tile(label: "Runs", value: career.runs.formatted())
                Tile(label: "Wins", value: career.wins.formatted())
                Tile(label: "Rounds", value: career.rounds.formatted())
                Tile(label: "Best ante", value: career.furthestAnte.formatted())
                Tile(label: "Best hand", value: score(career.bestHand))
                Tile(label: "Most money", value: "$\(career.mostMoney.formatted())", colour: Theme.money)
            }
        }
    }

    private var recentRuns: some View {
        Section("Runs Balabro has seen") {
            if data.runs.isEmpty {
                Text("Your runs appear here as you play them.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(data.runs.prefix(20)) { run in
                    RunRow(run: run, deck: name(run.summary.deck), jokers: run.summary.jokers.map(name), best: score(run.summary.bestHand))
                }
            }
        }
    }

    private func score(_ value: Double) -> String {
        guard value.isFinite else { return "naneinf" }
        return value < 1e15 ? Int(value).formatted() : String(format: "%.3e", value)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) { (self.title, self.content) = (title, content()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.pixelFont(2)).foregroundStyle(Theme.chips)
            content
        }
    }
}

private struct Tile: View {
    let label: String
    let value: String
    var colour = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.pixelFont(2)).foregroundStyle(colour)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

/// One series, so one colour. Every bar carries its own name and value.
private struct BarList: View {
    let title: String
    let items: [CareerStats.Count]

    var body: some View {
        Section(title) {
            let top = max(items.map(\.count).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.name) { item in
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        GeometryReader { space in
                            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(Theme.chips)
                                .frame(width: max(2, space.size.width * Double(item.count) / Double(top)))
                        }
                        .frame(height: 12)
                        Text(item.count.formatted())
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help("\(item.name): \(item.count.formatted())")
                }
            }
        }
    }
}

private struct AnteChart: View {
    let runs: [PlayedRun]
    let deckName: (CenterKey) -> String
    private static let height = 64.0

    var body: some View {
        Section("How far you got, oldest to newest") {
            let top = Double(max(runs.map(\.summary.ante).max() ?? 1, 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(runs) { run in
                        VStack(spacing: 2) {
                            Text("\(run.summary.ante)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(Theme.chips)
                                .frame(height: Self.height * Double(run.summary.ante) / top)
                        }
                        .frame(maxWidth: 28)
                        .help("Ante \(run.summary.ante), \(deckName(run.summary.deck)), \(run.lastPlayed.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                Text("Ante reached in each run")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct RunRow: View {
    let run: PlayedRun
    let deck: String
    let jokers: [String]
    let best: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(outcome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(deck).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Text(run.lastPlayed.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            ColouredText(details, size: 12)
                .foregroundStyle(Theme.muted)
        }
    }

    private var outcome: String {
        let s = run.summary
        return s.won ? "Won, reached Ante \(s.ante)" : s.ended ? "Reached Ante \(s.ante)" : "In progress, Ante \(s.ante)"
    }

    private var details: String {
        let s = run.summary
        return (["Best hand \(best)", "peak $\(s.peakDollars)"]
            + (s.mostPlayedHand.map { ["mostly \($0)"] } ?? [])
            + (jokers.isEmpty ? [] : [jokers.joined(separator: ", ")])).joined(separator: " · ")
    }
}
