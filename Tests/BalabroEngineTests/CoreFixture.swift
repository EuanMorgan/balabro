import Foundation

/// The core's test fixtures, read from the source tree so the two test targets share one copy.
enum CoreFixture {
    static func url(_ path: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "BalabroCoreTests/Fixtures/\(path)")
    }
}
