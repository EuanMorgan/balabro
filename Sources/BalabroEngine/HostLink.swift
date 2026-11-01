import BalabroCore
import Foundation
import Observation

public enum HostMessage: Sendable {
    case hello(version: String, fontPath: String?)
    case coach(CoachView)
    case pilot(PilotView)
    /// Answered by `AppMessage.screenshot` with the same id.
    case capture(id: Int)

    /// JSON with no newline inside, then a newline.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // A best hand of naneinf is infinite, and JSON has no infinity.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

extension HostMessage: Encodable {
    private enum CodingKeys: String, CodingKey { case type, version, fontPath, view, id }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version, let fontPath):
            try container.encode("hello", forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(fontPath, forKey: .fontPath)
        case .coach(let view):
            try container.encode("coach", forKey: .type)
            try container.encode(view, forKey: .view)
        case .pilot(let view):
            try container.encode("pilot", forKey: .type)
            try container.encode(view, forKey: .view)
        case .capture(let id):
            try container.encode("capture", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

/// One line from the Windows app: a player's action, named after the runtime method the Mac panel calls, or a screenshot.
public enum AppMessage: Sendable, Equatable {
    case ask(String)
    case retry
    case refresh
    case adviseNextRun
    case setGoal(CoachGoal)
    case playForMe(CoachGoal)
    case stopPilot
    case dismissPilot
    case screenshot(id: Int, png: Data?)

    public init?(line: String) {
        struct Fields: Decodable {
            var type: String
            var question: String?
            var goal: CoachGoal?
            var id: Int?
            var png: Data?
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
        case ("screenshot", _, _, let id?): self = .screenshot(id: id, png: fields.png)
        default: return nil
        }
    }
}

/// The engine's side of the Windows app: JSON lines on stdin and stdout.
@MainActor
public final class HostLink {
    private let input: FileHandle
    private let output: FileHandle
    private var captures: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var nextCapture = 0

    public init(input: FileHandle, output: FileHandle) { (self.input, self.output) = (input, output) }

    public func screenshot() async -> Data? {
        let id = nextCapture
        nextCapture += 1
        return await withCheckedContinuation { continuation in
            captures[id] = continuation
            send(.capture(id: id))
        }
    }

    /// Says hello, sends each view at once and again whenever it changes, and acts on the app's lines.
    /// Returns when the app closes stdin.
    public func serve(_ engine: Engine) async {
        let font = try? await engine.game?.extract("resources/fonts/m6x11plus.ttf")
        send(.hello(version: Self.version, fontPath: font.map(Platform.path)))
        let watchers = [watch { .coach(engine.coach.view) }, watch { .pilot(engine.pilot.view) }]
        for await line in LineReader.lines(from: input) {
            guard let message = AppMessage(line: line) else {
                Platform.log("Ignoring a line from the app: \(line.prefix(200))")
                continue
            }
            handle(message, engine)
        }
        watchers.forEach { $0.cancel() }
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
        case .screenshot(let id, let png): captures.removeValue(forKey: id)?.resume(returning: png)
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

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
