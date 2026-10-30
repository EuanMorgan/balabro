import Foundation

/// English names and description templates from the user's own `localization/en-us.lua`.
///
/// The repo is public and must not ship the game's text, so this is loaded at runtime from the
/// installed `Balatro.love`. Without it the coach still works, naming cards by key (`j_flower_pot`);
/// Opus knows most jokers by key, but descriptions make the advice reliable.
public struct GameText: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        /// Template lines with `{C:mult}`-style formatting tags stripped and `#1#` placeholders kept.
        public var text: [String]
    }

    let entries: [CenterKey: Entry]

    public static let missing = GameText(entries: [:])

    /// Parses `descriptions.{Joker,Tarot,Planet,Spectral,Voucher,Tag,Blind,Enhanced,Edition,Other,Back}`.
    public init(enUSLua source: String) throws(SaveFileError) {
        // TODO: LuaLiteral.parse(source), walk descriptions.*, strip `{...}` tags from each line.
        fatalError("not implemented")
    }

    init(entries: [CenterKey: Entry]) { self.entries = entries }

    public subscript(key: CenterKey) -> Entry? { entries[key] }
}
