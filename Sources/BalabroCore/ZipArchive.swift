import Foundation

/// A zip that may have other bytes in front of it: `Balatro.love` has none, and `Balatro.exe` on Windows is
/// LÖVE's `love.exe` with the game's zip appended. Stored and deflated entries only, which is all the game uses.
public struct ZipArchive: Sendable {
    public enum Failure: Error, Sendable, Hashable {
        case notAZip
        case corrupt
        case noEntry(String)
        case unsupportedMethod(entry: String, method: Int)
        case unsafePath(String)
    }

    private struct Entry: Sendable {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeader: Int
    }

    /// Bytes before the zip. Appending a zip to an exe doesn't rewrite its offsets, so every offset is short by this.
    public let prefixLength: Int
    private let bytes: Data
    private let entries: [Entry]

    public var names: [String] { entries.map(\.name) }

    public init(file: URL) throws {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: lowest, by: -1).first(where: { (try? Self.littleEndian(bytes, $0, 4)) == 0x0605_4b50 })
        else { throw Failure.notAZip }
        let entryCount = try Self.littleEndian(bytes, end + 10, 2)
        let directorySize = try Self.littleEndian(bytes, end + 12, 4)
        let directoryOffset = try Self.littleEndian(bytes, end + 16, 4)
        prefixLength = end - directorySize - directoryOffset
        guard prefixLength >= 0 else { throw Failure.corrupt }

        var entries: [Entry] = []
        var record = prefixLength + directoryOffset
        for _ in 0..<entryCount {
            guard try Self.littleEndian(bytes, record, 4) == 0x0201_4b50 else { throw Failure.corrupt }
            let nameLength = try Self.littleEndian(bytes, record + 28, 2)
            let nameStart = record + 46
            guard nameStart + nameLength <= bytes.count else { throw Failure.corrupt }
            entries.append(Entry(
                name: String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self),
                method: try Self.littleEndian(bytes, record + 10, 2),
                compressedSize: try Self.littleEndian(bytes, record + 20, 4),
                uncompressedSize: try Self.littleEndian(bytes, record + 24, 4),
                localHeader: prefixLength + (try Self.littleEndian(bytes, record + 42, 4))))
            record = nameStart + nameLength + (try Self.littleEndian(bytes, record + 30, 2)) + (try Self.littleEndian(bytes, record + 32, 2))
        }
        self.bytes = bytes
        self.entries = entries
    }

    public func read(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw Failure.noEntry(name) }
        return try read(entry)
    }

    public func extractAll(to folder: URL) throws {
        let files = FileManager.default
        for entry in entries {
            guard !entry.name.hasPrefix("/"), !entry.name.split(separator: "/").contains("..") else {
                throw Failure.unsafePath(entry.name)
            }
            let target = folder.appending(path: entry.name)
            if entry.name.hasSuffix("/") {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try read(entry).write(to: target)
            }
        }
    }

    private func read(_ entry: Entry) throws -> Data {
        guard try Self.littleEndian(bytes, entry.localHeader, 4) == 0x0403_4b50 else { throw Failure.corrupt }
        let start = entry.localHeader + 30 + (try Self.littleEndian(bytes, entry.localHeader + 26, 2)) + (try Self.littleEndian(bytes, entry.localHeader + 28, 2))
        guard start + entry.compressedSize <= bytes.count else { throw Failure.corrupt }
        let stored = bytes[start..<start + entry.compressedSize]
        let contents = switch entry.method {
        case 0: Data(stored)
        case 8: try Inflate.raw(stored)
        default: throw Failure.unsupportedMethod(entry: entry.name, method: entry.method)
        }
        guard contents.count == entry.uncompressedSize else { throw Failure.corrupt }
        return contents
    }

    private static func littleEndian(_ bytes: Data, _ offset: Int, _ size: Int) throws(Failure) -> Int {
        guard offset >= 0, offset + size <= bytes.count else { throw .corrupt }
        return (0..<size).reversed().reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
    }
}
