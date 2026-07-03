import XCTest
import CommonCrypto
@testable import VNCKit

final class VNCAuthTests: XCTestCase {
    func testReverseBits() {
        XCTAssertEqual(VNCAuth.reverseBits(0b0000_0001), 0b1000_0000)
        XCTAssertEqual(VNCAuth.reverseBits(0b0000_0010), 0b0100_0000)
        XCTAssertEqual(VNCAuth.reverseBits(0b1010_0000), 0b0000_0101)
        XCTAssertEqual(VNCAuth.reverseBits(0xFF), 0xFF)
        XCTAssertEqual(VNCAuth.reverseBits(0x00), 0x00)
    }

    func testKeyDerivationPadsAndTruncates() {
        // Short password is zero-padded to 8 bytes.
        let short = VNCAuth.desKey(from: "ab")
        XCTAssertEqual(short.count, 8)
        XCTAssertEqual(short[0], VNCAuth.reverseBits(UInt8(ascii: "a")))
        XCTAssertEqual(short[1], VNCAuth.reverseBits(UInt8(ascii: "b")))
        XCTAssertEqual(Array(short[2...]), [0, 0, 0, 0, 0, 0])

        // Long password is truncated to the first 8 bytes.
        let long = VNCAuth.desKey(from: "abcdefghij")
        XCTAssertEqual(long.count, 8)
        XCTAssertEqual(long, Array("abcdefgh".utf8).map(VNCAuth.reverseBits))
    }

    func testResponseIs16Bytes() {
        let challenge = Data((0..<16).map { UInt8($0) })
        let response = VNCAuth.response(challenge: challenge, password: "hunter2")
        XCTAssertEqual(response.count, 16)
    }

    /// The response is genuine DES-ECB: decrypting it with the same key
    /// recovers the challenge (independent CommonCrypto decrypt).
    func testResponseIsDESECBOfChallenge() {
        let challenge = Data((16..<32).map { UInt8($0) })
        let password = "swordfish"
        let response = VNCAuth.response(challenge: challenge, password: password)

        let key = VNCAuth.desKey(from: password)
        var decrypted = Data(count: response.count + kCCBlockSizeDES)
        var moved = 0
        let status = decrypted.withUnsafeMutableBytes { outPtr in
            response.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count, nil,
                            inPtr.baseAddress, response.count,
                            outPtr.baseAddress, outPtr.count, &moved)
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        decrypted.removeSubrange(moved..<decrypted.count)
        XCTAssertEqual(decrypted, challenge)
    }
}
