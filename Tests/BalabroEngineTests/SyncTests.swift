import BalabroEngine
import Foundation
import Testing

/// Choosing and leaving a sync folder, through `Machine` and the files the other computer reads.
@Suite
struct SyncTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "balabro-sync-\(UUID().uuidString)")
    var local: URL { root.appending(path: "data") }
    var sync: URL { root.appending(path: "iCloud Drive") }
    var shared: URL { sync.appending(path: "Balabro") }

    func write(_ text: String, to file: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }

    func json(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    /// A run on `seed` that has reached `round`, whose one piece of advice is `advice`.
    func writeRun(_ seed: String, round: Int, advice: String, in folder: URL, modified: Date? = nil) throws {
        try write("""
            {"key":{"identity":{"profile":1,"seed":"\(seed)","deck":"b_red","stake":1},"replay":0},
             "progress":{"round":\(round),"handsPlayed":\(round),"cardsDiscarded":0,"rerolls":0,"purchases":0},
             "transcript":[{"title":"Ante 1 · Shop","advice":"\(advice)"}]}
            """, to: folder.appending(path: "runs/p1-\(seed)-b_red-s1-0.json"), modified: modified)
    }

    /// Each run's advice, by seed.
    func advice(in folder: URL) throws -> [String: String] {
        let files = try FileManager.default.contentsOfDirectory(at: folder.appending(path: "runs"), includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { file in
            let record = try json(file)
            let seed = try #require(((record["key"] as? [String: Any])?["identity"] as? [String: Any])?["seed"] as? String)
            return (seed, try #require((record["transcript"] as? [[String: Any]])?.first?["advice"] as? String))
        })
    }

    @Test func choosingAFolderCopiesTheRunsItLacksAndKeepsTheFurthest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRun("AAA", round: 3, advice: "Mac's A", in: local)
        try writeRun("BBB", round: 1, advice: "Mac's B", in: local)
        try writeRun("AAA", round: 5, advice: "PC's A", in: shared)
        try writeRun("CCC", round: 2, advice: "PC's C", in: shared)

        _ = try await Machine.load(dataFolder: local).syncing(with: sync)

        #expect(try advice(in: shared) == ["AAA": "PC's A", "BBB": "Mac's B", "CCC": "PC's C"])
        #expect(try advice(in: local) == ["AAA": "Mac's A", "BBB": "Mac's B"])
    }

    @Test func aTieGoesToTheNewerFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (older, newer) = (Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_600))
        try writeRun("AAA", round: 3, advice: "Mac's newer A", in: local, modified: newer)
        try writeRun("AAA", round: 3, advice: "PC's older A", in: shared, modified: older)
        try writeRun("BBB", round: 3, advice: "Mac's older B", in: local, modified: older)
        try writeRun("BBB", round: 3, advice: "PC's newer B", in: shared, modified: newer)

        _ = try await Machine.load(dataFolder: local).syncing(with: sync)

        #expect(try advice(in: shared) == ["AAA": "Mac's newer A", "BBB": "PC's newer B"])
        let copied = try FileManager.default.attributesOfItem(atPath: shared.appending(path: "runs/p1-AAA-b_red-s1-0.json").path)
        #expect(copied[.modificationDate] as? Date == newer)
    }

    @Test func stoppingBringsTheFoldersRunsBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRun("AAA", round: 3, advice: "Mac's A", in: local)
        let syncing = try await Machine.load(dataFolder: local).syncing(with: sync)
        try writeRun("AAA", round: 7, advice: "PC's later A", in: shared)
        try writeRun("DDD", round: 1, advice: "PC's D", in: shared)

        _ = try await syncing.syncing(with: nil)

        #expect(try advice(in: local) == ["AAA": "PC's later A", "DDD": "PC's D"])
    }

    @Test func machineJSONRemembersTheFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let machine = Machine.load(dataFolder: local)
        let file = local.appending(path: "machine.json")
        #expect(try json(file) as NSDictionary == ["machine": machine.id.rawValue, "syncFolder": NSNull()])

        _ = try await machine.syncing(with: sync)

        #expect(try json(file) as NSDictionary == ["machine": machine.id.rawValue, "syncFolder": Platform.path(sync)])
        #expect(Machine.load(dataFolder: local).syncFolder == sync)
        #expect(Machine.load(dataFolder: local).id == machine.id)
    }

    /// The bot's results, as the Mac and the PC each wrote them.
    func writeResults(_ times: [String], in folder: URL) throws {
        let results = times.map {
            #"{"goal":"win","deck":"b_red","stake":1,"ending":{"won":{}},"ante":8,"round":24,"bestHand":88000,"seconds":412,"gameVersion":"1.0.1o","finishedAt":"\#($0)"}"#
        }
        try write("[\(results.joined(separator: ","))]", to: folder.appending(path: "pilot/results.json"))
    }

    @Test func theBotsResultsAreJoinedWithoutRepeats() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try writeResults(["2026-10-01T10:00:00Z", "2026-10-02T10:00:00Z"], in: local)
        try writeResults(["2026-10-02T10:00:00Z", "2026-10-03T10:00:00Z"], in: shared)

        _ = try await Machine.load(dataFolder: local).syncing(with: sync)

        let joined = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.appending(path: "pilot/results.json"))) as? [[String: Any]])
        #expect(joined.compactMap { $0["finishedAt"] as? String } == ["2026-10-01T10:00:00Z", "2026-10-02T10:00:00Z", "2026-10-03T10:00:00Z"])
    }

    @Test func theSyncFoldersGoalWins() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"goal":"win"}"#, to: local.appending(path: "settings.json"))
        try write(#"{"goal":"naneinf"}"#, to: shared.appending(path: "settings.json"))

        let syncing = try await Machine.load(dataFolder: local).syncing(with: sync)
        #expect(try json(shared.appending(path: "settings.json")) as NSDictionary == ["goal": "naneinf"])

        _ = try await syncing.syncing(with: nil)
        #expect(try json(local.appending(path: "settings.json")) as NSDictionary == ["goal": "naneinf"])
    }

    @Test func anEmptySyncFolderGetsThisComputersGoal() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"goal":"naneinf"}"#, to: local.appending(path: "settings.json"))

        _ = try await Machine.load(dataFolder: local).syncing(with: sync)

        #expect(try json(shared.appending(path: "settings.json")) as NSDictionary == ["goal": "naneinf"])
    }
}
