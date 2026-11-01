import BalabroCore
import Foundation

public struct PlayedRun: Identifiable, Sendable {
    public let id: String
    public let summary: RunSummary
    public let lastPlayed: Date
}

public struct StatsData: Sendable {
    public var career: CareerStats?
    /// Newest first.
    public var runs: [PlayedRun]

    /// The profile touched most recently is the one being played.
    public static func load(savesRoot: URL, store: RunStore) -> StatsData {
        let career = newestProfile(savesRoot).flatMap { try? Data(contentsOf: $0) }.flatMap { try? SaveFile.decodeCareer($0) }
        return StatsData(career: career, runs: store.playedRuns())
    }

    static func progress(savesRoot: URL) -> PlayerProgress? {
        guard let profile = newestProfile(savesRoot), let bytes = try? Data(contentsOf: profile) else { return nil }
        let meta = try? Data(contentsOf: profile.deletingLastPathComponent().appending(path: "meta.jkr"))
        return try? SaveFile.decodeProgress(profile: bytes, meta: meta)
    }

    private static func newestProfile(_ savesRoot: URL) -> URL? {
        SaveWatcher.profiles.map { savesRoot.appending(path: "\($0)/profile.jkr") }.max { modified($0) < modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Everything the stats window shows, in words and shares, so the Mac window and the Windows app draw the same page.
/// A section the player has no data for is nil.
public struct StatsPage: Sendable, Equatable, Encodable {
    public struct Totals: Sendable, Equatable, Encodable {
        public var title = "All time"
        public var tiles: [Tile]
    }

    public struct Tile: Sendable, Equatable, Encodable {
        public var label: String
        public var value: String
        public var isMoney = false
    }

    public struct AnteChart: Sendable, Equatable, Encodable {
        public var title = "How far you got, oldest to newest"
        public var caption = "Ante reached in each run"
        /// Oldest first.
        public var columns: [Column]
    }

    public struct Column: Sendable, Equatable, Encodable {
        public var ante: String
        /// The column's height as a share of the tallest the chart can draw, from 0 to 1.
        public var share: Double
        public var help: String
    }

    public struct BarList: Sendable, Equatable, Encodable {
        public var title: String
        public var bars: [Bar]
    }

    public struct Bar: Sendable, Equatable, Encodable {
        public var label: String
        public var value: String
        /// The bar's length as a share of the longest the chart can draw, from 0 to 1.
        public var share: Double
        public var help: String
    }

    public struct RunList: Sendable, Equatable, Encodable {
        public var title = "Runs Balabro has seen"
        public var empty: String?
        public var rows: [Run]
    }

    public struct Run: Sendable, Equatable, Encodable, Identifiable {
        public var id: String
        public var outcome: String
        public var deck: String
        public var date: String
        public var details: String
    }

    public var title = "Balabro stats"
    public var totals: Totals?
    public var anteChart: AnteChart?
    public var hands: BarList?
    public var jokers: BarList?
    public var runs: RunList

    /// `locale` and `timeZone` are the player's, and fixed only by tests.
    public init(_ data: StatsData, text: GameText, locale: Locale = .current, timeZone: TimeZone = .current) {
        func name(_ key: CenterKey) -> String { text[key]?.name ?? key.rawValue }
        func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        func score(_ value: Double) -> String {
            guard value.isFinite else { return "naneinf" }
            return value < 1e15 ? number(Int(value)) : String(format: "%.3e", value)
        }
        func date(_ value: Date, time: Date.FormatStyle.TimeStyle) -> String {
            value.formatted(Date.FormatStyle(date: .abbreviated, time: time, locale: locale, calendar: locale.calendar, timeZone: timeZone))
        }
        func bars(_ title: String, _ counts: some Collection<CareerStats.Count>, name: (String) -> String) -> BarList? {
            guard !counts.isEmpty else { return nil }
            let top = max(counts.map(\.count).max() ?? 1, 1)
            return BarList(title: title, bars: counts.map { count in
                Bar(label: name(count.name), value: number(count.count), share: Double(count.count) / Double(top), help: "\(name(count.name)): \(number(count.count))")
            })
        }

        if let career = data.career, career.rounds > 0 {
            totals = Totals(tiles: [
                Tile(label: "Runs", value: number(career.runs)),
                Tile(label: "Wins", value: number(career.wins)),
                Tile(label: "Rounds", value: number(career.rounds)),
                Tile(label: "Best ante", value: number(career.furthestAnte)),
                Tile(label: "Best hand", value: score(career.bestHand)),
                Tile(label: "Most money", value: "$\(number(career.mostMoney))", isMoney: true),
            ])
        }
        let recent = data.runs.prefix(20)
        if recent.count >= 2 {
            let top = Double(max(recent.map(\.summary.ante).max() ?? 1, 8))
            anteChart = AnteChart(columns: recent.reversed().map { run in
                Column(ante: "\(run.summary.ante)", share: Double(run.summary.ante) / top,
                    help: "Ante \(run.summary.ante), \(name(run.summary.deck)), \(date(run.lastPlayed, time: .omitted))")
            })
        }
        hands = data.career.flatMap { bars("Hands you play most", $0.hands.prefix(9)) { $0 } }
        jokers = data.career.flatMap { bars("Jokers you use most", $0.jokers.prefix(8)) { name(CenterKey(rawValue: $0)) } }
        runs = RunList(empty: data.runs.isEmpty ? "Your runs appear here as you play them." : nil, rows: recent.map { run in
            let s = run.summary
            let details = ["Best hand \(score(s.bestHand))", "peak $\(s.peakDollars)"]
                + (s.mostPlayedHand.map { ["mostly \($0)"] } ?? [])
                + (s.jokers.isEmpty ? [] : [s.jokers.map(name).joined(separator: ", ")])
            return Run(
                id: run.id,
                outcome: s.won ? "Won, reached Ante \(s.ante)" : s.ended ? "Reached Ante \(s.ante)" : "In progress, Ante \(s.ante)",
                deck: name(s.deck), date: date(run.lastPlayed, time: .shortened), details: details.joined(separator: " · "))
        })
    }
}
