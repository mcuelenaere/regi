import XCTest
@testable import JetKVMTransport

final class SpiceMessagesTests: XCTestCase {

    func testMainInitParse() throws {
        var w = SpiceByteWriter()
        w.writeU32(0xAABBCCDD)   // session_id
        w.writeU32(1)            // display_channels_hint
        w.writeU32(3)            // supported_mouse_modes (server|client)
        w.writeU32(2)            // current_mouse_mode (client)
        w.writeU32(0)            // agent_connected
        w.writeU32(10)           // agent_tokens
        w.writeU32(12345)        // multi_media_time
        w.writeU32(256)          // ram_hint

        let info = try SpiceMsgMainInit.parse(w.data)
        XCTAssertEqual(info.sessionID, 0xAABBCCDD)
        XCTAssertEqual(info.supportedMouseModes, 3)
        XCTAssertEqual(info.currentMouseMode, 2)
        XCTAssertEqual(info.ramHint, 256)
    }

    func testChannelsListParse() throws {
        var w = SpiceByteWriter()
        w.writeU32(3)                      // num channels
        w.writeU8(1); w.writeU8(0)         // main/0
        w.writeU8(2); w.writeU8(0)         // display/0
        w.writeU8(3); w.writeU8(0)         // inputs/0

        let list = try SpiceMsgChannelsList.parse(w.data)
        XCTAssertEqual(list.channels.count, 3)
        XCTAssertEqual(list.channels[1], SpiceChannelId(type: 2, id: 0))
    }

    func testMousePositionEncoding() {
        let d = SpiceByteWriter.mousePosition(x: 100, y: 200,
                                              buttons: SpiceMsg.ButtonMask.left, displayID: 0)
        XCTAssertEqual(d.count, 11)   // u32 + u32 + u16 + u8
        var r = SpiceByteReader(d)
        XCTAssertEqual(try? r.readU32(), 100)
        XCTAssertEqual(try? r.readU32(), 200)
        XCTAssertEqual(try? r.readU16(), 1)   // left button mask
        XCTAssertEqual(try? r.readU8(), 0)
    }

    func testMouseMotionEncoding() {
        let d = SpiceByteWriter.mouseMotion(dx: -5, dy: 7, buttons: 0)
        XCTAssertEqual(d.count, 10)   // i32 + i32 + u16
        var r = SpiceByteReader(d)
        XCTAssertEqual(try? r.readI32(), -5)
        XCTAssertEqual(try? r.readI32(), 7)
    }

    func testMouseButtonEncoding() {
        let d = SpiceByteWriter.mouseButton(.right, buttons: SpiceMsg.ButtonMask.right)
        XCTAssertEqual(d.count, 3)    // u8 + u16
        var r = SpiceByteReader(d)
        XCTAssertEqual(try? r.readU8(), SpiceMsg.MouseButton.right.rawValue)  // 3
        XCTAssertEqual(try? r.readU16(), 4)
    }

    func testMouseModeRequestEncoding() {
        let d = SpiceByteWriter.mouseModeRequest(.client)
        XCTAssertEqual(d.count, 2)
        var r = SpiceByteReader(d)
        XCTAssertEqual(try? r.readU16(), 2)   // CLIENT flag bit
    }

    func testOpcodeValues() {
        // Guard against accidental drift from spice.proto.
        XCTAssertEqual(SpiceMsg.Main.initMsg.rawValue, 103)
        XCTAssertEqual(SpiceMsg.Main.channelsList.rawValue, 104)
        XCTAssertEqual(SpiceMsg.MainClient.attachChannels.rawValue, 104)
        XCTAssertEqual(SpiceMsg.InputsClient.keyDown.rawValue, 101)
        XCTAssertEqual(SpiceMsg.InputsClient.mousePosition.rawValue, 112)
        XCTAssertEqual(SpiceMsg.Common.ping.rawValue, 4)
        XCTAssertEqual(SpiceMsg.CommonClient.pong.rawValue, 3)
    }
}
