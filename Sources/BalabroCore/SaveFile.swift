import Compression
import Foundation

/// The one boundary where Balatro's bytes become typed values.
///
/// Raw Lua never leaves this file and `LuaLiteral.swift`. Everything past `decode` sees `RunSnapshot`.
public enum SaveFile {
    /// Decodes `save.jkr` bytes. Accepts the raw DEFLATE the game writes and the plain
    /// `return {...}` text it also accepts on load (`get_compressed`), so tests can pass literals.
    ///
    /// Throws `.incomplete` for a file the game's save thread is still writing. That is normal;
    /// the caller retries. Every other error means the format isn't what we expect.
    public static func decode(_ bytes: Data, profile: Int) throws(SaveFileError) -> RunSnapshot {
        // TODO:
        //   text = bytes.starts(with: "return") ? utf8(bytes) : inflateRaw(bytes)   // inflate failure -> .incomplete
        //   root = try LuaLiteral.parse(text)                                       // unexpected EOF -> .incomplete
        //   return try RunSnapshot(lua: root, profile: profile)                     // missing key -> .unexpectedShape(path)
        fatalError("not implemented")
    }
}

public enum SaveFileError: Error, Sendable, Hashable {
    /// Truncated DEFLATE stream or Lua text that ends mid-table. Retry shortly.
    case incomplete
    /// The file parsed but a key we rely on is missing or the wrong type. `path` is like `GAME.round_resets.ante`.
    case unexpectedShape(path: String)
    case notLua(offset: Int)
}

/// `COMPRESSION_ZLIB` in Apple's Compression framework is raw DEFLATE (RFC 1951) with no zlib header,
/// which is exactly what LÖVE's `love.data.compress('string', 'deflate', ...)` writes.
func inflateRaw(_ bytes: Data) throws(SaveFileError) -> String {
    // TODO: compression_stream with COMPRESSION_STREAM_DECODE, growing the output buffer.
    //       A stream that ends before COMPRESSION_STATUS_END is a half-written file: throw .incomplete.
    fatalError("not implemented")
}

extension RunSnapshot {
    /// Maps the top-level save table (`cardAreas`, `tags`, `GAME`, `STATE`, `ACTION`, `BLIND`, `BACK`, `VERSION`).
    ///
    /// Strict on keys that define a decision (STATE, hand, jokers, dollars), lenient on everything else:
    /// an unknown edition or seal string maps to nil instead of failing the whole snapshot.
    init(lua root: LuaValue, profile: Int) throws(SaveFileError) {
        // TODO:
        //   hand: cardAreas.hand.cards in array order; facing == "back" -> .faceDown.
        //   deck: cardAreas.deck.cards folded into counts. The array order is the draw order; drop it here.
        //   openingBooster: ACTION.type == "use_card" -> the shop_booster card whose sort_id == ACTION.card.
        //   playing card: save_fields.card "H_Q" is the identity; base.suit / base.value confirm it;
        //                 save_fields.center "c_base" means no enhancement, "m_*" an enhancement.
        //   joker liveValues: flatten `ability` (skip name/set/effect/type and nested tables of tables).
        //   numbers: Lua prints huge scores as `1e+300` and overflow as `inf`; LuaLiteral handles both.
        fatalError("not implemented")
    }
}
