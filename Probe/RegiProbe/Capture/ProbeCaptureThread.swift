import CoreGraphics
import Foundation
import os
import ProbeKit

/// Owns the `CGEventTap` on a dedicated thread with its own `CFRunLoop`.
///
/// **Never the main run loop.** The window server force-disables a tap whose
/// callback runs longer than its timeout, and SwiftUI work on the main loop
/// guarantees that eventually. The failure is silent — the tap reports enabled
/// and delivers nothing — so the isolation is not an optimisation.
final class ProbeCaptureThread: @unchecked Sendable {
    private let log = Logger(subsystem: "app.regi.probe", category: "capture")
    private let ring: ProbeEventRing
    let layout = KeyboardLayoutSnapshot()

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Set while the run window is up. When true the callback returns nil for
    /// key and flags events so ⌘Q and friends cannot reach the target's other
    /// apps. Mouse events are never swallowed — the full-screen run window
    /// already absorbs them, and that is what keeps its Stop button clickable.
    private var _swallowKeyboard = false
    private var swallowLock = os_unfair_lock()
    var swallowKeyboard: Bool {
        get { os_unfair_lock_lock(&swallowLock); defer { os_unfair_lock_unlock(&swallowLock) }; return _swallowKeyboard }
        set { os_unfair_lock_lock(&swallowLock); _swallowKeyboard = newValue; os_unfair_lock_unlock(&swallowLock) }
    }

    /// Escape pressed five times inside two seconds always passes through and
    /// force-closes the run window. It is the backstop for the one case the
    /// Stop button cannot cover: the UI wedged while the tap still swallows.
    var onEscapeChord: (() -> Void)?
    private var escapeTimes: [CFAbsoluteTime] = []

    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }
    private(set) var state: State = .idle

    init(ring: ProbeEventRing) { self.ring = ring }

    func start() throws {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        var startError: String?

        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            do {
                try self.installTap()
            } catch {
                startError = "\(error)"
            }
            ready.signal()
            // Runs until stop() invalidates the source and the loop empties.
            while !Thread.current.isCancelled, self.tap != nil {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        t.name = "app.regi.probe.capture"
        // Above default so a busy UI cannot starve the tap into its timeout.
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()

        if let startError {
            thread = nil
            state = .failed(startError)
            throw ProbeError.tapCreationFailed(startError)
        }
        state = .running
    }

    private func installTap() throws {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ProbeCaptureThread>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: EventTapDecoder.eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            throw ProbeError.tapCreationFailed(
                "CGEvent.tapCreate returned nil — Accessibility not granted, or the "
                + "grant is stale because the binary was re-signed")
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
        log.info("event tap installed on capture thread")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // These arrive regardless of the mask and mean the tap has stopped
        // delivering. Re-enable, and record it — a gap in the record must be
        // visible rather than inferred.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let kind: ProbeEvent.Diagnostic.Kind = .tapDisabled
            ring.append(machAbsoluteNanos: MachClock.absoluteNanos(),
                        payload: .diagnostic(.init(kind: kind,
                                                   detail: type == .tapDisabledByTimeout
                                                       ? "timeout" : "userInput")))
            log.error("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")), re-enabled")
            return Unmanaged.passUnretained(event)
        }

        let nanos = MachClock.nanos(fromMachAbsolute: event.timestamp)
        if let payload = EventTapDecoder.payload(type: type, event: event, layout: layout) {
            ring.append(machAbsoluteNanos: nanos, payload: payload)
        }

        // Record first, swallow second: the probe must see everything it
        // suppresses, or the shield would create the blind spot it exists to
        // prevent.
        if isEscapeChord(type: type, event: event) {
            onEscapeChord?()
            return Unmanaged.passUnretained(event)
        }
        if swallowKeyboard, type == .keyDown || type == .keyUp || type == .flagsChanged {
            // Never swallow synthetic events: doing so can wedge assistive
            // technology, which has nothing to do with this test rig.
            if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func isEscapeChord(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 0x35 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        escapeTimes.append(now)
        escapeTimes.removeAll { now - $0 > 2.0 }
        if escapeTimes.count >= 5 {
            escapeTimes.removeAll()
            return true
        }
        return false
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopSourceInvalidate(source) }
        if let runLoop { CFRunLoopStop(runLoop) }
        thread?.cancel()
        tap = nil; source = nil; thread = nil; runLoop = nil
        state = .idle
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case tapCreationFailed(String)
    case secureInputActive(String)

    var description: String {
        switch self {
        case .tapCreationFailed(let m): return m
        case .secureInputActive(let h):
            return "Secure Input is held by \(h). Every event tap in this session is "
                + "starved, so a run would record nothing while looking healthy."
        }
    }
}
