import AppKit
import BalabroCore
import BalabroEngine
import SwiftUI

/// Same window level and Spaces as the overlay, so it opens over Balatro in fullscreen.
@MainActor
func makeStatsWindow(_ page: StatsPage) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = page.title
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.backgroundColor = NSColor(Theme.felt)
    window.contentView = NSHostingView(rootView: StatsView(page: page))
    window.center()
    return window
}

struct StatsView: View {
    let page: StatsPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let totals = page.totals {
                    Section(totals.title) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                            ForEach(totals.tiles, id: \.label) { Tile(tile: $0) }
                        }
                    }
                }
                if let chart = page.anteChart {
                    AnteChart(chart: chart)
                }
                if let hands = page.hands {
                    BarList(list: hands)
                }
                if let jokers = page.jokers {
                    BarList(list: jokers)
                }
                Section(page.runs.title) {
                    if let empty = page.runs.empty {
                        Text(empty)
                            .font(Theme.body)
                            .foregroundStyle(Theme.muted)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(page.runs.rows) { RunRow(run: $0) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Theme.felt)
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
    let tile: StatsPage.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.value).font(Theme.pixelFont(2)).foregroundStyle(tile.isMoney ? Theme.money : Theme.text)
            Text(tile.label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

/// One series, so one colour. Every bar carries its own name and value.
private struct BarList: View {
    let list: StatsPage.BarList

    var body: some View {
        Section(list.title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list.bars, id: \.label) { bar in
                    HStack(spacing: 8) {
                        Text(bar.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        GeometryReader { space in
                            UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                                .fill(Theme.chips)
                                .frame(width: max(2, space.size.width * bar.share))
                        }
                        .frame(height: 12)
                        Text(bar.value)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help(bar.help)
                }
            }
        }
    }
}

private struct AnteChart: View {
    let chart: StatsPage.AnteChart
    private static let height = 64.0

    var body: some View {
        Section(chart.title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(chart.columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: 2) {
                            Text(column.ante)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(Theme.chips)
                                .frame(height: Self.height * column.share)
                        }
                        .frame(maxWidth: 28)
                        .help(column.help)
                    }
                }
                Text(chart.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct RunRow: View {
    let run: StatsPage.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(run.outcome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(run.deck).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Text(run.date)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            ColouredText(run.details, size: 12)
                .foregroundStyle(Theme.muted)
        }
    }
}
