// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import JetKVMKit

final class VideoPauseSyncTests: XCTestCase {
    func testResendsOnlyWhenWantedStateMovedAndNothingInFlight() {
        // hide then show while the pause call was in flight: resume must follow
        XCTAssertTrue(VideoPauseSync.shouldResend(sent: true, desired: false, inFlight: false))
        XCTAssertFalse(VideoPauseSync.shouldResend(sent: true, desired: true, inFlight: false))
        XCTAssertFalse(VideoPauseSync.shouldResend(sent: true, desired: false, inFlight: true))
    }
}
