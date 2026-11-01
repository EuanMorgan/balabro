import BalabroCore
import Foundation

/// `settings.json`, beside the runs, so a computer that shares the runs shares these too.
struct Settings: Codable, Equatable {
    var goal: CoachGoal

    /// The goal was kept in UserDefaults before settings.json, so that's where it comes from until the file exists.
    static func load(from file: URL) -> Settings {
        if let data = try? Data(contentsOf: file), let settings = try? JSONDecoder().decode(Settings.self, from: data) { return settings }
        return Settings(goal: UserDefaults.standard.string(forKey: "goal").flatMap(CoachGoal.init) ?? .win)
    }

    func save(to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        } catch {
            Platform.log("Couldn't save settings.json: \(error)")
        }
    }
}
