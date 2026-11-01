import BalabroCore
import Foundation

/// `runs/<RunKey>.json` in the shared files, one file per run.
/// A projection of `CoachState`, written whole on each `.save` effect, never read back except at launch.
public struct RunStore: Sendable {
    let files: SharedFiles

    public init(files: SharedFiles) { self.files = files }

    private var runs: [String] { files.names(in: "runs").filter { $0.hasSuffix(".json") }.map { "runs/\($0)" } }

    /// Unreadable files are skipped and logged, not fatal: losing one run's history beats not starting.
    func loadAll() -> [RunRecord] {
        runs.compactMap { path in
            guard let data = files.read(path) else { return nil }
            do {
                return try RunRecord(json: data)
            } catch {
                Platform.log("Skipping unreadable run \(path): \(error)")
                return nil
            }
        }
    }

    /// A record's file changes on every save, so its date is when the run was last played.
    func playedRuns() -> [PlayedRun] {
        runs.compactMap { path -> PlayedRun? in
            guard let summary = files.read(path).flatMap({ try? RunRecord(json: $0) })?.summary else { return nil }
            return PlayedRun(id: path, summary: summary, lastPlayed: files.modified(path))
        }
        .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    func save(_ record: RunRecord) throws {
        try files.write(record.json(), to: "runs/\(record.key).json")
    }
}
