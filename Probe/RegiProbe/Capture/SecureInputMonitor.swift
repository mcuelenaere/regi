import Foundation
import IOKit
import os

/// Secure Input stops the window server delivering key events to **every** tap
/// in the session, while `CGEvent.tapCreate` still succeeds and the tap still
/// reports enabled. A probe that hits this looks healthy and records nothing —
/// which would surface as an entire scenario suite failing with "key never
/// arrived", pointing at Regi for something Regi did not do.
///
/// The tap is this probe's only witness (there is no HID capture), so this is
/// not a warning: a run overlapping Secure Input is **invalid** and the probe
/// refuses to start one.
///
/// Same IORegistry probe as `App/KeyboardCapturer.swift:311`, which documents
/// the mechanism in more detail.
enum SecureInputMonitor {
    private static let log = Logger(subsystem: "app.regi.probe", category: "secure-input")

    /// Name of the process holding Secure Input, or nil when it is not engaged.
    static func holder() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let prop = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for session in prop {
            guard let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, onConsole else { continue }
            guard let pid = session["kCGSSessionSecureInputPID"] as? Int32, pid != 0 else { continue }
            return processName(pid: pid) ?? "pid \(pid)"
        }
        return nil
    }

    private static func processName(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
    }
}
