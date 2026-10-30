import BalabroCore
import Foundation

/// `~/Library/Application Support/Balabro/runs/<RunKey>.json`, one file per run.
/// A projection of `CoachState`, written whole on each `.save` effect, never read back except at launch.
struct RunStore: Sendable {
    let directory: URL

    static var `default`: RunStore { fatalError("not implemented") }

    /// Unreadable files are skipped and logged, not fatal: losing one run's history beats not starting.
    func loadAll() -> [RunRecord] { fatalError("not implemented") }

    /// `JSONEncoder` with sorted keys, `Data.write(options: .atomic)`.
    func save(_ record: RunRecord) throws { fatalError("not implemented") }
}
