import AppKit
import Foundation
import Observation
import ProbeKit

/// Everything the UI observes, refreshed on a timer rather than per event.
///
/// At high mouse-report rates, invalidating SwiftUI once per event would melt
/// the main thread — and because the tap has a hard callback timeout, that
/// could indirectly get the tap disabled. So the capture path only appends to
/// the ring, and the UI samples it.
@MainActor
@Observable
final class ProbeModel {
    static let uiRefresh: TimeInterval = 1.0 / 60.0

    // Not observable: these are machinery the UI never reads directly, and
    // @Observable rejects `lazy` anyway.
    @ObservationIgnored let ring = ProbeEventRing()
    @ObservationIgnored let capture: ProbeCaptureThread
    @ObservationIgnored let renderer: TelemetryRenderer

    init() {
        capture = ProbeCaptureThread(ring: ring)
        renderer = TelemetryRenderer(ring: ring)
    }

    // Observed by the UI
    private(set) var accessibilityGranted = false
    private(set) var secureInputHolder: String?
    private(set) var captureState: ProbeCaptureThread.State = .idle
    private(set) var runActive = false

    private(set) var heldKeys: Set<UInt16> = []
    private(set) var counters = InvariantCounters()
    private(set) var violations: [Violation] = []
    private(set) var recentEvents: [ProbeEvent] = []
    private(set) var pointerTrail: [CGPoint] = []
    /// kVK -> seconds since that key last produced an event, for the decay glow.
    /// Without this a tap-and-release is invisible: the key is held for a few
    /// milliseconds and `heldKeys` never shows it.
    private(set) var keyRecency: [UInt16: Double] = [:]

    private(set) var qrImage: NSImage?
    private(set) var qrModules = 0
    private(set) var qrBytes = 0
    private(set) var qrEvents = 0
    private(set) var framesRendered: UInt32 = 0

    private var uiTimer: Timer?
    private var qrTimer: Timer?
    private var permissionTimer: Timer?

    var health: TelemetryFrame.Health {
        .init(tapEnabled: captureState == .running,
              runActive: runActive,
              accessibilityGranted: accessibilityGranted,
              secureInputHolder: secureInputHolder ?? "")
    }

    /// Why a run cannot start right now, or nil when it can.
    var blocker: String? {
        if let holder = secureInputHolder {
            return "Secure Input is held by \(holder). Every tap in this session is "
                + "starved, so a run would silently record nothing."
        }
        if !accessibilityGranted { return "Accessibility permission is not granted." }
        if case .failed(let m) = captureState { return m }
        return nil
    }

    func startMonitoring() {
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: Self.uiRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleForUI() }
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        secureInputHolder = SecureInputMonitor.holder()

        // Start the tap as soon as it is possible; the run window only controls
        // swallowing, not recording, so the visualization works while idle too.
        if accessibilityGranted, secureInputHolder == nil, captureState == .idle {
            do { try capture.start() } catch { captureState = .failed("\(error)") }
        }
        if case .failed = captureState {} else { captureState = capture.state }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func sampleForUI() {
        let (events, _, dropped) = ring.recent(300)
        var tracker = HeldStateTracker()
        for e in events { tracker.ingest(e) }
        var c = tracker.counters
        c.droppedByRing = dropped

        heldKeys = Set(tracker.heldKeys.keys)
        counters = c
        violations = Array(tracker.violations.suffix(20))
        recentEvents = Array(events.suffix(60).reversed())
        pointerTrail = events.suffix(120).compactMap {
            if case .pointer(let p) = $0.payload { return CGPoint(x: Int(p.x), y: Int(p.y)) }
            return nil
        }

        let now = MachClock.absoluteNanos()
        var recency: [UInt16: Double] = [:]
        for e in events.suffix(120) {
            let kvk: UInt16?
            switch e.payload {
            case .key(let k):   kvk = k.kvk
            case .flags(let f): kvk = f.kvk
            default:            kvk = nil
            }
            guard let kvk, now >= e.machAbsoluteNanos else { continue }
            let age = Double(now - e.machAbsoluteNanos) / 1_000_000_000
            recency[kvk] = min(recency[kvk] ?? .greatestFiniteMagnitude, age)
        }
        keyRecency = recency.filter { $0.value < 1.0 }
    }

    // MARK: - Run lifecycle (window lifetime == shield lifetime)

    func beginRun() {
        guard blocker == nil else { return }
        runActive = true
        capture.swallowKeyboard = true
        ring.append(machAbsoluteNanos: MachClock.absoluteNanos(),
                    payload: .diagnostic(.init(kind: .runWindowOpened)))
        qrTimer = Timer.scheduledTimer(withTimeInterval: TelemetryRenderer.dwell, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTelemetry() }
        }
        renderTelemetry()
    }

    func endRun() {
        guard runActive else { return }
        runActive = false
        capture.swallowKeyboard = false
        qrTimer?.invalidate(); qrTimer = nil
        ring.append(machAbsoluteNanos: MachClock.absoluteNanos(),
                    payload: .diagnostic(.init(kind: .runWindowClosed)))
    }

    private func renderTelemetry() {
        guard let r = renderer.render(health: health, sidePoints: 0) else { return }
        qrImage = r.image
        qrModules = r.modulesAcross
        qrBytes = r.byteCount
        qrEvents = r.eventCount
        framesRendered &+= 1
    }
}
