import BalabroCore
import Foundation
import os

/// The bot's private copy of the game, minimised and hidden, kept open so the coach can ask what a save's hands really score.
/// It reads a copy of the player's save and never writes to their folder.
/// Starting takes about 20 s and a request about 3 s, so it stays open for a while between requests and costs little waiting.
actor Scorer {
    struct Answer: Sendable {
        var facts: String?
        var packCards: [ShopItem.Card] = []
    }

    private static let idleLimit: Duration = .seconds(600)
    private static let maxFailures = 3

    private let game: GameInstall
    private let lua: URL
    private let request = URL.applicationSupportDirectory.appending(path: "Balabro/scorer/request.jkr")
    private var process: BotProcess?
    private var starting: Task<Void, Never>?
    private var pending: (id: ScoreID, answer: CheckedContinuation<Answer, Never>)?
    private var nextID = 0
    private var lastUsed = ContinuousClock.now
    /// Failures in a row. A copy that keeps dying won't start working by being restarted at every decision.
    private var failures = 0
    private var stopping = false

    init?(game: GameInstall?, lua: URL?) {
        guard let game, let lua else { return nil }
        (self.game, self.lua) = (game, lua)
    }

    func warm() async {
        lastUsed = .now
        guard process == nil, failures < Self.maxFailures else { return }
        if let starting { return await starting.value }
        let task = Task { await launch() }
        starting = task
        await task.value
        starting = nil
    }

    /// The newest request wins: an older one still waiting gets an empty answer, because the player has moved on.
    func score(save: URL, unlocks: URL, within limit: Duration) async -> Answer {
        let deadline = ContinuousClock.now + limit
        do {
            let bytes = try Data(contentsOf: save)
            try FileManager.default.createDirectory(at: request.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: request, options: .atomic)
        } catch {
            return Answer()
        }
        await warm()
        guard let process else { return Answer() }
        let id = ScoreID(nextID)
        nextID += 1
        return await withCheckedContinuation { answer in
            finish(pending?.id, Answer())
            pending = (id, answer)
            process.tell("score|\(id.value)|\(request.path)|\(unlocks.path)")
            Task {
                try? await Task.sleep(until: deadline)
                finish(id, Answer())
            }
        }
    }

    private func finish(_ id: ScoreID?, _ answer: Answer) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.answer.resume(returning: answer)
    }

    private func launch() async {
        do {
            let install = try await BotInstall.prepare(from: game, lua: lua)
            let (process, output) = try BotProcess.launch(install, settings: ["BALABRO_BOT_MODE": "scorer"])
            self.process = process
            stopping = false
            Task { await read(output) }
            Task { await stopWhenIdle() }
        } catch {
            failures += 1
            Logger.balabro.error("Couldn't start the scorer: \(error)")
        }
    }

    private func read(_ output: AsyncStream<BotOutput>) async {
        for await item in output {
            switch item {
            case .line(let line):
                guard case .scored(let id, let packFile, let facts)? = ScorerFrame(line: line) else { continue }
                failures = 0
                let packCards = packFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? SaveFile.decodePackCards($0) }
                finish(id, Answer(facts: facts, packCards: packCards ?? []))
            case .exited(let status):
                process = nil
                if !stopping {
                    failures += 1
                    Logger.balabro.error("The scorer stopped with status \(status)")
                }
                finish(pending?.id, Answer())
            }
        }
    }

    private func stopWhenIdle() async {
        while let process {
            try? await Task.sleep(for: Self.idleLimit / 4)
            guard self.process === process else { return }
            if ContinuousClock.now - lastUsed >= Self.idleLimit {
                stopping = true
                process.kill()
                return
            }
        }
    }
}
