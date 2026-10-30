import BalabroCore
import Foundation
import Testing

/// The game's text can't ship in a public repo, so this reads the unpacked copy when the machine has one.
private let enUSPath = "/tmp/balatro-src/localization/en-us.lua"

@Suite(.enabled(if: FileManager.default.fileExists(atPath: enUSPath), "needs an unpacked Balatro.love at /tmp/balatro-src"))
struct GameTextTests {
    func text() throws -> GameText { try GameText(enUSLua: String(contentsOfFile: enUSPath, encoding: .utf8)) }

    @Test func jokerTemplateWithoutFormattingTags() throws {
        let flowerPot = try #require(try text()[CenterKey(rawValue: "j_flower_pot")])
        #expect(flowerPot.name == "Flower Pot")
        #expect(flowerPot.text == ["X#1# Mult if poker", "hand contains a", "Diamond card, Club card,", "Heart card, and Spade card"])
    }

    @Test func blankSpacerLinesAreDropped() throws {
        #expect(try text()[CenterKey(rawValue: "b_black")]?.text == ["+#1# Joker slot", "-#2# hand", "every round"])
    }

    @Test func blindsAndTagsAreNamed() throws {
        let text = try text()
        #expect(text[CenterKey(rawValue: "bl_hook")]?.name == "The Hook")
        #expect(text[CenterKey(rawValue: "tag_garbage")]?.name == "Garbage Tag")
    }
}
