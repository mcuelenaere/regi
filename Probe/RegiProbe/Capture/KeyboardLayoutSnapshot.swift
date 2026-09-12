import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Translates a keycode to characters **without touching AppKit or TSM**.
///
/// `NSEvent.characters` goes through `TSMTranslateKeyEvent`, which calls
/// `dispatch_assert_queue` for the main queue and traps if it is not there.
/// The tap callback deliberately runs on its own thread (the window server
/// force-disables a tap whose callback runs long), so calling it from there
/// crashed the app on the first keystroke — twice, before it was caught.
///
/// `UCKeyTranslate` avoids TSM entirely: it is a pure function over a layout
/// blob, so the blob is fetched on the main thread and translation then happens
/// wherever. Dead-key state is explicitly disabled — the probe observes input,
/// and must never mutate the state of the input it is observing.
final class KeyboardLayoutSnapshot: @unchecked Sendable {
    private let log = Logger(subsystem: "app.regi.probe", category: "layout")
    private var layoutData: Data?
    private var lock = os_unfair_lock()

    /// Must be called on the main thread: the TIS input-source APIs carry the
    /// same main-queue assertion that caused the crash.
    @MainActor
    func refresh() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            log.error("could not read the current keyboard layout")
            return
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        os_unfair_lock_lock(&lock)
        layoutData = data
        os_unfair_lock_unlock(&lock)
    }

    /// Observe layout switches so a mid-run change does not silently produce
    /// characters from the wrong layout.
    @MainActor
    func observeLayoutChanges() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func characters(keyCode: UInt16, flags: CGEventFlags) -> String {
        os_unfair_lock_lock(&lock)
        let data = layoutData
        os_unfair_lock_unlock(&lock)
        guard let data else { return "" }

        // UCKeyTranslate wants the Carbon modifier byte, not CGEventFlags.
        var carbon: UInt32 = 0
        if flags.contains(.maskShift)      { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate)  { carbon |= UInt32(optionKey) }
        if flags.contains(.maskCommand)    { carbon |= UInt32(cmdKey) }
        if flags.contains(.maskControl)    { carbon |= UInt32(controlKey) }
        if flags.contains(.maskAlphaShift) { carbon |= UInt32(alphaLock) }
        let modifierKeyState = (carbon >> 8) & 0xFF

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                // Never mutate dead-key state: this is an observer.
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }
}
