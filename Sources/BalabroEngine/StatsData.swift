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
