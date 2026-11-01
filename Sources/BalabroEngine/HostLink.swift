import BalabroCore
import Foundation
import Observation

public enum HostMessage: Sendable {
    case hello(version: String, fontPath: String?, syncFolder: String?)
    case coach(CoachView)
    case pilot(PilotView)
    /// Answered by `AppMessage.screenshot` with the same id.
    case capture(id: Int)
    /// The answer to `AppMessage.stats`.
    case stats(StatsPage)
    /// A newer release with the Windows zip, which the app offers and installs itself.
    case update(AppRelease)
    /// The answer to `AppMessage.setSyncFolder`, after which the app starts a new engine. `path` is the folder in use.
    case syncFolderSet(path: String?, error: String?)

    public func line() throws -> Data { try jsonLine(self) }
}

/// JSON with no newline inside, then a newline.
func jsonLine(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    // A best hand of naneinf is infinite, and JSON has no infinity.
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return try encoder.encode(value) + Data("\n".utf8)
}

extension HostMessage: Encodable {
    private enum CodingKeys: String, CodingKey { case type, version, fontPath, syncFolder, statsMenuTitle, view, id, data, path, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version, let fontPath, let syncFolder):
            try container.encode("hello", forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(fontPath, forKey: .fontPath)
            try container.encode(syncFolder, forKey: .syncFolder)
            try container.encode(StatsPage.menuTitle, forKey: .statsMenuTitle)
        case .coach(let view):
            try container.encode("coach", forKey: .type)
            try container.encode(view, forKey: .view)
        case .pilot(let view):
            try container.encode("pilot", forKey: .type)
            try container.encode(view, forKey: .view)
        case .capture(let id):
            try container.encode("capture", forKey: .type)
            try container.encode(id, forKey: .id)
        case .stats(let page):
            try container.encode("stats", forKey: .type)
            try container.encode(page, forKey: .data)
        case .update(let release):
            try container.encode("update", forKey: .type)
            try release.encode(to: encoder)
        case .syncFolderSet(let path, let error):
            try container.encode("syncFolderSet", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(error, forKey: .error)
        }
    }
}

/// One line from the Windows app: a player's action, named after the runtime method the Mac panel calls, a screenshot, or a request for the stats page.
public enum AppMessage: Sendable, Equatable {
    case ask(String)
    case retry
    case refresh
    case adviseNextRun
    case setGoal(CoachGoal)
    case playForMe(CoachGoal)
    case stopPilot
    case dismissPilot
    case stats
    case screenshot(id: Int, png: Data?)
    /// nil stops syncing.
    case setSyncFolder(String?)

    public init?(line: String) {
        struct Fields: Decodable {
            var type: String
            var question: String?
            var goal: CoachGoal?
            var id: Int?
            var png: Data?
            var path: String?
        }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(line.utf8)) else { return nil }
        switch (fields.type, fields.question, fields.goal, fields.id) {
        case ("ask", let question?, _, _): self = .ask(question)
        case ("retry", _, _, _): self = .retry
        case ("refresh", _, _, _): self = .refresh
        case ("adviseNextRun", _, _, _): self = .adviseNextRun
        case ("setGoal", _, let goal?, _): self = .setGoal(goal)
        case ("playForMe", _, let goal?, _): self = .playForMe(goal)
        case ("stopPilot", _, _, _): self = .stopPilot
        case ("dismissPilot", _, _, _): self = .dismissPilot
        case ("stats", _, _, _): self = .stats
        case ("screenshot", _, _, let id?): self = .screenshot(id: id, png: fields.png)
        case ("setSyncFolder", _, _, _): self = .setSyncFolder(fields.path)
        default: return nil
        }
    }
}

/// The engine's side of the Windows app: JSON lines on stdin and stdout.
@MainActor
public final class HostLink {
    private let input: FileHandle
    private let output: FileHandle
    private let captureLimit: Duration
    private var captures: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var nextCapture = 0

    /// A screenshot the app hasn't sent within `captureLimit` is nil, and the reply is ignored if it comes later.
    public init(input: FileHandle, output: FileHandle, captureLimit: Duration = .seconds(5)) {
        (self.input, self.output, self.captureLimit) = (input, output, captureLimit)
    }

    public func screenshot() async -> Data? {
        let id = nextCapture
        nextCapture += 1
        return await withCheckedContinuation { continuation in
            captures[id] = continuation
            send(.capture(id: id))
            Task {
                try? await Task.sleep(for: captureLimit)
                captures.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    /// Says hello, sends each view at once and again whenever it changes, offers each newer release, and acts on the
    /// app's lines. Returns when the app closes stdin.
    public func serve(_ engine: Engine) async {
        let font = try? await engine.game?.extract("resources/fonts/m6x11plus.ttf")
        send(.hello(version: Platform.version, fontPath: font.map(Platform.path), syncFolder: engine.machine.syncFolder.map(Platform.path)))
        let watchers = [
            watch { .coach(engine.coach.view) },
            watch { .pilot(engine.pilot.view) },
            Task { await UpdateCheck.thisApp?.watch { send(.update($0)) } },
        ]
        await listen { handle($0, engine) }
        watchers.forEach { $0.cancel() }
    }

    /// Reads the app's lines until it closes stdin. Screenshots answer `screenshot()`, and every other line goes to `act`.
    public func listen(_ act: (AppMessage) -> Void) async {
        for await line in LineReader.lines(from: input) {
            guard let message = AppMessage(line: line) else {
                Platform.log("Ignoring a line from the app: \(line.prefix(200))")
                continue
            }
            if case .screenshot(let id, let png) = message {
                captures.removeValue(forKey: id)?.resume(returning: png)
            } else {
                act(message)
            }
        }
        captures.values.forEach { $0.resume(returning: nil) }
        captures = [:]
    }

    private func handle(_ message: AppMessage, _ engine: Engine) {
        switch message {
        case .ask(let question): engine.coach.ask(question)
        case .retry: engine.coach.retry()
        case .refresh: engine.coach.refresh()
        case .adviseNextRun: engine.coach.adviseNextRun()
        case .setGoal(let goal): engine.coach.setGoal(goal)
        case .playForMe(let goal): engine.pilot.start(goal: goal)
        case .stopPilot: engine.pilot.stop()
        case .dismissPilot: engine.pilot.dismiss()
        case .stats: send(.stats(engine.stats()))
        case .setSyncFolder(let path): Task { await setSyncFolder(path, engine) }
        case .screenshot: break
        }
    }

    /// Shuts the engine down first, so nothing it writes afterwards lands in the old place.
    private func setSyncFolder(_ path: String?, _ engine: Engine) async {
        await engine.shutdown()
        do {
            let machine = try await engine.machine.syncing(with: path.map { URL(filePath: $0) })
            send(.syncFolderSet(path: machine.syncFolder.map(Platform.path), error: nil))
        } catch {
            Platform.log("Couldn't sync through \(path ?? "the data folder"): \(error)")
            send(.syncFolderSet(path: engine.machine.syncFolder.map(Platform.path), error: "Couldn't sync through that folder. \(error.localizedDescription)"))
        }
    }

    private func watch(_ message: @escaping @MainActor () -> HostMessage) -> Task<Void, Never> {
        Task {
            var last: Data?
            while !Task.isCancelled {
                let (changed, signal) = AsyncStream.makeStream(of: Void.self)
                let current = withObservationTracking(message) { signal.finish() }
                if let line = try? current.line(), line != last {
                    write(line)
                    last = line
                }
                for await _ in changed {}
            }
        }
    }

    private func send(_ message: HostMessage) {
        do { write(try message.line()) } catch { Platform.log("Couldn't encode a line for the app: \(error)") }
    }

    private func write(_ line: Data) {
        try? output.write(contentsOf: line)
    }
}
