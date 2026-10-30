import Foundation

/// Real files, never hand-built Lua: the saves come from `tools/driver/run.sh` (seed BALABRO1, Red Deck,
/// White Stake), the stream logs from `claude` 2.1.312. Expected values in tests are read off these
/// files by hand or off the in-game screenshot the driver took, never recomputed by the code under test.
enum Fixture {
    static func save(_ name: String) -> Data { data("saves/\(name).jkr") }
    /// The save's Lua text, for tests that change one key of a real save to reach a state the driver didn't.
    static func saveText(_ name: String) -> String {
        String(decoding: try! (save(name) as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)
    }
    static func stream(_ name: String) -> [Data] {
        data("claude-stream/\(name).jsonl").split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }
    static func data(_ path: String) -> Data {
        try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil)!)
    }
}
