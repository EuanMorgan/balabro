import BalabroCore
import CoreServices
import CryptoKit
import Foundation

/// Watches the Balatro save root and turns writes of any `<profile>/save.jkr` into coach events.
/// It doesn't read `settings.jkr` to learn the active profile: the profile whose save was just
/// written is, by definition, the one being played.
struct SaveWatcher: Sendable {
    let root: URL
    static let profiles = 1...3

    static var defaultRoot: URL { .applicationSupportDirectory.appending(path: "Balatro") }

    /// First yields one event per save already on disk, then one per change.
    ///
    /// FSEvents on the directory, not a file descriptor on the file: the game deletes and recreates
    /// `save.jkr`, which orphans a descriptor.
    func events() -> AsyncStream<CoachEvent> {
        let (changed, notify) = AsyncStream.makeStream(of: Int.self)
        Self.profiles.forEach { notify.yield($0) }
        // FSEvents reports real paths (`/private/tmp`, which `resolvingSymlinksInPath` turns back into `/tmp`),
        // and a missing root never reports its own creation, so a root missing at launch is watched from above.
        let parent = root.deletingLastPathComponent()
        let realParent = realpath(parent.path, nil).map { path in
            defer { free(path) }
            return URL(filePath: String(cString: path))
        }
        let root = (realParent ?? parent).appending(path: root.lastPathComponent)
        let saves = Dictionary(uniqueKeysWithValues: Self.profiles.map { (root.appending(path: "\($0)/save.jkr").path, $0) })
        let watched = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let stream = FileEvents(watching: watched) { paths in
            Set(paths.compactMap { saves[$0] }).sorted().forEach { notify.yield($0) }
        }

        return AsyncStream { continuation in
            let reader = Task {
                var lastRead: [Int: SHA256.Digest] = [:]
                for await profile in changed {
                    let url = root.appending(path: "\(profile)/save.jkr")
                    guard let bytes = try? Data(contentsOf: url) else {
                        if lastRead.removeValue(forKey: profile) != nil { continuation.yield(.saveRemoved(profile: profile)) }
                        continue
                    }
                    // FSEvents often reports one write twice.
                    guard SHA256.hash(data: bytes) != lastRead[profile] else { continue }
                    let (settled, result) = await Self.settle(at: url, profile: profile, first: bytes)
                    lastRead[profile] = SHA256.hash(data: settled)
                    switch result {
                    case .success(let snapshot): continuation.yield(.saveWritten(snapshot))
                    case .failure(let error): continuation.yield(.saveUnreadable(profile: profile, error))
                    }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                stream.stop()
                notify.finish()
            }
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

/// An FSEvents stream with file-level events, delivered on a private serial queue.
private final class FileEvents: Sendable {
    private final class Context: Sendable {
        let onChange: @Sendable ([String]) -> Void
        init(_ onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
    }
    nonisolated(unsafe) private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.euanmorgan.balabro.saves")

    init(watching directory: URL, onChange: @escaping @Sendable ([String]) -> Void) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(Context(onChange)).toOpaque(),
            retain: nil, release: { Unmanaged<Context>.fromOpaque($0!).release() }, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, _, _ in
                let context = Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
                context.onChange(Array(paths.prefix(count)))
            },
            &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        )!
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
