// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "pointer-lock")

/// Pins the macOS cursor in place and hides it, so mouse motion is
/// reportable as relative deltas instead of an absolute position
/// crawling around the host display. Useful for FPS games on the
/// host, multi-monitor host setups, or pixel-perfect work in CAD /
/// image editors.
///
/// Mirrors KeyboardCapturer's two-layer state model:
/// - `userIntent`: what the toolbar toggle reflects.
/// - `state`: whether the lock is actually engaged right now.
///
/// They diverge when the app loses focus — `userIntent` stays true,
/// `state` flips to `.suspended` and the cursor returns to normal so
/// the user can click around in other apps. When focus returns the
/// lock re-engages.
@MainActor
@Observable
final class PointerLockManager {
    enum State: Equatable {
        case disabled
        case enabled    // lock active, cursor hidden
        case suspended  // user wants it but app isn't frontmost
    }

    private(set) var state: State = .disabled
    private(set) var userIntent: Bool = false

    private var notificationObservers: [NSObjectProtocol] = []

    init() {
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
    }

    func toggle() {
        if userIntent { disable() } else { enable() }
    }

    func enable() {
        log.info("user enabled pointer-lock")
        userIntent = true
        if NSApp.isActive {
            engage()
        } else {
            state = .suspended
        }
    }

    func disable() {
        log.info("user disabled pointer-lock")
        userIntent = false
        disengage()
        state = .disabled
    }

    private func engage() {
        // false = decouple cursor from mouse motion. Mouse still
        // produces NSEvent.deltaX/Y events; the cursor itself stays
        // pinned where it was when we engaged.
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        state = .enabled
        log.info("pointer-lock engaged")
    }

    private func disengage() {
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func appResignedActive() {
        guard userIntent else { return }
        if state == .enabled {
            log.info("app resigned active → pointer-lock suspended")
            disengage()
            state = .suspended
        }
    }

    private func appBecameActive() {
        guard userIntent, state != .enabled else { return }
        log.info("app became active → re-engaging pointer-lock")
        engage()
    }
}
