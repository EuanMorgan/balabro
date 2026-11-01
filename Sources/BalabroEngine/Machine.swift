import BalabroCore
import Foundation

/// `machine.json` in the data folder: this computer's ID. It stays on this computer.
public struct Machine: Sendable, Equatable {
    public let id: MachineID
    let dataFolder: URL

    /// Makes an ID the first time, so each computer keeps its own from then on.
    public static func load(dataFolder: URL = Platform.dataFolder) -> Machine {
        let file = dataFolder.appending(path: "machine.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            return Machine(id: saved.machine, dataFolder: dataFolder)
        }
        let machine = Machine(id: MachineID(rawValue: UUID().uuidString), dataFolder: dataFolder)
        do {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(machine: machine.id)).write(to: file, options: .atomic)
        } catch {
            Platform.log("Couldn't save machine.json: \(error)")
        }
        return machine
    }

    private struct Saved: Codable {
        var machine: MachineID
    }
}
