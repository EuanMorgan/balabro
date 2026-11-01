@testable import BalabroEngine
import BalabroCore
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SaveWatcherTests {
    /// What a watcher event says, in a form `#expect` can compare.
    func describe(_ event: CoachEvent?) -> String {
        switch event {
        case .saveWritten(let snapshot)?: "written \(snapshot.phase)"
        case .saveRemoved(let profile)?: "removed \(profile)"
        case .saveUnreadable(let profile, let error)?: "unreadable \(profile) \(error)"
        default: "\(String(describing: event))"
        }
    }

    @Test func reportsTheSaveOnDiskThenEachChangeThenItsRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "balabro-saves-\(UUID().uuidString)")
        let save = root.appending(path: "2/save.jkr")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: CoreFixture.url("saves/02-hand.jkr")).write(to: save)

        var events = SaveWatcher(root: root).events().makeAsyncIterator()
        #expect(describe(await events.next()) == "written selectingHand")

        try Data(contentsOf: CoreFixture.url("saves/05-shop.jkr")).write(to: save)
        #expect(describe(await events.next()) == "written shop")

        try FileManager.default.removeItem(at: save)
        #expect(describe(await events.next()) == "removed 2")
    }
}
