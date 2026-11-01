import BalabroCore
import Foundation
import Testing

/// `plain.zip` is `zip -r -n .dat plain.zip blind.dat joker`, so `blind.dat` is stored and `joker/advice.txt` is
/// deflated. `prefixed.zip` is 3,000 random bytes followed by `plain.zip`, the way `Balatro.exe` is `love.exe`
/// followed by the game.
@Suite
struct ZipArchiveTests {
    static let advice = "Jimbo says: play the flush. Jimbo says: play the flush. Jimbo says: play the flush.\n"
    static let blind = "Ante 1, Small Blind, 300 chips\n"

    func archive(_ name: String) throws -> ZipArchive {
        try ZipArchive(file: try #require(Bundle.module.url(forResource: "Fixtures/zip/\(name)", withExtension: nil)))
    }

    @Test(arguments: [("plain.zip", 0), ("prefixed.zip", 3000)])
    func readsEachEntry(name: String, prefixLength: Int) throws {
        let zip = try archive(name)
        #expect(zip.prefixLength == prefixLength)
        #expect(zip.names == ["blind.dat", "joker/", "joker/advice.txt"])
        #expect(try zip.read("blind.dat") == Data(Self.blind.utf8))
        #expect(try zip.read("joker/advice.txt") == Data(Self.advice.utf8))
    }

    @Test func extractsEveryEntryIntoAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try archive("prefixed.zip").extractAll(to: folder)
        #expect(try String(contentsOf: folder.appending(path: "blind.dat"), encoding: .utf8) == Self.blind)
        #expect(try String(contentsOf: folder.appending(path: "joker/advice.txt"), encoding: .utf8) == Self.advice)
    }
}
