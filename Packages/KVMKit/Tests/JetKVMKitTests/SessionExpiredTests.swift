// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import KVMCore
@testable import JetKVMKit

/// JetKVM's idle sign-out (jetkvm/kvm#1788) shows up as WS close code 4003 or
/// a 401 with `code: "session_expired"`.
final class SessionExpiredTests: XCTestCase {
    private struct Boom: Error {}

    func testCloseCode4003IsSessionExpired() {
        guard case .sessionExpired = SignalingError.closed(code: 4003, error: Boom()) else {
            return XCTFail("4003 should classify as sessionExpired")
        }
    }

    func testOtherCloseCodesStayDisconnects() {
        // 4001 is takeover; 0 means no close frame (plain network drop).
        for code in [0, 1000, 4001] {
            guard case .disconnected = SignalingError.closed(code: code, error: Boom()) else {
                return XCTFail("\(code) should stay a plain disconnect")
            }
        }
    }

    func test401BodyWithSessionExpiredCode() {
        let body = Data(#"{"error":"Session expired","code":"session_expired"}"#.utf8)
        XCTAssertTrue(HTTPClient.isSessionExpired(body))
        XCTAssertFalse(HTTPClient.isSessionExpired(Data(#"{"error":"Invalid password"}"#.utf8)))
        XCTAssertFalse(HTTPClient.isSessionExpired(Data()))
        XCTAssertTrue(HTTPClientError.sessionExpired.isAuthFailure)
        XCTAssertTrue(HTTPClientError.unauthorized(message: nil).isAuthFailure)
        XCTAssertFalse(HTTPClientError.notFound.isAuthFailure)
    }
}
