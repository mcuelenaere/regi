import ProbeKit
import SwiftUI

/// Cursor position and a fading trail, in the target's own screen space.
struct PointerCanvasView: View {
    let trail: [CGPoint]
    let screenSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            guard screenSize.width > 0, screenSize.height > 0 else { return }
            let sx = size.width / screenSize.width
            let sy = size.height / screenSize.height
            let scale = min(sx, sy)
            let offX = (size.width - screenSize.width * scale) / 2
            let offY = (size.height - screenSize.height * scale) / 2
            func map(_ p: CGPoint) -> CGPoint {
                CGPoint(x: offX + p.x * scale, y: offY + p.y * scale)
            }

            ctx.stroke(Path(CGRect(x: offX, y: offY,
                                   width: screenSize.width * scale,
                                   height: screenSize.height * scale)),
                       with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            guard trail.count > 1 else {
                if let p = trail.first {
                    ctx.fill(Path(ellipseIn: CGRect(x: map(p).x - 4, y: map(p).y - 4,
                                                    width: 8, height: 8)),
                             with: .color(.accentColor))
                }
                return
            }
            for i in 1..<trail.count {
                var seg = Path()
                seg.move(to: map(trail[i - 1]))
                seg.addLine(to: map(trail[i]))
                ctx.stroke(seg, with: .color(.accentColor.opacity(Double(i) / Double(trail.count))),
                           lineWidth: 2)
            }
            let last = map(trail[trail.count - 1])
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)),
                     with: .color(.accentColor))
        }
    }
}
