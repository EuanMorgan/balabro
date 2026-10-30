import BalabroCore
import Foundation
import os

/// `~/Library/Application Support/Balabro/runs/<RunKey>.json`, one file per run.
/// A projection of `CoachState`, written whole on each `.save` effect, never read back except at launch.
struct RunStore: Sendable {
    let directory: URL

    static var `default`: RunStore { RunStore(directory: .applicationSupportDirectory.appending(path: "Balabro/runs")) }

    /// Unreadable files are skipped and logged, not fatal: losing one run's history beats not starting.
    func loadAll() -> [RunRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: file))
            } catch {
                Logger.balabro.error("Skipping unreadable run \(file.lastPathComponent, privacy: .public): \(error)")
                return nil
            }
        }
    }

    /// A record's file changes on every save, so its date is when the run was last played.
    func playedRuns() -> [PlayedRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> PlayedRun? in
            guard let data = try? Data(contentsOf: file), let summary = (try? JSONDecoder().decode(RunRecord.self, from: data))?.summary else { return nil }
            return PlayedRun(id: file.lastPathComponent, summary: summary, lastPlayed: StatsData.modified(file))
        }
        .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func save(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(record).write(to: directory.appending(path: "\(record.key).json"), options: .atomic)
    }
}

extension Logger {
    static let balabro = Logger(subsystem: "com.euanmorgan.balabro", category: "app")
}
