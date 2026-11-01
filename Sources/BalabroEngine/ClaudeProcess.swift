import BalabroCore
import Foundation

/// Spawns one `claude -p` per turn and streams its output.
enum ClaudeProcess {
    /// Cancelling the consuming task ends the process (`Platform.interrupt`). The forked session the
    /// process was writing is abandoned; `Coach` never forks from it.
    static func run(_ request: TurnRequest, with invocation: ClaudeInvocation) -> AsyncStream<TurnOutput> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments(forkFrom: request.forkFrom)
            process.environment = Platform.claudeEnvironment(invocation)
            process.currentDirectoryURL = invocation.workingDirectory
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
            let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = {
                exited.yield($0.terminationStatus)
                exited.finish()
            }

            do {
                try FileManager.default.createDirectory(at: invocation.workingDirectory, withIntermediateDirectories: true)
                try process.run()
            } catch {
                continuation.yield(.failed(.cliNotFound))
                continuation.finish()
                return
            }

            let reader = Task.detached {
                // The CLI waits 3 s for stdin unless it's closed, so it always gets exactly one line and EOF.
                try? stdin.fileHandleForWriting.write(contentsOf: ClaudeInvocation.stdinLine(request.message))
                try? stdin.fileHandleForWriting.close()

                async let errorLines = LineReader.lines(from: stderr.fileHandleForReading).reduce(into: []) { $0.append($1) }
                var decoder = StreamDecoder()
                for await line in LineReader.lines(from: stdout.fileHandleForReading) {
                    if let output = decoder.feed(Data(line.utf8)) { continuation.yield(output) }
                }
                var status: Int32 = -1
                for await code in exit { status = code }
                if let output = decoder.finish(status: status, stderr: await errorLines.joined(separator: "\n")) { continuation.yield(output) }
                continuation.finish()
            }

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                reader.cancel()
                Platform.interrupt(process)
            }
        }
    }
}

/// Finds `claude` and the config dir it should use. On the Mac, an app launched from Finder inherits
/// neither `~/.local/bin` on PATH nor `CLAUDE_CONFIG_DIR` from `~/.zshrc`.
enum ClaudeLocator {
    /// Order: the user's override, then the last result that still works, then `Platform.claudeCandidates`.
    /// Every candidate must pass `claude --version`, and the winner is saved, so the Mac's login-shell probe
    /// runs once, not per launch.
    static func resolve(override: ClaudeInvocation?, workingDirectory: URL) async -> ClaudeInvocation? {
        let candidates: [@Sendable () async -> ClaudeInvocation?] = [
            { override },
            { saved(workingDirectory: workingDirectory) },
        ] + Platform.claudeCandidates(workingDirectory: workingDirectory)
        for candidate in candidates {
            guard let invocation = await candidate(), await works(invocation) else { continue }
            save(invocation)
            return invocation
        }
        return nil
    }

    private static func works(_ invocation: ClaudeInvocation) async -> Bool {
        await Command.run(invocation.executable, ["--version"], environment: Platform.claudeEnvironment(invocation), timeout: .seconds(10))?.status == 0
    }

    /// `-i` because `.zshrc` (where this user sets CLAUDE_CONFIG_DIR) only loads for interactive shells.
    /// The record separators fence off anything the shell's startup files print.
    static func loginShell(environment: [String: String], workingDirectory: URL) async -> ClaudeInvocation? {
        let shellEnv = environment.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]) { inherited, _ in inherited }
        let shell = shellEnv["SHELL"]!
        let script = #"printf "\x1e%s\x1e%s\x1e%s\x1e" "$(command -v claude)" "$CLAUDE_CONFIG_DIR" "$PATH""#
        guard let result = await Command.run(URL(filePath: shell), ["-l", "-i", "-c", script], environment: shellEnv, timeout: .seconds(5)) else { return nil }
        let fields = String(decoding: result.output, as: UTF8.self).split(separator: "\u{1e}", omittingEmptySubsequences: false)
        guard fields.count >= 5 else { return nil }
        let (executable, configDir, path) = (fields[fields.count - 4], fields[fields.count - 3], fields[fields.count - 2])
        guard executable.hasPrefix("/") else { return nil }
        return ClaudeInvocation(
            executable: URL(filePath: String(executable)),
            configDir: configDir.isEmpty ? nil : URL(filePath: String(configDir)),
            searchPath: String(path), workingDirectory: workingDirectory)
    }

    private struct Saved: Codable { var executable: String; var configDir: String?; var searchPath: String }
    private static let savedKey = "claude"

    private static func saved(workingDirectory: URL) -> ClaudeInvocation? {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return ClaudeInvocation(
            executable: URL(filePath: saved.executable), configDir: saved.configDir.map { URL(filePath: $0) },
            searchPath: saved.searchPath, workingDirectory: workingDirectory)
    }

    private static func save(_ invocation: ClaudeInvocation) {
        let saved = Saved(executable: invocation.executable.path, configDir: invocation.configDir?.path, searchPath: invocation.searchPath)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: savedKey)
    }
}
