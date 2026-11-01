import BalabroCore
import BalabroEngine
import Foundation
import Testing

/// The lines the Windows app reads, against the files in `Fixtures/wire`, which the Windows app's tests read too.
@Suite
struct WireTests {
    /// Any JSON value, so a file and a line compare by content rather than by spacing or key order.
    indirect enum JSON: Decodable, Equatable {
        case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([JSON].self) { self = .array(array) }
            else { self = .object(try value.decode([String: JSON].self)) }
        }
    }

    func expectLine(_ message: HostMessage, matches name: String) throws {
        let line = try message.line()
        #expect(line.last == UInt8(ascii: "\n") && !line.dropLast().contains(UInt8(ascii: "\n")), "one line per message")
        let golden = try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/wire/\(name)", withExtension: "json")))
        let decoder = JSONDecoder()
        #expect(try decoder.decode(JSON.self, from: line) == decoder.decode(JSON.self, from: golden), "\(name).json differs from \(String(decoding: line, as: UTF8.self))")
    }

    let coach = Coach(text: .missing, machine: MachineID(rawValue: "mac"))

    func snap(_ name: String) throws -> RunSnapshot {
        try SaveFile.decode(Data(contentsOf: CoreFixture.url("saves/\(name).jkr")), profile: 1)
    }

    func replay(_ stream: String, as turn: TurnID, _ state: inout CoachState) throws {
        var decoder = StreamDecoder()
        let lines = try Data(contentsOf: CoreFixture.url("claude-stream/\(stream).jsonl")).split(separator: UInt8(ascii: "\n"))
        for line in lines {
            if let output = decoder.feed(Data(line)) { _ = coach.reduce(&state, .turnOutput(turn, output)) }
        }
        if let output = decoder.finish(status: 0, stderr: "") { _ = coach.reduce(&state, .turnOutput(turn, output)) }
    }

    @Test func hello() throws {
        try expectLine(
            .hello(version: "1.2.3", fontPath: #"C:\Users\player\AppData\Local\Balabro\game\1730000000\resources\fonts\m6x11plus.ttf"#, syncFolder: #"C:\Users\player\iCloudDrive"#),
            matches: "hello")
    }

    @Test func waitingForARun() throws {
        try expectLine(.coach(CoachState(restoring: []).view), matches: "coach-waiting")
    }

    @Test func thinkingAboutAHand() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        try expectLine(.coach(state.view), matches: "coach-thinking")
    }

    /// The recorded streams answered "ok", then "PLUM" to a follow-up.
    @Test func readyWithAFollowUp() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        try replay("new-session", as: TurnID(0), &state)
        for case .captureGameWindow(let id, _) in coach.reduce(&state, .ask("Say a fruit")) {
            _ = coach.reduce(&state, .screenshot(id, png: Data([0x89, 0x50, 0x4E, 0x47])))
        }
        try replay("resume-fork", as: TurnID(2), &state)
        try expectLine(.coach(state.view), matches: "coach-ready")
    }

    /// 02-hand needs 300 more chips, so the Two Pair leaves 208.
    @Test func adviceWithScoreNotes() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        let answer = """
            **Do this now:**
            1. Discard J♦ 4♠ 3♥
            2. Play K♥ K♣ 7♠ 7♦
            **Score:**
            - Two Pair: 46 x 2 = 92
            - Instead, Pair: 30 x 2 = 60
            **Goal:** Build towards a Flush.
            **Why:**
            - The Kings are your best pair.
            **Lesson 3: Pairs first**
            Early blinds are cleared by pairs.
            """
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .done(answer, SessionID(rawValue: "S0"))))
        try expectLine(.coach(state.view), matches: "coach-advice")
    }

    @Test func notLoggedIn() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
        _ = coach.reduce(&state, .turnOutput(TurnID(0), .failed(.notLoggedIn)))
        try expectLine(.coach(state.view), matches: "coach-problem")
    }

    /// The words have to fit both systems, because the core doesn't know which one it runs on.
    @Test func noScreenshot() throws {
        var state = CoachState(restoring: [])
        _ = coach.reduce(&state, .saveWritten(try snap("07-pack-opening")))
        _ = coach.reduce(&state, .screenshot(CaptureID(0), png: nil))
        try expectLine(.coach(state.view), matches: "coach-no-screenshot")
    }

    @Test func pilotPlaying() throws {
        let view = PilotView(
            status: .askingClaude, startedAt: Date(timeIntervalSince1970: 1_790_000_000), goal: .win,
            run: BotStatus(ante: 4, round: 11, dollars: 41, bestHand: 4420, doing: "Discarding 3 cards, 61% to reach 2,442"),
            why: "Hologram gives scaling XMult.", bestTimes: [BestTime(title: "Fastest win", seconds: 412)])
        try expectLine(.pilot(view), matches: "pilot-playing")
    }

    @Test func pilotFailed() throws {
        let result = PilotResult(
            goal: "naneinf", deck: CenterKey(rawValue: "b_plasma"), stake: 1, ending: .failed("Claude isn't logged in."),
            ante: 12, round: 36, bestHand: .infinity, seconds: 3725, gameVersion: "1.0.1o", finishedAt: Date(timeIntervalSince1970: 1_790_003_725))
        try expectLine(.pilot(PilotView(status: .finished, goal: .naneinf, result: result)), matches: "pilot-failed")
    }

    @Test func capture() throws {
        try expectLine(.capture(id: 3), matches: "capture")
    }

    /// The driver's profile, and its run twice: once after the shop in ante 1, and once played to the end and removed.
    @Test func stats() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "balabro-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "runs"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CoreFixture.url("profiles/driver.jkr"), to: root.appending(path: "1/profile.jkr"))

        var state = CoachState(restoring: [])
        var record: RunRecord?
        func play(_ saves: [String]) throws {
            for name in saves {
                for case .save(let saved) in coach.reduce(&state, .saveWritten(try snap(name))) { record = saved }
            }
        }
        func store(_ name: String, playedAt seconds: TimeInterval) throws {
            let file = root.appending(path: "runs/\(name).json")
            try #require(record).json().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
        }
        try play(["01-blind-select", "02-hand", "03-hand-after-discard", "04-round-eval", "05-shop"])
        try store("early", playedAt: 1_790_000_000)
        try play(["06-shop-reroll", "07-pack-opening", "08-pack-closed", "09-blind-select", "10-hand", "11-round-eval", "12-shop"])
        for case .save(let saved) in coach.reduce(&state, .saveRemoved(profile: 1)) { record = saved }
        try store("ended", playedAt: 1_790_090_000)

        let text = try GameText(enUSLua: #"return {descriptions={Back={b_red={name="Red Deck"}},Joker={j_gluttenous_joker={name="Gluttonous Joker"}}}}"#)
        let page = StatsPage(
            StatsData.load(savesRoot: root, store: RunStore(files: await SharedFiles.open(root))),
            text: text, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        try expectLine(.stats(page), matches: "stats")
    }

    /// All-time totals from a profile that predates Balabro, so no runs of its own.
    @Test func statsBeforeAnyRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "balabro-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "2"), withIntermediateDirectories: true)
        let profile = """
            return {["career_stats"]={["c_wins"]=2,["c_losses"]=11,["c_rounds"]=111,},
            ["high_scores"]={["hand"]={["amt"]=32163,},["most_money"]={["amt"]=1083,},["furthest_ante"]={["amt"]=6,},},}
            """
        try Data(profile.utf8).write(to: root.appending(path: "2/profile.jkr"))
        let page = StatsPage(
            StatsData.load(savesRoot: root, store: RunStore(files: await SharedFiles.open(root))),
            text: .missing, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        try expectLine(.stats(page), matches: "stats-before-any-run")
    }

    @Test func update() throws {
        let release = AppRelease(
            version: AppVersion("0.3.0")!,
            download: URL(string: "https://github.com/EuanMorgan/balabro/releases/download/v0.3.0/Balabro-0.3.0-windows-x64.zip")!,
            page: URL(string: "https://github.com/EuanMorgan/balabro/releases/tag/v0.3.0")!)
        try expectLine(.update(release), matches: "update")
    }

    @Test func syncFolderSet() throws {
        try expectLine(.syncFolderSet(path: nil, error: "Couldn't sync through that folder. You don't have permission."), matches: "sync-folder-set")
    }

    @Test func appLines() {
        #expect(AppMessage(line: #"{"type":"ask","question":"why keep the 6?"}"#) == .ask("why keep the 6?"))
        #expect(AppMessage(line: #"{"type":"setGoal","goal":"naneinf"}"#) == .setGoal(.naneinf))
        #expect(AppMessage(line: #"{"type":"playForMe","goal":"win"}"#) == .playForMe(.win))
        #expect(AppMessage(line: #"{"type":"stopPilot"}"#) == .stopPilot)
        #expect(AppMessage(line: #"{"type":"stats"}"#) == .stats)
        #expect(AppMessage(line: #"{"type":"screenshot","id":2,"png":"iVBO"}"#) == .screenshot(id: 2, png: Data([0x89, 0x50, 0x4E])))
        #expect(AppMessage(line: #"{"type":"screenshot","id":2,"png":null}"#) == .screenshot(id: 2, png: nil))
        #expect(AppMessage(line: #"{"type":"setSyncFolder","path":"C:\\Users\\player\\iCloudDrive"}"#) == .setSyncFolder(#"C:\Users\player\iCloudDrive"#))
        #expect(AppMessage(line: #"{"type":"setSyncFolder","path":null}"#) == .setSyncFolder(nil))
    }

    @Test func ignoresLinesItCannotActOn() {
        #expect(AppMessage(line: #"{"type":"ask"}"#) == nil)
        #expect(AppMessage(line: #"{"type":"setGoal","goal":"lose"}"#) == nil)
        #expect(AppMessage(line: #"{"type":"jump"}"#) == nil)
        #expect(AppMessage(line: "not json") == nil)
    }
}
