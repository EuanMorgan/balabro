import BalabroCore
import Foundation

/// `machine.json` in the data folder: this computer's ID and the folder it syncs through. It stays on this computer.
public struct Machine: Sendable, Equatable {
    public let id: MachineID
    /// A folder a sync service keeps the same on the owner's computers, or nil when this one doesn't sync.
    public let syncFolder: URL?
    let dataFolder: URL

    var sharedFolder: URL { syncFolder?.appending(path: "Balabro") ?? dataFolder }

    /// Makes an ID the first time, so each computer keeps its own from then on.
    public static func load(dataFolder: URL = Platform.dataFolder) -> Machine {
        if let data = try? Data(contentsOf: dataFolder.appending(path: file)), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            return Machine(id: saved.machine, syncFolder: saved.syncFolder.map { URL(filePath: $0) }, dataFolder: dataFolder)
        }
        let machine = Machine(id: MachineID(rawValue: UUID().uuidString), syncFolder: nil, dataFolder: dataFolder)
        do { try machine.save() } catch { Platform.log("Couldn't save machine.json: \(error)") }
        return machine
    }

    public func open() async -> SharedFiles { await SharedFiles.open(sharedFolder) }

    /// Moves the shared files to `folder`, or back to the data folder when nil. The files go with the move, and nothing is
    /// deleted, so the data folder keeps its copies for when the owner stops syncing. The sync folder's settings win,
    /// because they're what the other computer has been using.
    public func syncing(with folder: URL?) async throws -> Machine {
        let next = Machine(id: id, syncFolder: folder, dataFolder: dataFolder)
        try FileManager.default.createDirectory(at: next.sharedFolder, withIntermediateDirectories: true)
        let (from, to) = (await open(), await next.open())
        try to.takeRuns(from: from)
        to.takeResults(from: from)
        let (synced, local) = folder == nil ? (from, to) : (to, from)
        (Settings.stored(in: synced) ?? Settings.load(from: local)).save(to: to)
        try next.save()
        return next
    }

    private static let file = "machine.json"

    private func save() throws {
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Saved(machine: id, syncFolder: syncFolder.map(Platform.path))).write(to: dataFolder.appending(path: Self.file), options: .atomic)
    }

    private struct Saved: Codable {
        var machine: MachineID
        var syncFolder: String?

        /// `null` rather than leaving the key out, so the file says this computer doesn't sync.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(machine, forKey: .machine)
            try container.encode(syncFolder, forKey: .syncFolder)
        }
    }
}
