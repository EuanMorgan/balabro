import Foundation

// How the views go to the Windows app. Each carries the text the Mac panel shows, so the Windows app has no
// coaching rules of its own, and an enum with values is an object with a "kind".

extension CoachView: Encodable {
    private enum CodingKeys: String, CodingKey {
        case status, goal, headline, chipsNeeded, waitingOn, waitingCaptions, placeholder, advice, score, sawScreen, thread, queuedQuestion, problem, canRetry
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(goal, forKey: .goal)
        try container.encode(headline, forKey: .headline)
        try container.encodeIfPresent(chipsNeeded, forKey: .chipsNeeded)
        try container.encodeIfPresent(waitingOn.map(Self.name), forKey: .waitingOn)
        try container.encode(waitingCaptions, forKey: .waitingCaptions)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        try container.encodeIfPresent(advice, forKey: .advice)
        try container.encode(score, forKey: .score)
        try container.encode(sawScreen, forKey: .sawScreen)
        try container.encode(thread, forKey: .thread)
        try container.encodeIfPresent(queuedQuestion, forKey: .queuedQuestion)
        try container.encodeIfPresent(problem, forKey: .problem)
        try container.encode(canRetry, forKey: .canRetry)
    }

    private static func name(_ kind: Decision.Kind) -> String {
        switch kind {
        case .playHand: "playHand"
        case .shop: "shop"
        case .blindSelect: "blindSelect"
        case .openPack: "openPack"
        }
    }
}

extension CoachView.Status: Encodable {}
extension PilotView.Status: Encodable {}

extension CoachView.ScoredLine: Encodable {
    private enum CodingKeys: String, CodingKey { case label, sum, isAlternative, clears, note }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(line.label, forKey: .label)
        try container.encodeIfPresent(line.sum, forKey: .sum)
        try container.encode(line.isAlternative, forKey: .isAlternative)
        try container.encode(outcome == .clears, forKey: .clears)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

extension Advice.Lesson: Encodable {
    private enum CodingKeys: String, CodingKey { case number, title, body, heading }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(heading, forKey: .heading)
    }
}

extension Problem: Encodable {
    private enum CodingKeys: String, CodingKey { case kind, reason, message }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let (kind, reason): (String, String?) = switch self {
        case .noRun: ("noRun", nil)
        case .screenRecordingDenied: ("screenRecordingDenied", nil)
        case .saveUnreadable: ("saveUnreadable", nil)
        case .turnFailed(.notLoggedIn): ("turnFailed", "notLoggedIn")
        case .turnFailed(.rateLimited): ("turnFailed", "rateLimited")
        case .turnFailed(.cliNotFound): ("turnFailed", "cliNotFound")
        case .turnFailed(.exited): ("turnFailed", "exited")
        case .turnFailed(.malformedOutput): ("turnFailed", "malformedOutput")
        }
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(message, forKey: .message)
    }
}

extension PilotView: Encodable {
    private enum CodingKeys: String, CodingKey {
        case status, title, startedAt, goal, run, startingLine, choosingLine, why, warning, result, bestTimes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(goal, forKey: .goal)
        try container.encodeIfPresent(run, forKey: .run)
        try container.encodeIfPresent(startingLine, forKey: .startingLine)
        try container.encodeIfPresent(choosingLine, forKey: .choosingLine)
        try container.encodeIfPresent(why, forKey: .why)
        try container.encodeIfPresent(warning, forKey: .warning)
        try container.encodeIfPresent(result.map(ResultJSON.init), forKey: .result)
        try container.encode(bestTimes, forKey: .bestTimes)
    }

    /// Not `PilotResult`'s own `Codable`, which is the results file's format and spells `.failed` with a `_0` key.
    private struct ResultJSON: Encodable {
        struct Ending: Encodable {
            var kind: String
            var reason: String?
        }
        var ending: Ending
        var goal: String
        var deck: String
        var stake: Int
        var ante: Int
        var round: Int
        var bestHand: Double
        var bestHandText: String
        var seconds: Double
        var time: String
        var lines: [String]
        var gameVersion: String
        var finishedAt: Date

        init(_ result: PilotResult) {
            ending = switch result.ending {
            case .won: Ending(kind: "won")
            case .naneinf: Ending(kind: "naneinf")
            case .lost: Ending(kind: "lost")
            case .stopped: Ending(kind: "stopped")
            case .failed(let reason): Ending(kind: "failed", reason: reason)
            }
            (goal, deck, stake, ante, round) = (result.goal, result.deck.rawValue, result.stake, result.ante, result.round)
            (bestHand, bestHandText, seconds, time) = (result.bestHand, result.bestHandText, result.seconds, PilotView.clock(result.seconds))
            (lines, gameVersion, finishedAt) = (result.lines, result.gameVersion, result.finishedAt)
        }
    }
}

extension BotStatus: Encodable {
    private enum CodingKeys: String, CodingKey { case ante, round, dollars, bestHand, bestHandText, doing, lines }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ante, forKey: .ante)
        try container.encode(round, forKey: .round)
        try container.encode(dollars, forKey: .dollars)
        try container.encode(bestHand, forKey: .bestHand)
        try container.encode(bestHandText, forKey: .bestHandText)
        try container.encode(doing, forKey: .doing)
        try container.encode(lines, forKey: .lines)
    }
}

extension BestTime: Encodable {
    private enum CodingKeys: String, CodingKey { case title, seconds, line }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(line, forKey: .line)
    }
}

extension AppRelease: Encodable {
    private enum CodingKeys: String, CodingKey { case version, assetURL, pageURL, words }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version.description, forKey: .version)
        try container.encode(download, forKey: .assetURL)
        try container.encode(page, forKey: .pageURL)
        try container.encode(words, forKey: .words)
    }
}
