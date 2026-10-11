import XCTest
@testable import JetKVMKit

final class TakeoverPeerMetricsParserTests: XCTestCase {
    func testSelectsNewestSessionRequestAcrossSources() throws {
        let metrics = #"""
        # HELP jetkvm_connection_last_session_request_timestamp_seconds The timestamp of the last session request
        jetkvm_connection_last_session_request_timestamp_seconds{source="192.168.1.10",type="local"} 1760000000
        jetkvm_connection_last_session_request_timestamp_seconds{source="192.168.1.42",type="local"} 1760000012
        jetkvm_connection_last_session_request_timestamp_seconds{source="cloud.jetkvm.com",type="cloud"} 1759999999
        """#.data(using: .utf8)!

        let peer = try XCTUnwrap(TakeoverPeerMetricsParser.latestPeer(in: metrics))
        XCTAssertEqual(peer.sourceType, "local")
        XCTAssertEqual(peer.source, "192.168.1.42")
        XCTAssertEqual(peer.requestTimestamp, 1_760_000_012)
    }

    func testSupportsLegacyMetricNameAndReorderedLabels() throws {
        let metrics = #"""
        jetkvm_connection_last_session_request_timestamp{type="local",source="2001:db8::42"} 1740000000
        """#.data(using: .utf8)!

        let peer = try XCTUnwrap(TakeoverPeerMetricsParser.latestPeer(in: metrics))
        XCTAssertEqual(peer.sourceType, "local")
        XCTAssertEqual(peer.source, "2001:db8::42")
    }

    func testDecodesPrometheusLabelEscapes() throws {
        let metrics = #"""
        jetkvm_connection_last_session_request_timestamp_seconds{source="peer\\\"name",type="future"} 42
        """#.data(using: .utf8)!

        let peer = try XCTUnwrap(TakeoverPeerMetricsParser.latestPeer(in: metrics))
        XCTAssertEqual(peer.source, #"peer\"name"#)
        XCTAssertEqual(peer.sourceType, "future")
    }

    func testIgnoresResetAndMalformedSamples() {
        let metrics = #"""
        jetkvm_connection_last_session_request_timestamp_seconds{source="old",type="local"} -1
        jetkvm_connection_last_session_request_timestamp_seconds{source="missing-type"} 1760000000
        unrelated_metric{source="192.168.1.50",type="local"} 1760000001
        """#.data(using: .utf8)!

        XCTAssertNil(TakeoverPeerMetricsParser.latestPeer(in: metrics))
    }
}
