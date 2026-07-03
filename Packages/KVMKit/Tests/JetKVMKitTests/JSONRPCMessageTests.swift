import XCTest
@testable import JetKVMKit

final class JSONRPCMessageTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Request encoding

    func testEncodeRequestWithParams() throws {
        struct Params: Encodable, Sendable { let factor: Double }
        let req = JSONRPCRequest(
            method: "setStreamQualityFactor",
            params: Params(factor: 0.8),
            id: 42
        )
        let json = String(data: try encoder.encode(req), encoding: .utf8)
        XCTAssertEqual(
            json,
            #"{"id":42,"jsonrpc":"2.0","method":"setStreamQualityFactor","params":{"factor":0.8}}"#
        )
    }

    func testEncodeRequestWithEmptyParams() throws {
        let req = JSONRPCRequest(method: "getDeviceID", params: EmptyParams(), id: 1)
        let json = String(data: try encoder.encode(req), encoding: .utf8)
        XCTAssertEqual(
            json,
            #"{"id":1,"jsonrpc":"2.0","method":"getDeviceID","params":{}}"#
        )
    }

    // MARK: - VoidValue

    func testVoidValueDecodesFromNull() throws {
        struct Wrapped: Decodable { let result: VoidValue }
        let json = #"{"result":null}"#.data(using: .utf8)!
        XCTAssertNoThrow(try decoder.decode(Wrapped.self, from: json))
    }

    func testVoidValueDecodesFromArbitraryShape() throws {
        // VoidValue should accept anything — null, object, number, …
        struct Wrapped: Decodable { let result: VoidValue }
        for fragment in [#""ok""#, "42", "{}", "[1,2,3]"] {
            let json = #"{"result":\#(fragment)}"#.data(using: .utf8)!
            XCTAssertNoThrow(try decoder.decode(Wrapped.self, from: json), "fragment=\(fragment)")
        }
    }

    // MARK: - Error object

    func testDecodeErrorObject() throws {
        let json = #"{"code":-32601,"message":"Method not found"}"#.data(using: .utf8)!
        let err = try decoder.decode(JSONRPCErrorObject.self, from: json)
        XCTAssertEqual(err, JSONRPCErrorObject(code: -32601, message: "Method not found"))
    }

    // MARK: - Notification params decoding

    func testNotificationDecodesTypedParams() throws {
        struct OTAState: Decodable, Equatable { let progress: Double; let phase: String }
        let payload = #"{"progress":0.5,"phase":"download"}"#.data(using: .utf8)!
        let notif = JSONRPCNotification(method: "otaState", paramsData: payload)
        let parsed = try notif.decodeParams(OTAState.self)
        XCTAssertEqual(parsed, OTAState(progress: 0.5, phase: "download"))
    }

    func testNotificationDecodeWithoutParamsThrows() {
        let notif = JSONRPCNotification(method: "otherSessionConnected", paramsData: nil)
        struct AnyParams: Decodable {}
        XCTAssertThrowsError(try notif.decodeParams(AnyParams.self))
    }
}
