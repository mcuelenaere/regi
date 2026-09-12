import AppKit
import CoreGraphics
import Foundation
import ProbeKit
import ScreenCaptureKit

/// Executes scenarios against the rig and judges them.
///
/// There is no channel to the probe, so a scenario is scoped by *reading*
/// rather than by writing a marker: note the newest sequence number before
/// injecting, inject, wait for the stream to go quiet, then assert over
/// everything that arrived after that number.
///
/// Because of that, the probe being quiet between scenarios is load-bearing
/// rather than merely tidy — anything still arriving belongs to the previous
/// scenario and would be attributed to the next one.
public final class ScenarioRunner {
    public struct Outcome {
        public let scenario: Scenario
        public let passed: Bool
        public let quarantined: Bool
        public let checks: [(expectation: Expectation, result: ExpectationEvaluator.Result)]
        public let events: [ProbeEvent]
        public let failure: String?
        public let duration: TimeInterval
    }

    private let reader: VideoReader
    private let regiWindow: SCWindow
    private let driver: AXDriver
    private let injector: OSInjector
    public let geometry: VideoGeometry

    /// Modifiers this runner currently holds down.
    ///
    /// A flagsChanged event describes the state of the *whole* keyboard, not
    /// just the key that moved. Sending `flags: 0` to release one modifier
    /// therefore claims they are all up, and the target released the others
    /// too — which is how `modifiers.bothSides` failed.
    private var heldModifiers: Set<UInt16> = []

    public init(reader: VideoReader, regiWindow: SCWindow, driver: AXDriver) throws {
        self.reader = reader
        self.regiWindow = regiWindow
        self.driver = driver
        self.geometry = try driver.videoGeometry()
        self.injector = OSInjector(geometry: geometry)
        // Window-relative, so the reader can crop the screenshot to the video.
        reader.videoRectInWindow = CGRect(
            x: geometry.viewFrame.minX - regiWindow.frame.minX,
            y: geometry.viewFrame.minY - regiWindow.frame.minY,
            width: geometry.viewFrame.width, height: geometry.viewFrame.height)
    }

    public func run(_ scenario: Scenario) async -> Outcome {
        let started = Date()
        heldModifiers.removeAll()
        var accumulator = TelemetryAccumulator()
        var collected: [ProbeEvent] = []
        var checks: [(Expectation, ExpectationEvaluator.Result)] = []

        // Start from the current tip. Anything already in the probe's window
        // belongs to whatever happened before this scenario.
        // Individual reads miss a few percent of the time (the probe swaps
        // codes on a dwell timer and a capture can land mid-swap). For a
        // measurement that is fine; for the precondition that establishes the
        // baseline it is not, so retry rather than fail the scenario.
        var opening: VideoReader.Capture?
        for attempt in 0..<6 {
            if let cap = try? await reader.read(from: regiWindow) { opening = cap; break }
            if attempt < 5 { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard let opening else {
            return Outcome(scenario: scenario, passed: false, quarantined: scenario.quarantined,
                           checks: [], events: [],
                           failure: "no telemetry after 6 attempts — is the probe's run window up?",
                           duration: Date().timeIntervalSince(started))
        }
        _ = try? accumulator.ingest(opening.frame)
        let baseline = opening.frame.latestSeq

        for step in scenario.steps {
            switch step {
            case .expect(let expectation):
                let result = ExpectationEvaluator.evaluate(expectation, over: collected)
                checks.append((expectation, result))
            default:
                do {
                    try await perform(step, accumulator: &accumulator, collected: &collected,
                                      baseline: baseline)
                } catch {
                    return Outcome(scenario: scenario, passed: false,
                                   quarantined: scenario.quarantined, checks: checks,
                                   events: collected, failure: "\(error)",
                                   duration: Date().timeIntervalSince(started))
                }
            }
        }

        let passed = checks.allSatisfy(\.1.passed)
        return Outcome(scenario: scenario, passed: passed, quarantined: scenario.quarantined,
                       checks: checks, events: collected, failure: nil,
                       duration: Date().timeIntervalSince(started))
    }

    private func perform(_ step: Step, accumulator: inout TelemetryAccumulator,
                         collected: inout [ProbeEvent], baseline: UInt64) async throws {
        switch step {
        case .key(let kvk, let action):
            switch action {
            case .down: injector.key(CGKeyCode(kvk), down: true)
            case .up:   injector.key(CGKeyCode(kvk), down: false)
            case .tap(let hold):
                injector.tap(CGKeyCode(kvk), hold: Double(hold) / 1000)
            }

        case .modifier(let kvk, let down):
            if down { heldModifiers.insert(kvk) } else { heldModifiers.remove(kvk) }
            // Compose the flags from everything still held, not just this key.
            var raw: UInt64 = 0
            for held in heldModifiers {
                raw |= deviceBit(for: held) | coarseMask(for: held)
            }
            injector.modifier(CGKeyCode(kvk), flags: CGEventFlags(rawValue: raw))

        case .type(let text):
            for ch in text {
                guard let kvk = Self.keyCode(for: ch) else { continue }
                injector.tap(CGKeyCode(kvk))
            }

        case .moveTo(let x, let y):
            injector.glide(to: CGPoint(x: x, y: y),
                           from: CGPoint(x: x - 60, y: y - 40), steps: 5)

        case .click(let button, let x, let y, let count):
            injector.click(at: CGPoint(x: x, y: y),
                           button: button == .left ? .left : .right, count: count)

        case .drag(let fx, let fy, let tx, let ty, let steps):
            injector.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), steps: steps)

        case .buttonDown(let button, let x, let y):
            injector.buttonDown(at: CGPoint(x: x, y: y),
                                button: button == .left ? .left : .right)

        case .buttonUp(let button, let x, let y):
            injector.buttonUp(at: CGPoint(x: x, y: y),
                              button: button == .left ? .left : .right)

        case .sideButton(let number, let x, let y, let down):
            injector.sideButton(at: CGPoint(x: x, y: y), number: number, down: down)

        case .scroll(let axis, let lines):
            injector.scroll(lines: lines, horizontal: axis == .horizontal)

        case .autorepeat(let kvk, let count, let interval):
            injector.autorepeat(CGKeyCode(kvk), count: count, intervalMillis: interval)

        case .focusRegi:
            driver.activate()
            try? await Task.sleep(nanoseconds: 500_000_000)

        case .focusElsewhere:
            // Deliberately a real focus change: this is what makes Regi's
            // resign-active path fire, which is where stuck modifiers come from.
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.finder" }?
                .activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 800_000_000)

        case .wait(let millis):
            try? await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)

        case .settle(let quietMillis, let maxMillis):
            try await settle(quietMillis: quietMillis, maxMillis: maxMillis,
                             accumulator: &accumulator, collected: &collected,
                             baseline: baseline)

        case .expect:
            break   // handled by the caller
        }
    }

    /// Wait until the probe has stopped producing new events.
    ///
    /// Wall-clock silence is not enough on its own. Telemetry lags the actual
    /// event by the video path plus the probe's dwell interval — roughly
    /// 300-500ms — so a scenario ending in a *single* event (one wheel detent)
    /// would see earlier traffic stop, sit quiet for `quietMillis`, and exit
    /// before the event ever surfaced. That produced wheel scenarios which
    /// failed in a full run and passed in isolation, where the preceding run's
    /// traffic happened to keep the stream alive.
    ///
    /// So quiet is only counted after enough *frames* have gone by for anything
    /// in flight to have appeared: each frame covers one dwell interval, and
    /// the probe cannot show a change sooner than that.
    private func settle(quietMillis: Int, maxMillis: Int,
                        accumulator: inout TelemetryAccumulator,
                        collected: inout [ProbeEvent], baseline: UInt64) async throws {
        let deadline = Date().addingTimeInterval(Double(maxMillis) / 1000)
        var lastChange = Date()
        var lastSeq = accumulator.lastSeqSeen
        var framesSeen = 0
        var lastFrameIndex = accumulator.lastFrameIndex

        while Date() < deadline {
            if let cap = try? await reader.read(from: regiWindow) {
                if cap.frame.frameIndex != lastFrameIndex {
                    lastFrameIndex = cap.frame.frameIndex
                    framesSeen += 1
                }
                let fresh = try accumulator.ingest(cap.frame)
                collected.append(contentsOf: fresh.filter { $0.seq > baseline })
                if accumulator.lastSeqSeen != lastSeq {
                    lastSeq = accumulator.lastSeqSeen
                    lastChange = Date()
                    framesSeen = 0      // something arrived; start counting again
                }
            }
            let quietLongEnough = Date().timeIntervalSince(lastChange) * 1000 >= Double(quietMillis)
            if quietLongEnough, framesSeen >= Self.minimumQuietFrames { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Distinct telemetry frames that must pass with no new events before the
    /// stream counts as quiet. Three covers the probe's dwell plus a missed
    /// read or two, which happen at a few percent.
    static let minimumQuietFrames = 3

    // MARK: - Flag helpers

    private func deviceBit(for kvk: UInt16) -> UInt64 {
        switch kvk {
        case 0x3B: return 0x1
        case 0x38: return 0x2
        case 0x3C: return 0x4
        case 0x37: return 0x8
        case 0x36: return 0x10
        case 0x3A: return 0x20
        case 0x3D: return 0x40
        case 0x3E: return 0x2000
        default:   return 0
        }
    }

    private func coarseMask(for kvk: UInt16) -> UInt64 {
        switch kvk {
        case 0x3B, 0x3E: return CGEventFlags.maskControl.rawValue
        case 0x38, 0x3C: return CGEventFlags.maskShift.rawValue
        case 0x3A, 0x3D: return CGEventFlags.maskAlternate.rawValue
        case 0x37, 0x36: return CGEventFlags.maskCommand.rawValue
        default:         return 0
        }
    }

    static func keyCode(for character: Character) -> UInt16? {
        KeyLabels.named.first { $0.value.lowercased() == String(character).lowercased() }?.key
    }
}
