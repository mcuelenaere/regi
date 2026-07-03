import XCTest
@testable import PiKVMKit

final class JanusMessageTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCreateOmitsSessionId() throws {
        let o = try json(JanusMessage.create(transaction: "t1"))
        XCTAssertEqual(o["janus"] as? String, "create")
        XCTAssertEqual(o["transaction"] as? String, "t1")
        XCTAssertNil(o["session_id"], "create carries no session_id")
    }

    func testAttachUsesUStreamerPlugin() throws {
        let o = try json(JanusMessage.attach(sessionId: 42, transaction: "t2"))
        XCTAssertEqual(o["janus"] as? String, "attach")
        XCTAssertEqual(o["plugin"] as? String, "janus.plugin.ustreamer")
        XCTAssertEqual(o["session_id"] as? UInt64, 42)
    }

    func testWatchBody() throws {
        let o = try json(JanusMessage.watch(sessionId: 1, handleId: 2, transaction: "t3", audio: false))
        XCTAssertEqual(o["janus"] as? String, "message")
        XCTAssertEqual(o["session_id"] as? UInt64, 1)
        XCTAssertEqual(o["handle_id"] as? UInt64, 2)
        let body = try XCTUnwrap(o["body"] as? [String: Any])
        XCTAssertEqual(body["request"] as? String, "watch")
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        XCTAssertEqual(params["audio"] as? Bool, false)
    }

    func testStartAnswerCarriesJSEP() throws {
        let o = try json(JanusMessage.startAnswer(sessionId: 1, handleId: 2, transaction: "t4", answerSDP: "v=0\r\n"))
        let body = try XCTUnwrap(o["body"] as? [String: Any])
        XCTAssertEqual(body["request"] as? String, "start")
        let jsep = try XCTUnwrap(o["jsep"] as? [String: Any])
        XCTAssertEqual(jsep["type"] as? String, "answer")
        XCTAssertEqual(jsep["sdp"] as? String, "v=0\r\n")
    }

    func testTrickleCandidate() throws {
        let cand = JanusCandidate(candidate: "candidate:1 1 udp", sdpMid: "0", sdpMLineIndex: 0)
        let o = try json(JanusMessage.trickle(sessionId: 1, handleId: 2, transaction: "t5", candidate: cand))
        XCTAssertEqual(o["janus"] as? String, "trickle")
        let c = try XCTUnwrap(o["candidate"] as? [String: Any])
        XCTAssertEqual(c["candidate"] as? String, "candidate:1 1 udp")
        XCTAssertEqual(c["sdpMid"] as? String, "0")
        XCTAssertEqual(c["sdpMLineIndex"] as? Int, 0)
        XCTAssertNil(c["completed"])
    }

    func testTrickleCompletedSentinel() throws {
        let o = try json(JanusMessage.trickle(sessionId: 1, handleId: 2, transaction: "t6", candidate: .completedSentinel))
        let c = try XCTUnwrap(o["candidate"] as? [String: Any])
        XCTAssertEqual(c["completed"] as? Bool, true)
        XCTAssertNil(c["candidate"])
    }

    func testKeepaliveOmitsHandle() throws {
        let o = try json(JanusMessage.keepalive(sessionId: 7, transaction: "t7"))
        XCTAssertEqual(o["janus"] as? String, "keepalive")
        XCTAssertEqual(o["session_id"] as? UInt64, 7)
        XCTAssertNil(o["handle_id"])
    }

    // MARK: - Inbound

    func testDecodeSuccessWithId() throws {
        let data = Data(#"{"janus":"success","transaction":"t","data":{"id":99}}"#.utf8)
        let msg = try JanusIncoming.decode(data)
        XCTAssertEqual(msg.janus, "success")
        XCTAssertEqual(msg.data?.id, 99)
    }

    func testDecodeEventWithJSEPOffer() throws {
        let data = Data(#"""
        {"janus":"event","sender":5,"plugindata":{"plugin":"janus.plugin.ustreamer","data":{}},"jsep":{"type":"offer","sdp":"v=0"}}
        """#.utf8)
        let msg = try JanusIncoming.decode(data)
        XCTAssertEqual(msg.janus, "event")
        XCTAssertEqual(msg.sender, 5)
        XCTAssertEqual(msg.jsep?.type, "offer")
        XCTAssertEqual(msg.jsep?.sdp, "v=0")
        XCTAssertEqual(msg.plugindata?.plugin, "janus.plugin.ustreamer")
    }

    func testDecodeError() throws {
        let data = Data(#"{"janus":"error","transaction":"t","error":{"code":458,"reason":"No such session"}}"#.utf8)
        let msg = try JanusIncoming.decode(data)
        XCTAssertEqual(msg.janus, "error")
        XCTAssertEqual(msg.error?.code, 458)
        XCTAssertEqual(msg.error?.reason, "No such session")
    }

    func testDecodeAck() throws {
        let msg = try JanusIncoming.decode(Data(#"{"janus":"ack","transaction":"t"}"#.utf8))
        XCTAssertEqual(msg.janus, "ack")
        XCTAssertNil(msg.jsep)
    }

    func testDecodeInboundTrickleCandidate() throws {
        let data = Data(#"{"janus":"trickle","sender":5,"candidate":{"candidate":"candidate:1 1 udp 2122 1.2.3.4 5000 typ host","sdpMid":"0","sdpMLineIndex":0}}"#.utf8)
        let msg = try JanusIncoming.decode(data)
        XCTAssertEqual(msg.janus, "trickle")
        XCTAssertEqual(msg.candidate?.candidate, "candidate:1 1 udp 2122 1.2.3.4 5000 typ host")
        XCTAssertEqual(msg.candidate?.sdpMid, "0")
        XCTAssertEqual(msg.candidate?.sdpMLineIndex, 0)
        XCTAssertNil(msg.candidate?.completed)
    }

    func testDecodeInboundTrickleCompleted() throws {
        let msg = try JanusIncoming.decode(Data(#"{"janus":"trickle","candidate":{"completed":true}}"#.utf8))
        XCTAssertEqual(msg.candidate?.completed, true)
        XCTAssertNil(msg.candidate?.candidate)
    }
}
