// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import KVMKit
import MCP
import SwiftUI

/// The MCP tool surface. Sessions and screenshots have their own tools; the
/// work itself — reading text, typing, clicking, waiting — happens in
/// `run_script`, so a whole flow costs the LLM one call instead of one per
/// step. Every coordinate is a framebuffer pixel of the remote display.
@MainActor
enum MCPTools {
    static let instructions = """
        Regi shows remote computers through KVM-over-IP devices (JetKVM, PiKVM, VNC), one window per \
        session, and lets you operate them. Use list_hosts and open_session to connect, then do the work with \
        run_script: one JavaScript call reads the screen with on-device OCR, types, clicks and waits for text, \
        so a sequence of steps is one call. Use screenshot to see what OCR can't read. Coordinates are \
        framebuffer pixels of the remote display.
        """

    nonisolated static func install(on server: Server, connection: UUID) async {
        _ = await server.withMethodHandler(ListTools.self) { _ in
            await MainActor.run { ListTools.Result(tools: definitions) }
        }
        _ = await server.withMethodHandler(CallTool.self) { params in
            await call(params, connection: connection)
        }
    }

    // MARK: - Dispatch

    struct Outcome {
        var content: [Tool.Content]
        /// One line for the activity window.
        var summary: String
        /// Set when the call failed but still has content to return.
        var failure: String?
        /// Report the failure in the content only, not as an MCP error:
        /// clients keep just the text of an error result, and a failed
        /// script's screenshot is the part that explains it.
        var failureInContent = false
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func call(_ params: CallTool.Parameters, connection: UUID) async -> CallTool.Result {
        let started = Date()
        let args = Args(raw: params.arguments ?? [:])
        var outcome: Outcome
        do {
            outcome = try await run(params.name, args, connection: connection)
        } catch {
            outcome = Outcome(content: [textContent("\(error)")], summary: args.brief, failure: "\(error)")
        }
        let host = MCPHost.shared
        host.record(.init(time: started, client: host.clientName(connection),
                          session: args.string("session") ?? args.string("host") ?? "",
                          tool: params.name, details: outcome.summary,
                          result: outcome.failure ?? "ok",
                          isError: outcome.failure != nil, duration: Date().timeIntervalSince(started)))
        return CallTool.Result(content: outcome.content, isError: outcome.failure != nil && !outcome.failureInContent)
    }

    private static func run(_ name: String, _ a: Args, connection: UUID) async throws -> Outcome {
        switch name {
        case "list_hosts": return try await listHosts()
        case "open_session": return try await openSession(a)
        case "close_session": return try await closeSession(a)
        case "list_sessions": return listSessions()
        case "screenshot": return try await screenshot(a)
        case "run_script": return try await runScript(a, connection: connection)
        case "power": return try await power(a)
        default: throw Failure("unknown tool \(name)")
        }
    }

    struct Args {
        let raw: [String: Value]

        func string(_ key: String) -> String? { raw[key]?.stringValue }
        func number(_ key: String) -> Double? { raw[key]?.doubleValue ?? raw[key]?.intValue.map(Double.init) }

        func required(_ key: String) throws -> String {
            guard let value = string(key), !value.isEmpty else { throw Failure("missing \(key)") }
            return value
        }

        func requiredNumber(_ key: String) throws -> Double {
            guard let value = number(key) else { throw Failure("missing \(key) (a number)") }
            return value
        }

        /// What a failed call was asked to do, for the activity window.
        var brief: String {
            [string("action"), string("script").map(MCPTools.oneLine), string("host")].compactMap { $0 }.first ?? ""
        }
    }

    // MARK: - Hosts and sessions

    private static func listHosts() async throws -> Outcome {
        let (store, _) = try await hostsWindow()
        let hosts: [Value] = store.hosts.map { host in
            let id = MCPHost.OpenSession.id(host.host, host.port)
            return ["id": .string(id), "name": .string(host.displayName), "kind": .string(host.kind.displayName),
                    "session_open": .bool(MCPHost.shared.sessions[id] != nil)]
        }
        return Outcome(content: [json(.array(hosts))], summary: "\(hosts.count) hosts")
    }

    /// The saved hosts and SwiftUI's `openWindow`, which `HostsView` hands
    /// over when it appears. Regi can launch with no windows at all, so open
    /// the Hosts window if it never has been.
    private static func hostsWindow() async throws -> (HostStore, OpenWindowAction) {
        if MCPHost.shared.hostStore == nil { openHostsViaMenu() }
        for _ in 0..<20 {
            if let store = MCPHost.shared.hostStore, let openWindow = MCPHost.shared.openWindow { return (store, openWindow) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Regi's host list isn't loaded and its Hosts window didn't open; ask the user to open it (Window ▸ Hosts)")
    }

    private static func openSession(_ a: Args) async throws -> Outcome {
        let wanted = try a.required("host")
        let (store, openWindow) = try await hostsWindow()
        guard let host = store.hosts.first(where: { MCPHost.OpenSession.id($0.host, $0.port) == wanted })
            ?? store.hosts.first(where: { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame })
        else { throw Failure("no saved host \"\(wanted)\"; see list_hosts") }

        let id = MCPHost.OpenSession.id(host.host, host.port)
        // An already-open window is just brought forward.
        openWindow(value: KVMSessionWindowID(saved: host))
        var state = "opening"
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let open = MCPHost.shared.sessions[id] {
                state = describe(open.session)
                if settled(open.session) { break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let open = MCPHost.shared.sessions[id], open.session.state == .connected,
           open.session.videoRenderer?.latestFrame() == nil, (open.session.videoState?.error ?? "").isEmpty {
            state = "connected, no video frame yet"
        }
        return Outcome(content: [json(["session": .string(id), "state": .string(state)])], summary: state)
    }

    /// Connected with video (or a reported reason there is none), or stopped
    /// at something only the user can resolve.
    private static func settled(_ session: Session) -> Bool {
        switch session.state {
        case .connected:
            return session.videoRenderer?.latestFrame() != nil || !(session.videoState?.error ?? "").isEmpty
        case .awaitingPassword, .awaitingTrustOverride, .failed, .kicked:
            return true
        default:
            return false
        }
    }

    private static func closeSession(_ a: Args) async throws -> Outcome {
        let open = try lookup(a)
        open.close()
        for _ in 0..<12 where MCPHost.shared.sessions[open.id] != nil {
            try await Task.sleep(for: .milliseconds(250))
        }
        return Outcome(content: [textContent("closed \(open.id)")], summary: "closed")
    }

    private static func listSessions() -> Outcome {
        let sessions: [Value] = MCPHost.shared.sessions.values.sorted { $0.id < $1.id }.map { open in
            let session = open.session
            var entry: [String: Value] = [
                "id": .string(open.id), "name": .string(open.windowID.displayName),
                "kind": .string(open.windowID.kind.displayName), "state": .string(describe(session)),
                "power_actions": .array(session.availablePowerActions.map { .string($0.rawValue) }),
                "script_running": .bool(MCPHost.shared.scripts[open.id] != nil),
            ]
            if let size = ScreenReader.size(of: session) {
                entry["framebuffer"] = ["width": .int(size.width), "height": .int(size.height)]
            }
            if let led = session.powerIndicator { entry["power_led"] = .bool(led) }
            return .object(entry)
        }
        return Outcome(content: [json(.array(sessions))], summary: "\(sessions.count) sessions")
    }

    static func lookup(_ a: Args) throws -> MCPHost.OpenSession {
        let id = try a.required("session")
        if let open = MCPHost.shared.sessions[id] { return open }
        let ids = MCPHost.shared.sessions.keys.sorted()
        throw Failure("no open session \"\(id)\"; open sessions: \(ids.isEmpty ? "none (see open_session)" : ids.joined(separator: ", "))")
    }

    static func describe(_ session: Session) -> String {
        switch session.state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .awaitingPassword: return "waiting for a password: the user must enter it in Regi's window"
        case .awaitingTrustOverride(let host, _): return "waiting for the user to trust \(host)'s certificate in Regi's window"
        case .connected:
            if let error = session.videoState?.error, !error.isEmpty { return "connected, no video signal: \(error)" }
            return "connected"
        case .reconnecting(let attempt): return "reconnecting (attempt \(attempt))"
        case .kicked: return "kicked: another client took over the device"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    static func noVideo(_ open: MCPHost.OpenSession) -> Failure {
        Failure("no video from \(open.id) yet (\(describe(open.session)))")
    }

    /// When the device says there is no HDMI signal, frames stop arriving and
    /// the last one stays put: say so rather than let a stale frame pass as live.
    static func signalWarning(_ open: MCPHost.OpenSession) -> String? {
        guard let error = open.session.videoState?.error, !error.isEmpty else { return nil }
        return "the device reports no video signal (\(error)); this frame may be stale"
    }

    // MARK: - Screenshot

    private static func screenshot(_ a: Args) async throws -> Outcome {
        let open = try lookup(a)
        guard let size = ScreenReader.size(of: open.session) else { throw noVideo(open) }
        var scale = 1.0
        if let w = a.number("max_width"), w > 0 { scale = min(scale, w / Double(size.width)) }
        if let h = a.number("max_height"), h > 0 { scale = min(scale, h / Double(size.height)) }
        let format = a.string("format") ?? "png"
        guard format == "png" || format == "jpeg" else { throw Failure("format is png or jpeg") }

        guard let image = ScreenReader.frame(of: open.session, scale: scale) else { throw noVideo(open) }
        var data = await Task.detached { ScreenReader.encode(image, png: format == "png") }.value
        var mime = "image/\(format)"
        var notes: [String] = []
        // The Anthropic API refuses images over 5 MB.
        if format == "png", (data?.count ?? 0) > 5_000_000 {
            data = await Task.detached { ScreenReader.encode(image, png: false) }.value
            mime = "image/jpeg"
            notes.append("The PNG was over 5 MB, so this is a JPEG.")
        }
        guard let data else { throw Failure("couldn't encode the frame") }
        if scale < 1 {
            notes.insert("\(image.width)×\(image.height) image of the \(size.width)×\(size.height) framebuffer (scale \(String(format: "%.3f", scale))). Coordinates take framebuffer pixels: divide this image's pixel positions by the scale.", at: 0)
        } else {
            notes.insert("\(size.width)×\(size.height), the full framebuffer: coordinates take these pixels.", at: 0)
        }
        if let warning = signalWarning(open) { notes.append(warning) }
        return Outcome(content: [imageContent(data, mimeType: mime), textContent(notes.joined(separator: " "))],
                       summary: "\(image.width)×\(image.height) \(mime.dropFirst(6)), \(data.count / 1024) KB")
    }

    // MARK: - Script

    private static func runScript(_ a: Args, connection: UUID) async throws -> Outcome {
        let open = try lookup(a)
        let script = try a.required("script")
        guard MCPHost.shared.scripts[open.id] == nil else {
            throw Failure("a script is already running on \(open.id); wait for it to finish")
        }
        let timeout = min(max(a.number("timeout_s") ?? 60, 1), 600)
        let run = ScriptRun(open: open, connection: connection, client: MCPHost.shared.clientName(connection))
        MCPHost.shared.scripts[open.id] = run
        defer { if MCPHost.shared.scripts[open.id] === run { MCPHost.shared.scripts[open.id] = nil } }

        let report = await withTaskCancellationHandler {
            await run.run(script, timeout: timeout)
        } onCancel: {
            run.stop("cancelled by the client")
        }

        var reply: [String: Value] = ["log": .array(report.log.map(Value.string))]
        if case .failure = report.result { reply["ok"] = false } else { reply["ok"] = true }
        // Snapshots the script asked for, each after its caption.
        var images: [Tool.Content] = report.snapshots.flatMap { snapshot in
            [textContent(snapshot.caption), imageContent(snapshot.jpeg)]
        }
        let trace = Value.array(report.trace.map(Value.string))
        switch report.result {
        case .success(let result):
            reply["result"] = (try? JSONDecoder().decode(Value.self, from: Data(result.utf8))) ?? .null
            reply["elapsed_s"] = .double((report.elapsed * 10).rounded() / 10)
            if a.raw["trace"]?.boolValue == true { reply["trace"] = trace }
            if report.unfinishedInput > 0 {
                reply["warning"] = .string("\(report.unfinishedInput) keyboard or pointer call(s) had not finished when the script returned, so they were cut short or skipped. Await every call.")
            }
            if let warning = signalWarning(open) { reply["video"] = .string(warning) }
            return Outcome(content: [json(.object(reply))] + images, summary: script)
        case .failure(let failure):
            reply["error"] = .string(failure.message)
            if let line = failure.line { reply["line"] = .int(line) }
            reply["trace"] = trace
            reply["screen"] = await screenText(open)
            // What the screen looked like when it failed: often what explains it.
            if let jpeg = await failureShot(open) {
                images += [textContent("The screen when the script failed (1280 px wide at most; framebuffer = image pixel ÷ scale, see list_sessions for its size)."),
                           imageContent(jpeg)]
            }
            return Outcome(content: [json(.object(reply))] + images, summary: script, failure: failure.message,
                           failureInContent: true)
        }
    }

    private static func failureShot(_ open: MCPHost.OpenSession) async -> Data? {
        guard MCPHost.shared.sessions[open.id]?.session === open.session,
              let size = ScreenReader.size(of: open.session),
              let image = ScreenReader.frame(of: open.session, scale: min(1, 1280 / Double(size.width)))
        else { return nil }
        return await Task.detached { ScreenReader.encode(image, png: false) }.value
    }

    static func imageContent(_ data: Data, mimeType: String = "image/jpeg") -> Tool.Content {
        .image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)
    }

    /// What is on screen now, as text lines, for a failed script's report.
    private static func screenText(_ open: MCPHost.OpenSession) async -> Value {
        guard MCPHost.shared.sessions[open.id]?.session === open.session,
              let image = ScreenReader.frame(of: open.session),
              let lines = try? await Task.detached(operation: { try ScreenReader.recognizeText(in: image) }).value
        else { return .null }
        return .array(lines.map { .string($0.text) })
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }

    // MARK: - Power

    private static func power(_ a: Args) async throws -> Outcome {
        let open = try lookup(a)
        let name = try a.required("action")
        let available = open.session.availablePowerActions
        guard let action = KVMPowerAction(rawValue: name), available.contains(action) else {
            throw Failure("\(open.id) offers: \(available.isEmpty ? "no power actions" : available.map(\.rawValue).joined(separator: ", "))")
        }
        try await open.session.sendPowerAction(action)
        return Outcome(content: [textContent("sent \(name) to \(open.id)")], summary: name)
    }

    // MARK: - Output

    static func textContent(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    static func json(_ value: Value) -> Tool.Content {
        textContent(encode(value))
    }

    static func encode(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: - Definitions

    /// The schemas and descriptions: the documentation the LLM reads.
    static let definitions: [Tool] = {
        func object(_ properties: [String: Value], required: [String] = []) -> Value {
            ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string))]
        }
        func property(_ type: String, _ description: String) -> Value {
            ["type": .string(type), "description": .string(description)]
        }
        let session = property("string", "Session id from list_sessions (host:port).")
        let readOnly = Tool.Annotations(readOnlyHint: true)

        return [
            Tool(name: "list_hosts",
                 description: "Saved hosts in Regi (JetKVM, PiKVM and VNC devices), with whether each has an open session. Pass an id to open_session.",
                 inputSchema: object([:]), annotations: readOnly),
            Tool(name: "open_session",
                 description: """
                    Open a saved host in a Regi window and connect; the user sees the window. Waits up to 15 s for the \
                    connection to settle, then returns the session id and state. If the state says Regi is waiting for a \
                    password or a certificate decision, the user has to answer in that window: check back with list_sessions.
                    """,
                 inputSchema: object(["host": property("string", "A host id from list_hosts (host:port), or the host's name.")],
                                     required: ["host"]),
                 annotations: .init(destructiveHint: false, idempotentHint: true)),
            Tool(name: "close_session",
                 description: "Close a session's window, which disconnects it.",
                 inputSchema: object(["session": session], required: ["session"]),
                 annotations: .init(destructiveHint: false)),
            Tool(name: "list_sessions",
                 description: """
                    Open sessions: id, state, framebuffer size (the pixel space every coordinate uses), available power \
                    actions, the power LED, and whether a script is running.
                    """,
                 inputSchema: object([:]), annotations: readOnly),
            Tool(name: "screenshot",
                 description: """
                    The session's current frame as an image, at the remote display's full resolution unless max_width or \
                    max_height ask for less. PNG by default: lossless, exactly what Regi shows; jpeg is smaller. The text \
                    part gives the scale when the image is reduced. To read text or find something to click, \
                    run_script's screen.text() is cheaper: it costs no image tokens.
                    """,
                 inputSchema: object(["session": session,
                                      "max_width": property("number", "Largest width to return, in pixels."),
                                      "max_height": property("number", "Largest height to return, in pixels."),
                                      "format": ["type": "string", "enum": ["png", "jpeg"], "description": "png by default."]],
                                     required: ["session"]),
                 annotations: readOnly),
            Tool(name: "run_script",
                 description: runScriptDescription,
                 inputSchema: object(["session": session,
                                      "script": property("string", "JavaScript: the body of an async function."),
                                      "timeout_s": property("number", "Stop the script after this long; 60 by default, at most 600."),
                                      "trace": property("boolean", "Return the trace on success too (a failure always has it).")],
                                     required: ["session", "script"])),
            Tool(name: "power",
                 description: """
                    Run one of the session's power actions (list_sessions shows which): powerButtonShort, powerButtonLong \
                    (force off), reset, shutdown, reboot. This acts on a real machine's power.
                    """,
                 inputSchema: object(["session": session,
                                      "action": property("string", "A power action from list_sessions.")],
                                     required: ["session", "action"]),
                 annotations: .init(destructiveHint: true)),
        ]
    }()

    private static let runScriptDescription = """
        Operate one session with JavaScript: read the screen, type, click and wait, all in one call. A whole flow \
        (press a key, wait for a prompt, pick a menu entry, confirm) is one run_script, so prefer it over \
        several calls. The script is the body of an async function: await every call, and return what you want \
        back (any JSON value). While it runs, the user's keyboard and mouse on this host are paused, so never \
        wait inside a script for the user to do something.

        API. Coordinates are framebuffer pixels; every function but log returns a Promise.
        type Line = { text, x, y, box: [x, y, w, h], confidence }   // x, y: the centre, a ready click target
        type Target = string | RegExp | Line | { x, y }
        screen.size(): { width, height }
        screen.text(region?: { x, y, width, height }): Line[]        // on-device OCR, top to bottom
        screen.find(what: string | RegExp, region?): Line[]
        screen.waitForText(what, { timeoutS = 30, gone = false, region }?): Line | null
        screen.waitStable({ quietMs = 500, timeoutS = 10 }?): boolean   // true once the picture stops changing
        screen.snapshot(label?, { region, maxWidth = 1280 }?)          // attach a JPEG to the reply for you to see
        keys.press(...chords, { intervalMs = 100 }?)
        keys.type(text, { delayMs = 15 }?)
        pointer.click(target, { button = "left", count = 1 }?)
        pointer.move(target, { durationMs = 0 }?)                       // 0 jumps; more glides
        pointer.drag(from, to, { durationMs = 300, button = "left" }?)
        pointer.scroll(dy, dx = 0)                                      // wheel notches at the pointer; dy > 0 scrolls down
        sleep(ms)
        log(...values)

        Text: a string matches case-insensitively as a substring, and exact matches win over partial ones; a \
        RegExp is tested against each line. A string or RegExp target must match exactly one line: none or several \
        throws, listing the screen's text (with positions when several match), so pick one and pass it or {x, y}. \
        waitForText throws on timeout, with the visible text; gone: true waits for the text to disappear. Text \
        is matched anywhere on screen, address-bar suggestions and tab titles included: pass a region to wait for \
        the page's own text.

        Timing: keys typed while a page or window is still opening are lost. After anything that navigates or \
        opens something, wait for text that only the new content shows (in a region), or waitStable, before typing.

        Keys: \(KeyNames.accepted) keys.type sends printable ASCII, newline (Enter) and tab as US-layout keystrokes.

        Seeing: screen.snapshot shows you what OCR can't read (icons, layout, colours). Image tokens grow with \
        pixels, so pass a region when you know where to look; it is cropped at full resolution, then scaled to \
        maxWidth. At most \(ScriptRun.maxSnapshots) per run; each image comes with a caption that maps its \
        pixels back to framebuffer pixels.

        Returns {ok: true, result, log, elapsed_s}, then any snapshots. trace: true adds the trace: one timed \
        line per key press, typing, click (what was asked for and where it landed), wait and snapshot. A script \
        that fails returns {ok: false, error, line, log, trace, screen}: the message, the script line, your log() \
        output, the trace, and the text on screen, followed by any snapshots and a screenshot of that moment. \
        Check ok before trusting result.

        Example:
        await keys.press("ctrl+alt+delete");
        await screen.waitForText(/press (del|f2)/i, { timeoutS: 60 });
        await keys.press("delete");
        await screen.waitForText("Boot");
        await pointer.click("Boot");
        return (await screen.text()).map(l => l.text);
        """
}
