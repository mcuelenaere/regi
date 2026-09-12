import Foundation

/// One rendered QR code's worth of telemetry.
///
/// `events` is a **sliding window of the most recent N**, not an incremental
/// delta. Any single successful decode therefore yields the last N events, so
/// the driver needs one good read per N events rather than every frame — which
/// step 0 showed is essential: at a 200 ms read interval the frame index
/// advances 2-3 per read, so frames genuinely are missed.
public struct TelemetryFrame: Sendable, Equatable {
    public var wireVersion: UInt32
    /// Bumped when the probe relaunches. A change mid-run means the event
    /// sequence restarted, so the driver must fail the run rather than splice.
    public var epoch: UInt32
    /// Monotonic; advances when content changes. Lets the driver skip re-reads
    /// of a code it already has.
    public var frameIndex: UInt32
    public var probeMonotonicNanos: UInt64
    /// If the driver's last-seen seq is older than this, events fell out of the
    /// window and evidence was lost: **fail the run, never pass it**.
    public var oldestSeqInWindow: UInt64
    public var health: Health
    public var counters: InvariantCounters
    public var heldKeys: [UInt16]
    public var screen: ScreenInfo?
    public var events: [ProbeEvent]

    public init(wireVersion: UInt32 = WireVersion.current,
                epoch: UInt32, frameIndex: UInt32, probeMonotonicNanos: UInt64,
                oldestSeqInWindow: UInt64, health: Health,
                counters: InvariantCounters = .init(), heldKeys: [UInt16] = [],
                screen: ScreenInfo? = nil, events: [ProbeEvent]) {
        self.wireVersion = wireVersion; self.epoch = epoch
        self.frameIndex = frameIndex; self.probeMonotonicNanos = probeMonotonicNanos
        self.oldestSeqInWindow = oldestSeqInWindow; self.health = health
        self.counters = counters; self.heldKeys = heldKeys
        self.screen = screen; self.events = events
    }

    public var latestSeq: UInt64 { events.last?.seq ?? oldestSeqInWindow }

    public struct Health: Sendable, Equatable {
        public var tapEnabled: Bool
        public var runActive: Bool
        public var accessibilityGranted: Bool
        /// Non-empty means Secure Input is engaged, which starves every tap in
        /// the session while `tapCreate` still reports healthy. The run is
        /// invalid — the driver must abort rather than report phantom
        /// "key never arrived" failures.
        public var secureInputHolder: String

        public init(tapEnabled: Bool = false, runActive: Bool = false,
                    accessibilityGranted: Bool = false, secureInputHolder: String = "") {
            self.tapEnabled = tapEnabled; self.runActive = runActive
            self.accessibilityGranted = accessibilityGranted
            self.secureInputHolder = secureInputHolder
        }

        public var isUsable: Bool {
            tapEnabled && accessibilityGranted && secureInputHolder.isEmpty
        }
    }

    public struct ScreenInfo: Sendable, Equatable {
        public var originX: Int32, originY: Int32
        public var width: UInt32, height: UInt32
        public var backingScale: Float

        public init(originX: Int32, originY: Int32, width: UInt32, height: UInt32, backingScale: Float) {
            self.originX = originX; self.originY = originY
            self.width = width; self.height = height; self.backingScale = backingScale
        }
    }
}
