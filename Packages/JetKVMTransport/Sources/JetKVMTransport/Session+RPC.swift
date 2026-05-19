import Foundation
import JetKVMProtocol
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "session")

/// Typed wrappers for the JSON-RPC methods the control plane needs.
///
/// All methods are gated on `rpcReady` — calling before the channel
/// has fully opened throws `SessionError.rpcNotReady` rather than
/// hanging waiting for a response that can't ride the channel.
extension Session {

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

    // MARK: - Video codec preference

    public func getVideoCodecPreference() async throws -> VideoCodecPreference {
        try await rpcCall(method: "getVideoCodecPreference")
    }

    public func setVideoCodecPreference(_ codec: VideoCodecPreference) async throws {
        struct Params: Encodable, Sendable { let codec: String }
        try await rpcCallVoid(method: "setVideoCodecPreference", params: Params(codec: codec.rawValue))
    }

    // MARK: - Stream quality

    public func getStreamQualityFactor() async throws -> Double {
        try await rpcCall(method: "getStreamQualityFactor")
    }

    public func setStreamQualityFactor(_ factor: Double) async throws {
        struct Params: Encodable, Sendable { let factor: Double }
        try await rpcCallVoid(method: "setStreamQualityFactor", params: Params(factor: factor))
    }

    // MARK: - Pause / resume video stream
    //
    // Lets the client gate WebRTC RTP traffic to keepalive levels
    // without renegotiating the session, e.g. when the KVM window
    // is occluded or minimized. The server pauses encoder feed and
    // forces an IDR on resume so the decoder never sees half-dependent
    // frames. Both calls are idempotent server-side.

    public func pauseVideoRPC() async throws {
        try await rpcCallVoid(method: "pauseVideo")
    }

    public func resumeVideoRPC() async throws {
        try await rpcCallVoid(method: "resumeVideo")
    }

    // MARK: - Scroll wheel
    //
    // Scroll lives on the JSON-RPC channel rather than the binary
    // HID-RPC channel: the server's `wheelReport` method funnels
    // wheelY/wheelX into the same `gadget.{Abs,Rel}MouseWheelReport`
    // HID gadget call the keyboard / mouse paths use. Notify (no
    // response) so we don't pay a round-trip per scroll event.

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
        async let codec = fetch("getVideoCodecPreference") { try await self.getVideoCodecPreference() }
        async let clipAgent = fetch("getClipboardAgentState") { try await self.getClipboardAgentState() }

        videoState = await video
        usbState = await usb
        atxState = await atx
        streamQualityFactor = await factor
        videoCodecPreference = await codec
        if let c = await clipAgent { clipboardAgentState = c }
    }

    /// Optimistically update the cached factor and send the setter.
    /// On failure, refresh from the server to restore truth.
    public func updateStreamQualityFactor(_ factor: Double) async {
        streamQualityFactor = factor
        do {
            try await setStreamQualityFactor(factor)
        } catch {
            log.error("setStreamQualityFactor(\(factor, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
            streamQualityFactor = await fetch("getStreamQualityFactor") {
                try await self.getStreamQualityFactor()
            }
        }
    }

    public func updateVideoCodecPreference(_ codec: VideoCodecPreference) async {
        videoCodecPreference = codec
        do {
            try await setVideoCodecPreference(codec)
        } catch {
            log.error("setVideoCodecPreference(\(codec.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
            videoCodecPreference = await fetch("getVideoCodecPreference") {
                try await self.getVideoCodecPreference()
            }
        }
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
