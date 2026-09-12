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
        for i in 1...count {
            post(button == .left ? .leftMouseDown : .rightMouseDown, at: pixel,
                 button: button, clickState: i)
            Thread.sleep(forTimeInterval: 0.03)
            post(button == .left ? .leftMouseUp : .rightMouseUp, at: pixel,
                 button: button, clickState: i)
            if i < count { Thread.sleep(forTimeInterval: 0.06) }
        }
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
