import Foundation

/// Short helper commands (`unzip`, `claude --version`, the login-shell probe), as opposed to a coaching turn.
enum Command {
    /// Stdout goes to a temporary file, not a pipe: an interactive shell can leave background jobs
    /// (prompt themes start daemons) holding a pipe open long after the command itself exits.
    /// Returns nil if the command can't start or outlives `timeout`.
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration
    ) async -> (status: Int32, output: Data)? {
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "balabro-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let status: Int32? = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                done.resume(returning: nil)
                return
            }
            let pid = process.processIdentifier
            Task {
                try? await Task.sleep(for: timeout)
                // SIGKILL: an interactive shell ignores SIGTERM.
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        try? output.close()
        guard let status, process.terminationReason == .exit else { return nil }
        return (status, (try? Data(contentsOf: outputURL)) ?? Data())
    }
}
