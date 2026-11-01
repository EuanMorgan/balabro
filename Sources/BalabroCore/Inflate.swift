import Foundation

/// Raw DEFLATE (RFC 1951), with no zlib or gzip header: what LÖVE writes into `save.jkr` and what a zip's deflated
/// entries hold. `NSData.decompressed` exists only in Apple's Foundation. Decoding follows zlib's `contrib/puff`.
public enum Inflate {
    public enum Failure: Error, Sendable, Hashable {
        /// The input ends before the final block does.
        case truncated
        case corrupt
    }

    public static func raw(_ bytes: Data) throws(Failure) -> Data {
        var stream = Stream(input: [UInt8](bytes))
        var isFinal = false
        while !isFinal {
            isFinal = try stream.bits(1) == 1
            switch try stream.bits(2) {
            case 0: try stream.stored()
            case 1: try stream.codes(literals: fixedLiterals, distances: fixedDistances)
            case 2:
                let (literals, distances) = try stream.dynamicTables()
                try stream.codes(literals: literals, distances: distances)
            default: throw .corrupt
            }
        }
        return Data(stream.output)
    }

    private static let fixedLiterals = try! Huffman(lengths:
        Array(repeating: 8, count: 144) + Array(repeating: 9, count: 112) + Array(repeating: 7, count: 24) + Array(repeating: 8, count: 8))
    private static let fixedDistances = try! Huffman(lengths: Array(repeating: 5, count: 30))

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
        1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) throws(Failure) {
            for length in lengths { counts[length] += 1 }
            var unused = 1
            for length in 1...15 {
                unused = unused << 1 - counts[length]
                guard unused >= 0 else { throw .corrupt }
            }
            var next = [Int](repeating: 0, count: 16)
            for length in 1..<15 { next[length + 1] = next[length] + counts[length] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[next[length]] = symbol
                next[length] += 1
            }
        }
    }

    private struct Stream {
        let input: [UInt8]
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []

        mutating func bits(_ count: Int) throws(Failure) -> Int {
            while bitCount < count {
                guard position < input.count else { throw .truncated }
                bitBuffer |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            let value = bitBuffer & (1 << count - 1)
            bitBuffer >>= count
            bitCount -= count
            return value
        }

        mutating func stored() throws(Failure) {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw .truncated }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            guard length == complement ^ 0xFFFF else { throw .corrupt }
            position += 4
            guard position + length <= input.count else { throw .truncated }
            output += input[position..<position + length]
            position += length
        }

        mutating func decode(_ code: Huffman) throws(Failure) -> Int {
            var value = 0
            var first = 0
            var index = 0
            for length in 1...15 {
                value |= try bits(1)
                let count = code.counts[length]
                if value - first < count { return code.symbols[index + value - first] }
                index += count
                first = (first + count) << 1
                value <<= 1
            }
            throw .corrupt
        }

        mutating func codes(literals: Huffman, distances: Huffman) throws(Failure) {
            while true {
                let symbol = try decode(literals)
                if symbol < 256 {
                    output.append(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let lengthIndex = symbol - 257
                guard lengthIndex < lengthBase.count else { throw .corrupt }
                let length = lengthBase[lengthIndex] + (try bits(lengthExtraBits[lengthIndex]))
                let distanceIndex = try decode(distances)
                guard distanceIndex < distanceBase.count else { throw .corrupt }
                let distance = distanceBase[distanceIndex] + (try bits(distanceExtraBits[distanceIndex]))
                guard distance <= output.count else { throw .corrupt }
                let start = output.count - distance
                for offset in 0..<length { output.append(output[start + offset]) }
            }
        }

        mutating func dynamicTables() throws(Failure) -> (literals: Huffman, distances: Huffman) {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw .corrupt }
            var codeLengthLengths = [Int](repeating: 0, count: 19)
            for index in 0..<codeLengthCount { codeLengthLengths[codeLengthOrder[index]] = try bits(3) }
            let codeLengths = try Huffman(lengths: codeLengthLengths)

            var lengths: [Int] = []
            while lengths.count < literalCount + distanceCount {
                let symbol = try decode(codeLengths)
                switch symbol {
                case 0..<16: lengths.append(symbol)
                case 16:
                    guard let previous = lengths.last else { throw .corrupt }
                    lengths += repeatElement(previous, count: 3 + (try bits(2)))
                case 17: lengths += repeatElement(0, count: 3 + (try bits(3)))
                default: lengths += repeatElement(0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else { throw .corrupt }
            return (try Huffman(lengths: Array(lengths[..<literalCount])), try Huffman(lengths: Array(lengths[literalCount...])))
        }
    }
}
