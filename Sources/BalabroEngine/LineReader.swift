import Foundation

/// Lines from a child process's output, read on a thread of their own.
///
/// Not `FileHandle.bytes`: Windows doesn't have it, and on the Mac all its reads queue behind one another, so a game
/// with nothing to say would stop Claude's reply from being read, and that reply is what the game is waiting for.
public enum LineReader {
    public static func lines(from handle: FileHandle) -> AsyncStream<String> {
        lines { handle.availableData }
    }

    /// `next` blocks until it has bytes and returns none at the end. A trailing `\r` is dropped, because Windows
    /// programs end lines with CRLF, and a last line with no newline still counts.
    public static func lines(reading next: @escaping @Sendable () -> Data) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global().async {
                var pending = Data()
                while case let chunk = next(), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        continuation.yield(line(pending[pending.startIndex..<newline]))
                        pending = pending[(newline + 1)...]
                    }
                }
                if !pending.isEmpty { continuation.yield(line(pending)) }
                continuation.finish()
            }
        }
    }

    private static func line(_ bytes: Data) -> String {
        String(decoding: bytes.last == UInt8(ascii: "\r") ? bytes.dropLast() : bytes, as: UTF8.self)
    }
}
