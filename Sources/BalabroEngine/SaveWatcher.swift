import BalabroCore
import Foundation

/// Watches the Balatro save root and turns writes of any `<profile>/save.jkr` into coach events.
/// It doesn't read `settings.jkr` to learn the active profile: the profile whose save was just
/// written is, by definition, the one being played.
struct SaveWatcher: Sendable {
    let root: URL
    static let profiles = 1...3

    /// First yields one event per save already on disk, then one per change.
    ///
    /// Reads every save each 250 ms and compares the bytes. The game writes at most every 5 s, and the same code
    /// runs on the Mac and Windows. Reading by path also survives the game deleting and recreating `save.jkr`.
    func events() -> AsyncStream<CoachEvent> {
        AsyncStream { continuation in
            let reader = Task {
                var lastRead: [Int: Data] = [:]
                while !Task.isCancelled {
                    for profile in Self.profiles {
                        let url = root.appending(path: "\(profile)/save.jkr")
                        guard let bytes = try? Data(contentsOf: url) else {
                            if lastRead.removeValue(forKey: profile) != nil { continuation.yield(.saveRemoved(profile: profile)) }
                            continue
                        }
                        guard bytes != lastRead[profile] else { continue }
                        let (settled, result) = await Self.settle(at: url, profile: profile, first: bytes)
                        lastRead[profile] = settled
                        switch result {
                        case .success(let snapshot): continuation.yield(.saveWritten(snapshot))
                        case .failure(let error): continuation.yield(.saveUnreadable(profile: profile, error))
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// The game's save thread writes non-atomically (`love.filesystem.write`), so a read can catch
    /// half a file. `.incomplete` is retried every 100 ms, up to 2 s, rereading the file each time.
    static func decodeSettled(at url: URL, profile: Int) async -> Result<RunSnapshot, SaveFileError> {
        await settle(at: url, profile: profile, first: (try? Data(contentsOf: url)) ?? Data()).result
    }

    private static func settle(at url: URL, profile: Int, first: Data) async -> (bytes: Data, result: Result<RunSnapshot, SaveFileError>) {
        var bytes = first
        for attempt in 0...20 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                bytes = (try? Data(contentsOf: url)) ?? Data()
            }
            let result = Result { () throws(SaveFileError) in try SaveFile.decode(bytes, profile: profile) }
            if case .failure(.incomplete) = result { continue }
            return (bytes, result)
        }
        return (bytes, .failure(.incomplete))
    }
}
