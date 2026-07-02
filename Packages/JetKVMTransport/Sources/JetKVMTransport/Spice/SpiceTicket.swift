import Foundation
import Security

/// SPICE "ticket" authentication: the client encrypts the password with the
/// server's RSA public key (sent in `SpiceLinkReply.pub_key` as a DER
/// SubjectPublicKeyInfo) using RSA-OAEP with SHA-1, matching spice-gtk /
/// spice-server (`RSA_PKCS1_OAEP_PADDING`, default SHA-1 digest + MGF1).
enum SpiceTicket {
    enum Error: Swift.Error, Equatable {
        case passwordTooLong
        case malformedPublicKey
        case keyImportFailed(String)
        case encryptionFailed(String)
        case unexpectedCiphertextSize(Int)
    }

    /// Produce the 128-byte encrypted ticket for `password` against the
    /// server's DER SPKI public key.
    static func encrypt(password: String, derPublicKey: [UInt8]) throws -> [UInt8] {
        // Plaintext is the password bytes plus a terminating NUL, as the
        // SPICE server expects a C string. Capped at the protocol maximum.
        let pwBytes = Array(password.utf8)
        guard pwBytes.count <= SpiceProtocol.maxPasswordLength else {
            throw Error.passwordTooLong
        }
        var plaintext = pwBytes
        plaintext.append(0)

        let pkcs1 = try pkcs1PublicKey(fromSPKI: derPublicKey)

        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: NSNumber(value: SpiceProtocol.ticketKeyPairLengthBits),
        ]
        var cfErr: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attrs as CFDictionary, &cfErr) else {
            throw Error.keyImportFailed(Self.describe(cfErr))
        }

        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA1) else {
            throw Error.encryptionFailed("OAEP-SHA1 unsupported for imported key")
        }
        guard let cipher = SecKeyCreateEncryptedData(
            key, .rsaEncryptionOAEPSHA1, Data(plaintext) as CFData, &cfErr
        ) as Data? else {
            throw Error.encryptionFailed(Self.describe(cfErr))
        }

        let bytes = [UInt8](cipher)
        guard bytes.count == SpiceProtocol.ticketEncryptedBytes else {
            throw Error.unexpectedCiphertextSize(bytes.count)
        }
        return bytes
    }

    private static func describe(_ err: Unmanaged<CFError>?) -> String {
        guard let err else { return "unknown" }
        return (err.takeRetainedValue() as Swift.Error).localizedDescription
    }

    // MARK: - DER SubjectPublicKeyInfo → PKCS#1 RSAPublicKey

    /// Extract the inner PKCS#1 `RSAPublicKey` DER from an X.509
    /// SubjectPublicKeyInfo, which is what `SecKeyCreateWithData` expects for
    /// an RSA public key on macOS.
    ///
    /// SPKI ::= SEQUENCE { AlgorithmIdentifier SEQUENCE {...}, BIT STRING }
    /// The BIT STRING's contents (after the leading "unused bits" byte) are
    /// the RSAPublicKey DER.
    static func pkcs1PublicKey(fromSPKI der: [UInt8]) throws -> [UInt8] {
        var p = DERCursor(der)
        try p.expect(tag: 0x30)              // outer SEQUENCE
        _ = try p.readLength()               // outer length (rest of buffer)

        // AlgorithmIdentifier — skip the whole element.
        try p.expect(tag: 0x30)
        let algLen = try p.readLength()
        try p.skip(algLen)

        // subjectPublicKey BIT STRING.
        try p.expect(tag: 0x03)
        let bitLen = try p.readLength()
        guard bitLen >= 1 else { throw Error.malformedPublicKey }
        let unusedBits = try p.readByte()
        guard unusedBits == 0 else { throw Error.malformedPublicKey }
        let pkcs1 = try p.read(bitLen - 1)
        return pkcs1
    }

    /// Minimal DER TLV cursor (short + long-form lengths).
    private struct DERCursor {
        let bytes: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { bytes = b }

        mutating func readByte() throws -> UInt8 {
            guard i < bytes.count else { throw Error.malformedPublicKey }
            defer { i += 1 }
            return bytes[i]
        }
        mutating func expect(tag: UInt8) throws {
            guard try readByte() == tag else { throw Error.malformedPublicKey }
        }
        mutating func readLength() throws -> Int {
            let first = try readByte()
            if first & 0x80 == 0 { return Int(first) }
            let n = Int(first & 0x7F)
            guard n >= 1 && n <= 4 else { throw Error.malformedPublicKey }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(try readByte()) }
            return len
        }
        mutating func read(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= bytes.count else { throw Error.malformedPublicKey }
            defer { i += n }
            return Array(bytes[i..<(i + n)])
        }
        mutating func skip(_ n: Int) throws {
            guard n >= 0, i + n <= bytes.count else { throw Error.malformedPublicKey }
            i += n
        }
    }
}
