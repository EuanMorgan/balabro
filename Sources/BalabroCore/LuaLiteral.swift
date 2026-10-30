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
    var named: [String: LuaValue] = [:]
    /// `[1]=`, `[2]=` and positional entries, by Lua index. STR_PACK writes `pairs` order, so indices arrive shuffled.
    var indexed: [Int: LuaValue] = [:]

    /// Values at 1...n in order, stopping at the first gap, like Lua's `ipairs`.
    var array: [LuaValue] {
        var values: [LuaValue] = []
        while let next = indexed[values.count + 1] { values.append(next) }
        return values
    }
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
        var parser = Parser(bytes: Array(source.utf8))
        try parser.keyword("return")
        let value = try parser.value()
        parser.skipSpace()
        guard parser.atEnd else { throw .notLua(offset: parser.offset) }
        return value
    }
}

private struct Parser {
    let bytes: [UInt8]
    var offset = 0

    var atEnd: Bool { offset >= bytes.count }

    mutating func skipSpace() {
        while offset < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[offset]) { offset += 1 }
    }

    mutating func peek() throws(SaveFileError) -> UInt8 {
        skipSpace()
        guard offset < bytes.count else { throw .incomplete }
        return bytes[offset]
    }

    mutating func expect(_ byte: UInt8) throws(SaveFileError) {
        guard try peek() == byte else { throw .notLua(offset: offset) }
        offset += 1
    }

    mutating func keyword(_ word: String) throws(SaveFileError) {
        skipSpace()
        let start = offset
        guard try self.word() == word else { throw .notLua(offset: start) }
    }

    mutating func value() throws(SaveFileError) -> LuaValue {
        switch try peek() {
        case UInt8(ascii: "{"): return .table(try table())
        case UInt8(ascii: "\""): return .string(try string())
        default:
            let start = offset
            let token = try word()
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "inf": return .number(.infinity)
            case "-inf": return .number(-.infinity)
            case "nan", "-nan": return .number(.nan)
            default:
                guard let number = Double(token) else { throw .notLua(offset: start) }
                return .number(number)
            }
        }
    }

    /// A bare run of identifier or number characters. Throws `.incomplete` if it runs into the end of input,
    /// because a number cut off mid-digits can't be told apart from a whole one.
    mutating func word() throws(SaveFileError) -> String {
        _ = try peek()
        let start = offset
        while offset < bytes.count, Self.isWordByte(bytes[offset]) { offset += 1 }
        guard offset < bytes.count else { throw .incomplete }
        guard offset > start else { throw .notLua(offset: start) }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == UInt8(ascii: "_") || b == UInt8(ascii: ".") || b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
    }

    mutating func table() throws(SaveFileError) -> LuaTable {
        try expect(UInt8(ascii: "{"))
        var table = LuaTable()
        var position = 1
        while true {
            let next = try peek()
            if next == UInt8(ascii: "}") {
                offset += 1
                return table
            }
            if next == UInt8(ascii: "[") {
                offset += 1
                let key = try value()
                try expect(UInt8(ascii: "]"))
                try expect(UInt8(ascii: "="))
                switch key {
                case .string(let name): table.named[name] = try value()
                case .number(let n) where n == n.rounded() && abs(n) < 1e15: table.indexed[Int(n)] = try value()
                default: throw .notLua(offset: offset)
                }
            } else if let name = try identifierKey() {
                table.named[name] = try value()
            } else {
                table.indexed[position] = try value()
                position += 1
            }
            let separator = try peek()
            if separator == UInt8(ascii: ",") || separator == UInt8(ascii: ";") {
                offset += 1
            } else if separator != UInt8(ascii: "}") {
                throw .notLua(offset: offset)
            }
        }
    }

    /// `name =`, consumed only if the `=` follows; otherwise the offset is left alone for a positional value.
    mutating func identifierKey() throws(SaveFileError) -> String? {
        let start = offset
        let first = bytes[offset]
        guard first == UInt8(ascii: "_") || (first | 0x20 >= 0x61 && first | 0x20 <= 0x7A) else { return nil }
        let name = try word()
        guard try peek() == UInt8(ascii: "=") else {
            offset = start
            return nil
        }
        offset += 1
        return name
    }

    mutating func string() throws(SaveFileError) -> String {
        try expect(UInt8(ascii: "\""))
        var out: [UInt8] = []
        while true {
            guard offset < bytes.count else { throw .incomplete }
            let b = bytes[offset]
            offset += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard offset < bytes.count else { throw .incomplete }
                let e = bytes[offset]
                offset += 1
                switch e {
                case UInt8(ascii: "n"), 0x0A: out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "a"): out.append(0x07)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "v"): out.append(0x0B)
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    var code = Int(e - 0x30)
                    for _ in 0..<2 {
                        guard offset < bytes.count else { throw .incomplete }
                        guard bytes[offset] >= 0x30, bytes[offset] <= 0x39 else { break }
                        code = code * 10 + Int(bytes[offset] - 0x30)
                        offset += 1
                    }
                    guard code <= 255 else { throw .notLua(offset: offset) }
                    out.append(UInt8(code))
                default: out.append(e)
                }
            default:
                out.append(b)
            }
        }
    }
}
