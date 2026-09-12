import Foundation

/// One-line renderings, shared by the probe's timeline and the driver's failure
/// diffs so a given event reads identically in both places.
extension ProbeEvent {
    /// CGEventType raw values for the drag variants, which carry a held button
    /// but are not transitions.
    static func draggedButton(type: UInt32) -> PointerButton? {
        switch type {
        case 6:  return .left
        case 7:  return .right
        case 27: return .middle
        default: return nil
        }
    }

    public var kindLabel: String {
        switch payload {
        case .key(let k):    return k.down ? "key↓" : "key↑"
        case .flags:         return "flags"
        case .pointer(let p):
            if PointerButton.transition(type: p.type, buttonNumber: p.buttonNumber) != nil {
                return "button"
            }
            return Self.draggedButton(type: p.type) != nil ? "drag" : "move"
        case .wheel:         return "wheel"
        case .gesture:       return "gesture"
        case .touches:       return "touch"
        case .diagnostic:    return "diag"
        }
    }

    /// Same line, plus the raw CGEventType and button number.
    ///
    /// `detail` names what the event *means*, which is what a reader wants
    /// until the naming itself is in question: a right click that reports as
    /// `M1` is either the target sending something unexpected or this mapping
    /// being wrong, and the rendered label cannot tell those apart.
    public var rawDetail: String {
        guard case .pointer(let p) = payload else { return detail }
        return detail + "  [type=\(p.type) btn=\(p.buttonNumber)]"
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
            // Name the transition, not just the coordinates. Every pointer
            // event used to render the same way, so a press, a release and a
            // plain move were indistinguishable — and the button was shown as
            // a raw number that is 0 for left, making left clicks look like
            // nothing at all.
            var s: String
            if let (button, down) = PointerButton.transition(type: p.type,
                                                             buttonNumber: p.buttonNumber) {
                s = "\(button.label)\(down ? "↓" : "↑") (\(p.x),\(p.y))"
                // clickState is only meaningful on a press or release. macOS
                // also stamps it onto the motion that follows a click, which
                // made drags look like they were holding a button.
                if p.clickState > 1 { s += " ×\(p.clickState)" }
            } else if let dragged = Self.draggedButton(type: p.type) {
                s = "drag \(dragged.label) (\(p.x),\(p.y))"
            } else {
                s = "move (\(p.x),\(p.y))"
            }
            if p.deltaX != 0 || p.deltaY != 0 { s += " Δ(\(p.deltaX),\(p.deltaY))" }
            if p.sourcePID != 0 { s += " [pid \(p.sourcePID)]" }
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
