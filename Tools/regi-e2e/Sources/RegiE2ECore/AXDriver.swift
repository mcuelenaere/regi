import ApplicationServices
import AppKit
import Foundation

/// Drives Regi through the Accessibility API — pressing the app's real
/// controls, the way a user or a screen reader does, rather than through a
/// test-only back door.
///
/// The cost of that choice is sensitivity to UI change, and the mitigation is
/// that every lookup failure is named: "identifier not found" must never be
/// reported as "the app did not respond".
public final class AXDriver {
    public enum DriverError: Error, CustomStringConvertible {
        case appNotRunning(String)
        case notTrusted
        case identifierNotFound(String)
        case attributeUnavailable(String, String)
        case actionFailed(String, AXError)
        case timedOut(String)

        public var description: String {
            switch self {
            case .appNotRunning(let n): return "\(n) is not running"
            case .notTrusted:
                return """
                Accessibility is not granted to this binary.
                  TCC keys the grant to the code signature, so a rebuild of an
                  ad-hoc-signed binary invalidates it. Grant it again, or sign
                  with a stable identity.
                """
            case .identifierNotFound(let id):
                return """
                no element with accessibility identifier "\(id)".
                  Either the window holding it is not open, or a UI change
                  dropped the identifier — see App/AXIdentifiers.swift.
                """
            case .attributeUnavailable(let id, let attr):
                return "element \"\(id)\" has no \(attr)"
            case .actionFailed(let id, let e): return "action on \"\(id)\" failed: \(e.rawValue)"
            case .timedOut(let what): return "timed out waiting for \(what)"
            }
        }
    }

    public let appName: String
    private let app: AXUIElement
    public let pid: pid_t

    public init(appName: String = "Regi") throws {
        guard AXIsProcessTrusted() else { throw DriverError.notTrusted }
        guard let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == appName }) else {
            throw DriverError.appNotRunning(appName)
        }
        self.appName = appName
        self.pid = running.processIdentifier
        self.app = AXUIElementCreateApplication(running.processIdentifier)
    }

    // MARK: - Lookup

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success
            ? out : nil
    }

    /// Depth-limited search. The tree is re-walked per lookup rather than
    /// cached: SwiftUI rebuilds elements freely, and a stale AXUIElement fails
    /// in ways that read like the app misbehaving.
    public func find(_ identifier: String, maxDepth: Int = 14) throws -> AXUIElement {
        let windows = value(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        for window in windows {
            if let hit = search(window, identifier, depth: 0, maxDepth: maxDepth) { return hit }
        }
        throw DriverError.identifierNotFound(identifier)
    }

    public func exists(_ identifier: String) -> Bool {
        (try? find(identifier)) != nil
    }

    private func search(_ element: AXUIElement, _ identifier: String,
                        depth: Int, maxDepth: Int) -> AXUIElement? {
        if depth > maxDepth { return nil }
        if let id = value(element, kAXIdentifierAttribute as String) as? String, id == identifier {
            return element
        }
        let children = value(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
        for child in children {
            if let hit = search(child, identifier, depth: depth + 1, maxDepth: maxDepth) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Reading

    public func text(of identifier: String) throws -> String {
        let element = try find(identifier)
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = value(element, attribute as String) as? String, !s.isEmpty { return s }
        }
        throw DriverError.attributeUnavailable(identifier, "text")
    }

    /// Screen frame in **top-left-origin** coordinates — the same space
    /// `CGEvent` posting uses, so no Cocoa/Quartz flip is needed.
    public func frame(of identifier: String) throws -> CGRect {
        let element = try find(identifier)
        guard let posRef = value(element, kAXPositionAttribute as String),
              let sizeRef = value(element, kAXSizeAttribute as String) else {
            throw DriverError.attributeUnavailable(identifier, "frame")
        }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Acting

    public func press(_ identifier: String) throws {
        let element = try find(identifier)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else { throw DriverError.actionFailed(identifier, result) }
    }

    /// The capture toggles live inside a menu, so they only enter the tree once
    /// it is open. Opening it is therefore part of reaching them.
    public func pressInMenu(menu: String, item: String, settle: TimeInterval = 0.35) throws {
        try press(menu)
        Thread.sleep(forTimeInterval: settle)
        defer {
            // Leave the menu closed whatever happened, or the next lookup sees
            // a tree that does not match the app's resting state.
            let esc = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true)
            esc?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
        try press(item)
    }

    /// Resize the app's largest window.
    ///
    /// Not cosmetic: the QR band arrives scaled by how big Regi's window is, so
    /// a small window drops captured pixels per module below the ~4 floor and
    /// telemetry stops decoding. Being able to set it makes a run reproducible
    /// rather than dependent on how the window was left.
    @discardableResult
    public func resizeLargestWindow(to size: CGSize) -> Bool {
        let windows = value(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        guard let target = windows.max(by: { a, b in area(of: a) < area(of: b) }) else {
            return false
        }
        var newSize = size
        guard let axValue = AXValueCreate(.cgSize, &newSize) else { return false }
        return AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString,
                                            axValue) == .success
    }

    private func area(of element: AXUIElement) -> CGFloat {
        guard let sizeRef = value(element, kAXSizeAttribute as String) else { return 0 }
        var s = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return s.width * s.height
    }

    public func activate() {
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    @discardableResult
    public func waitFor(_ what: String, timeout: TimeInterval = 10,
                        poll: TimeInterval = 0.1,
                        _ condition: () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: poll)
        }
        throw DriverError.timedOut(what)
    }
}

/// Mirrors `App/AXIdentifiers.swift`. There is no compile-time link between
/// the two — the CLI does not depend on the app — so `regi-e2e doctor` resolves
/// every one of these as an explicit drift check.
public enum AXID {
    public static let videoView = "session.videoView"
    public static let resolutionText = "session.resolutionText"
    public static let captureMenu = "session.captureMenu"
    public static let keyboardCaptureToggle = "session.keyboardCaptureToggle"
    public static let pointerLockToggle = "session.pointerLockToggle"
    public static let hideCursorToggle = "session.hideCursorToggle"
    public static let controlsButton = "session.controlsButton"
    public static let statsButton = "session.statsButton"
    public static let hostsAddButton = "hosts.addButton"
    public static func hostsRow(_ host: String) -> String { "hosts.row.\(host)" }

    /// Resolvable without opening anything. The menu items are excluded
    /// because they only exist while the menu is open.
    public static let alwaysPresentInSession = [videoView, resolutionText,
                                                captureMenu, statsButton]
}
