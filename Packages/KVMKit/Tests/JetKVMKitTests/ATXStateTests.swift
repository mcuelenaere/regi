import XCTest
@testable import JetKVMKit

final class ATXStateTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testOlderFirmwareOmitsRespondingAndDefaultsToTrue() throws {
        let s = try decoder.decode(ATXState.self, from: Data(#"{"power":true,"hdd":false}"#.utf8))
        XCTAssertEqual(s, ATXState(power: true, hdd: false, responding: true))
    }

    func testNewFirmwareReportsResponding() throws {
        let s = try decoder.decode(ATXState.self, from: Data(#"{"power":false,"hdd":true,"responding":false}"#.utf8))
        XCTAssertEqual(s, ATXState(power: false, hdd: true, responding: false))
    }
}
