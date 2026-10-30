import Foundation

/// How one turn becomes a `claude` command line, and how its stdout becomes `TurnOutput`.
/// Pure: the shell's `ClaudeProcess` spawns it. The wire format stays here, not on `Coach`'s API.
public struct ClaudeInvocation: Sendable, Hashable {
    public var executable: URL
    /// `CLAUDE_CONFIG_DIR`. nil means the CLI's default (`~/.claude`). A Finder-launched app never inherits it.
    public var configDir: URL?
    /// The PATH of the user's login shell, so the CLI finds what it shells out to.
    public var searchPath: String
    /// Fixed for the app's lifetime: the CLI files sessions under `<configDir>/projects/<cwd>/`,
    /// and `--resume` only finds sessions filed under the current cwd.
    public var workingDirectory: URL
    public var model = "claude-opus-5-5"

    public init(executable: URL, configDir: URL?, searchPath: String, workingDirectory: URL) {
        (self.executable, self.configDir, self.searchPath, self.workingDirectory) = (executable, configDir, searchPath, workingDirectory)
    }

    /// Verified on CLI 2.1.312 (fixtures in `Tests/.../claude-stream`): `--resume X --fork-session` with
    /// stream-json in and out keeps the conversation and reports a new session ID.
    ///
    /// ```
    /// -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
    /// --model claude-opus-5-5 --system-prompt <Prompt.system>
    /// --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands
    /// [--resume <forkFrom> --fork-session]
    /// ```
    /// `--tools ""`: the coach needs no tools, and images go in as content blocks, not file reads.
    /// `--strict-mcp-config --setting-sources ""`: skip the user's MCP servers, hooks and CLAUDE.md
    /// (9.5 s -> 2.8 s measured) while keeping their subscription login. Not `--bare`: it drops the login.
    /// Forked turns still hit the prompt cache: on Sonnet, turns 2 and 3 read 7,838 and 8,444 cached tokens.
    public func arguments(forkFrom: SessionID?) -> [String] {
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", model, "--system-prompt", Prompt.system,
            "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
        ]
        if let forkFrom { args += ["--resume", forkFrom.rawValue, "--fork-session"] }
        return args
    }

    /// HOME and USER from the app, PATH from `searchPath`, CLAUDE_CONFIG_DIR from `configDir` if set.
    public func environment(inheriting env: [String: String]) -> [String: String] {
        var out = env.filter { $0.key == "HOME" || $0.key == "USER" }
        out["PATH"] = searchPath
        if let configDir { out["CLAUDE_CONFIG_DIR"] = configDir.path(percentEncoded: false) }
        return out
    }

    /// The single stdin line: `{"type":"user","message":{"role":"user","content":[image?, text]}}`.
    /// The image is a base64 PNG content block, so it needs no tool and no temp file. It goes before the text,
    /// as Anthropic recommends for image prompts.
    public static func stdinLine(_ message: UserMessage) -> Data {
        var content: [[String: Any]] = []
        if let png = message.screenshotPNG {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]])
        }
        content.append(["type": "text", "text": message.text])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }
}

public enum TurnOutput: Sendable, Hashable {
    case started(SessionID)
    case text(String)
    case done(String, SessionID)
    case failed(TurnFailure)
}

public enum TurnFailure: Sendable, Hashable {
    case notLoggedIn
    case rateLimited(resetsAt: Date?)
    case cliNotFound
    case exited(status: Int32, stderrTail: String)
    case malformedOutput
}

/// Turns stream-json stdout lines into `TurnOutput`. Feed it one line at a time.
///
/// Line types seen on 2.1.312: `system/init` (session_id), `system/status`, `stream_event` with
/// `content_block_delta.text_delta` (the streamed text), `assistant` (whole message, ignored: the
/// deltas already carried it), `rate_limit_event`, and a final object with `result`, `session_id`, `is_error`.
public struct StreamDecoder: Sendable {
    private var sawResult = false

    public init() {}

    /// Returns nil for lines that carry nothing the coach uses. Unknown line types and lines that aren't JSON
    /// are ignored, not errors, so a CLI update that adds event types doesn't break coaching.
    public mutating func feed(_ line: Data) -> TurnOutput? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "system" where object["subtype"] as? String == "init":
            return (object["session_id"] as? String).map { .started(SessionID(rawValue: $0)) }
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            sawResult = true
            let text = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true { return .failed(Self.failure(fromResult: text)) }
            guard let session = object["session_id"] as? String else { return .failed(.malformedOutput) }
            return .done(text, SessionID(rawValue: session))
        default:
            return nil
        }
    }

    /// Call when the process exits. Turns "exited without a result line" into `.failed`.
    public mutating func finish(status: Int32, stderr: String) -> TurnOutput? {
        guard !sawResult else { return nil }
        if stderr.contains("Not logged in") { return .failed(.notLoggedIn) }
        if status == 0 { return .failed(.malformedOutput) }
        return .failed(.exited(status: status, stderrTail: String(stderr.suffix(400))))
    }

    /// The CLI reports usage limits as an error result such as `Claude AI usage limit reached|1760000000`,
    /// where the number is when the limit resets.
    private static func failure(fromResult text: String) -> TurnFailure {
        if text.contains("Not logged in") { return .notLoggedIn }
        if text.lowercased().contains("limit") {
            let resetsAt = text.split(separator: "|").last.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:))
            return .rateLimited(resetsAt: resetsAt)
        }
        return .exited(status: 0, stderrTail: String(text.suffix(400)))
    }
}
