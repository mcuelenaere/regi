import XCTest
@testable import JetKVMTransport

final class SpiceLinkTests: XCTestCase {

    func testLinkHeaderRoundTrip() throws {
        let h = SpiceLinkHeader(major: 2, minor: 2, size: 42)
        let data = h.encode()
        XCTAssertEqual(data.count, SpiceLinkHeader.byteCount)
        XCTAssertEqual([UInt8](data.prefix(4)), Array("REDQ".utf8))

        let parsed = try SpiceLinkHeader.parse(data)
        XCTAssertEqual(parsed.major, 2)
        XCTAssertEqual(parsed.minor, 2)
        XCTAssertEqual(parsed.size, 42)
    }

    func testLinkHeaderRejectsBadMagic() {
        var bytes = [UInt8](SpiceLinkHeader(major: 2, minor: 2, size: 0).encode())
        bytes[0] = 0x00
        XCTAssertThrowsError(try SpiceLinkHeader.parse(Data(bytes))) { err in
            XCTAssertEqual(err as? SpiceLinkHeader.Error, .badMagic)
        }
    }

    func testClientMessageLayout() throws {
        let msg = SpiceLinkClientMessage(
            connectionID: 0,
            channelType: .main,
            channelID: 0,
            commonCaps: SpiceCaps(bits: [
                SpiceProtocol.CommonCap.protocolAuthSelection.rawValue,
                SpiceProtocol.CommonCap.authSpice.rawValue,
                SpiceProtocol.CommonCap.miniHeader.rawValue,
            ]),
            channelCaps: SpiceCaps()
        )
        let data = msg.encode()

        // header(16) + mess(18) + 1 common-caps word(4) + 0 channel-caps
        XCTAssertEqual(data.count, 16 + 18 + 4)

        // Parse back the header and confirm the declared body size.
        let header = try SpiceLinkHeader.parse(data.prefix(16))
        XCTAssertEqual(Int(header.size), 18 + 4)

        // Inspect the mess fields.
        var r = SpiceByteReader(data.suffix(from: 16))
        XCTAssertEqual(try r.readU32(), 0)          // connection_id
        XCTAssertEqual(try r.readU8(), 1)           // channel_type = main
        XCTAssertEqual(try r.readU8(), 0)           // channel_id
        XCTAssertEqual(try r.readU32(), 1)          // num_common_caps words
        XCTAssertEqual(try r.readU32(), 0)          // num_channel_caps words
        XCTAssertEqual(try r.readU32(), 18)         // caps_offset
        XCTAssertEqual(try r.readU32(), 0b1011)     // bits 0,1,3 set
    }

    func testReplyParse() throws {
        // Build a synthetic reply body: error + 162-byte pubkey + caps.
        var w = SpiceByteWriter()
        w.writeU32(0)                                // error = OK
        let pub = (0..<SpiceProtocol.ticketPubkeyBytes).map { UInt8($0 & 0xFF) }
        w.writeBytes(pub)
        w.writeU32(1)                                // num_common_caps
        w.writeU32(1)                                // num_channel_caps
        let capsOffset = 4 + SpiceProtocol.ticketPubkeyBytes + 4 + 4 + 4
        w.writeU32(UInt32(capsOffset))               // caps_offset = 178
        w.writeU32(0b1000)                            // common caps: MINI_HEADER (bit 3)
        w.writeU32(0b0001)                            // channel caps: bit 0

        let reply = try SpiceLinkReply.parse(w.data)
        XCTAssertEqual(reply.error, 0)
        XCTAssertEqual(reply.pubKey, pub)
        XCTAssertTrue(reply.commonCaps.has(SpiceProtocol.CommonCap.miniHeader.rawValue))
        XCTAssertTrue(reply.channelCaps.has(0))
    }

    func testDataHeaderRoundTrip() throws {
        let h = SpiceDataHeader(serial: 7, type: 103, size: 256, subList: 0)
        let parsed = try SpiceDataHeader.parse(h.encode())
        XCTAssertEqual(parsed.serial, 7)
        XCTAssertEqual(parsed.type, 103)
        XCTAssertEqual(parsed.size, 256)
        XCTAssertEqual(SpiceDataHeader.byteCount, 18)
    }

    func testMiniDataHeaderRoundTrip() throws {
        let h = SpiceMiniDataHeader(type: 111, size: 64)
        let parsed = try SpiceMiniDataHeader.parse(h.encode())
        XCTAssertEqual(parsed.type, 111)
        XCTAssertEqual(parsed.size, 64)
        XCTAssertEqual(SpiceMiniDataHeader.byteCount, 6)
    }
}
