import XCTest
import Security
@testable import JetKVMTransport

final class SpiceTicketTests: XCTestCase {

    /// End-to-end: generate an RSA-1024 keypair, present its public key as a
    /// DER SPKI (as a SPICE server would), encrypt a password with
    /// SpiceTicket, then decrypt with the private key and confirm we recover
    /// "password\0". Exercises SPKI parsing + RSA-OAEP-SHA1.
    func testTicketEncryptDecryptRoundTrip() throws {
        let (priv, pub) = try makeRSAKeyPair(bits: SpiceProtocol.ticketKeyPairLengthBits)

        var err: Unmanaged<CFError>?
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, &err) as Data?,
                                  "export public key")
        let spki = Self.wrapPKCS1AsSPKI([UInt8](pkcs1))
        XCTAssertEqual(spki.count, SpiceProtocol.ticketPubkeyBytes,
                       "1024-bit SPKI should be 162 bytes")

        let password = "hunter2"
        let ticket = try SpiceTicket.encrypt(password: password, derPublicKey: spki)
        XCTAssertEqual(ticket.count, SpiceProtocol.ticketEncryptedBytes)

        let plain = try XCTUnwrap(SecKeyCreateDecryptedData(
            priv, .rsaEncryptionOAEPSHA1, Data(ticket) as CFData, &err) as Data?,
            "decrypt ticket")
        var expected = Array(password.utf8); expected.append(0)
        XCTAssertEqual([UInt8](plain), expected)
    }

    func testSPKIParseExtractsPKCS1() throws {
        let (_, pub) = try makeRSAKeyPair(bits: SpiceProtocol.ticketKeyPairLengthBits)
        var err: Unmanaged<CFError>?
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, &err) as Data?)
        let spki = Self.wrapPKCS1AsSPKI([UInt8](pkcs1))
        let extracted = try SpiceTicket.pkcs1PublicKey(fromSPKI: spki)
        XCTAssertEqual(extracted, [UInt8](pkcs1))
    }

    func testPasswordTooLongRejected() {
        let spki = [UInt8](repeating: 0, count: SpiceProtocol.ticketPubkeyBytes)
        XCTAssertThrowsError(
            try SpiceTicket.encrypt(password: String(repeating: "x", count: 61),
                                    derPublicKey: spki)
        ) { XCTAssertEqual($0 as? SpiceTicket.Error, .passwordTooLong) }
    }

    // MARK: - Helpers

    private func makeRSAKeyPair(bits: Int) throws -> (SecKey, SecKey) {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: NSNumber(value: bits),
        ]
        var err: Unmanaged<CFError>?
        let priv = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, &err),
                                 "generate key")
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv), "derive public key")
        return (priv, pub)
    }

    /// Wrap a PKCS#1 RSAPublicKey DER in an X.509 SubjectPublicKeyInfo
    /// (rsaEncryption AlgorithmIdentifier + BIT STRING), matching what a
    /// SPICE server sends. DER lengths are computed, not hardcoded.
    static func wrapPKCS1AsSPKI(_ pkcs1: [UInt8]) -> [UInt8] {
        // AlgorithmIdentifier: SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
        let algId: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        ]
        // BIT STRING { 0x00 unused-bits, pkcs1... }
        var bitStringContent: [UInt8] = [0x00]
        bitStringContent.append(contentsOf: pkcs1)
        var bitString: [UInt8] = [0x03]
        bitString.append(contentsOf: derLength(bitStringContent.count))
        bitString.append(contentsOf: bitStringContent)

        var body = algId
        body.append(contentsOf: bitString)
        var spki: [UInt8] = [0x30]
        spki.append(contentsOf: derLength(body.count))
        spki.append(contentsOf: body)
        return spki
    }

    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n <= 0xFF { return [0x81, UInt8(n)] }
        return [0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }
}
