import BalabroCore
import Foundation
import Testing

@Suite
struct ClaudeCLITests {
    @Test func newSessionStream() {
        var decoder = StreamDecoder()
        let out = Fixture.stream("new-session").compactMap { decoder.feed($0) }
        let id = SessionID(rawValue: "9e697c65-c9da-4653-8ccb-a6288767c991")
        #expect(out == [.started(id), .text("ok"), .done("ok", id)])
    }

    @Test func forkedResumeReportsTheNewSession() {
        var decoder = StreamDecoder()
        let out = Fixture.stream("resume-fork").compactMap { decoder.feed($0) }
        #expect(out.last == .done("PLUM", SessionID(rawValue: "987daa32-d7e9-40bc-ad06-d33d17305900")))
    }

    @Test func notLoggedIn() {
        var decoder = StreamDecoder()
        #expect(decoder.finish(status: 1, stderr: "Not logged in · Please run /login") == .failed(.notLoggedIn))
    }

    @Test func resumeArguments() {
        let inv = ClaudeInvocation(
            executable: URL(filePath: "/u/.local/bin/claude"), configDir: URL(filePath: "/u/.claude"),
            searchPath: "/u/.local/bin:/usr/bin", workingDirectory: URL(filePath: "/u/Balabro"))
        let args = inv.arguments(forkFrom: SessionID(rawValue: "S1"))
        #expect(Array(args.suffix(3)) == ["--resume", "S1", "--fork-session"])
        #expect(args.contains("--setting-sources") && args[args.firstIndex(of: "--setting-sources")! + 1] == "")
    }

    let invocation = ClaudeInvocation(
        executable: URL(filePath: "/u/.local/bin/claude"), configDir: URL(filePath: "/u/.claude"),
        searchPath: "/u/.local/bin:/usr/bin", workingDirectory: URL(filePath: "/u/Balabro"))

    @Test func firstTurnStartsAFreshConversationWithoutTools() {
        let args = invocation.arguments(forkFrom: nil)
        #expect(!args.contains("--resume") && !args.contains("--fork-session"))
        for flag in ["-p", "--strict-mcp-config", "--disable-slash-commands", "--verbose", "--include-partial-messages"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
        #expect(args[args.firstIndex(of: "--model")! + 1] == "claude-opus-5-5")
        #expect(args[args.firstIndex(of: "--input-format")! + 1] == "stream-json")
        #expect(args[args.firstIndex(of: "--output-format")! + 1] == "stream-json")
        #expect(args[args.firstIndex(of: "--system-prompt")! + 1].contains("**Do this now:**"))
    }

    @Test func environmentCarriesTheLoginShellsPathAndConfigDir() {
        let env = invocation.environment(inheriting: ["HOME": "/u", "USER": "u", "PATH": "/usr/bin", "CLAUDE_CODE_ENTRYPOINT": "x"])
        #expect(env == ["HOME": "/u", "USER": "u", "PATH": "/u/.local/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/u/.claude"])
    }

    @Test func stdinIsOneLineWithTheImageBeforeTheText() throws {
        let line = ClaudeInvocation.stdinLine(UserMessage(text: "pick?", screenshotPNG: Data([0x89, 0x50])))
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
        #expect(String(decoding: line, as: UTF8.self) == #"""
            {"message":{"content":[{"source":{"data":"iVA=","media_type":"image/png","type":"base64"},"type":"image"},{"text":"pick?","type":"text"}],"role":"user"},"type":"user"}

            """#)
    }

    @Test func textOnlyMessageHasOneContentBlock() {
        let line = String(decoding: ClaudeInvocation.stdinLine(UserMessage(text: "a\nb")), as: UTF8.self)
        #expect(line == #"{"message":{"content":[{"text":"a\nb","type":"text"}],"role":"user"},"type":"user"}"# + "\n")
    }

    @Test func noResultLineIsAFailure() {
        var decoder = StreamDecoder()
        #expect(decoder.finish(status: 1, stderr: "boom") == .failed(.exited(status: 1, stderrTail: "boom")))
        var clean = StreamDecoder()
        #expect(clean.finish(status: 0, stderr: "") == .failed(.malformedOutput))
    }

    @Test func exitAfterAResultAddsNothing() {
        var decoder = StreamDecoder()
        _ = Fixture.stream("new-session").compactMap { decoder.feed($0) }
        #expect(decoder.finish(status: 0, stderr: "") == nil)
    }

    @Test func errorResultIsAFailure() {
        var decoder = StreamDecoder()
        let line = Data(#"{"type":"result","subtype":"error","is_error":true,"result":"Claude AI usage limit reached|1760000000","session_id":"x"}"#.utf8)
        #expect(decoder.feed(line) == .failed(.rateLimited(resetsAt: Date(timeIntervalSince1970: 1_760_000_000))))
    }
}
