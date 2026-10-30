import BalabroCore
import Foundation

/// Spawns one `claude -p` per turn and streams its output.
enum ClaudeProcess {
    /// Cancelling the consuming task sends SIGINT, then SIGTERM after 2 s. The forked session the
    /// process was writing is abandoned; `Coach` never forks from it.
    static func run(_ request: TurnRequest, with invocation: ClaudeInvocation) -> AsyncStream<TurnOutput> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments(forkFrom: request.forkFrom)
            process.environment = invocation.environment(inheriting: ProcessInfo.processInfo.environment)
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

                async let errorText = String(decoding: (try? await stderr.fileHandleForReading.bytes.reduce(into: Data()) { $0.append($1) }) ?? Data(), as: UTF8.self)
                var decoder = StreamDecoder()
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if let output = decoder.feed(Data(line.utf8)) { continuation.yield(output) }
                    }
                } catch {}
                var status: Int32 = -1
                for await code in exit { status = code }
                if let output = decoder.finish(status: status, stderr: await errorText) { continuation.yield(output) }
                continuation.finish()
            }

            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                reader.cancel()
                process.interrupt()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGTERM) }
                }
            }
        }
    }
}

/// Finds `claude` and the user's config dir for an app launched from Finder, which inherits
/// neither `~/.local/bin` on PATH nor `CLAUDE_CONFIG_DIR` from `~/.zshrc`.
enum ClaudeLocator {
    /// Order: the user's override, then the last result that still works, then their login shell,
    /// then well-known install paths. Every candidate must pass `claude --version`, and the winner is
    /// saved, so the login-shell probe runs once, not per launch.
    static func resolve(override: ClaudeInvocation?, workingDirectory: URL) async -> ClaudeInvocation? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [() async -> ClaudeInvocation?] = [
            { override },
            { saved(workingDirectory: workingDirectory) },
            { await loginShell(workingDirectory: workingDirectory) },
        ]
        let shellPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        for path in [".local/bin/claude", ".claude/local/claude"].map({ home.appending(path: $0).path }) + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            candidates.append {
                ClaudeInvocation(
                    executable: URL(filePath: path), configDir: nil,
                    searchPath: "\(URL(filePath: path).deletingLastPathComponent().path):/opt/homebrew/bin:\(shellPath)",
                    workingDirectory: workingDirectory)
            }
        }
        for candidate in candidates {
            guard let invocation = await candidate(), await works(invocation) else { continue }
            save(invocation)
            return invocation
        }
        return nil
    }

    private static func works(_ invocation: ClaudeInvocation) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else { return false }
        let env = invocation.environment(inheriting: ProcessInfo.processInfo.environment)
        return await Command.run(invocation.executable, ["--version"], environment: env, timeout: .seconds(10))?.status == 0
    }

    /// `-i` because `.zshrc` (where this user sets CLAUDE_CONFIG_DIR) only loads for interactive shells.
    /// The record separators fence off anything the shell's startup files print.
    private static func loginShell(workingDirectory: URL) async -> ClaudeInvocation? {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        let shellEnv = ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
            .merging(env) { _, inherited in inherited }
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
