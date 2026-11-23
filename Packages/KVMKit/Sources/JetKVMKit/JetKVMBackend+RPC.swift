// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import KVMCore
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "session")

/// Typed wrappers for the JSON-RPC methods the control plane needs.
///
/// All methods are gated on `rpcReady` — calling before the channel
/// has fully opened throws `SessionError.rpcNotReady` rather than
/// hanging waiting for a response that can't ride the channel.
extension JetKVMBackend {

    // MARK: - Identity

    public func getDeviceID() async throws -> String {
        try await rpcCall(method: "getDeviceID")
    }

    // MARK: - ATX power

    public func setATXPowerAction(_ action: ATXPowerAction) async throws {
        struct Params: Encodable, Sendable { let action: String }
        try await rpcCallVoid(method: "setATXPowerAction", params: Params(action: action.rawValue))
    }

    public func getATXState() async throws -> ATXState {
        try await rpcCall(method: "getATXState")
    }

    // MARK: - Stream quality
    //
    // Read-only: the device's web UI owns tuning this, we only display it.

    public func getStreamQualityFactor() async throws -> Double {
        try await rpcCall(method: "getStreamQualityFactor")
    }

    // MARK: - Pause / resume video stream
    //
    // Lets the client gate WebRTC RTP traffic to keepalive levels
    // without renegotiating the session, e.g. when the KVM window
    // is occluded or minimized. Paused means the device's encoder is
    // stopped outright (`VideoStop`); resuming restarts it, so the
    // stream comes back on a fresh keyframe. The data channels stay
    // open throughout, so input keeps working through a pause.
    //
    // The pause is *owned by the session that set it*: the firmware
    // records us in `videoPausedBy` and ignores a resume from anyone
    // else, and a session connecting while a pause is held does not
    // get video. Our disconnect releases it, so we never need to
    // unwind the pause on teardown. Repeat calls with the same value
    // are harmless.
    //
    // Named for the firmware method, which is a single setter rather
    // than the `pauseVideo` / `resumeVideo` pair proposed in
    // jetkvm/kvm#1455 — that PR was superseded and never merged, so
    // those two methods exist in no released firmware.
    public func setVideoStreamPausedRPC(_ paused: Bool) async throws {
        struct Params: Encodable, Sendable { let paused: Bool }
        try await rpcCallVoid(method: "setVideoStreamPaused", params: Params(paused: paused))
    }

    // MARK: - Host wake
    //
    // Since 0.5.9 the keyboard/mouse gadgets no longer wake a sleeping
    // host (jetkvm/kvm#1471 set their `wakeup_on_write` to 0). Wake now
    // goes through a dedicated vendor HID device that the firmware
    // pulses three times. Returns once the pulses are sent (~600 ms);
    // whether the host actually wakes shows up later as a videoState change.
    // Failures are logged, not thrown: the UI has nothing better to do with them.
    public func wakeHostRPC() async {
        _ = await fetch("wakeHost") { try await self.rpcCallVoid(method: "wakeHost") }
    }

    // MARK: - Scroll wheel
    //
    // Legacy scroll path for firmware 0.5.9/0.5.10: the `wheelReport`
    // method funnels wheelY/wheelX into the HID gadget's wheel report.
    // 0.5.11 removed it (jetkvm/kvm#1462) in favour of HID-RPC 0x04; see
    // `sendWheelReport`, which falls back when this answers -32601.

    public func sendWheelReportRPC(wheelY: Int8, wheelX: Int8) async throws {
        struct Params: Encodable, Sendable {
            let wheelY: Int8
            let wheelX: Int8
        }
        try await rpcCallVoid(method: "wheelReport", params: Params(wheelY: wheelY, wheelX: wheelX))
    }

    // MARK: - State

    public func getVideoState() async throws -> VideoState {
        try await rpcCall(method: "getVideoState")
    }

    public func getUSBState() async throws -> String {
        try await rpcCall(method: "getUSBState")
    }

    // MARK: - Clipboard agent
    //
    // Bootstrap call paired with the `clipboardAgentStateChanged` push
    // notification handled in Session. Wire shape: a bare string —
    // "absent" or "active".

    public func getClipboardAgentState() async throws -> ClipboardAgentState {
        let raw: String = try await rpcCall(method: "getClipboardAgentState")
        let parsed = ClipboardAgentState(rawValue: raw) ?? .absent
        log.info("[SESSION] getClipboardAgentState RPC returned '\(raw, privacy: .public)' → \(parsed.rawValue, privacy: .public)")
        return parsed
    }

    // MARK: - OS Services
    //
    // Firmware with OS Services (jetkvm/kvm#1769) relays these to a sender
    // program on the host over the KVM's USB cable. `videoState` says which
    // services the sender offers. Statuses are "ok", "unsupported", "empty",
    // "denied" (a password manager marked the text secret) or "failed".

    struct GuestClipboardContent: Decodable, Sendable {
        let status: String
        let text: String
        let truncated: Bool
    }

    func guestClipboardGet() async throws -> GuestClipboardContent {
        try await rpcCall(method: "guestClipboardGet")
    }

    func guestClipboardSet(_ text: String) async throws -> String {
        struct Params: Encodable, Sendable { let text: String }
        struct Result: Decodable, Sendable { let status: String }
        let result: Result = try await rpcCall(method: "guestClipboardSet", params: Params(text: text))
        return result.status
    }

    struct GuestFileDropResult: Decodable, Sendable {
        /// Label of the data channel to stream the files on.
        let channel: String
        /// One transfer ID per file, in order.
        let transfers: [UInt32]
    }

    func guestFileDrop(_ files: [(name: String, size: UInt64)]) async throws -> GuestFileDropResult {
        struct File: Encodable, Sendable { let name: String; let size: UInt64 }
        struct Drop: Encodable, Sendable { let files: [File] }
        struct Params: Encodable, Sendable { let drop: Drop }
        let drop = Drop(files: files.map { File(name: $0.name, size: $0.size) })
        return try await rpcCall(method: "guestFileDrop", params: Params(drop: drop))
    }

    // MARK: - Convenience: initial state fetch + optimistic updates

    /// Fetch every cached control-plane field in parallel. Called
    /// automatically when the rpc channel becomes ready; can also be
    /// invoked manually by a UI refresh button. Per-method failures
    /// are logged but don't fail the whole refresh.
    public func refreshControlState() async {
        guard rpcReady else { return }

        async let video = fetch("getVideoState") { try await self.getVideoState() }
        async let usb = fetch("getUSBState") { try await self.getUSBState() }
        async let atx = fetch("getATXState") { try await self.getATXState() }
        async let factor = fetch("getStreamQualityFactor") { try await self.getStreamQualityFactor() }
        async let clipAgent = fetch("getClipboardAgentState") { try await self.getClipboardAgentState() }

        videoState = await video
        usbState = await usb
        atxState = await atx
        streamQualityFactor = await factor
        if let c = await clipAgent { clipboardAgentState = c }
    }

    private func fetch<R>(_ method: String, _ call: () async throws -> R) async -> R? {
        do {
            return try await call()
        } catch {
            log.error("\(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Internal helpers

    private func rpcCall<R: Decodable & Sendable>(
        method: String,
        params: some Encodable & Sendable = EmptyParams()
    ) async throws -> R {
        guard let rpc, rpcReady else { throw SessionError.rpcNotReady }
        return try await rpc.call(method: method, params: params)
    }

    /// Convenience for void-result methods. Same plumbing as
    /// `rpcCall`, but uses `VoidValue` so the caller doesn't have to
    /// type-annotate the throwaway result. JSONRPCClient.call's
    /// short-circuit handles JetKVM responses that omit the `result`
    /// key entirely (which is what void methods return).
    private func rpcCallVoid(
        method: String,
        params: some Encodable & Sendable = EmptyParams()
    ) async throws {
        guard let rpc, rpcReady else { throw SessionError.rpcNotReady }
        let _: VoidValue = try await rpc.call(method: method, params: params)
    }
}
