import Foundation

/// Presence of a host-side clipboard agent on the connected JetKVM.
/// Surfaced via the JSON-RPC `getClipboardAgentState` bootstrap call
/// and the `clipboardAgentStateChanged` push notification. The wire
/// representation is a bare JSON string — see the firmware's
/// `clipboard.go`.
public enum ClipboardAgentState: String, Codable, Sendable, Equatable {
    case absent
    case active
}
