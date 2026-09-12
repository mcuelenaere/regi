import ProbeKit
import SwiftUI

/// ANSI layout drawn in a single `Canvas` rather than ~100 SwiftUI views —
/// at high event rates the view-per-key version is a main-thread problem, and
/// the main thread is what the tap's callback timeout is sensitive to.
struct KeyboardView: View {
    let held: Set<UInt16>
    let recent: [UInt16: Double]   // kvk -> seconds since last event, for the fade

    /// Rows of (kvk, width in units). kVK values that have no key here simply
    /// do not draw; this is a visual aid, not the assertion surface.
    private static let rows: [[(UInt16, CGFloat)]] = [
        [(0x35, 1), (0x7A, 1), (0x78, 1), (0x63, 1), (0x76, 1), (0x60, 1), (0x61, 1),
         (0x62, 1), (0x64, 1), (0x65, 1), (0x6D, 1), (0x67, 1), (0x6F, 1)],
        [(0x32, 1), (0x12, 1), (0x13, 1), (0x14, 1), (0x15, 1), (0x17, 1), (0x16, 1),
         (0x1A, 1), (0x1C, 1), (0x19, 1), (0x1D, 1), (0x1B, 1), (0x18, 1), (0x33, 2)],
        [(0x30, 1.5), (0x0C, 1), (0x0D, 1), (0x0E, 1), (0x0F, 1), (0x11, 1), (0x10, 1),
         (0x20, 1), (0x22, 1), (0x1F, 1), (0x23, 1), (0x21, 1), (0x1E, 1), (0x2A, 1.5)],
        [(0x39, 1.75), (0x00, 1), (0x01, 1), (0x02, 1), (0x03, 1), (0x05, 1), (0x04, 1),
         (0x26, 1), (0x28, 1), (0x25, 1), (0x29, 1), (0x27, 1), (0x24, 2.25)],
        [(0x38, 2.25), (0x06, 1), (0x07, 1), (0x08, 1), (0x09, 1), (0x0B, 1), (0x2D, 1),
         (0x2E, 1), (0x2B, 1), (0x2F, 1), (0x2C, 1), (0x3C, 2.75)],
        // All eight modifier keycodes appear somewhere on this layout (right
        // Shift in row 5, the rest here). Left/right fidelity is one of the
        // headline assertions, so none of them may be invisible — `fn` is
        // omitted instead, since nothing under test emits it.
        [(0x3B, 1), (0x3A, 1), (0x37, 1.25), (0x31, 4.5), (0x36, 1.25),
         (0x3D, 1), (0x3E, 1), (0x7B, 1), (0x7D, 1), (0x7E, 1), (0x7C, 1)],
    ]

    var body: some View {
        Canvas { ctx, size in
            // Derived, not hardcoded: a row that does not sum to the assumed
            // width silently clips its last key.
            let unitsWide = Self.rows.map { $0.reduce(0) { $0 + $1.1 } }.max() ?? 15
            let gap: CGFloat = 3
            let unit = (size.width - gap * (unitsWide + 1)) / unitsWide
            let rowH = min(unit, (size.height - gap * CGFloat(Self.rows.count + 1))
                                 / CGFloat(Self.rows.count))
            var y = gap

            for row in Self.rows {
                var x = gap
                for (kvk, widthUnits) in row {
                    let w = unit * widthUnits + gap * (widthUnits - 1)
                    let rect = CGRect(x: x, y: y, width: w, height: rowH)
                    let path = Path(roundedRect: rect, cornerRadius: 4)

                    if held.contains(kvk) {
                        ctx.fill(path, with: .color(.accentColor))
                    } else if let age = recent[kvk], age < 0.6 {
                        ctx.fill(path, with: .color(.accentColor.opacity(0.55 * (1 - age / 0.6))))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                    } else {
                        ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    }

                    let label = KeyLabels.named[kvk] ?? ""
                    if !label.isEmpty, w > 18 {
                        let text = Text(label)
                            .font(.system(size: min(11, rowH * 0.42), weight: .medium))
                            .foregroundStyle(held.contains(kvk) ? Color.white : Color.primary)
                        ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                    }
                    x += w + gap
                }
                y += rowH + gap
            }
        }
    }
}
