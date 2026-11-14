// SPDX-License-Identifier: AGPL-3.0-or-later

import KVMCore
import AppKit
import WebRTC

/// Renders a WebRTC video track (JetKVM/PiKVM) into an `RTCMTLNSVideoView`
/// (VideoToolbox-backed hardware decode + Metal rendering). The backend owns
/// this and exposes it as `videoRenderer`; the App embeds `view`.
///
/// Extracted from the App's former `attach(track:)` path so WebRTC stays out
/// of `KVMCore` and the App target — the host view sees only a `KVMVideoRenderer`.
@MainActor
public final class WebRTCVideoRenderer: NSObject, KVMVideoRenderer {
    public var view: NSView { metalView }
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    private let track: RTCVideoTrack
    private let metalView = RTCMTLNSVideoView(frame: .zero)
    private let tap = FrameTap()

    public init(track: RTCVideoTrack) {
        self.track = track
        super.init()
        metalView.translatesAutoresizingMaskIntoConstraints = false
        // Become the delegate so didChangeVideoSize fires and the host can
        // track the source's aspect ratio for coordinate translation.
        metalView.delegate = self
        track.add(metalView)
        // A second sink on the same track: it only swaps a reference per
        // frame, so the Metal view's path is untouched.
        track.add(tap)
    }

    public func latestFrame() -> CVPixelBuffer? { tap.latest }

    public func detach() {
        track.remove(metalView)
        track.remove(tap)
    }
}

extension WebRTCVideoRenderer: RTCVideoViewDelegate {
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        onVideoSizeChanged?(size)
    }
}

/// Keeps the newest decoded frame for `latestFrame()`. WebRTC calls
/// `renderFrame` on its decode thread, hence the lock.
private final class FrameTap: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    // ponytail: only the VideoToolbox path (RTCCVPixelBuffer) is kept; a
    // software-decoded I420 frame leaves the previous one in place.
    var latest: CVPixelBuffer? { lock.withLock { buffer } }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let pixels = (frame?.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        lock.withLock { buffer = pixels }
    }
}
