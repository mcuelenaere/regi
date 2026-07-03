import XCTest
import CSpiceCodecs

/// Verifies the vendored SPICE codecs decode correctly through the C bridge.
///
/// The QUIC fixture below was produced by encoding a known 64×48 BGRX
/// gradient with spice-common's own `quic_encode` (QUIC is lossless for
/// RGB), so a correct decoder must reproduce the gradient exactly. This
/// exercises the full path: Swift → CSpiceCodecs → quic.c, the QuicUsrContext
/// callbacks, and the setjmp/longjmp error handling.
final class SpiceCodecTests: XCTestCase {

    // 64×48 gradient: B = x*4, G = y*5, R = (x+y)*2.
    private static let quicGradientVectorBase64 = "UVVJQwAAAAAEAAAAQAAAADAAAAAMgICAzogJAzjjjDPjjDPOjDPOODPOOOPOOOOMOOOMM+OMM86MM844M844484444w444wz44wzzowzzjgzzjjjzjjjjDjjjDPjjDPOjDPOOAjOOOMshswAzM6EhuzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuycVczOmZ3ZWdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndk4q5idMzuzs7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7NxVjE7Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmbirGJ2zuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzFWcXsndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZmLs4rZO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szMWZxWzdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2Zmcszipm7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM5ZnFXM2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2zOKuYszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMztncVYxZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3bO4qxizM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuydxVnFmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndk7i7OKMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7N2FmcVZ3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmbsLM4qzuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzZWZxVndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZid2ZmzszirO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzE7szNmZ3FWdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmJ2ZmfMzuKs7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7MXszM6ZncVZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2YrZmZ0zO4uzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7sxWzMztndhZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZipmZ3bO7CzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szFXMzuyd2VmcmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmauYndk7s7M4MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7M7s3NwMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7M7s3NwMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7M7s3NwMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7M7s3NwMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7M7s3NwMzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM1YxO7N2ZmdxZ3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ6xidmbszM7izuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzlnF7MzZmZ3FndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnbOK2ZmzMzuLO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzO2cVszNmZ3YWdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZnds4qZmfMzuws7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7JxVzM6ZndlZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2TirmJ0zO7OzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7s3FWMTtndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZuKsYnbO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szOzMzuzO7MzOzM7szMVZxeyd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmdmZndmd2ZmdmZ3ZmYuzitk7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzM7MzO7M7szM7MzuzMxZnFbN2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZ2ZndmZ2Zmd2Z3ZmZyzOKmbszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzszO7MzszM7szuzMzlmcVczZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnZmd2ZnZmZ3ZndmZnQAAAIAAAAAA"

    func testQuicDecodeGradient() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.quicGradientVectorBase64))

        var out: UnsafeMutablePointer<UInt8>? = nil
        var w: UInt32 = 0
        var h: UInt32 = 0
        let rc = data.withUnsafeBytes { buf -> Int32 in
            regi_quic_decode_bgra(buf.bindMemory(to: UInt8.self).baseAddress, buf.count, &out, &w, &h)
        }
        XCTAssertEqual(rc, 0, "decode should succeed")
        let pixels = try XCTUnwrap(out)
        defer { regi_free(pixels) }
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 48)

        // Spot-check pixels against the known gradient (BGRA byte order).
        func check(_ x: Int, _ y: Int) {
            let i = (y * Int(w) + x) * 4
            XCTAssertEqual(pixels[i + 0], UInt8(truncatingIfNeeded: x * 4), "B @ (\(x),\(y))")
            XCTAssertEqual(pixels[i + 1], UInt8(truncatingIfNeeded: y * 5), "G @ (\(x),\(y))")
            XCTAssertEqual(pixels[i + 2], UInt8(truncatingIfNeeded: (x + y) * 2), "R @ (\(x),\(y))")
            XCTAssertEqual(pixels[i + 3], 0xFF, "A @ (\(x),\(y))")
        }
        check(0, 0); check(63, 0); check(0, 47); check(63, 47); check(31, 23); check(17, 5)
    }

    func testQuicDecodeRejectsGarbage() {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var w: UInt32 = 0, h: UInt32 = 0
        let junk: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]
        let rc = junk.withUnsafeBytes { buf in
            regi_quic_decode_bgra(buf.bindMemory(to: UInt8.self).baseAddress, buf.count, &out, &w, &h)
        }
        XCTAssertNotEqual(rc, 0, "garbage input must fail gracefully, not crash")
    }

    func testGlzWindowLifecycle() {
        let win = regi_glz_window_new()
        XCTAssertNotNil(win)
        regi_glz_window_reset(win)
        regi_glz_window_free(win)
    }
}
