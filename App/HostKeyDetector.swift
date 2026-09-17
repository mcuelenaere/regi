// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "host-key")

/// Watches keyboard state for the pointer-lock release combo
/// (⌃⌥ — Control + Option held alone for 500ms with no other key
/// pressed). Fires `onTriggered` when matched. The owner is expected
/// to use that signal to disengage pointer-lock.
///
/// Why a chord-with-hold rather than a tap: the modifiers are also
/// legitimate parts of host shortcuts (⌃⌥+letter), so we only act
/// when they're held in isolation past a clear threshold. The 500ms
/// delay is comfortably longer than the typical chord-then-key gap,
/// so accidentally triggering during a real shortcut is rare.
///
/// The detector is fed from KeyboardCapturer (when keyboard-lock is
/// engaged — that's the inescapable case). When keyboard-lock is off,
/// the user can already exit pointer-lock via Cmd+Tab (PointerLock
/// auto-suspends on focus loss), so we don't need a second feed path.
@MainActor
final class HostKeyDetector {
    /// Hold duration before the trigger fires. Long enough to avoid
    /// false positives during normal ⌃⌥+key chords; short enough that
    /// a deliberate "I want out" hold is comfortable.
    static let holdDuration: Duration = .milliseconds(500)

    /// Set by the owner. Fires on the main actor.
    var onTriggered: (() -> Void)?

    private var heldNonModifiers: Set<UInt16> = []
    private var pending: Task<Void, Never>?

    func didKeyDown(_ keyCode: UInt16) {
        heldNonModifiers.insert(keyCode)
        cancelPending()
    }

    func didKeyUp(_ keyCode: UInt16) {
        heldNonModifiers.remove(keyCode)
    }

    func didChangeFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.control, .option, .command, .shift, .capsLock])
        let isExactCtrlOption = relevant == [.control, .option]
        if isExactCtrlOption && heldNonModifiers.isEmpty {
            schedule()
        } else {
            cancelPending()
        }
    }

    /// Reset state — called when the owner tears down (e.g. session
    /// ends) or when we want to forget held keys after capture
    /// suspends.
    func reset() {
        heldNonModifiers.removeAll()
        cancelPending()
    }

    private func schedule() {
        cancelPending()
        log.info("⌃⌥ chord detected; waiting \(Self.holdDuration.description, privacy: .public) before firing")
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.holdDuration)
            guard let self, !Task.isCancelled else { return }
            log.info("⌃⌥ host-key hold elapsed → triggering")
            self.pending = nil
            self.onTriggered?()
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
