import XCTest
@testable import JetKVMTransport

final class VeNCryptTests: XCTestCase {
    func testInnerAuthMapping() {
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.x509Plain), .plain)
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.tlsPlain), .plain)
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.x509Vnc), .vnc)
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.tlsVnc), .vnc)
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.x509None), RFBProtocol.VeNCrypt.InnerAuth.none)
        XCTAssertEqual(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.tlsNone), RFBProtocol.VeNCrypt.InnerAuth.none)
        // Unencrypted Plain (256) is not an accepted inner auth here.
        XCTAssertNil(RFBProtocol.VeNCrypt.innerAuth(for: RFBProtocol.VeNCrypt.plain))
    }

    func testPreferredSubtypesWithCredentials() {
        // Username + password → Plain first, then Vnc, then None; X509 before
        // anonymous TLS within each; never the unencrypted `plain` (256).
        let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: true, hasPassword: true)
        XCTAssertEqual(prefs, [262, 259, 261, 258, 260, 257])
        XCTAssertFalse(prefs.contains(256))
    }

    func testPreferredSubtypesUsernameNoPassword() {
        // PiKVM's first connect: a username is set but no password is stored
        // yet. Plain must still be offered (password is prompted afterward), so
        // a Plain-only server matches.
        let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: true, hasPassword: false)
        XCTAssertEqual(prefs, [262, 259, 260, 257]) // Plain (via username) + None; no Vnc
        // PiKVM offers [256, 262, 259]; we pick x509Plain.
        let offered: Set<UInt32> = [256, 262, 259]
        XCTAssertEqual(prefs.first(where: { offered.contains($0) }), 262)
    }

    func testPreferredSubtypesPasswordOnly() {
        let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: false, hasPassword: true)
        XCTAssertEqual(prefs, [261, 258, 260, 257]) // no Plain subtypes
    }

    func testPreferredSubtypesNoCredentials() {
        let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: false, hasPassword: false)
        XCTAssertEqual(prefs, [260, 257]) // None only
    }

    func testSubtypeSelectionAgainstServerOffer() {
        // Server offers X509None + X509Plain; with full creds we pick X509Plain.
        let prefs = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: true, hasPassword: true)
        let offered: Set<UInt32> = [260, 262]
        XCTAssertEqual(prefs.first(where: { offered.contains($0) }), 262)

        // Server offers only anonymous TLSVnc; password-only client picks it.
        let prefs2 = RFBProtocol.VeNCrypt.preferredSubtypes(hasUsername: false, hasPassword: true)
        XCTAssertEqual(prefs2.first(where: { [258].contains($0) }), 258)
    }

    func testPlainAuthMessageFormat() {
        // u32 user-length, u32 pass-length, then UTF-8 user + pass.
        let data = [UInt8](RFBProtocol.veNCryptPlainAuth(username: "ab", password: "xyz"))
        XCTAssertEqual(Array(data[0...3]), [0, 0, 0, 2])                 // user len 2
        XCTAssertEqual(Array(data[4...7]), [0, 0, 0, 3])                 // pass len 3
        XCTAssertEqual(Array(data[8...9]), Array("ab".utf8))
        XCTAssertEqual(Array(data[10...12]), Array("xyz".utf8))
    }

    func testSecurityTypeValue() {
        XCTAssertEqual(RFBProtocol.SecurityType.veNCrypt.rawValue, 19)
    }
}
