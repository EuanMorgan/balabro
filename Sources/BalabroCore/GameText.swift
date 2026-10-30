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

    /// Parses `descriptions.{Joker,Tarot,Planet,Spectral,Voucher,Tag,Blind,Enhanced,Edition,Other,Back,Stake}`.
    public init(enUSLua source: String) throws(SaveFileError) {
        guard case .table(let root) = try LuaLiteral.parse(source), case .table(let descriptions)? = root["descriptions"] else {
            throw .unexpectedShape(path: "descriptions")
        }
        var entries: [CenterKey: Entry] = [:]
        for set in Self.sets {
            guard case .table(let group)? = descriptions[set] else { continue }
            for (key, value) in group.named {
                guard case .table(let entry) = value, case .string(let name)? = entry["name"] else { continue }
                let lines: [String] = if case .table(let text)? = entry["text"] {
                    text.array.compactMap { if case .string(let line) = $0 { Self.stripTags(line) } else { nil } }.filter { !$0.isEmpty }
                } else { [] }
                entries[CenterKey(rawValue: key)] = Entry(name: name, text: lines)
            }
        }
        self.entries = entries
    }

    static let sets = ["Joker", "Tarot", "Planet", "Spectral", "Voucher", "Tag", "Blind", "Enhanced", "Edition", "Other", "Back", "Stake"]

    /// `"{X:mult,C:white} X#1# {} Mult"` -> `"X#1# Mult"`.
    static func stripTags(_ line: String) -> String {
        var out = ""
        var inTag = false
        for c in line {
            if c == "{" { inTag = true } else if c == "}" { inTag = false } else if !inTag { out.append(c) }
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    init(entries: [CenterKey: Entry]) { self.entries = entries }

    public subscript(key: CenterKey) -> Entry? { entries[key] }
}
