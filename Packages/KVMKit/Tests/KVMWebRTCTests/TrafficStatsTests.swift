// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
import KVMCore
@testable import KVMWebRTC

final class TrafficStatsTests: XCTestCase {
    private func stat(_ id: String, _ type: String, _ values: [String: Any]) -> (id: String, type: String, values: [String: NSObject]) {
        (id, type, values.mapValues { $0 as! NSObject })
    }

    func testSplitsByCategoryAndKeepsClosedChannels() {
        var parser = WebRTCStatsParser()
        let video = stat("IV", "inbound-rtp", ["kind": "video", "bytesReceived": 900, "headerBytesReceived": 100])
        let input = stat("D1", "data-channel", ["label": "hidrpc", "bytesSent": 50, "bytesReceived": 0])
        let file = stat("D2", "data-channel", ["label": "guestfile_7", "bytesSent": 4000, "bytesReceived": 10])

        let first = parser.traffic([
            video, input, file,
            stat("T", "transport", ["bytesReceived": 1200, "bytesSent": 4100]),
        ])
        XCTAssertEqual(first[.video], ByteCounts(received: 1000, sent: 0))
        XCTAssertEqual(first[.input], ByteCounts(received: 0, sent: 50))
        XCTAssertEqual(first[.clipboardAndFiles], ByteCounts(received: 10, sent: 4000))
        XCTAssertEqual(first[.other], ByteCounts(received: 190, sent: 50))

        // The file channel closed and dropped out of the report; its bytes stay.
        let second = parser.traffic([
            video, input,
            stat("T", "transport", ["bytesReceived": 1200, "bytesSent": 4100]),
        ])
        XCTAssertEqual(second[.clipboardAndFiles], ByteCounts(received: 10, sent: 4000))
        XCTAssertEqual(second.values.reduce(ByteCounts(), +), ByteCounts(received: 1200, sent: 4100))
    }

    func testChannelLabels() {
        XCTAssertEqual(WebRTCStatsParser.category(forDataChannel: "hidrpc-unreliable-ordered"), .input)
        XCTAssertEqual(WebRTCStatsParser.category(forDataChannel: "rpc"), .control)
        XCTAssertEqual(WebRTCStatsParser.category(forDataChannel: "host_bridge"), .clipboardAndFiles)
        XCTAssertEqual(WebRTCStatsParser.category(forDataChannel: "terminal"), .other)
    }

    func testRates() {
        let t = Date()
        func sample(_ at: TimeInterval, _ traffic: [TrafficCategory: ByteCounts]) -> ConnectionStats {
            ConnectionStats(timestamp: t.addingTimeInterval(at), roundTripTimeMs: nil, jitterMs: nil,
                            packetsReceived: 0, packetsLost: 0, connectionType: nil, framesPerSecond: 0,
                            codec: nil, freezeCount: 0, totalFreezesDurationSec: 0, decodeTimePerFrameMs: nil,
                            playbackDelayMs: nil, endToEndLatencyMs: nil, traffic: traffic)
        }
        let a = sample(0, [.video: ByteCounts(received: 1000, sent: 0)])
        let b = sample(2, [.video: ByteCounts(received: 3000, sent: 0), .input: ByteCounts(received: 0, sent: 250)])
        let rates = b.trafficRates(since: a)
        XCTAssertEqual(rates[.video]?.received, 8000)
        XCTAssertEqual(rates[.input]?.sent, 1000)

        // Side-channel bytes (PiKVM's WebSocket) add to a category,
        // existing or not, without touching the others.
        let merged = b.addingTraffic(ByteCounts(received: 40, sent: 60), to: .input)
            .addingTraffic(ByteCounts(received: 5), to: .control)
        XCTAssertEqual(merged.traffic[.input], ByteCounts(received: 40, sent: 310))
        XCTAssertEqual(merged.traffic[.control], ByteCounts(received: 5))
        XCTAssertEqual(merged.traffic[.video], b.traffic[.video])
    }
}
