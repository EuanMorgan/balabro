import BalabroCore
import CoreServices
import CryptoKit
import Foundation

/// Watches `~/Library/Application Support/Balatro/` and turns writes of any `<profile>/save.jkr`
/// into coach events. It doesn't read `settings.jkr` to learn the active profile: the profile
/// whose save was just written is, by definition, the one being played.
struct SaveWatcher: Sendable {
    let root: URL

    /// First yields one event per save already on disk, then one per change.
    ///
    /// FSEvents on the directory, not a file descriptor on the file: the game deletes and recreates
    /// `save.jkr`, which orphans a descriptor. `kFSEventStreamCreateFlagFileEvents | NoDefer`, latency 0.1 s.
    func events() -> AsyncStream<CoachEvent> {
        // TODO:
        //   for path matching `^<root>/([123])/save\.jkr$`:
        //     missing -> .saveRemoved(profile)
        //     bytes unchanged since last read (SHA-256) -> nothing (FSEvents often reports one write twice)
        //     else decodeSettled(bytes) -> .saveWritten / .saveUnreadable
        fatalError("not implemented")
    }

    /// The game's save thread writes non-atomically (`love.filesystem.write`), so a read can catch
    /// half a file. `.incomplete` is retried every 100 ms, up to 2 s, rereading the file each time.
    static func decodeSettled(at url: URL, profile: Int) async -> Result<RunSnapshot, SaveFileError> {
        fatalError("not implemented")
    }
}
