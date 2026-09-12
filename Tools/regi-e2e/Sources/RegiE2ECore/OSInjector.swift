import AppKit
import CoreGraphics
import Foundation

/// Posts real `CGEvent`s so input traverses the same OS path a human's would:
/// window server → Regi's own session tap or AppKit → backend → KVM → target.
///
/// Coordinates are given in **framebuffer pixels on the target**; the geometry
/// converts. Callers never deal in screen points, so a scenario reads the same
/// regardless of where Regi's window happens to be.
public final class OSInjector {
    /// One long-lived source. `.privateState` would not feed the window
    /// server's modifier-state machine, which breaks anything reading
    /// `NSEvent.modifierFlags` — notably Regi's ⌃⌥ host-key chord.
    private let source = CGEventSource(stateID: .hidSystemState)
    private let geometry: VideoGeometry

    /// Motion is throttled at 8ms inside the backends, so steps closer together
    /// than this are coalesced away before they reach the wire.
    public var stepInterval: TimeInterval = 0.02

    public init(geometry: VideoGeometry) {
        self.geometry = geometry
    }

    // MARK: - Pointer

    public func move(to pixel: CGPoint) {
        post(.mouseMoved, at: pixel, button: .left)
    }

    /// Several interpolated steps, because a single jump can be coalesced into
    /// nothing observable and tells you less about the path.
    public func glide(to pixel: CGPoint, from origin: CGPoint? = nil, steps: Int = 4) {
        let start = origin ?? pixel
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            move(to: CGPoint(x: start.x + (pixel.x - start.x) * t,
                             y: start.y + (pixel.y - start.y) * t))
            Thread.sleep(forTimeInterval: stepInterval)
        }
    }

    public func click(at pixel: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        // `1...0` traps at runtime, and a zero-count click is a caller mistake
        // rather than something to silently perform.
        guard count >= 1 else { return }
        for i in 1...count {
            post(button == .left ? .leftMouseDown : .rightMouseDown, at: pixel,
                 button: button, clickState: i)
            Thread.sleep(forTimeInterval: 0.03)
            post(button == .left ? .leftMouseUp : .rightMouseUp, at: pixel,
                 button: button, clickState: i)
            if i < count { Thread.sleep(forTimeInterval: 0.06) }
        }
    }

    // MARK: - Button transitions and drag

    public func buttonDown(at pixel: CGPoint, button: CGMouseButton = .left) {
        post(downType(button), at: pixel, button: button, clickState: 1)
    }

    public func buttonUp(at pixel: CGPoint, button: CGMouseButton = .left) {
        post(upType(button), at: pixel, button: button, clickState: 1)
    }

    /// Press, move, release. The intermediate events must be `*MouseDragged`
    /// rather than `mouseMoved`, or the target sees motion with no button held
    /// and the drag is not a drag.
    public func drag(from origin: CGPoint, to destination: CGPoint,
                     button: CGMouseButton = .left, steps: Int = 8) {
        move(to: origin)
        Thread.sleep(forTimeInterval: 0.08)
        buttonDown(at: origin, button: button)
        Thread.sleep(forTimeInterval: 0.04)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            post(draggedType(button),
                 at: CGPoint(x: origin.x + (destination.x - origin.x) * t,
                             y: origin.y + (destination.y - origin.y) * t),
                 button: button)
            Thread.sleep(forTimeInterval: stepInterval)
        }
        buttonUp(at: destination, button: button)
    }

    /// Back and forward are `otherMouse*` with a button number; bits 3 and 4 of
    /// `NSEvent.pressedMouseButtons`, which is what Regi reads.
    public func sideButton(at pixel: CGPoint, number: Int, down: Bool) {
        let screen = geometry.screenPoint(forFramebufferPixel: pixel)
        guard let e = CGEvent(mouseEventSource: source,
                              mouseType: down ? .otherMouseDown : .otherMouseUp,
                              mouseCursorPosition: screen, mouseButton: .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Wheel

    /// A discrete wheel detent, the way a real mouse reports it: line units,
    /// not pixels. A KVM wheel must arrive discrete rather than as
    /// trackpad-style continuous scroll, which is itself worth asserting.
    public func scroll(lines: Int, horizontal: Bool = false) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line,
                              wheelCount: horizontal ? 2 : 1,
                              wheel1: horizontal ? 0 : Int32(lines),
                              wheel2: horizontal ? Int32(lines) : 0,
                              wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    private func downType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseDown; case .right: return .rightMouseDown
                   default: return .otherMouseDown }
    }
    private func upType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseUp; case .right: return .rightMouseUp
                   default: return .otherMouseUp }
    }
    private func draggedType(_ b: CGMouseButton) -> CGEventType {
        switch b { case .left: return .leftMouseDragged; case .right: return .rightMouseDragged
                   default: return .otherMouseDragged }
    }

    // MARK: - Autorepeat

    /// The OS marks repeats with `keyboardEventAutorepeat`, and the probe uses
    /// it to distinguish a repeat from the client double-sending a press.
    public func autorepeat(_ kvk: CGKeyCode, count: Int, intervalMillis: Int) {
        key(kvk, down: true)
        for _ in 0..<max(0, count - 1) {
            Thread.sleep(forTimeInterval: Double(intervalMillis) / 1000)
            if let e = CGEvent(keyboardEventSource: source, virtualKey: kvk, keyDown: true) {
                e.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                e.post(tap: .cghidEventTap)
            }
        }
        Thread.sleep(forTimeInterval: Double(intervalMillis) / 1000)
        key(kvk, down: false)
    }

    private func post(_ type: CGEventType, at pixel: CGPoint,
                      button: CGMouseButton, clickState: Int = 0) {
        let screen = geometry.screenPoint(forFramebufferPixel: pixel)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: screen, mouseButton: button) else { return }
        if clickState > 1 {
            // Double-click needs click state on BOTH down and up, inside the
            // system interval, or the target sees two separate clicks.
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    public func key(_ kvk: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: kvk, keyDown: down)
        else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    public func tap(_ kvk: CGKeyCode, flags: CGEventFlags = [], hold: TimeInterval = 0.04) {
        key(kvk, down: true, flags: flags)
        Thread.sleep(forTimeInterval: hold)
        key(kvk, down: false, flags: flags)
    }

    /// Modifiers must be delivered as their own `flagsChanged` events.
    ///
    /// Measured on the rig: setting `.maskShift` on a key event alone produced
    /// "a" on the target, while a preceding `flagsChanged` produced "A".
    /// Regi's `ModifierTracker` only learns modifier state from flagsChanged,
    /// so a modifier is an event here, never a property of a keypress.
    ///
    /// `CGEvent(keyboardEventSource:)` yields a `.keyDown` even for a modifier
    /// keycode, so all three of the type, keycode and flags must be set.
    public func modifier(_ kvk: CGKeyCode, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: kvk, keyDown: true)
        else { return }
        e.type = .flagsChanged
        e.setIntegerValueField(.keyboardEventKeycode, value: Int64(kvk))
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Modifier keycodes and their device-side flag bits
    //
    // The device-side bits are what distinguish left from right; CGEventFlags'
    // documented masks collapse the sides.
    public enum Modifier {
        public static let leftShift: (CGKeyCode, UInt64)    = (0x38, 0x2)
        public static let rightShift: (CGKeyCode, UInt64)   = (0x3C, 0x4)
        public static let leftControl: (CGKeyCode, UInt64)  = (0x3B, 0x1)
        public static let rightControl: (CGKeyCode, UInt64) = (0x3E, 0x2000)
        public static let leftOption: (CGKeyCode, UInt64)   = (0x3A, 0x20)
        public static let rightOption: (CGKeyCode, UInt64)  = (0x3D, 0x40)
        public static let leftCommand: (CGKeyCode, UInt64)  = (0x37, 0x8)
        public static let rightCommand: (CGKeyCode, UInt64) = (0x36, 0x10)
    }
}
