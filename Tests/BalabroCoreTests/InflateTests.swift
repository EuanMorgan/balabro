import BalabroCore
import Foundation
import Testing

/// The saves cover dynamic Huffman blocks. These streams come from Python's zlib, at level 0 for a stored block and
/// with `Z_FIXED` for a fixed Huffman block.
@Suite
struct InflateTests {
    @Test func storedBlock() throws {
        let stream: [UInt8] = [0x01, 0x0d, 0x00, 0xf2, 0xff, 0x42, 0x61, 0x6c, 0x61, 0x74, 0x72, 0x6f, 0x20, 0x73, 0x61, 0x76, 0x65, 0x73]
        #expect(try Inflate.raw(Data(stream)) == Data("Balatro saves".utf8))
    }

    @Test func fixedBlock() throws {
        let stream: [UInt8] = [0xf3, 0xca, 0xcc, 0x4d, 0xca, 0xd7, 0x51, 0xf0, 0x42, 0xa2, 0x14, 0x01]
        #expect(try Inflate.raw(Data(stream)) == Data("Jimbo, Jimbo, Jimbo!".utf8))
    }

    @Test func storedBlockCutShortIsTruncated() {
        let stream: [UInt8] = [0x01, 0x0d, 0x00, 0xf2, 0xff, 0x42, 0x61, 0x6c]
        #expect(throws: Inflate.Failure.truncated) { try Inflate.raw(Data(stream)) }
    }
}
