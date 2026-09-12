import CoreGraphics
import Foundation
import ProbeKit
import RegiE2ECore

func value(_ name: String, _ def: String) -> String {
    guard let a = CommandLine.arguments.first(where: { $0.hasPrefix("--\(name)=") }) else { return def }
    return String(a.dropFirst(name.count + 3))
}
func intValue(_ name: String, _ def: Int) -> Int { Int(value(name, "")) ?? def }

/// "1680x1050", or "0" to leave the window alone.
func parseSize(_ text: String) -> CGSize {
    let parts = text.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
        return .zero
    }
    return CGSize(width: w, height: h)
}

// Line-buffer stdout.
//
// `print` block-buffers when stdout is a file rather than a terminal, so a
// redirected `watch` that is stopped with a signal loses whatever is still in
// the buffer -- which for a short recording is all of it. Several captures of
// a hard-to-reproduce bug came back empty that way, each one costing a
// reproduction that had to be done by hand.
setvbuf(stdout, nil, _IOLBF, 0)

/// `--raw` appends each pointer event's CGEventType and button number, for
/// when the question is whether the *naming* is right rather than what
/// happened.
let showRaw = CommandLine.arguments.contains("--raw")


let usage = """
regi-e2e — drives Regi and reads the probe's telemetry back over the KVM's video.

  regi-e2e watch [--window=Regi] [--interval=250] [--limit=0] [--raw]
      Continuously decode the probe's QR telemetry from Regi's window and print
      events as they arrive. --limit stops after N reads (0 = forever).

  regi-e2e doctor [--window=Regi]
      One capture, reporting decode health and the probe's own readiness,
      plus every accessibility identifier and the derived video geometry.

  regi-e2e list
      The scenario catalogue.

  regi-e2e schema
      The scenario file format and authoring vocabulary.

  regi-e2e export
      The built-in catalogue as JSON — worked examples in that format.

  regi-e2e run [--window=Regi] [--scenario=SUBSTRING] [--tag=TAG] [--scenarios=FILE]
               [--window-size=1680x1050]
      --window-size fixes Regi's window before running, because both QR
      legibility and pointer accuracy depend on it. Pass 0 to leave it.
      Run scenarios against the rig. Quarantined failures are reported but
      do not affect the exit code.

  regi-e2e pointer-check [--window=Regi] [--tolerance=2]
      Drive the pointer to known framebuffer pixels and verify where the
      target says it landed. End-to-end check on the coordinate path.

Requires Screen Recording permission for whatever runs this binary.
"""

extension String {
    /// Pads by CHARACTERS. `String(format:"%-7s")` pads by bytes and re-decodes
    /// the C string in the system encoding, which turned "key↓" into "key‚Üì".
    func rightPadded(to n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
    func leftPadded(to n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}

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

/// Cumulative totals of what the target received. Printed separately from the
/// violations because on their own they say nothing — they are only meaningful
/// held against what the client reports sending.
func renderTotals(_ c: InvariantCounters) -> String {
    "buttons \(c.buttonDowns)↓/\(c.buttonUps)↑   keys \(c.keyDowns)↓/\(c.keyUps)↑"
}

/// Resolving every identifier is the drift check: the CLI and the app keep
/// separate copies of these strings, so a UI refactor that drops one has to
/// fail loudly here rather than as a mysterious scenario failure later.
func checkAccessibility(_ failures: inout Int) {
    print("\n── Regi (accessibility) ──")
    do {
        let driver = try AXDriver()
        print("app        : pid \(driver.pid)")
        var missing: [String] = []
        for id in AXID.alwaysPresentInSession {
            let ok = driver.exists(id)
            print("  \(ok ? "✓" : "✗") \(id)")
            if !ok { missing.append(id) }
        }
        if !missing.isEmpty {
            print("\(missing.count) identifier(s) missing — is a session window open?")
            print("If one is open, a UI change dropped them: see App/AXIdentifiers.swift")
            failures += 1
            return
        }
        let g = try driver.videoGeometry()
        print("video view : \(Int(g.viewFrame.width))x\(Int(g.viewFrame.height)) pt "
              + "at (\(Int(g.viewFrame.minX)),\(Int(g.viewFrame.minY)))")
        print("source     : \(Int(g.sourceSize.width))x\(Int(g.sourceSize.height)) px")
        let c = g.contentRect
        print("content    : \(Int(c.width))x\(Int(c.height)) pt at (\(Int(c.minX)),\(Int(c.minY)))"
              + "  [letterbox derived independently of Regi]")
        print(String(format: "accuracy   : %.2f framebuffer px per screen point "
                     + "— the floor on pointer assertions", g.pixelsPerPoint))
        let centre = g.screenPoint(forFramebufferPixel: CGPoint(x: 959.5, y: 539.5))
        print("centre px  : (960,540) -> screen (\(Int(centre.x)),\(Int(centre.y)))")
    } catch {
        print("FAILED     : \(error)")
        failures += 1
    }
}

func doctor(window: String) async {
    // The two halves are reported independently on purpose: the accessibility
    // checks are exactly what you need when the telemetry side is broken, so
    // one failing must not hide the other.
    var failures = 0

    print("── telemetry (probe, via Regi's video) ──")
    let reader = VideoReader(windowName: window)
    do {
        let w = try await reader.findWindow()
        print("window     : \"\(w.title ?? "")\" (\(w.owningApplication?.applicationName ?? "?"))"
              + "  \(Int(w.frame.width))x\(Int(w.frame.height)) pt")
        // Match what `run` does, or doctor reports a different verdict.
        if let driver = try? AXDriver(), let g = try? driver.videoGeometry() {
            reader.videoRectInWindow = CGRect(x: g.viewFrame.minX - w.frame.minX,
                                              y: g.viewFrame.minY - w.frame.minY,
                                              width: g.viewFrame.width, height: g.viewFrame.height)
        }
        let cap = try await reader.read(from: w)
        print("capture    : \(String(format: "%.0fms", cap.millis)), \(Int(cap.capturePixelWidth)) px wide")
        if let ppm = cap.pixelsPerModule {
            let verdict = ppm >= 4 ? "OK" : (ppm >= 3 ? "MARGINAL" : "TOO SMALL")
            print("QR module  : >= \(String(format: "%.2f", ppm)) captured px  [\(verdict), want >= 4]"
                  + "  (lower bound: assumes the largest symbol)")
            if ppm < 3 {
                // Reads will fail intermittently from here, which surfaces as
                // flaky scenarios rather than as an obvious cause. Fail now.
                print("             enlarge Regi's window: the band arrives scaled by "
                      + "window size, and below ~3 px/module Vision stops finding it")
                failures += 1
            }
        }
        print("probe      : \(renderHealth(cap.frame.health))")
        print("invariants : \(renderCounters(cap.frame.counters))")
        print("received   : \(renderTotals(cap.frame.counters))")
        print("frame      : #\(cap.frame.frameIndex), \(cap.frame.events.count) events, "
              + "seq \(cap.frame.oldestSeqInWindow)…\(cap.frame.latestSeq)")
        if !cap.frame.heldKeys.isEmpty {
            print("held       : \(cap.frame.heldKeys.map(KeyLabels.label).joined(separator: " "))")
        }
        if !cap.frame.health.isUsable {
            print("NOT READY  : the probe cannot record reliably in this state")
            failures += 1
        }
    } catch {
        print("FAILED     : \(error)")
        failures += 1
    }

    checkAccessibility(&failures)

    print("")
    if failures == 0 {
        print("all checks passed")
    } else {
        print("\(failures) check(s) failed")
        exit(1)
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
                let seq = String(e.seq).leftPadded(to: 8)
                let kind = e.kindLabel.rightPadded(to: 7)
                print("\(seq)  \(kind) \(showRaw ? e.rawDetail : e.detail)")
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

/// Drives the pointer to known framebuffer pixels and reports where the target
/// says it landed. This is the end-to-end check on the coordinate path:
/// AXFrame -> letterbox -> screen point -> Regi -> KVM -> target.
func pointerCheck(window: String, tolerance: Int) async {
    let reader = VideoReader(windowName: window)
    guard let regiWindow = try? await reader.findWindow() else {
        print("FAILED: Regi window not found"); exit(2)
    }
    let driver: AXDriver
    let geometry: VideoGeometry
    do {
        driver = try AXDriver()
        geometry = try driver.videoGeometry()
    } catch {
        print("FAILED: \(error)"); exit(2)
    }
    print("geometry   : content \(Int(geometry.contentRect.width))x\(Int(geometry.contentRect.height))"
          + " pt at (\(Int(geometry.contentRect.minX)),\(Int(geometry.contentRect.minY)))")
    print(String(format: "accuracy   : %.2f framebuffer px per screen point, tolerance %d px\n",
                 geometry.pixelsPerPoint, tolerance))

    let injector = OSInjector(geometry: geometry)
    driver.activate()
    try? await Task.sleep(nanoseconds: 600_000_000)

    let targets: [(String, CGPoint)] = [
        ("centre",      CGPoint(x: 960, y: 540)),
        ("upper-left",  CGPoint(x: 480, y: 270)),
        ("lower-right", CGPoint(x: 1440, y: 810)),
        ("near-origin", CGPoint(x: 40, y: 40)),
    ]

    var failures = 0
    for (name, want) in targets {
        // A short glide, then settle: motion is throttled at 8ms in the
        // backends, so the last position is what matters, not the count.
        injector.glide(to: want, from: CGPoint(x: want.x - 60, y: want.y - 40), steps: 5)
        try? await Task.sleep(nanoseconds: 500_000_000)

        guard let cap = try? await reader.read(from: regiWindow) else {
            print("  \(name): could not read telemetry"); failures += 1; continue
        }
        let lastPointer = cap.frame.events.reversed().compactMap { e -> CGPoint? in
            if case .pointer(let p) = e.payload { return CGPoint(x: Int(p.x), y: Int(p.y)) }
            return nil
        }.first
        guard let got = lastPointer else {
            print("  \(name): no pointer event arrived"); failures += 1; continue
        }
        let dx = Int(got.x - want.x), dy = Int(got.y - want.y)
        let ok = abs(dx) <= tolerance && abs(dy) <= tolerance
        if !ok { failures += 1 }
        print("  \(ok ? "✓" : "✗") \(name.rightPadded(to: 12)) want (\(Int(want.x)),\(Int(want.y)))"
              + "  got (\(Int(got.x)),\(Int(got.y)))  error (\(dx),\(dy))")
    }

    print("")
    print(failures == 0 ? "pointer mapping OK" : "\(failures) of \(targets.count) targets missed")
    exit(failures == 0 ? 0 : 1)
}

func runScenarios(window: String, filterID: String, tag: String,
                  scenarioFile: String, windowSize: CGSize) async {
    let reader = VideoReader(windowName: window)
    guard let regiWindow = try? await reader.findWindow() else {
        print("FAILED: Regi window not found"); exit(2)
    }
    let runner: ScenarioRunner
    var activeWindow = regiWindow
    do {
        let driver = try AXDriver()
        // Set the window rather than inheriting whatever it was left at. Two
        // things depend on it: the QR band arrives scaled by window size, and
        // pointer accuracy is bounded by framebuffer pixels per screen point.
        // Fixing it makes a run reproducible instead of quietly different.
        if windowSize.width > 0 {
            driver.activate()
            _ = driver.resizeWindow(containing: AXID.videoView, to: windowSize)
            try? await Task.sleep(nanoseconds: 700_000_000)
            // Re-find it: SCWindow carries the frame from when it was looked
            // up, and the crop rectangle is computed against that frame. Using
            // the pre-resize one crops the wrong region and Vision finds no QR
            // at all — which reads as "the probe stopped", not as a stale
            // reference.
            if let fresh = try? await reader.findWindow() { activeWindow = fresh }
        }
        runner = try ScenarioRunner(reader: reader, regiWindow: activeWindow, driver: driver)
    } catch {
        print("FAILED: \(error)"); exit(2)
    }

    var chosen: [Scenario]
    if !scenarioFile.isEmpty {
        do {
            chosen = try ScenarioFile.load(contentsOf: URL(fileURLWithPath: scenarioFile))
            print("loaded \(chosen.count) scenario(s) from \(scenarioFile)")
        } catch {
            print("FAILED to load \(scenarioFile): \(error)"); exit(2)
        }
    } else {
        chosen = Catalogue.all
    }
    if !filterID.isEmpty { chosen = chosen.filter { $0.id.contains(filterID) } }
    if !tag.isEmpty { chosen = chosen.filter { $0.tags.contains { $0.rawValue == tag } } }
    guard !chosen.isEmpty else { print("no scenarios matched"); exit(2) }

    // A run takes focus and drives the mouse and keyboard, so on a machine
    // someone is also using, it has to be obvious when that starts and stops.
    // Input arriving during a run is indistinguishable from injected input
    // once it reaches the target, so it does not merely annoy -- it corrupts
    // the results.
    let estimate = Int(Double(chosen.count) * 4.5)
    print("""

    ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
    ┃  RUN STARTING — hands off the keyboard and mouse                 ┃
    ┃  \(chosen.count) scenario(s), roughly \(estimate)s. Regi will take focus.
    ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
    """)
    print(String(format: "geometry: %.2f framebuffer px per screen point\n", runner.geometry.pixelsPerPoint))

    let runStarted = Date()
    var failed = 0, quarantinedFailures = 0
    for (index, scenario) in chosen.enumerated() {
        FileHandle.standardError.write(Data("  [\(index + 1)/\(chosen.count)] \(scenario.id)…\r".utf8))
        let outcome = await runner.run(scenario)
        let mark = outcome.passed ? "✓" : (outcome.quarantined ? "~" : "✗")
        print("\(mark) \(scenario.id.rightPadded(to: 42)) \(scenario.title)"
              + String(format: "  %.1fs", outcome.duration))

        if !outcome.passed {
            if let failure = outcome.failure { print("      error: \(failure)") }
            for (_, result) in outcome.checks where !result.passed {
                print("      \(result.detail)")
            }
            // The observed slice is what makes a failure diagnosable rather
            // than merely reported.
            let shown = outcome.events.suffix(10).map(\.detail).joined(separator: ", ")
            if !shown.isEmpty { print("      saw: \(shown)") }
            if outcome.quarantined { quarantinedFailures += 1 } else { failed += 1 }
        }
    }

    print("""

    ┗━━ RUN COMPLETE after \(Int(Date().timeIntervalSince(runStarted)))s — the machine is yours again
    """)
    print("\(chosen.count - failed - quarantinedFailures)/\(chosen.count) passed"
          + (quarantinedFailures > 0 ? ", \(quarantinedFailures) quarantined failure(s)" : ""))
    exit(failed == 0 ? 0 : 1)
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch mode {
case "watch":
    await watch(window: value("window", "Regi"),
                intervalMillis: intValue("interval", 250),
                limit: intValue("limit", 0))
case "doctor":
    await doctor(window: value("window", "Regi"))
case "run":
    await runScenarios(window: value("window", "Regi"),
                       filterID: value("scenario", ""), tag: value("tag", ""),
                       scenarioFile: value("scenarios", ""),
                       windowSize: parseSize(value("window-size", "1680x1050")))
case "schema":
    print(ScenarioSchema.text)
case "export":
    // The built-in catalogue as JSON: worked examples in the exact format a
    // generated file must use.
    do { print(try ScenarioFile.json(for: Catalogue.all)) }
    catch { print("FAILED: \(error)"); exit(2) }
case "list":
    for s in Catalogue.all {
        let tags = s.tags.map(\.rawValue).sorted().joined(separator: ",")
        print("\(s.id.rightPadded(to: 42)) [\(tags)]\(s.quarantined ? " (quarantined)" : "")")
        print("  \(s.title)")
    }
case "pointer-check":
    await pointerCheck(window: value("window", "Regi"), tolerance: intValue("tolerance", 2))
default:
    print(usage)
}
