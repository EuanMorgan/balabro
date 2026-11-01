@testable import BalabroEngine
import Foundation
import Testing

/// The parts of finding and copying the Windows game that don't need Windows.
@Suite
struct WindowsGameTests {
    @Test func readsEverySteamLibraryPath() {
        let vdf = #"""
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        		"label"		""
        		"apps"
        		{
        			"228980"		"417476617"
        		}
        	}
        	"1"
        	{
        		"path"		"D:\\SteamLibrary"
        	}
        }
        """#
        #expect(SteamLibraries.paths(in: vdf) == [#"C:\Program Files (x86)\Steam"#, #"D:\SteamLibrary"#])
    }

    /// `prefixed.zip` is 3,000 bytes followed by a zip, standing in for LÖVE with the game appended.
    @Test func cutsLoveFromTheGameAndCopiesItsLibraries() throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "balabro-\(UUID().uuidString)")
        let (game, runtime) = (work.appending(path: "Balatro"), work.appending(path: "Runtime"))
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = try Data(contentsOf: CoreFixture.url("zip/prefixed.zip"))
        try exe.write(to: game.appending(path: "Balatro.exe"))
        try Data("SDL".utf8).write(to: game.appending(path: "SDL2.dll"))

        try BotInstall.cutLove(from: game, to: runtime)

        #expect(try FileManager.default.contentsOfDirectory(atPath: runtime.path).sorted() == ["SDL2.dll", "love.exe"])
        #expect(try Data(contentsOf: runtime.appending(path: "love.exe")) == exe.prefix(3000))
        #expect(try Data(contentsOf: runtime.appending(path: "SDL2.dll")) == Data("SDL".utf8))
    }
}
