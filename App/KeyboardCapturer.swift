import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOKit
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "tap")

/// Manages a session-level `CGEventTap` so the app can swallow
/// system-grabbed key combos (Cmd+Tab, Cmd+Q, Cmd+Space, etc.) and
/// forward them to the JetKVM host instead.
///
/// Capture has two layers of state:
///  - `userIntent`: what the toolbar toggle reflects.
///  - `state`: whether the tap is actually installed right now.
///
/// They diverge when the app loses focus: `userIntent` stays `true`
/// but `state` flips to `.suspended` (tap removed) so we don't grab
/// system shortcuts while the user is in another app. When focus
/// returns we re-install the tap automatically. This matters for
/// modifier state, too — `onSuspend` fires when active capture pauses
/// so the owner can release held modifiers on the host (otherwise
/// the host ends up thinking Cmd is still held after the user
/// alt-tabbed away).
///
/// Requires Accessibility permission. The first call to `enable()`
/// triggers macOS's system prompt; if the user grants it, the tap
/// installs and `state` flips to `.enabled`. If the prompt is
/// dismissed without granting, `state` becomes `.awaitingAccessibility`
/// — the user has to grant manually in System Settings → Privacy &
/// Security → Accessibility, then call `enable()` again.
///
/// Also blocked by macOS **Secure Input** (`.blockedBySecureInput`).
/// See `secureInputHolder()` — that condition is invisible from the tap
/// API itself, so we probe for it explicitly rather than install a tap
/// that would silently receive nothing.
///
/// **The app must be unsandboxed** for CGEventTap to work; App Sandbox
/// blocks session-level taps outright. Our build has no App Sandbox
/// entitlement for this reason (hardened runtime is on, which is fine —
/// it's the sandbox specifically that kills session taps).
@MainActor
@Observable
final class KeyboardCapturer {
    enum State: Equatable {
        case disabled
        case awaitingAccessibility
        /// Secure Input is engaged session-wide, so no event tap can
        /// receive keys. `holder` is a human-readable name for the
        /// process holding it (or "pid N" if we can't resolve one).
        case blockedBySecureInput(holder: String)
        case enabled    // tap installed AND user intends capture
        case suspended  // user intends capture, tap removed (app not active)
        case failed(String)
    }

    private(set) var state: State = .disabled

    /// Tracks whether the user has the toolbar toggle on. Capture
    /// suspends/resumes around app focus changes, but `userIntent`
    /// persists across them.
    private(set) var userIntent: Bool = false

    /// Set by the owner to receive forwarded key events. Each closure
    /// is invoked on the main thread — same context the tap runs on
    /// (we register the tap source on the main run loop).
    var onKeyDown: ((UInt16) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    /// (keyCode, rawFlags). The flags are required: the modifier's state has
    /// to be read from them, not inferred by toggling — see ModifierTracker.
    var onFlagsChanged: ((UInt16, UInt64) -> Void)?

    /// Fires alongside `onFlagsChanged` with the current bitmask of
    /// pressed modifiers. Used by HostKeyDetector to spot the
    /// pointer-lock release chord (Ctrl+Option held alone). We pass
    /// the snapshot rather than expecting the listener to maintain
    /// its own tracker — KeyboardCapturer already has it via the
    /// CGEvent flags.
    var onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?

    /// Fires when an active tap is suspended — either the user
    /// toggled off, or the app lost focus while capture was on. Use
    /// this to release any modifiers your tracker thinks are held,
    /// so the host doesn't end up with stuck-down keys.
    var onSuspend: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var notificationObservers: [NSObjectProtocol] = []
    /// The window the user enabled capture in. The tap stays globally
    /// installed (it must be — CGEventTap is session-level), but it
    /// only swallows + forwards keys while this window is the key
    /// window of our app. With multiple KVM windows open this is what
    /// keeps a window-A capture from eating keys aimed at window B.
    private weak var boundWindow: NSWindow?

    init() {
        // Watch for app focus changes so we can suspend/resume the
        // tap automatically. NSApp-level catches the case where the
        // user switches to a different app entirely; the per-window
        // observers below catch in-app focus changes between KVM
        // session windows.
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResignedActive() }
        })
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        // Per-window key-status: filter by `boundWindow` in the handler
        // (registering with object: nil and comparing inside is simpler
        // than re-registering on every boundWindow change).
        notificationObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.windowBecameKey(note.object as? NSWindow) }
        })
        notificationObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.windowResignedKey(note.object as? NSWindow) }
        })
    }

    // No deinit cleanup: deinit runs nonisolated and we can't read
    // MainActor-isolated state from there. Owners (KVMWindowView)
    // call `disable()` from `.onDisappear` to tear the tap down. If
    // we ever leak this object the tap stays installed until process
    // exit — acceptable given the audience and lifetime.

    func toggle() {
        if userIntent {
            disable()
        } else {
            enable()
        }
    }

    /// Express "user wants capture on". If the app is currently
    /// active, Accessibility is granted and Secure Input is off, the
    /// tap installs and `state` becomes `.enabled`. Otherwise `state`
    /// reflects the blocking condition (`.awaitingAccessibility`,
    /// `.blockedBySecureInput` or `.suspended`).
    func enable() {
        log.info("user enabled capture")
        userIntent = true
        // Remember which window the user toggled this in — we'll
        // gate event-swallowing on this window being key, so a
        // capture in window A doesn't steal keys aimed at window B.
        boundWindow = NSApp.keyWindow
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Bool] = [promptKey: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            log.notice("Accessibility permission not granted yet")
            state = .awaitingAccessibility
            return
        }
        if NSApp.isActive {
            installTap()
        } else {
            // App not frontmost yet — wait for didBecomeActive.
            state = .suspended
        }
    }

    /// Express "user wants capture off". Tears down the tap (if
    /// installed) and clears `userIntent` so we don't auto-resume on
    /// the next app-active notification.
    func disable() {
        let wasActiveCapture: Bool = (state == .enabled)
        userIntent = false
        teardownTap()
        state = .disabled
        if wasActiveCapture {
            onSuspend?()
        }
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // Notification handlers — wire app focus changes through to the
    // tap state. userIntent is the source of truth for "should this
    // tap exist when the app is active?"
    private func appResignedActive() {
        guard userIntent else { return }
        let wasActiveCapture = (state == .enabled)
        teardownTap()
        state = .suspended
        if wasActiveCapture {
            log.info("app resigned active → tap suspended; releasing held modifiers")
            // Tell the owner so it can release any modifiers the
            // tracker thinks are held — otherwise the host gets a
            // stuck Cmd / Shift / etc.
            onSuspend?()
        }
    }

    private func appBecameActive() {
        guard userIntent, state != .enabled else { return }
        log.info("app became active → re-installing tap")
        // Re-check Accessibility — the user may have granted it
        // manually while we were away.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            state = .awaitingAccessibility
            return
        }
        installTap()
    }

    private func windowResignedKey(_ window: NSWindow?) {
        // Only react to the window the user enabled capture in. Other
        // windows of our app coming and going don't matter to this
        // capturer instance.
        guard let window, window === boundWindow else { return }
        appResignedActive()
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window, window === boundWindow else { return }
        appBecameActive()
    }

    private func installTap() {
        // Secure Input blocks key delivery to every tap in the
        // session, and `tapCreate` gives no hint of it — see
        // `secureInputHolder()`. Check before installing a tap that
        // would look healthy and silently receive nothing.
        if let holder = secureInputHolder() {
            log.notice("Secure Input active (held by \(holder, privacy: .public)) — not installing tap")
            state = .blockedBySecureInput(holder: holder)
            return
        }

        let mask: CGEventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // The C callback is @convention(c) — it can't capture Swift
        // state. Pass `self` as opaque userInfo and unwrap inside.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<KeyboardCapturer>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            log.error("CGEvent.tapCreate returned nil — Accessibility permission may have been revoked")
            state = .failed("Failed to install event tap")
            return
        }
        log.info("CGEventTap installed")

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        state = .enabled
    }

    // MARK: - Secure Input

    /// Name of the process holding macOS Secure Input, or nil when
    /// Secure Input isn't engaged.
    ///
    /// While it is engaged the window server stops delivering key
    /// events to *every* event tap in the session. `tapCreate` still
    /// succeeds and the tap still reports enabled, so a capture that
    /// hits this looks on while doing nothing at all. Normally it's
    /// transient (a password field has focus), but a process that
    /// calls `EnableSecureEventInput` without balancing it — we've
    /// seen `loginwindow` do this — leaves it stuck until the user
    /// logs out and back in.
    ///
    /// The flag lives in the IORegistry root's `IOConsoleUsers`
    /// property, an array of per-session dictionaries — the same thing
    /// `ioreg -l -d 1 -k IOConsoleUsers` prints. Depth 1 there is the
    /// hint that this is a root property, so no plane walk is needed.
    private func secureInputHolder() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in sessions {
            // Ignore sessions switched away from: another logged-in
            // user typing a password can't affect our taps.
            if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, !onConsole {
                continue
            }
            guard let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
                  pid != 0 else { continue }
            return Self.processName(for: pid)
        }
        return nil
    }

    /// Best-effort display name for a pid. The holder is often not a
    /// regular app (`loginwindow`, a daemon), so fall back to the
    /// executable name and finally to the raw pid.
    private static func processName(for pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
        }
        return "pid \(pid)"
    }

    /// Tap callback. Marked `nonisolated` so it can be called from the
    /// `@convention(c)` callback; we registered the run loop source on
    /// the main run loop, so this fires on the main thread and using
    /// `MainActor.assumeIsolated` is safe.
    private nonisolated func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            // Only swallow when our app is the frontmost. Otherwise
            // we'd grab Cmd+Tab system-wide, which is rude.
            guard NSApp.isActive else {
                return Unmanaged.passUnretained(event)
            }

            switch type {
            case .keyDown, .keyUp, .flagsChanged:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                switch type {
                case .keyDown: onKeyDown?(keyCode)
                case .keyUp: onKeyUp?(keyCode)
                case .flagsChanged:
                    onFlagsChanged?(keyCode, event.flags.rawValue)
                    // The CGEvent's flags field has the same bit layout
                    // as NSEvent.ModifierFlags, so we can map straight
                    // across without parsing keycodes ourselves.
                    let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                    onModifierFlagsChanged?(flags)
                default: break
                }
                return nil // swallow

            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // The system auto-disables a tap that's too slow or
                // the user deliberately suspended. Re-enable so the
                // user doesn't have to flip our toggle off-and-on.
                log.notice("event tap auto-disabled (\(type.rawValue, privacy: .public)) — re-enabling")
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)

            default:
                return Unmanaged.passUnretained(event)
            }
        }
    }
}
