import Foundation

/// One-line renderings, shared by the probe's timeline and the driver's failure
/// diffs so a given event reads identically in both places.
extension ProbeEvent {
    public var kindLabel: String {
        switch payload {
        case .key(let k):    return k.down ? "key↓" : "key↑"
        case .flags:         return "flags"
        case .pointer:       return "ptr"
        case .wheel:         return "wheel"
        case .gesture:       return "gesture"
        case .touches:       return "touch"
        case .diagnostic:    return "diag"
        }
    }

    public var detail: String {
        switch payload {
        case .key(let k):
            var s = KeyLabels.label(k.kvk)
            if !k.characters.isEmpty, k.characters != " " {
                s += " “\(k.characters)”"
            }
            if k.autorepeat { s += " (repeat)" }
            if k.sourcePID != 0 { s += " [pid \(k.sourcePID)]" }
            return s
        case .flags(let f):
            return "\(KeyLabels.label(f.kvk))  flags 0x\(String(f.rawFlags, radix: 16))"
        case .pointer(let p):
            var s = "(\(p.x),\(p.y))"
            if p.buttonNumber != 0 { s += " btn \(p.buttonNumber)" }
            if p.clickState > 1 { s += " click×\(p.clickState)" }
            if p.deltaX != 0 || p.deltaY != 0 { s += " Δ(\(p.deltaX),\(p.deltaY))" }
            return s
        case .wheel(let w):
            return "line(\(w.lineDeltaY),\(w.lineDeltaX)) px(\(w.pointDeltaY),\(w.pointDeltaX))"
                + (w.isContinuous ? " continuous" : " discrete")
        case .gesture(let g):
            return "\(g.kind)"
        case .touches(let t):
            return "\(t.count) finger\(t.count == 1 ? "" : "s")"
        case .diagnostic(let d):
            return d.detail.isEmpty ? "\(d.kind)" : "\(d.kind): \(d.detail)"
        }
    }
}
