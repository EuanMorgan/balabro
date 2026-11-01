import BalabroCore
import Foundation
import Testing

/// The example vectors from FIPS 180-4's examples document (csrc.nist.gov, SHA256.pdf).
@Suite
struct SHA256Tests {
    @Test(arguments: [
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    ])
    func fipsExample(message: String, digest: String) {
        #expect(SHA256.hex(Data(message.utf8)) == digest)
    }
}
