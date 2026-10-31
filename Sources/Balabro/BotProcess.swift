import BalabroCore
import Foundation
import os

/// The bot's private copy of the game, built from the player's own install at runtime, so the repo ships no game files.
/// The folder is named `balabro-bot`, so LÖVE saves to `~/Library/Application Support/LOVE/balabro-bot`, which
/// `SaveWatcher` (rooted at `.../Balatro`) can't see and which isn't the player's profile.
struct BotInstall: Sendable {
    let runtime: URL
    let gameFolder: URL

    /// Cached by the game's modified date, like `GameInstall.extract`, so a game update rebuilds it.
    /// The bot's Lua is copied on every launch, so a Balabro update takes effect at once.
    static func prepare(from game: GameInstall, lua: URL) async throws -> BotInstall {
        let modified = try game.love.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let root = URL.applicationSupportDirectory.appending(path: "Balabro/bot")
        let work = root.appending(path: String(Int(modified.timeIntervalSince1970)))
        let install = BotInstall(runtime: work.appending(path: "Runtime.app"), gameFolder: work.appending(path: "balabro-bot"))
        let files = FileManager.default
        if !files.fileExists(atPath: install.runtime.path) {
            try? files.removeItem(at: root)
            try files.createDirectory(at: install.gameFolder, withIntermediateDirectories: true)
            guard let unzip = await Command.run(URL(filePath: "/usr/bin/unzip"), ["-q", game.love.path, "-d", install.gameFolder.path], timeout: .seconds(60)), unzip.status == 0
            else { throw CocoaError(.fileReadCorruptFile) }
            let main = install.gameFolder.appending(path: "main.lua")
            let handle = try FileHandle(forWritingTo: main)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\nrequire \"bot/main\"\n".utf8))
            try handle.close()
            guard let ditto = await Command.run(URL(filePath: "/usr/bin/ditto"), [game.app.path, install.runtime.path], timeout: .seconds(60)), ditto.status == 0
            else { throw CocoaError(.fileWriteUnknown) }
            // With no Balatro.love inside, LÖVE runs the folder it's given instead of the shipped game.
            try files.removeItem(at: install.runtime.appending(path: "Contents/Resources/Balatro.love"))
        }
        // No Dock icon. Done on every launch, so a copy built by an older Balabro gets it too.
        _ = await Command.run(URL(filePath: "/usr/bin/plutil"), ["-replace", "LSUIElement", "-bool", "YES", install.runtime.appending(path: "Contents/Info.plist").path], timeout: .seconds(10))
        let botFolder = install.gameFolder.appending(path: "bot")
        try? files.removeItem(at: botFolder)
        try files.copyItem(at: lua, to: botFolder)
        return install
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
        process.executableURL = install.runtime.appending(path: "Contents/MacOS/love")
        process.arguments = [install.gameFolder.path]
        var environment = ProcessInfo.processInfo.environment
        // Otherwise the new window would pull the player out of whatever they're doing.
        environment["SDL_MAC_BACKGROUND_APP"] = "1"
        process.environment = environment.merging(settings) { $1 }
        let stdin = Pipe(), stdout = Pipe()
        (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, FileHandle.nullDevice)
        let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = {
            exited.yield($0.terminationStatus)
            exited.finish()
        }
        try process.run()

        let output = AsyncStream<BotOutput> { continuation in
            // Not `FileHandle.bytes`: all its reads queue behind one another, so a game with nothing to say would stop
            // Claude's reply from being read, and that reply is what the game is waiting for.
            DispatchQueue.global().async {
                let handle = stdout.fileHandleForReading
                var pending = Data()
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending = pending[(newline + 1)...]
                        continuation.yield(.line(line))
                    }
                }
                Task {
                    for await status in exit { continuation.yield(.exited(status)) }
                    continuation.finish()
                }
            }
        }
        return (BotProcess(process: process, stdin: stdin.fileHandleForWriting), output)
    }

    func tell(_ line: String) {
        try? stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Safe to call twice.
    func kill() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if self.process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }
}

/// `Balabro/pilot/results.json`. Written whole and atomically, like `RunStore`.
struct PilotResults: Sendable {
    let file: URL

    static var `default`: PilotResults { PilotResults(file: .applicationSupportDirectory.appending(path: "Balabro/pilot/results.json")) }

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
            Logger.balabro.error("Couldn't save the bot's results: \(error)")
        }
    }
}
