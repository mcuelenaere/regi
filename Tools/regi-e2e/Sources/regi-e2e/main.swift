import Foundation
import ProbeKit
import RegiE2ECore

func value(_ name: String, _ def: String) -> String {
    guard let a = CommandLine.arguments.first(where: { $0.hasPrefix("--\(name)=") }) else { return def }
    return String(a.dropFirst(name.count + 3))
}
func intValue(_ name: String, _ def: Int) -> Int { Int(value(name, "")) ?? def }

let usage = """
regi-e2e — drives Regi and reads the probe's telemetry back over the KVM's video.

  regi-e2e watch [--window=Regi] [--interval=250] [--limit=0]
      Continuously decode the probe's QR telemetry from Regi's window and print
      events as they arrive. --limit stops after N reads (0 = forever).

  regi-e2e doctor [--window=Regi]
      One capture, reporting decode health and the probe's own readiness.

Requires Screen Recording permission for whatever runs this binary.
"""

func renderHealth(_ h: TelemetryFrame.Health) -> String {
    var parts: [String] = []
    parts.append(h.tapEnabled ? "tap:on" : "tap:OFF")
    parts.append(h.runActive ? "run:active" : "run:IDLE")
    if !h.accessibilityGranted { parts.append("accessibility:MISSING") }
    if !h.secureInputHolder.isEmpty { parts.append("secureInput:\(h.secureInputHolder)") }
    return parts.joined(separator: "  ")
}

func renderCounters(_ c: InvariantCounters) -> String {
    var parts: [String] = []
    if c.upWithoutDown > 0 { parts.append("upWithoutDown:\(c.upWithoutDown)") }
    if c.duplicateDown > 0 { parts.append("duplicateDown:\(c.duplicateDown)") }
    if c.syntheticSourceEvents > 0 { parts.append("injected:\(c.syntheticSourceEvents)") }
    if c.droppedByRing > 0 { parts.append("droppedByRing:\(c.droppedByRing)") }
    return parts.isEmpty ? "clean" : parts.joined(separator: "  ")
}

func doctor(window: String) async {
    let reader = VideoReader(windowName: window)
    do {
        let w = try await reader.findWindow()
        print("window     : \"\(w.title ?? "")\" (\(w.owningApplication?.applicationName ?? "?"))"
              + "  \(Int(w.frame.width))x\(Int(w.frame.height)) pt")
        let cap = try await reader.read(from: w)
        print("capture    : \(String(format: "%.0fms", cap.millis)), \(Int(cap.capturePixelWidth)) px wide")
        if let ppm = cap.pixelsPerModule {
            let verdict = ppm >= 4 ? "OK" : (ppm >= 3 ? "MARGINAL" : "TOO SMALL")
            print("QR module  : \(String(format: "%.2f", ppm)) captured px  [\(verdict), want >= 4]")
        }
        print("probe      : \(renderHealth(cap.frame.health))")
        print("invariants : \(renderCounters(cap.frame.counters))")
        print("frame      : #\(cap.frame.frameIndex), \(cap.frame.events.count) events, "
              + "seq \(cap.frame.oldestSeqInWindow)…\(cap.frame.latestSeq)")
        if !cap.frame.heldKeys.isEmpty {
            print("held       : \(cap.frame.heldKeys.map(KeyLabels.label).joined(separator: " "))")
        }
        if !cap.frame.health.isUsable {
            print("\nNOT READY — the probe cannot record reliably in this state.")
            exit(1)
        }
    } catch {
        print("FAILED: \(error)")
        exit(2)
    }
}

func watch(window: String, intervalMillis: Int, limit: Int) async {
    let reader = VideoReader(windowName: window)
    var acc = TelemetryAccumulator()
    var reads = 0, failures = 0
    var lastHealth: String?

    guard let w = try? await reader.findWindow() else {
        print("FAILED: \(VideoReader.ReadError.noMatchingWindow(window))")
        exit(2)
    }
    print("watching \"\(w.title ?? "")\" (\(w.owningApplication?.applicationName ?? "?")) — ^C to stop\n")

    while limit == 0 || reads < limit {
        reads += 1
        do {
            let cap = try await reader.read(from: w)
            let health = renderHealth(cap.frame.health)
            if health != lastHealth {
                print("── probe: \(health)"
                      + (cap.pixelsPerModule.map { String(format: "   %.2f px/module", $0) } ?? ""))
                lastHealth = health
            }
            for e in try acc.ingest(cap.frame) {
                print(String(format: "%8d  %-7s %@", e.seq,
                             (e.kindLabel as NSString).utf8String!, e.detail))
            }
            failures = 0
        } catch let fault as TelemetryAccumulator.Fault {
            print("\n\(fault)\n")
            exit(3)
        } catch {
            failures += 1
            // A transient miss is expected: the probe swaps codes on a dwell
            // timer and a capture can land mid-swap. A sustained run of them is
            // not, and silence would look identical to "nothing is happening".
            if failures == 1 || failures % 12 == 0 {
                print("read failed (\(failures)x): \(error)")
            }
        }
        if intervalMillis > 0 {
            try? await Task.sleep(nanoseconds: UInt64(intervalMillis) * 1_000_000)
        }
    }
    print("\n\(acc.totalEvents) events over \(reads) reads")
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch mode {
case "watch":
    await watch(window: value("window", "Regi"),
                intervalMillis: intValue("interval", 250),
                limit: intValue("limit", 0))
case "doctor":
    await doctor(window: value("window", "Regi"))
default:
    print(usage)
}
