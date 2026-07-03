import XCTest
import CoreVideo
@testable import JetKVMTransport

/// Thread-safe collector for callbacks that fire on the decode task.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var presents = 0
    private(set) var sizes: [(Int, Int)] = []
    private(set) var errors: [String] = []
    private(set) var clipboard: [VNCInboundClipboard] = []
    private(set) var extKeyAcks = 0
    private(set) var lastFrame: LocalVideoFrame?

    func present(_ f: LocalVideoFrame) { lock.lock(); presents += 1; lastFrame = f; lock.unlock() }
    func size(_ w: Int, _ h: Int) { lock.lock(); sizes.append((w, h)); lock.unlock() }
    func error(_ m: String) { lock.lock(); errors.append(m); lock.unlock() }
    func clip(_ c: VNCInboundClipboard) { lock.lock(); clipboard.append(c); lock.unlock() }
    func extAck() { lock.lock(); extKeyAcks += 1; lock.unlock() }
}

final class VNCStreamEngineTests: XCTestCase {
    private func rawRect(x: Int, y: Int, w: Int, h: Int, bgra: [UInt8]) -> Data {
        var out = VNCByteWriter()
        out.writeU16(UInt16(x)); out.writeU16(UInt16(y)); out.writeU16(UInt16(w)); out.writeU16(UInt16(h))
        out.writeS32(RFBProtocol.Encoding.raw)
        out.writeBytes(bgra)
        return out.data
    }

    private func update(numRects: Int, body: Data) -> Data {
        var out = VNCByteWriter()
        out.writeU8(RFBProtocol.ServerMessage.framebufferUpdate.rawValue)
        out.writeU8(0)
        out.writeU16(UInt16(numRects & 0xFFFF))
        out.writeData(body)
        return out.data
    }

    /// Run the engine to completion (the scripted channel throws EOF once
    /// drained, which ends the loop). Returns the recorder and channel.
    private func runEngine(
        script: Data, width: Int, height: Int
    ) async -> (Recorder, ScriptedByteChannel) {
        let channel = ScriptedByteChannel(script)
        let presenter = VideoFramePresenter()
        let recorder = Recorder()
        presenter.onFrame = { recorder.present($0) }
        let engine = VNCStreamEngine(
            channel: channel, presenter: presenter,
            width: width, height: height, pixelFormat: .bgra32,
            stats: VNCStatsCollector())
        engine.onFrameSize = { recorder.size($0, $1) }
        engine.onError = { recorder.error($0) }
        engine.onClipboard = { recorder.clip($0) }
        engine.onExtKeyEventAck = { recorder.extAck() }
        await engine.run()
        return (recorder, channel)
    }

    func testSingleRawRectPresentsOnce() async throws {
        let pixels = [UInt8](repeating: 0, count: 2 * 2 * 4).enumerated().map { UInt8($0.offset & 0xFF) }
        let script = update(numRects: 1, body: rawRect(x: 0, y: 0, w: 2, h: 2, bgra: pixels))
        let (rec, channel) = await runEngine(script: script, width: 2, height: 2)
        XCTAssertEqual(rec.presents, 1, "exactly one present per complete update")

        // First request non-incremental; second (after the update) incremental.
        let sent = await channel.sent
        XCTAssertGreaterThanOrEqual(sent.count, 20) // two 10-byte requests
        XCTAssertEqual(sent[1], 0, "initial request is non-incremental")
        XCTAssertEqual(sent[11], 1, "post-update request is incremental")
    }

    func testMultipleRectsPresentOnce() async throws {
        let a = rawRect(x: 0, y: 0, w: 2, h: 1, bgra: [UInt8](repeating: 1, count: 2 * 1 * 4))
        let b = rawRect(x: 0, y: 1, w: 2, h: 1, bgra: [UInt8](repeating: 2, count: 2 * 1 * 4))
        let script = update(numRects: 2, body: a + b)
        let (rec, _) = await runEngine(script: script, width: 2, height: 2)
        XCTAssertEqual(rec.presents, 1, "two rects in one update → one present")
    }

    func testDesktopSizeResizesAndRequestsFull() async throws {
        var body = VNCByteWriter()
        body.writeU16(0); body.writeU16(0); body.writeU16(16); body.writeU16(12)
        body.writeS32(RFBProtocol.Encoding.desktopSize)
        let script = update(numRects: 1, body: body.data)
        let (rec, channel) = await runEngine(script: script, width: 8, height: 8)

        XCTAssertTrue(rec.sizes.contains { $0 == (16, 12) }, "onFrameSize reports new size")
        XCTAssertEqual(rec.presents, 1)
        // The post-resize request must be non-incremental (full repaint).
        let sent = await channel.sent
        XCTAssertEqual(sent[11], 0, "post-resize request is non-incremental")
    }

    func testDesktopSizeThenContentInSameUpdate() async throws {
        // A resize followed, in the same update, by a raw rect that only fits
        // the NEW size — proves rects after a mid-update resize see the new
        // dimensions.
        var ds = VNCByteWriter()
        ds.writeU16(0); ds.writeU16(0); ds.writeU16(4); ds.writeU16(4)
        ds.writeS32(RFBProtocol.Encoding.desktopSize)
        let raw = rawRect(x: 2, y: 2, w: 2, h: 2, bgra: [UInt8](repeating: 9, count: 2 * 2 * 4))
        let script = update(numRects: 2, body: ds.data + raw)
        let (rec, channel) = await runEngine(script: script, width: 2, height: 2)
        XCTAssertTrue(rec.sizes.contains { $0 == (4, 4) })
        XCTAssertEqual(rec.presents, 1)
        // After a resize the follow-up request must be non-incremental.
        let sent = await channel.sent
        XCTAssertEqual(sent[11], 0)
    }

    func testOpenEndedWithLastRect() async throws {
        var lastRect = VNCByteWriter()
        lastRect.writeU16(0); lastRect.writeU16(0); lastRect.writeU16(0); lastRect.writeU16(0)
        lastRect.writeS32(RFBProtocol.Encoding.lastRect)
        let raw = rawRect(x: 0, y: 0, w: 2, h: 2, bgra: [UInt8](repeating: 5, count: 16))
        let script = update(numRects: 0xFFFF, body: raw + lastRect.data)
        let (rec, _) = await runEngine(script: script, width: 2, height: 2)
        XCTAssertEqual(rec.presents, 1)
    }

    func testUnknownEncodingErrorsWithoutPresent() async throws {
        var body = VNCByteWriter()
        body.writeU16(0); body.writeU16(0); body.writeU16(2); body.writeU16(2)
        body.writeS32(999) // unknown
        let script = update(numRects: 1, body: body.data)
        let (rec, _) = await runEngine(script: script, width: 2, height: 2)
        XCTAssertEqual(rec.presents, 0)
        XCTAssertTrue(rec.errors.contains { $0.contains("unsupported encoding") })
    }

    func testQEMUExtendedKeyAckPseudoRect() async throws {
        var body = VNCByteWriter()
        body.writeU16(0); body.writeU16(0); body.writeU16(0); body.writeU16(0)
        body.writeS32(RFBProtocol.Encoding.qemuExtendedKeyEvent)
        let script = update(numRects: 1, body: body.data)
        let (rec, _) = await runEngine(script: script, width: 4, height: 4)
        XCTAssertEqual(rec.extKeyAcks, 1)
        XCTAssertEqual(rec.presents, 0, "pseudo-rect only → nothing to present")
    }

    func testServerCutTextClassic() async throws {
        var msg = VNCByteWriter()
        msg.writeU8(RFBProtocol.ServerMessage.serverCutText.rawValue)
        msg.writeBytes([0, 0, 0])
        let text = Array("hello".utf8)
        msg.writeU32(UInt32(text.count))
        msg.writeBytes(text)
        let (rec, _) = await runEngine(script: msg.data, width: 4, height: 4)
        XCTAssertEqual(rec.clipboard.count, 1)
        if case .classicText(let s) = rec.clipboard.first {
            XCTAssertEqual(s, "hello")
        } else {
            XCTFail("expected classic text")
        }
    }

    func testServerCutTextExtremeNegativeLengthDoesNotTrap() async throws {
        // A hostile ServerCutText with length == Int32.min must not trap on
        // negation (regression: `-Int32.min` overflows Int32).
        var msg = VNCByteWriter()
        msg.writeU8(RFBProtocol.ServerMessage.serverCutText.rawValue)
        msg.writeBytes([0, 0, 0])
        msg.writeS32(Int32.min)
        // No body follows; the engine will try to read the (capped) length and
        // hit EOF — which must surface as a clean error, not a crash.
        let (rec, _) = await runEngine(script: msg.data, width: 4, height: 4)
        XCTAssertTrue(rec.clipboard.isEmpty)
        // Reaching here at all means no arithmetic-overflow trap occurred.
    }

    func testBellIsIgnored() async throws {
        var msg = VNCByteWriter()
        msg.writeU8(RFBProtocol.ServerMessage.bell.rawValue)
        let (rec, _) = await runEngine(script: msg.data, width: 4, height: 4)
        XCTAssertEqual(rec.presents, 0)
        // No fatal error from the bell itself (EOF error afterward is fine).
        XCTAssertFalse(rec.errors.contains { $0.contains("unknown server message") })
    }
}
