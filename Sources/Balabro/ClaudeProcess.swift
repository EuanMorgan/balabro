import BalabroCore
import Foundation

/// Spawns one `claude -p` per turn and streams its output. The only code that touches `Process`.
enum ClaudeProcess {
    /// Cancelling the consuming task sends SIGINT, then SIGTERM after 2 s. The forked session the
    /// process was writing is abandoned; `Coach` never forks from it.
    static func run(_ request: TurnRequest, with invocation: ClaudeInvocation) -> AsyncStream<TurnOutput> {
        // TODO:
        //   process.executableURL = invocation.executable
        //   process.arguments = invocation.arguments(forkFrom: request.forkFrom)
        //   process.environment = invocation.environment(inheriting: ProcessInfo.processInfo.environment)
        //   process.currentDirectoryURL = invocation.workingDirectory
        //   stdin.write(ClaudeInvocation.stdinLine(request.message)); stdin.close()
        //   for line in stdout lines: decoder.feed(line).map(continuation.yield)
        //   on exit: decoder.finish(status:stderr:).map(continuation.yield); continuation.finish()
        //   continuation.onTermination = { if cancelled: process.interrupt(); after 2 s process.terminate() }
        fatalError("not implemented")
    }
}

/// Finds `claude` and the user's config dir for an app launched from Finder, which inherits
/// neither `~/.local/bin` on PATH nor `CLAUDE_CONFIG_DIR` from `~/.zshrc`.
enum ClaudeLocator {
    /// Order: the user's saved override, then their login shell, then well-known install paths.
    ///
    /// Login shell probe: `$SHELL -l -i -c 'printf "\x1e%s\x1e%s\x1e%s\x1e" "$(command -v claude)" "$CLAUDE_CONFIG_DIR" "$PATH"'`
    /// with a 5 s timeout. `-i` because `.zshrc` (where this user sets CLAUDE_CONFIG_DIR) only loads
    /// for interactive shells; the record separators fence off anything the prompt theme prints.
    /// Fallback paths: `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`.
    ///
    /// The result is checked with `claude --version` and saved, so the probe runs once, not per turn.
    static func resolve(override: ClaudeInvocation?, workingDirectory: URL) async -> ClaudeInvocation? {
        fatalError("not implemented")
    }
}
