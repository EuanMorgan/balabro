import BalabroCore
import Foundation

/// The files both computers share: the runs, the bot's results and the settings. They live in the sync folder's
/// `Balabro` folder, or in the data folder when this computer doesn't sync.
public struct SharedFiles: Sendable {
    public let folder: URL
    /// Paths iCloud hadn't downloaded when Balabro opened. They're neither read nor written until the next launch, so a
    /// run started here without its history can't replace the other computer's copy.
    let notDownloaded: Set<String>

    static func open(_ folder: URL) async -> SharedFiles {
        async let top = Platform.download(folder)
        async let runs = Platform.download(folder.appending(path: "runs"))
        async let pilot = Platform.download(folder.appending(path: "pilot"))
        let missing = await top.union(runs.map { "runs/\($0)" }).union(pilot.map { "pilot/\($0)" })
        if !missing.isEmpty { Platform.log("Leaving \(missing.sorted()) alone until Balabro next opens, because iCloud hasn't downloaded them") }
        return SharedFiles(folder: folder, notDownloaded: missing)
    }

    func names(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: directory).path)) ?? []
    }

    func read(_ path: String) -> Data? {
        notDownloaded.contains(path) ? nil : try? Data(contentsOf: folder.appending(path: path))
    }

    func modified(_ path: String) -> Date {
        StatsData.modified(folder.appending(path: path))
    }

    /// `modified` keeps a copied run's date, which the stats show as when it was last played.
    func write(_ data: Data, to path: String, modified: Date? = nil) throws {
        guard !notDownloaded.contains(path) else { return }
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }

    /// A run's progress counters only go up, so the copy ahead is the later one. Equal or crossed counters fall back to the file date.
    func takeRuns(from other: SharedFiles) throws {
        for name in other.names(in: "runs") where name.hasSuffix(".json") {
            let path = "runs/\(name)"
            guard let data = other.read(path), let theirs = try? RunRecord(json: data) else { continue }
            if let mine = read(path).flatMap({ try? RunRecord(json: $0) }) {
                let (theirsAhead, mineAhead) = (mine.progress < theirs.progress, theirs.progress < mine.progress)
                guard theirsAhead != mineAhead ? theirsAhead : other.modified(path) > modified(path) else { continue }
            }
            try write(data, to: path, modified: other.modified(path))
        }
    }

    func takeResults(from other: SharedFiles) {
        let store = PilotResults(files: self)
        let mine = store.load()
        let merged = (mine + PilotResults(files: other).load().filter { !mine.contains($0) }).sorted { $0.finishedAt < $1.finishedAt }
        if merged != mine { store.save(merged) }
    }
}
