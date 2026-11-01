import BalabroCore
import Foundation

/// `settings.json`, beside the runs, so a computer that shares the runs shares these too.
struct Settings: Codable, Equatable {
    var goal: CoachGoal

    private static let path = "settings.json"

    static func stored(in files: SharedFiles) -> Settings? {
        files.read(path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
    }

    /// The goal was kept in UserDefaults before settings.json, so that's where it comes from until the file exists.
    static func load(from files: SharedFiles) -> Settings {
        stored(in: files) ?? Settings(goal: UserDefaults.standard.string(forKey: "goal").flatMap(CoachGoal.init) ?? .win)
    }

    func save(to files: SharedFiles) {
        do { try files.write(JSONEncoder().encode(self), to: Self.path) } catch { Platform.log("Couldn't save settings.json: \(error)") }
    }
}
