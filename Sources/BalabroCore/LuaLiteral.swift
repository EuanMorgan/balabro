import Foundation

/// A Lua table literal, the only Lua this app reads. Internal: no type outside BalabroCore can name it.
///
/// One parser serves both inputs:
/// - `save.jkr`, written by `STR_PACK`: `return {["k"]=v,[1]=v,}` with `%q` strings.
/// - `localization/en-us.lua`: `return { descriptions={ Joker={ j_x={ name="..", text={ "..", }}}}}`
///   with bare identifier keys and positional entries.
indirect enum LuaValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case table(LuaTable)
}

struct LuaTable: Sendable, Equatable {
    var named: [String: LuaValue]
    /// `[1]=`, `[2]=` and positional entries, by Lua index. STR_PACK writes `pairs` order, so indices arrive shuffled.
    var indexed: [Int: LuaValue]

    /// Values at 1...n in order, stopping at the first gap, like Lua's `ipairs`.
    var array: [LuaValue] { fatalError("not implemented") }
    subscript(_ key: String) -> LuaValue? { named[key] }
}

enum LuaLiteral {
    /// Parses `return <table>`.
    ///
    /// Grammar accepted: tables, `[string]=`, `[number]=`, `ident=`, positional values, `%q` strings
    /// (escapes `\\`, `\"`, `\n`, backslash-newline, `\ddd`), numbers including `1e+15`, `inf`, `-inf`, `nan`, `-nan`,
    /// and `true` / `false`. Not accepted: expressions, `..`, function calls, comments.
    /// End of input inside a table throws `.incomplete`; anything else unexpected throws `.notLua(offset:)`.
    static func parse(_ source: String) throws(SaveFileError) -> LuaValue {
        // TODO: hand-written recursive descent over the UTF-8 bytes. ~150 lines. No regex.
        fatalError("not implemented")
    }
}
