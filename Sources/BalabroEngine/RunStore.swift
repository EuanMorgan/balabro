import BalabroCore
import Foundation

/// `runs/<RunKey>.json` in the data folder, one file per run.
/// A projection of `CoachState`, written whole on each `.save` effect, never read back except at launch.
public struct RunStore: Sendable {
    let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var `default`: RunStore { RunStore(directory: Platform.dataFolder.appending(path: "runs")) }

    /// Unreadable files are skipped and logged, not fatal: losing one run's history beats not starting.
    func loadAll() -> [RunRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try RunRecord(json: Data(contentsOf: file))
            } catch {
                Platform.log("Skipping unreadable run \(file.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    /// A record's file changes on every save, so its date is when the run was last played.
    func playedRuns() -> [PlayedRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> PlayedRun? in
            guard let data = try? Data(contentsOf: file), let summary = (try? RunRecord(json: data))?.summary else { return nil }
            return PlayedRun(id: file.lastPathComponent, summary: summary, lastPlayed: StatsData.modified(file))
        }
        .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func save(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try record.json().write(to: directory.appending(path: "\(record.key).json"), options: .atomic)
    }
}
