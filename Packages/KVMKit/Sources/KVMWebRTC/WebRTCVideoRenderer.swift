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

    public init(track: RTCVideoTrack) {
        self.track = track
        super.init()
        metalView.translatesAutoresizingMaskIntoConstraints = false
        // Become the delegate so didChangeVideoSize fires and the host can
        // track the source's aspect ratio for coordinate translation.
        metalView.delegate = self
        track.add(metalView)
    }

    public func detach() {
        track.remove(metalView)
    }
}

extension WebRTCVideoRenderer: RTCVideoViewDelegate {
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        onVideoSizeChanged?(size)
    }
}
