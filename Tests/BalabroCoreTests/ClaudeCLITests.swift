import BalabroCore
import Foundation
import Testing

@Suite(.disabled("sketch: bodies not implemented"))
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
}
