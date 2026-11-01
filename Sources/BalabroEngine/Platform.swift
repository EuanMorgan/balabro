import BalabroCore
import Foundation
#if os(Windows)
#else
import AppKit
import os
#endif

/// Everything the engine does differently on Windows and the Mac. Nowhere else in the engine has `#if os`.
public enum Platform {
    /// Runs, conversations and caches: `~/Library/Application Support/Balabro` on the Mac, `%LOCALAPPDATA%\Balabro` on Windows.
    public static let dataFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Balabro")

    public static var defaultSavesRoot: URL {
        #if os(Windows)
        let roaming = ProcessInfo.processInfo.environment["APPDATA"].map { URL(filePath: $0) }
        return (roaming ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "AppData/Roaming")).appending(path: "Balatro")
        #else
        URL.applicationSupportDirectory.appending(path: "Balatro")
        #endif
    }

    static func findGame() -> URL? {
        #if os(Windows)
        let steam = URL(filePath: #"C:\Program Files (x86)\Steam"#)
        let vdf = (try? String(contentsOf: steam.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8)) ?? ""
        return ([steam] + SteamLibraries.paths(in: vdf).map { URL(filePath: $0) })
            .map { $0.appending(path: "steamapps/common/Balatro") }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "Balatro.exe").path) }
        #else
        // The Steam path first, then Launch Services by bundle ID (other Steam libraries, a moved app).
        let steam = URL.applicationSupportDirectory.appending(path: "Steam/steamapps/common/Balatro/Balatro.app")
        return FileManager.default.fileExists(atPath: steam.path) ? steam : NSWorkspace.shared.urlForApplication(withBundleIdentifier: GameInstall.bundleID)
        #endif
    }

    /// The zip of the game's Lua and assets. On Windows it is appended to LÖVE in `Balatro.exe`.
    static func gameArchive(in game: URL) -> URL {
        #if os(Windows)
        game.appending(path: "Balatro.exe")
        #else
        game.appending(path: "Contents/Resources/Balatro.love")
        #endif
    }

    static var botLua: URL? {
        #if os(Windows)
        Bundle.main.executableURL.map { $0.deletingLastPathComponent().appending(path: "bot") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        #else
        Bundle.main.url(forResource: "bot", withExtension: nil)
        #endif
    }

    /// A path for another program, such as the game copy's Lua or the Windows app.
    public static func path(_ url: URL) -> String {
        #if os(Windows)
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        #else
        url.path
        #endif
    }

    /// Where to look for `claude` after the user's override and the last one that worked.
    static func claudeCandidates(workingDirectory: URL) -> [@Sendable () async -> ClaudeInvocation?] {
        #if os(Windows)
        // A program started from Explorer already has the user's Path and CLAUDE_CONFIG_DIR, so there's no shell to ask.
        let environment = ProcessInfo.processInfo.environment
        let path = environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
        let configDir = environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")]
            + path.split(separator: ";").map { URL(filePath: String($0)) }
        return folders.map { folder in
            { ClaudeInvocation(executable: folder.appending(path: "claude.exe"), configDir: configDir, searchPath: path, workingDirectory: workingDirectory) }
        }
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shellPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let installs = [".local/bin/claude", ".claude/local/claude"].map { home.appending(path: $0).path } + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return [{ await ClaudeLocator.loginShell(environment: userEnvironment, workingDirectory: workingDirectory) }] + installs.map { path in
            {
                ClaudeInvocation(
                    executable: URL(filePath: path), configDir: nil,
                    searchPath: "\(URL(filePath: path).deletingLastPathComponent().path):/opt/homebrew/bin:\(shellPath)",
                    workingDirectory: workingDirectory)
            }
        }
        #endif
    }

    /// On the Mac, a Finder-launched app has neither the user's PATH nor CLAUDE_CONFIG_DIR, so claude gets them from the invocation.
    /// On Windows it gets everything Balabro inherited.
    static func claudeEnvironment(_ invocation: ClaudeInvocation) -> [String: String] {
        #if os(Windows)
        ProcessInfo.processInfo.environment
        #else
        invocation.environment(inheriting: userEnvironment)
        #endif
    }

    #if !os(Windows)
    /// The app's environment, plus the account basics a process started with an empty environment lacks.
    private static var userEnvironment: [String: String] {
        let user = NSUserName()
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        return ProcessInfo.processInfo.environment.merging(
            ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": user, "LOGNAME": user, "SHELL": shell]
        ) { inherited, _ in inherited }
    }
    #endif

    /// Ends a claude turn. On the Mac, SIGINT lets it stop cleanly, and SIGTERM follows after 2 s.
    static func interrupt(_ process: Process) {
        #if os(Windows)
        if process.isRunning { process.terminate() }
        #else
        process.interrupt()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(pid, SIGTERM) }
        }
        #endif
    }

    /// Ends a game copy. On the Mac, SIGTERM, then SIGKILL after 2 s.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        #if !os(Windows)
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
        #endif
    }

    /// Ends a command that ran out of time. SIGKILL on the Mac, because an interactive shell ignores SIGTERM.
    static func kill(_ process: Process) {
        guard process.isRunning else { return }
        #if os(Windows)
        process.terminate()
        #else
        Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
    }

    /// A process that dies before reading its stdin must fail the write, not kill Balabro.
    public static func ignoreBrokenPipes() {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    static func botExecutable(in work: URL) -> URL {
        #if os(Windows)
        work.appending(path: "Runtime/love.exe")
        #else
        work.appending(path: "Runtime.app/Contents/MacOS/love")
        #endif
    }

    /// LÖVE without the game, so it runs the folder it's given instead of the shipped game.
    static func makeBotRuntime(from game: GameInstall, in work: URL) async throws {
        #if os(Windows)
        if !FileManager.default.fileExists(atPath: botExecutable(in: work).path) {
            try BotInstall.cutLove(from: game.folder, to: work.appending(path: "Runtime"))
        }
        #else
        let runtime = work.appending(path: "Runtime.app")
        if !FileManager.default.fileExists(atPath: runtime.path) {
            guard let ditto = await Command.run(URL(filePath: "/usr/bin/ditto"), [game.folder.path, runtime.path], timeout: .seconds(60)), ditto.status == 0
            else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.removeItem(at: runtime.appending(path: "Contents/Resources/Balatro.love"))
        }
        // No Dock icon. Done on every launch, so a copy built by an older Balabro gets it too.
        _ = await Command.run(URL(filePath: "/usr/bin/plutil"), ["-replace", "LSUIElement", "-bool", "YES", runtime.appending(path: "Contents/Info.plist").path], timeout: .seconds(10))
        #endif
    }

    /// Otherwise the copy's new window would pull the player out of whatever they're doing.
    static let botEnvironment = {
        #if os(Windows)
        ["SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN": "1"]
        #else
        ["SDL_MAC_BACKGROUND_APP": "1"]
        #endif
    }()

    /// The unified log on the Mac. On Windows, `logs\engine.log` in the data folder, a file the owner can send, and stderr.
    static func log(_ message: String) {
        #if os(Windows)
        let line = Data("\(Date.now.ISO8601Format()) \(message)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: line)
        let file = dataFolder.appending(path: "logs/engine.log")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()
        #else
        logger.error("\(message, privacy: .public)")
        #endif
    }

    #if !os(Windows)
    private static let logger = Logger(subsystem: "com.euanmorgan.balabro", category: "app")
    #endif
}
