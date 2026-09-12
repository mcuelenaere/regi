import Foundation
import SwiftProtobuf

/// Serializes a `TelemetryFrame` small enough to fit one QR code.
///
/// Container: `[1 B format][4 B BE uncompressed size][4 B BE CRC32][payload]`.
///
/// The size prefix is needed because `compression_decode_buffer` requires the
/// destination size up front, and the format byte lets a frame that compresses
/// badly (small ones do) ship raw rather than larger.
///
/// The CRC is not optional hygiene. LZFSE decodes a truncated payload back to
/// its full declared length whenever the missing tail was an end-of-stream
/// marker, so damage otherwise arrives looking valid — and a partly-repaired QR
/// read lands in the same place. Without this, a corrupt frame would be
/// asserted over as if it were evidence.
public enum FrameCodec {
    public enum Format: UInt8 { case rawProtobuf = 0x00, lzfseProtobuf = 0x01 }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case truncated
        case checksumMismatch(expected: UInt32, actual: UInt32)
        case unknownFormat(UInt8)
        case decompressionFailed
        case malformed(String)
        case unsupportedWireVersion(UInt32)

        public var description: String {
            switch self {
            case .truncated:                    return "telemetry payload truncated"
            case .checksumMismatch(let e, let a):
                return String(format: "telemetry checksum mismatch (expected %08X, got %08X)", e, a)
            case .unknownFormat(let b):         return String(format: "unknown container format 0x%02X", b)
            case .decompressionFailed:          return "LZFSE decompression failed"
            case .malformed(let m):             return "malformed frame: \(m)"
            case .unsupportedWireVersion(let v): return "wire version \(v), this build speaks \(WireVersion.current)"
            }
        }
    }

    // MARK: - Encode

    /// Byte budget for one rendered code.
    ///
    /// Exceeding it makes `CIQRCodeGenerator` silently pick a higher QR version
    /// — more modules, smaller modules at the same band size, and the decode
    /// loop breaks with no error anywhere. So the frame is capped instead, and
    /// the **window shrinks rather than the symbol growing**.
    ///
    /// 1,273 B is the capacity of a version-40 symbol at EC level H, which the
    /// step 0 spike verified end to end through the real rig: 240/240 reads,
    /// byte-for-byte, at 5.56 captured px/module from a 640-pt band. Level H is
    /// the strongest error correction, which is what a compressed video path
    /// wants.
    ///
    /// At the measured density (see DensityTests: 6.7 B/event for keyboard
    /// traffic, 9.6 for a mixed stream) that window self-sizes to roughly
    /// 130-190 events — comfortably above the largest catalogue scenario, the
    /// 160-event burst-ordering test, which is pure keyboard traffic.
    ///
    /// If a future scenario needs a larger window, the lever is **sharding**:
    /// a 2x2 grid of level-H codes carries ~5 KB at twice the band width.
    /// Prefer that over dropping to a weaker EC level.
    public static let defaultMaxBytes = 1273

    /// Encode, dropping oldest events until the result fits `maxBytes`.
    ///
    /// Returns the frame actually encoded alongside the bytes: it carries the
    /// surviving `events` and an `oldestSeqInWindow` raised to match, which is
    /// what lets the driver detect that evidence fell out of the window and
    /// fail the run rather than silently assert over a partial record.
    public static func encodeCapped(
        _ frame: TelemetryFrame, maxBytes: Int = defaultMaxBytes
    ) throws -> (data: Data, encoded: TelemetryFrame) {
        var trimmed = frame
        while true {
            let data = try encode(trimmed)
            if data.count <= maxBytes || trimmed.events.isEmpty {
                return (data, trimmed)
            }
            // Drop ~10% of the oldest events per pass; a linear walk would be
            // O(n) encodes on a large overflow.
            let drop = max(1, trimmed.events.count / 10)
            trimmed.events.removeFirst(drop)
            trimmed.oldestSeqInWindow = trimmed.events.first?.seq ?? frame.oldestSeqInWindow
        }
    }

    public static func encode(_ frame: TelemetryFrame) throws -> Data {
        let proto = try makeProto(frame)
        let body = try proto.serializedData()

        var out = Data(capacity: body.count + headerSize)
        let crc = CRC32.compute(body)
        if let z = Compressor.compress(body), z.count < body.count {
            out.append(Format.lzfseProtobuf.rawValue)
            out.append(contentsOf: beBytes(UInt32(body.count)))
            out.append(contentsOf: beBytes(crc))
            out.append(z)
        } else {
            out.append(Format.rawProtobuf.rawValue)
            out.append(contentsOf: beBytes(UInt32(body.count)))
            out.append(contentsOf: beBytes(crc))
            out.append(body)
        }
        return out
    }

    private static func makeProto(_ frame: TelemetryFrame) throws -> Regiprobe_Telemetry_V1_Frame {
        var f = Regiprobe_Telemetry_V1_Frame()
        f.wireVersion = frame.wireVersion
        f.epoch = frame.epoch
        f.frameIndex = frame.frameIndex
        f.probeMonotonicNanos = frame.probeMonotonicNanos
        f.oldestSeqInWindow = frame.oldestSeqInWindow
        f.heldKeys = frame.heldKeys.map(UInt32.init)

        var health = Regiprobe_Telemetry_V1_Health()
        health.tapEnabled = frame.health.tapEnabled
        health.runActive = frame.health.runActive
        health.accessibilityGranted = frame.health.accessibilityGranted
        health.secureInputHolder = frame.health.secureInputHolder
        f.health = health

        var c = Regiprobe_Telemetry_V1_Counters()
        c.upWithoutDown = frame.counters.upWithoutDown
        c.duplicateDown = frame.counters.duplicateDown
        c.stuckAtEnd = frame.counters.stuckAtEnd
        c.nonMonotonicTimestamp = frame.counters.nonMonotonicTimestamp
        c.syntheticSourceEvents = frame.counters.syntheticSourceEvents
        c.droppedByRing = frame.counters.droppedByRing
        f.counters = c

        if let s = frame.screen {
            var si = Regiprobe_Telemetry_V1_ScreenInfo()
            si.originX = s.originX; si.originY = s.originY
            si.width = s.width; si.height = s.height; si.backingScale = s.backingScale
            f.screen = si
        }

        guard let first = frame.events.first else { return f }
        f.baseSeq = first.seq
        f.baseTMicros = first.machAbsoluteNanos / 1000

        // Delta-encode. proto3 omits zero-valued fields entirely, so the common
        // case — a contiguous run of events with unchanged modifier flags —
        // costs nothing for seq or flags. That is what makes ~200 events fit.
        var prevSeq = first.seq
        var prevMicros = f.baseTMicros
        var prevRawFlags: UInt64? = nil
        var prevPoint = (x: Int32(0), y: Int32(0))

        for (i, e) in frame.events.enumerated() {
            var pe = Regiprobe_Telemetry_V1_Event()
            if i > 0 {
                let gap = e.seq >= prevSeq ? e.seq - prevSeq : 0
                pe.seqDeltaMinusOne = UInt32(clamping: gap == 0 ? 0 : gap - 1)
                let micros = e.machAbsoluteNanos / 1000
                pe.tDeltaMicros = UInt32(clamping: micros >= prevMicros ? micros - prevMicros : 0)
                prevSeq = e.seq
                prevMicros = micros
            }
            pe.payload = payloadProto(e.payload, prevRawFlags: &prevRawFlags, prevPoint: &prevPoint)
            f.events.append(pe)
        }
        return f
    }

    private static func payloadProto(
        _ payload: ProbeEvent.Payload, prevRawFlags: inout UInt64?,
        prevPoint: inout (x: Int32, y: Int32)
    ) -> Regiprobe_Telemetry_V1_Event.OneOf_Payload {
        switch payload {
        case .key(let k):
            var p = Regiprobe_Telemetry_V1_Key()
            p.kvk = UInt32(k.kvk); p.down = k.down; p.autorepeat = k.autorepeat
            p.characters = k.characters; p.sourcePid = k.sourcePID
            // Only carried when it changes — flags are identical across most
            // runs of events and this is the single largest per-event field.
            if prevRawFlags != k.rawFlags { p.rawFlags = k.rawFlags; prevRawFlags = k.rawFlags }
            return .key(p)
        case .flags(let fl):
            var p = Regiprobe_Telemetry_V1_Flags()
            p.kvk = UInt32(fl.kvk); p.rawFlags = fl.rawFlags
            prevRawFlags = fl.rawFlags
            return .flags(p)
        case .pointer(let pt):
            var p = Regiprobe_Telemetry_V1_Pointer()
            p.type = pt.type
            p.xDelta = pt.x &- prevPoint.x
            p.yDelta = pt.y &- prevPoint.y
            prevPoint = (pt.x, pt.y)
            p.deltaX = pt.deltaX; p.deltaY = pt.deltaY
            p.buttonNumber = pt.buttonNumber; p.clickState = pt.clickState
            p.sourcePid = pt.sourcePID
            return .pointer(p)
        case .wheel(let w):
            var p = Regiprobe_Telemetry_V1_Wheel()
            p.lineDeltaY = w.lineDeltaY; p.lineDeltaX = w.lineDeltaX
            p.pointDeltaY = w.pointDeltaY; p.pointDeltaX = w.pointDeltaX
            p.isContinuous = w.isContinuous; p.phase = w.phase; p.sourcePid = w.sourcePID
            return .wheel(p)
        case .gesture(let g):
            var p = Regiprobe_Telemetry_V1_Gesture()
            p.kind = g.kind.rawValue; p.value = g.value; p.secondary = g.secondary
            p.phase = g.phase; p.stage = g.stage
            return .gesture(p)
        case .touches(let ts):
            var p = Regiprobe_Telemetry_V1_Touches()
            p.touches = ts.map {
                var t = Regiprobe_Telemetry_V1_Touches.Touch()
                t.identity = $0.identity; t.normX = $0.normX; t.normY = $0.normY
                t.phase = $0.phase; t.type = $0.type
                return t
            }
            return .touches(p)
        case .diagnostic(let d):
            var p = Regiprobe_Telemetry_V1_Diagnostic()
            p.kind = d.kind.rawValue; p.detail = d.detail; p.value = d.value
            return .diagnostic(p)
        }
    }

    // MARK: - Decode

    static let headerSize = 9

    public static func decode(_ data: Data) throws -> TelemetryFrame {
        guard data.count >= headerSize else { throw Error.truncated }
        let bytes = [UInt8](data)
        guard let format = Format(rawValue: bytes[0]) else { throw Error.unknownFormat(bytes[0]) }
        let size = Int(beUInt32(bytes, 1))
        let expectedCRC = beUInt32(bytes, 5)
        let body = data.dropFirst(headerSize)

        let raw: Data
        switch format {
        case .rawProtobuf:
            guard body.count == size else { throw Error.truncated }
            raw = Data(body)
        case .lzfseProtobuf:
            guard let d = Compressor.decompress(Data(body), expectedSize: size) else {
                throw Error.decompressionFailed
            }
            raw = d
        }

        let actualCRC = CRC32.compute(raw)
        guard actualCRC == expectedCRC else {
            throw Error.checksumMismatch(expected: expectedCRC, actual: actualCRC)
        }
        let proto = try Regiprobe_Telemetry_V1_Frame(serializedBytes: raw)

        guard proto.wireVersion == WireVersion.current else {
            throw Error.unsupportedWireVersion(proto.wireVersion)
        }
        return try makeFrame(proto)
    }

    private static func makeFrame(_ p: Regiprobe_Telemetry_V1_Frame) throws -> TelemetryFrame {
        var counters = InvariantCounters()
        counters.upWithoutDown = p.counters.upWithoutDown
        counters.duplicateDown = p.counters.duplicateDown
        counters.stuckAtEnd = p.counters.stuckAtEnd
        counters.nonMonotonicTimestamp = p.counters.nonMonotonicTimestamp
        counters.syntheticSourceEvents = p.counters.syntheticSourceEvents
        counters.droppedByRing = p.counters.droppedByRing

        var seq = p.baseSeq
        var micros = p.baseTMicros
        var rawFlags: UInt64 = 0
        var point = (x: Int32(0), y: Int32(0))
        var events: [ProbeEvent] = []
        events.reserveCapacity(p.events.count)

        for (i, pe) in p.events.enumerated() {
            if i > 0 {
                seq += UInt64(pe.seqDeltaMinusOne) + 1
                micros += UInt64(pe.tDeltaMicros)
            }
            guard let payload = pe.payload else { throw Error.malformed("event \(i) has no payload") }
            events.append(ProbeEvent(seq: seq,
                                     machAbsoluteNanos: micros * 1000,
                                     payload: try swiftPayload(payload, rawFlags: &rawFlags,
                                                               point: &point)))
        }

        return TelemetryFrame(
            wireVersion: p.wireVersion,
            epoch: p.epoch,
            frameIndex: p.frameIndex,
            probeMonotonicNanos: p.probeMonotonicNanos,
            oldestSeqInWindow: p.oldestSeqInWindow,
            health: .init(tapEnabled: p.health.tapEnabled,
                          runActive: p.health.runActive,
                          accessibilityGranted: p.health.accessibilityGranted,
                          secureInputHolder: p.health.secureInputHolder),
            counters: counters,
            heldKeys: p.heldKeys.map { UInt16(truncatingIfNeeded: $0) },
            screen: p.hasScreen ? .init(originX: p.screen.originX, originY: p.screen.originY,
                                        width: p.screen.width, height: p.screen.height,
                                        backingScale: p.screen.backingScale) : nil,
            events: events
        )
    }

    private static func swiftPayload(
        _ p: Regiprobe_Telemetry_V1_Event.OneOf_Payload, rawFlags: inout UInt64,
        point: inout (x: Int32, y: Int32)
    ) throws -> ProbeEvent.Payload {
        switch p {
        case .key(let k):
            // Flags are only on the wire when they changed; carry the last
            // value forward so every decoded event has absolute flags.
            if k.hasRawFlags { rawFlags = k.rawFlags }
            return .key(.init(kvk: UInt16(truncatingIfNeeded: k.kvk), down: k.down,
                              autorepeat: k.autorepeat, rawFlags: rawFlags,
                              characters: k.characters, sourcePID: k.sourcePid))
        case .flags(let f):
            rawFlags = f.rawFlags
            return .flags(.init(kvk: UInt16(truncatingIfNeeded: f.kvk), rawFlags: f.rawFlags))
        case .pointer(let pt):
            point = (point.x &+ pt.xDelta, point.y &+ pt.yDelta)
            return .pointer(.init(type: pt.type, x: point.x, y: point.y,
                                  deltaX: pt.deltaX, deltaY: pt.deltaY,
                                  buttonNumber: pt.buttonNumber, clickState: pt.clickState,
                                  sourcePID: pt.sourcePid))
        case .wheel(let w):
            return .wheel(.init(lineDeltaY: w.lineDeltaY, lineDeltaX: w.lineDeltaX,
                                pointDeltaY: w.pointDeltaY, pointDeltaX: w.pointDeltaX,
                                isContinuous: w.isContinuous, phase: w.phase,
                                sourcePID: w.sourcePid))
        case .gesture(let g):
            guard let kind = ProbeEvent.Gesture.Kind(rawValue: g.kind) else {
                throw Error.malformed("unknown gesture kind \(g.kind)")
            }
            return .gesture(.init(kind: kind, value: g.value, secondary: g.secondary,
                                  phase: g.phase, stage: g.stage))
        case .touches(let t):
            return .touches(t.touches.map {
                .init(identity: $0.identity, normX: $0.normX, normY: $0.normY,
                      phase: $0.phase, type: $0.type)
            })
        case .diagnostic(let d):
            guard let kind = ProbeEvent.Diagnostic.Kind(rawValue: d.kind) else {
                throw Error.malformed("unknown diagnostic kind \(d.kind)")
            }
            return .diagnostic(.init(kind: kind, detail: d.detail, value: d.value))
        }
    }

    private static func beBytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    private static func beUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
