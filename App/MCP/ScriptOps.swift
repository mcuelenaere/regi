// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import KVMKit
import MCP

/// What a script can ask of Regi, by name; `ScriptRun` decides when each
/// runs. Keyboard and pointer ops always let go of what they press: a stopped
/// script cancels them only between presses, never while a key or button is
/// down. `power` and session management are deliberately not here.
@MainActor
enum ScriptOps {
    typealias Failure = MCPTools.Failure

    /// Mean colour difference (0–255) between two thumbnails above which the
    /// screen counts as changing.
    static let stableThreshold = 1.0

    static func run(_ name: String, _ json: String, in run: ScriptRun) async throws -> Value {
        let args = MCPTools.Args(raw: (try? JSONDecoder().decode([String: Value].self, from: Data(json.utf8))) ?? [:])
        let open = run.open
        guard MCPHost.shared.sessions[open.id]?.session === open.session else {
            throw Failure("the session's window was closed")
        }
        let started = Date()
        do {
            let (value, summary) = try await perform(name, args, open)
            if let summary { record(run, name, summary, error: nil, since: started) }
            return value
        } catch {
            if !(error is CancellationError), name != "ocr", name != "size" {
                record(run, name, "", error: "\(error)", since: started)
            }
            throw error
        }
    }

    /// Keyboard and pointer actions, and waits, get a row in the activity
    /// window; reads don't, since `waitForText` polls them several times a second.
    private static func record(_ run: ScriptRun, _ name: String, _ details: String, error: String?, since started: Date) {
        MCPHost.shared.record(.init(time: started, client: run.client, session: run.open.id,
                                    tool: "run_script ▸ \(name)", details: details,
                                    result: error.map { String($0.prefix(300)) } ?? "ok", isError: error != nil,
                                    duration: Date().timeIntervalSince(started)))
    }

    private static func perform(_ name: String, _ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> (Value, String?) {
        let session = open.session
        switch name {
        case "size":
            guard let size = ScreenReader.size(of: session) else { throw MCPTools.noVideo(open) }
            return (["width": .int(size.width), "height": .int(size.height)], nil)
        case "ocr": return (try await ocr(a, open), nil)
        case "stable": return try await stable(a, open)
        case "press": return try await press(a, session)
        case "type": return try await type(a, session)
        case "move": return try await move(a, open)
        case "click": return try await click(a, open)
        case "drag": return try await drag(a, open)
        case "scroll": return try await scroll(a, session)
        default: throw Failure("unknown operation \(name)")
        }
    }

    // MARK: - Screen

    private static func ocr(_ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> Value {
        guard var image = ScreenReader.frame(of: open.session) else { throw MCPTools.noVideo(open) }
        var origin = CGPoint.zero
        if let region = a.raw["region"]?.objectValue {
            func number(_ key: String) -> Double { region[key]?.doubleValue ?? region[key]?.intValue.map(Double.init) ?? 0 }
            let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !rect.isNull, !rect.isEmpty, let cropped = image.cropping(to: rect) else {
                throw Failure("region must lie inside the \(image.width)×\(image.height) framebuffer")
            }
            image = cropped
            origin = rect.origin
        }
        let target = image
        let lines = try await Task.detached { try ScreenReader.recognizeText(in: target) }.value
        return .array(lines.map { line in
            let box = line.box.offsetBy(dx: origin.x, dy: origin.y)
            return ["text": .string(line.text), "x": .int(Int(box.midX)), "y": .int(Int(box.midY)),
                    "box": [.int(Int(box.minX)), .int(Int(box.minY)), .int(Int(box.width.rounded())), .int(Int(box.height.rounded()))],
                    "confidence": .double((Double(line.confidence) * 100).rounded() / 100)]
        })
    }

    /// Stable once no two thumbnails 100 ms apart differ by more than the
    /// threshold for `quiet_ms`. `noise` is the largest difference seen while
    /// quiet and `peak` the largest overall, to tune the threshold on real
    /// streams.
    // ponytail: a mean over a 96 px thumbnail, so a change of a few thumbnail
    // pixels (a blinking cursor, a ticking clock) never counts; compare tiles
    // if a screen needs finer.
    private static func stable(_ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> (Value, String?) {
        let quiet = min(max(a.number("quiet_ms") ?? 500, 100), 60_000) / 1000
        let timeout = min(max(a.number("timeout_s") ?? 10, 0.1), 600)
        let threshold = a.number("threshold") ?? stableThreshold
        let started = Date()
        guard var previous = ScreenReader.thumbnail(of: open.session) else { throw MCPTools.noVideo(open) }
        var quietSince = started, changed = false, noise = 0.0, peak = 0.0
        while true {
            try await Task.sleep(for: .milliseconds(100))
            guard let next = ScreenReader.thumbnail(of: open.session) else { throw MCPTools.noVideo(open) }
            let difference = ScreenReader.difference(previous, next)
            previous = next
            peak = max(peak, difference)
            if difference > threshold {
                changed = true
                quietSince = Date()
                noise = 0
            } else {
                noise = max(noise, difference)
            }
            let now = Date()
            let isStable = now.timeIntervalSince(quietSince) >= quiet
            guard isStable || now.timeIntervalSince(started) >= timeout else { continue }
            let ms = Int(now.timeIntervalSince(started) * 1000)
            let rounded = { (value: Double) in Value.double((value * 100).rounded() / 100) }
            return (["stable": .bool(isStable), "elapsed_ms": .int(ms), "changed": .bool(changed),
                     "noise": rounded(noise), "peak": rounded(peak)],
                    "\(isStable ? "stable" : "still changing") after \(ms) ms; noise \(String(format: "%.2f", noise)), peak \(String(format: "%.2f", peak))")
        }
    }

    // MARK: - Keyboard

    private static func press(_ a: MCPTools.Args, _ session: Session) async throws -> (Value, String?) {
        let names = a.raw["chords"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !names.isEmpty else { throw Failure("keys.press needs at least one chord") }
        // Every chord parses before any is sent.
        let chords = try names.map { try KeyNames.chord($0) }
        let gap = min(max(a.number("interval_ms") ?? 100, 0), 5000)
        for (index, chord) in chords.enumerated() {
            // Nothing is held between chords, so a stop may land here.
            if index > 0 { try await Task.sleep(for: .milliseconds(gap)) }
            await press(chord, on: session)
        }
        return (.null, names.joined(separator: ", "))
    }

    /// Modifiers travel the same `flagsChanged` path as a real keyboard's:
    /// the backends read held state from the device bits in `rawFlags`.
    private static func press(_ chord: KeyNames.Chord, on session: Session) async {
        var held: UInt64 = 0
        for modifier in chord.modifiers {
            held |= ModifierTracker.deviceFlagBit(forKeyCode: modifier) ?? 0
            session.handleFlagsChanged(virtualKeyCode: modifier, rawFlags: held, source: .eventTap)
            await pause(15)
        }
        if let key = chord.key {
            session.sendKeypress(virtualKeyCode: key, pressed: true, source: .eventTap)
            await pause(40)
            session.sendKeypress(virtualKeyCode: key, pressed: false, source: .eventTap)
        }
        for modifier in chord.modifiers.reversed() {
            await pause(15)
            held &= ~(ModifierTracker.deviceFlagBit(forKeyCode: modifier) ?? 0)
            session.handleFlagsChanged(virtualKeyCode: modifier, rawFlags: held, source: .eventTap)
        }
    }

    private static func type(_ a: MCPTools.Args, _ session: Session) async throws -> (Value, String?) {
        let text = a.string("text") ?? ""
        let strokes = try KeyNames.strokes(for: text)
        let delay = min(max(a.number("delay_ms") ?? 15, 1), 1000)
        let shiftBit = ModifierTracker.deviceFlagBit(forKeyCode: KeyNames.shift) ?? 0
        var shifted = false
        for stroke in strokes {
            if Task.isCancelled { break }
            if stroke.shift != shifted {
                shifted = stroke.shift
                session.handleFlagsChanged(virtualKeyCode: KeyNames.shift, rawFlags: shifted ? shiftBit : 0, source: .eventTap)
                await pause(delay)
            }
            session.sendKeypress(virtualKeyCode: stroke.keyCode, pressed: true, source: .eventTap)
            await pause(delay)
            session.sendKeypress(virtualKeyCode: stroke.keyCode, pressed: false, source: .eventTap)
            await pause(delay)
        }
        if shifted {
            session.handleFlagsChanged(virtualKeyCode: KeyNames.shift, rawFlags: 0, source: .eventTap)
        }
        try Task.checkCancellation()
        return (.null, text)
    }

    /// A pause inside a press: never throws, so a stopped script still lets go.
    private static func pause(_ ms: Double) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Pointer

    private typealias Point = (x: Int32, y: Int32)

    private static func point(_ a: MCPTools.Args, _ xKey: String, _ yKey: String, _ open: MCPHost.OpenSession) throws -> Point {
        guard let size = ScreenReader.size(of: open.session) else { throw MCPTools.noVideo(open) }
        let x = try a.requiredNumber(xKey), y = try a.requiredNumber(yKey)
        guard x >= 0, y >= 0, x < Double(size.width), y < Double(size.height) else {
            throw Failure("(\(Int(x)), \(Int(y))) is outside the \(size.width)×\(size.height) framebuffer")
        }
        // Aim at the pixel's centre.
        return (AbsolutePointer.normalize(CGFloat(x) + 0.5, extent: CGFloat(size.width)),
                AbsolutePointer.normalize(CGFloat(y) + 0.5, extent: CGFloat(size.height)))
    }

    private static func buttons(_ a: MCPTools.Args) throws -> MouseButtons {
        switch a.string("button") ?? "left" {
        case "left": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw Failure("button is left, right or middle")
        }
    }

    /// Jump (0 ms) or glide with smoothstep easing at about 60 Hz. A stopped
    /// script ends the glide wherever it got to; returns that point.
    private static func glide(_ session: Session, to: Point, durationMs: Double, buttons: MouseButtons) async -> Point {
        guard durationMs > 0, let from = session.lastPointer else {
            session.sendPointerMotion(normalizedX: to.x, normalizedY: to.y, buttons: buttons)
            return to
        }
        let steps = max(2, Int(durationMs / 16))
        var at = from
        for step in 1...steps {
            if Task.isCancelled { break }
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            at = (from.x + Int32((Double(to.x - from.x) * eased).rounded()),
                  from.y + Int32((Double(to.y - from.y) * eased).rounded()))
            session.sendPointerMotion(normalizedX: at.x, normalizedY: at.y, buttons: buttons)
            await pause(16)
        }
        return at
    }

    private static func label(_ a: MCPTools.Args, _ x: String = "x", _ y: String = "y") -> String {
        "(\(Int(a.number(x) ?? 0)),\(Int(a.number(y) ?? 0)))"
    }

    private static func move(_ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> (Value, String?) {
        let to = try point(a, "x", "y", open)
        let duration = min(max(a.number("duration_ms") ?? 0, 0), 10_000)
        _ = await glide(open.session, to: to, durationMs: duration, buttons: [])
        try Task.checkCancellation()
        return (.null, label(a) + (duration > 0 ? " over \(Int(duration)) ms" : ""))
    }

    private static func click(_ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> (Value, String?) {
        let session = open.session
        let at: Point
        if a.number("x") == nil, a.number("y") == nil {
            guard let current = session.lastPointer else { throw Failure("the pointer hasn't been placed yet; click a target") }
            at = current
        } else {
            at = try point(a, "x", "y", open)
        }
        let button = try buttons(a)
        let count = Int(min(max(a.number("count") ?? 1, 1), 3))
        // Arrive first, as a mouse would: some targets only react to a hover.
        if session.lastPointer.map({ $0 != at }) ?? true {
            session.sendPointerMotion(normalizedX: at.x, normalizedY: at.y, buttons: [])
            await pause(30)
        }
        for index in 0..<count {
            if index > 0 { try await Task.sleep(for: .milliseconds(60)) }
            session.sendPointerButtonChange(normalizedX: at.x, normalizedY: at.y, buttons: button)
            await pause(40)
            session.sendPointerButtonChange(normalizedX: at.x, normalizedY: at.y, buttons: [])
        }
        return (.null, "\(a.number("x") == nil ? "pointer" : label(a)) \(a.string("button") ?? "left")×\(count)")
    }

    private static func drag(_ a: MCPTools.Args, _ open: MCPHost.OpenSession) async throws -> (Value, String?) {
        let session = open.session
        let from = try point(a, "from_x", "from_y", open), to = try point(a, "to_x", "to_y", open)
        let button = try buttons(a)
        let duration = min(max(a.number("duration_ms") ?? 300, 0), 10_000)
        session.sendPointerMotion(normalizedX: from.x, normalizedY: from.y, buttons: [])
        await pause(30)
        session.sendPointerButtonChange(normalizedX: from.x, normalizedY: from.y, buttons: button)
        await pause(50)
        let end = await glide(session, to: to, durationMs: duration, buttons: button)
        await pause(50)
        session.sendPointerButtonChange(normalizedX: end.x, normalizedY: end.y, buttons: [])
        try Task.checkCancellation()
        return (.null, "\(label(a, "from_x", "from_y")) → \(label(a, "to_x", "to_y"))")
    }

    private static func scroll(_ a: MCPTools.Args, _ session: Session) async throws -> (Value, String?) {
        let dy = Int(a.number("dy") ?? 0), dx = Int(a.number("dx") ?? 0)
        guard dy != 0 || dx != 0 else { throw Failure("pointer.scroll needs dy and/or dx, in wheel notches") }
        guard abs(dy) <= 100, abs(dx) <= 100 else { throw Failure("at most 100 notches per call") }
        // One notch per report, so hosts that integrate wheel velocity see
        // every step. HID wheel reports count up as away-from-user (scroll up).
        for step in 0..<max(abs(dy), abs(dx)) {
            if step > 0 { try await Task.sleep(for: .milliseconds(20)) }
            let wheelY: Int8 = step < abs(dy) ? (dy > 0 ? -1 : 1) : 0
            let wheelX: Int8 = step < abs(dx) ? (dx > 0 ? 1 : -1) : 0
            session.sendWheelReport(wheelY: wheelY, wheelX: wheelX)
        }
        return (.null, "dy=\(dy) dx=\(dx)")
    }
}
