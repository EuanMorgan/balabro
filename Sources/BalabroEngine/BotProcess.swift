import BalabroCore
import Foundation

/// The bot's private copy of the game, built from the player's own install at runtime, so the repo ships no game files.
/// The folder is named `balabro-bot`, so LÖVE saves under `LOVE/balabro-bot`, which `SaveWatcher` (rooted at
/// `Balatro`) can't see and which isn't the player's profile.
struct BotInstall: Sendable {
    let executable: URL
    let gameFolder: URL

    /// Cached by the game's modified date, like `GameInstall.extract`, so a game update rebuilds it.
    /// The bot's Lua is copied on every launch, so a Balabro update takes effect at once.
    static func prepare(from game: GameInstall, lua: URL) async throws -> BotInstall {
        let modified = try game.archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let root = Platform.dataFolder.appending(path: "bot")
        let work = root.appending(path: String(Int(modified.timeIntervalSince1970)))
        let install = BotInstall(executable: Platform.botExecutable(in: work), gameFolder: work.appending(path: "balabro-bot"))
        let files = FileManager.default
        if !files.fileExists(atPath: install.executable.path) {
            try? files.removeItem(at: root)
            try files.createDirectory(at: install.gameFolder, withIntermediateDirectories: true)
            try ZipArchive(file: game.archive).extractAll(to: install.gameFolder)
            let main = install.gameFolder.appending(path: "main.lua")
            let handle = try FileHandle(forWritingTo: main)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\nrequire \"bot/main\"\n".utf8))
            try handle.close()
        }
        try await Platform.makeBotRuntime(from: game, in: work)
        let botFolder = install.gameFolder.appending(path: "bot")
        try? files.removeItem(at: botFolder)
        try files.copyItem(at: lua, to: botFolder)
        return install
    }

    /// Windows' `Balatro.exe` is LÖVE with the game's zip appended. Its bytes before the zip, beside the game's DLLs,
    /// are a plain LÖVE that runs the folder it's given.
    static func cutLove(from game: URL, to runtime: URL) throws {
        let files = FileManager.default
        let exe = game.appending(path: "Balatro.exe")
        try files.createDirectory(at: runtime, withIntermediateDirectories: true)
        for file in try files.contentsOfDirectory(at: game, includingPropertiesForKeys: nil) where file.lastPathComponent != exe.lastPathComponent {
            try files.copyItem(at: file, to: runtime.appending(path: file.lastPathComponent))
        }
        let love = try Data(contentsOf: exe, options: .mappedIfSafe).prefix(ZipArchive(file: exe).prefixLength)
        try love.write(to: runtime.appending(path: "love.exe"))
    }
}

enum BotOutput: Sendable {
    case line(String)
    case exited(Int32)
}

/// One game process. Stdio is the transport: when Balabro exits, however it exits, stdin closes and the bot quits,
/// so no game is left running on its own.
final class BotProcess: Sendable {
    private let process: Process
    private let stdin: FileHandle

    private init(process: Process, stdin: FileHandle) { (self.process, self.stdin) = (process, stdin) }

    static func launch(_ install: BotInstall, settings: [String: String]) throws -> (BotProcess, AsyncStream<BotOutput>) {
        let process = Process()
        process.executableURL = install.executable
        process.arguments = [Platform.path(install.gameFolder)]
        process.environment = ProcessInfo.processInfo.environment.merging(Platform.botEnvironment) { $1 }.merging(settings) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, FileHandle.nullDevice)
        let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = {
            exited.yield($0.terminationStatus)
            exited.finish()
        }
        try process.run()

        let output = AsyncStream<BotOutput> { continuation in
            Task {
                for await line in LineReader.lines(from: stdout.fileHandleForReading) { continuation.yield(.line(line)) }
                for await status in exit { continuation.yield(.exited(status)) }
                continuation.finish()
            }
        }
        return (BotProcess(process: process, stdin: stdin.fileHandleForWriting), output)
    }

    func tell(_ line: String) {
        try? stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Safe to call twice.
    func kill() { Platform.stop(process) }
}

/// `Balabro/pilot/results.json`. Written whole and atomically, like `RunStore`.
struct PilotResults: Sendable {
    let file: URL

    static var `default`: PilotResults { PilotResults(file: Platform.dataFolder.appending(path: "pilot/results.json")) }

    private static let infinity = "inf"

    func load() -> [PilotResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: Self.infinity, negativeInfinity: "-inf", nan: "nan")
        return (try? Data(contentsOf: file)).flatMap { try? decoder.decode([PilotResult].self, from: $0) } ?? []
    }

    func save(_ results: [PilotResult]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: Self.infinity, negativeInfinity: "-inf", nan: "nan")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(results).write(to: file, options: .atomic)
        } catch {
            Platform.log("Couldn't save the bot's results: \(error)")
        }
    }
}
