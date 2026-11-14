// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import JavaScriptCore
import KVMKit
import OSLog

private let log = Logger(subsystem: "app.regi.mcp", category: "script")

/// One `run_script` call.
///
/// The script runs in a fresh JavaScriptCore context (no network, no files,
/// only what the prelude defines) on a queue of its own, so an endless loop
/// can't stall Regi. Everything it asks of Regi goes through one bridge,
/// `__call(name, argsJSON)`, to `ScriptOps` on the main actor: keyboard and
/// pointer ops one at a time in the order issued, reads as soon as asked.
/// `sleep` never leaves the script's queue.
///
/// Ops are only started once the turn of JavaScript that issued them is over,
/// so a call made without `await` in the same turn as `return` never runs,
/// rather than racing the reply.
final class ScriptRun: @unchecked Sendable {
    struct Failure: Error {
        let message: String
        var line: Int?
    }

    struct Report {
        let result: Result<String, Failure>
        let log: [String]
        /// What the script did, one line per action, timed from its start.
        let trace: [String]
        let snapshots: [Snapshot]
        let elapsed: TimeInterval
        /// Keyboard or pointer calls still pending when the script returned.
        let unfinishedInput: Int
    }

    /// An image `screen.snapshot` attached to the reply.
    struct Snapshot {
        let jpeg: Data
        let caption: String
    }

    static let maxSnapshots = 3

    /// Used on the main actor only.
    let open: MCPHost.OpenSession
    let connection: UUID
    let client: String

    private static let inputOps: Set<String> = ["press", "type", "move", "click", "drag", "scroll"]
    private let queue = DispatchQueue(label: "app.regi.mcp.script", qos: .userInitiated)
    private let started = Date()
    private let inputOps: AsyncStream<Op>
    private let inputQueue: AsyncStream<Op>.Continuation

    // Guarded by `lock`.
    private let lock = NSLock()
    private var outcome: Result<String, Failure>?
    private var waiter: CheckedContinuation<Result<String, Failure>, Never>?
    private var logLines: [String] = []
    private var traceLines: [String] = []
    private var snapshots: [Snapshot] = []
    private var unfinishedInput = 0
    private var ranAway = false
    private var tasks: [Task<Void, Never>] = []

    // Script queue only.
    private var context: JSContext?
    private var nextID = 0
    private var issued: [Op] = []
    private var pending: [Int: Pending] = [:]
    private var returned: Result<String, Failure>?

    private struct Op: Sendable {
        let id: Int
        let name: String
        let args: String
    }

    private struct Pending {
        let resolve: JSValue
        let reject: JSValue
        let isInput: Bool
    }

    init(open: MCPHost.OpenSession, connection: UUID, client: String) {
        self.open = open
        self.connection = connection
        self.client = client
        (inputOps, inputQueue) = AsyncStream.makeStream(of: Op.self)
    }

    private var isFinished: Bool { lock.withLock { outcome != nil } }

    // MARK: - Running

    @MainActor
    func run(_ script: String, timeout: TimeInterval) async -> Report {
        let session = open.session
        // Let go of whatever the user is holding, then shut them out.
        session.releaseAllHeldModifiers()
        if let at = session.lastPointer {
            session.sendPointerButtonChange(normalizedX: at.x, normalizedY: at.y, buttons: [])
        }
        session.localInputSuspended = true
        defer { session.localInputSuspended = false }

        track(Task { @MainActor [weak self] in
            guard let self else { return }
            for await op in inputOps {
                guard !isFinished else { break }
                await perform(op)
            }
        })
        track(Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.stop("the script timed out after \(Int(timeout)) s (timeout_s)")
        })
        queue.async { self.start(script) }

        let result = await withCheckedContinuation { continuation in
            let ready: Result<String, Failure>? = lock.withLock {
                if outcome == nil { waiter = continuation }
                return outcome
            }
            if let ready { continuation.resume(returning: ready) }
        }
        lock.withLock { () -> [Task<Void, Never>] in defer { tasks = [] }; return tasks }.forEach { $0.cancel() }
        inputQueue.finish()
        // Drop the JavaScript on its own queue, behind whatever it is still doing.
        queue.async { self.pending = [:]; self.context = nil }
        let (lines, trace, images, unfinished) = lock.withLock { (logLines, traceLines, snapshots, unfinishedInput) }
        return Report(result: result, log: lines, trace: trace, snapshots: images,
                      elapsed: Date().timeIntervalSince(started), unfinishedInput: unfinished)
    }

    /// The number the new snapshot got, from 1; throws once the cap is reached.
    func attach(_ jpeg: Data, caption: (Int) -> String) throws -> Int {
        try lock.withLock {
            guard snapshots.count < Self.maxSnapshots else {
                throw MCPTools.Failure("at most \(Self.maxSnapshots) snapshots per run; use a region and fewer calls")
            }
            snapshots.append(Snapshot(jpeg: jpeg, caption: caption(snapshots.count + 1)))
            return snapshots.count
        }
    }

    /// The banner's Stop, a disconnecting client, a closed window, a timeout.
    func stop(_ reason: String) {
        finish(.failure(Failure(message: reason)))
    }

    private func finish(_ result: Result<String, Failure>) {
        let waiting: CheckedContinuation<Result<String, Failure>, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: result)
    }

    private func track(_ task: Task<Void, Never>) {
        let finished = lock.withLock { () -> Bool in
            if outcome == nil { tasks.append(task) }
            return outcome != nil
        }
        if finished { task.cancel() }
    }

    @MainActor
    private func perform(_ op: Op) async {
        guard !isFinished else { return }
        let result: Result<String, Error>
        do {
            let value = try await Session.$isAutomation.withValue(true) {
                try await ScriptOps.run(op.name, op.args, in: self)
            }
            result = .success(MCPTools.encode(value))
        } catch {
            result = .failure(error)
        }
        queue.async { self.settle(op.id, result) }
    }

    // MARK: - JavaScript (script queue)

    private func start(_ script: String) {
        guard !isFinished, let context = JSContext(virtualMachine: JSVirtualMachine()) else { return }
        self.context = context
        limitRunTime(context)
        context.exceptionHandler = { [weak self] _, exception in self?.uncaught(exception) }

        let call: @convention(block) (String, String) -> JSValue? = { [weak self] name, args in
            self?.call(name, args, isInput: Self.inputOps.contains(name))
        }
        let sleep: @convention(block) (Double) -> JSValue? = { [weak self] ms in
            self?.sleep(ms)
        }
        let say: @convention(block) (String) -> Void = { [weak self] text in
            self?.lock.withLock {
                guard let self, self.logLines.count < 500 else { return }
                self.logLines.append(String(text.prefix(4000)))
            }
        }
        let trace: @convention(block) (String) -> Void = { [weak self] text in
            self?.lock.withLock {
                guard let self, self.traceLines.count < 300 else { return }
                self.traceLines.append(String(text.prefix(300)))
            }
        }
        let done: @convention(block) (String) -> Void = { [weak self] json in
            guard let self, returned == nil else { return }
            returned = .success(json)
        }
        let fail: @convention(block) (String, Double) -> Void = { [weak self] message, line in
            guard let self, returned == nil else { return }
            returned = .failure(Failure(message: message, line: line > 0 ? Int(line) : nil))
        }
        for (name, block) in [("__call", call as Any), ("__sleep", sleep), ("__log", say), ("__trace", trace),
                              ("__done", done), ("__fail", fail)] {
            context.setObject(block, forKeyedSubscript: name as NSString)
        }
        context.evaluateScript(Self.prelude, withSourceURL: URL(string: "regi.js"))
        context.evaluateScript(Self.wrapped(script), withSourceURL: URL(string: "script.js"))
        afterTurn()
    }

    private func promise(isInput: Bool) -> (id: Int, promise: JSValue?) {
        let id = nextID
        nextID += 1
        let promise = JSValue(newPromiseIn: JSContext.current()) { resolve, reject in
            if let resolve, let reject { self.pending[id] = Pending(resolve: resolve, reject: reject, isInput: isInput) }
        }
        return (id, promise)
    }

    private func call(_ name: String, _ args: String, isInput: Bool) -> JSValue? {
        let (id, promise) = promise(isInput: isInput)
        issued.append(Op(id: id, name: name, args: args))
        return promise
    }

    private func sleep(_ ms: Double) -> JSValue? {
        let (id, promise) = promise(isInput: false)
        let delay = ms.isFinite ? min(max(ms, 0), 600_000) : 0
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { self.settle(id, .success("null")) }
        return promise
    }

    private func settle(_ id: Int, _ result: Result<String, Error>) {
        guard let entry = pending.removeValue(forKey: id), let context, !isFinished else { return }
        switch result {
        case .success(let json):
            entry.resolve.call(withArguments: [json])
        case .failure(let error):
            entry.reject.call(withArguments: [JSValue(newErrorFromMessage: "\(error)", in: context) as Any])
        }
        afterTurn()
    }

    /// An exception no promise caught: a syntax error, or the watchdog's stop.
    private func uncaught(_ exception: JSValue?) {
        guard returned == nil, let exception else { return }
        let inScript = exception.objectForKeyedSubscript("sourceURL")?.toString() == "script.js"
        let line = exception.objectForKeyedSubscript("line")?.toInt32() ?? 0
        returned = .failure(Failure(message: exception.toString() ?? "unknown error",
                                    line: inScript && line > 0 ? Int(line) : nil))
    }

    /// After every entry into JavaScript: start what this turn issued, or, if
    /// the script has returned or been stopped, drop it.
    private func afterTurn() {
        if lock.withLock({ ranAway }) {
            returned = .failure(Failure(message: "the script ran for over a second without awaiting anything, so it was stopped (an endless loop?)"))
        }
        if returned != nil || isFinished {
            if case .success = returned {
                let unfinished = pending.values.filter(\.isInput).count
                lock.withLock { unfinishedInput = unfinished }
            }
            issued.removeAll()
            pending.removeAll()
            if let returned { finish(returned) }
            return
        }
        let ops = issued
        issued.removeAll()
        for op in ops {
            if Self.inputOps.contains(op.name) {
                inputQueue.yield(op)
            } else {
                track(Task { @MainActor [weak self] in await self?.perform(op) })
            }
        }
    }

    // MARK: - Watchdog

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    /// `JSContextGroupSetExecutionTimeLimit` is in JavaScriptCore's private
    /// header but exported since macOS 10.6, and checked to stop a busy loop
    /// both on first entry and after an `await`. Regi ships outside the App
    /// Store, so a private symbol is no review risk; looked up at run time so
    /// its absence costs only the guard.
    private static let setTimeLimit: SetTimeLimit? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            log.error("JSContextGroupSetExecutionTimeLimit is missing: a script stuck in a loop keeps its thread until Regi quits")
            return nil
        }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
    }()

    /// One second of JavaScript per entry: plenty for glue code, which spends
    /// its time awaiting Regi.
    private func limitRunTime(_ context: JSContext) {
        Self.setTimeLimit?(JSContextGetGroup(context.jsGlobalContextRef), 1, { _, info in
            guard let info else { return true }
            let run = Unmanaged<ScriptRun>.fromOpaque(info).takeUnretainedValue()
            run.lock.withLock { run.ranAway = true }
            return true
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Source

    /// On the script's own first line, so error lines are the script's.
    private static func wrapped(_ script: String) -> String {
        "(async () => { " + script + """

            })().then(
              (value) => {
                let json;
                try { json = value === undefined ? "null" : JSON.stringify(value); }
                catch (error) { return __fail("the returned value isn't JSON: " + error.message, -1); }
                __done(json === undefined ? "null" : json);
              },
              (error) => __fail(
                error instanceof Error ? (error.name === "Error" ? error.message : error.name + ": " + error.message) : String(error),
                (error && (error.scriptLine ?? __lineOf(error.stack))) ?? -1));
            """
    }

    /// The API scripts see, over `__call`, `__sleep` and `__log`.
    private static let prelude = #"""
        "use strict";
        (() => {
          const native = { call: __call, sleep: __sleep, log: __log, trace: __trace };
          const started = Date.now();
          const trace = (text) => native.trace(`${((Date.now() - started) / 1000).toFixed(1)} s  ${text}`);
          const quote = (text, limit = 60) => JSON.stringify(text.length > limit ? text.slice(0, limit) + "…" : text);

          const lineOf = (stack) => {
            const match = /script\.js:(\d+)/.exec(String(stack ?? ""));
            return match ? Number(match[1]) : undefined;
          };
          globalThis.__lineOf = lineOf;

          // Each API function remembers the script line that called it and
          // puts it on any error, so a failure points at the script.
          const api = (fn) => function (...args) {
            const line = lineOf(new Error().stack);
            return fn.apply(this, args).catch((error) => {
              if (!(error instanceof Error)) error = new Error(String(error));
              if (error.scriptLine === undefined) error.scriptLine = line;
              throw error;
            });
          };

          const op = async (name, args) => JSON.parse(await native.call(name, JSON.stringify(args ?? {})));

          // Vision reads some Latin letters as Cyrillic or Greek look-alikes
          // (a white-on-blue "OK" came back as "oк"): match on the Latin.
          const lookalikes = {
            "а": "a", "е": "e", "ё": "e", "і": "i", "ј": "j", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p",
            "с": "c", "т": "t", "у": "y", "х": "x", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w",
            "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
            "У": "Y", "Х": "X", "Ѕ": "S", "І": "I", "Ј": "J",
            "α": "a", "ε": "e", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x",
            "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O",
            "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
          };
          const latin = (s) => String(s).replace(/[^\u0000-\u007f]/g, (c) => lookalikes[c] ?? c);
          const plain = (s) => latin(s).toLowerCase().replace(/\s+/g, " ").trim();
          const describe = (what) => (what instanceof RegExp ? String(what) : JSON.stringify(String(what)));
          const visible = (lines) => (lines.length ? lines.slice(0, 80).map((l) => l.text).join(" | ") : "no text");

          // Strings: case-insensitive substring, exact matches winning.
          const select = (lines, what) => {
            if (what instanceof RegExp) {
              const test = (s) => { what.lastIndex = 0; return what.test(s); };
              return lines.filter((l) => test(l.text) || test(latin(l.text)));
            }
            const wanted = plain(what);
            if (!wanted) throw new Error("the text to look for is empty");
            const exact = lines.filter((l) => plain(l.text) === wanted);
            return exact.length ? exact : lines.filter((l) => plain(l.text).includes(wanted));
          };

          const read = (region) => op("ocr", region ? { region } : {});

          // A target as the trace shows it: what it was asked as, and where it landed.
          const label = (target, at) => {
            const asked = target instanceof RegExp ? String(target)
              : typeof target === "string" ? quote(target)
              : target && typeof target.text === "string" ? quote(target.text) : null;
            return asked ? `${asked} → (${at.x}, ${at.y})` : `(${at.x}, ${at.y})`;
          };

          const point = async (target) => {
            if (target && typeof target === "object" && !(target instanceof RegExp)) {
              if (typeof target.x !== "number" || typeof target.y !== "number") {
                throw new Error(`a target object needs numeric x and y; got ${JSON.stringify(target)}`);
              }
              return { x: target.x, y: target.y };
            }
            if (typeof target !== "string" && !(target instanceof RegExp)) {
              throw new Error(`a target is text, a RegExp, a line from screen.text() or {x, y}; got ${typeof target}`);
            }
            const lines = await read();
            const found = select(lines, target);
            if (found.length === 1) return { x: found[0].x, y: found[0].y };
            if (!found.length) throw new Error(`no text on screen matches ${describe(target)}. On screen: ${visible(lines)}`);
            const where = found.map((l) => `${JSON.stringify(l.text)} at (${l.x}, ${l.y})`).join("; ");
            throw new Error(`${found.length} lines match ${describe(target)}: ${where}. Pass one of them, or {x, y}.`);
          };

          // A trailing plain object is the options.
          const split = (args) => {
            const last = args[args.length - 1];
            return last && typeof last === "object" && !Array.isArray(last) ? [args.slice(0, -1), last] : [args, {}];
          };

          const screen = {
            size: api(async () => op("size")),
            text: api(async (region) => read(region)),
            find: api(async (what, region) => select(await read(region), what)),
            elements: api(async (region) => op("elements", region ? { region } : {})),
            waitForText: api(async (what, { timeoutS = 30, gone = false, region } = {}) => {
              const begun = Date.now(), deadline = begun + timeoutS * 1000;
              const waited = () => `${((Date.now() - begun) / 1000).toFixed(1)} s`;
              for (;;) {
                const lines = await read(region);
                const found = select(lines, what);
                if (!gone && found.length) {
                  trace(`waitForText ${describe(what)}: ${quote(found[0].text)} at (${found[0].x}, ${found[0].y}) after ${waited()}`);
                  return found[0];
                }
                if (gone && !found.length) {
                  trace(`waitForText ${describe(what)} gone after ${waited()}`);
                  return null;
                }
                if (Date.now() >= deadline) {
                  throw new Error(`waited ${timeoutS} s for ${describe(what)} to ${gone ? "disappear" : "appear"}. On screen: ${visible(lines)}`);
                }
                await native.sleep(200);
              }
            }),
            waitStable: api(async ({ quietMs = 500, timeoutS = 10 } = {}) => {
              const result = await op("stable", { quiet_ms: quietMs, timeout_s: timeoutS });
              trace(`waitStable: ${result.stable ? "stable" : "still changing"} after ${result.elapsed_ms} ms`);
              return result.stable;
            }),
            snapshot: api(async (...args) => {
              const [[caption], { region, maxWidth = 1280, marks }] = split(args);
              if (marks !== undefined && !Array.isArray(marks)) throw new Error("marks is an array of elements or lines");
              const result = await op("snapshot", {
                label: caption === undefined ? "" : String(caption), region, max_width: maxWidth,
                marks: marks?.map((m) => ({ box: m?.box })),
              });
              trace(`snapshot ${result.number}${caption === undefined ? "" : " " + quote(String(caption))}${marks ? `, ${marks.length} marks` : ""}`);
            }),
          };

          const keys = {
            press: api(async (...args) => {
              const [chords, { intervalMs = 100 }] = split(args);
              const list = chords.flat().map(String);
              if (!list.length) throw new Error('keys.press needs a chord, e.g. keys.press("enter")');
              await op("press", { chords: list, interval_ms: intervalMs });
              trace(`press ${list.join(", ")}`);
            }),
            type: api(async (text, { delayMs = 15 } = {}) => {
              await op("type", { text: String(text), delay_ms: delayMs });
              trace(`type ${quote(String(text))}`);
            }),
          };

          const pointer = {
            click: api(async (target, { button = "left", count = 1 } = {}) => {
              const at = target === undefined ? {} : await point(target);
              await op("click", { ...at, button, count });
              const how = (button === "left" ? "" : ` ${button}`) + (count > 1 ? ` ×${count}` : "");
              trace(`click${how} ${target === undefined ? "at the pointer" : label(target, at)}`);
            }),
            move: api(async (target, { durationMs = 0 } = {}) => {
              const at = await point(target);
              await op("move", { ...at, duration_ms: durationMs });
              trace(`move ${label(target, at)}`);
            }),
            drag: api(async (from, to, { durationMs = 300, button = "left" } = {}) => {
              const a = await point(from), b = await point(to);
              await op("drag", { from_x: a.x, from_y: a.y, to_x: b.x, to_y: b.y, duration_ms: durationMs, button });
              trace(`drag ${label(from, a)} to ${label(to, b)}`);
            }),
            scroll: api(async (dy = 0, dx = 0) => {
              await op("scroll", { dy, dx });
              trace(`scroll dy=${dy} dx=${dx}`);
            }),
          };

          const sleep = api(async (ms) => { await native.sleep(Number(ms) || 0); trace(`sleep ${Number(ms) || 0} ms`); });
          const show = (value) => {
            if (typeof value === "string") return value;
            try { return JSON.stringify(value) ?? String(value); } catch { return String(value); }
          };
          const log = (...values) => native.log(values.map(show).join(" "));

          Object.assign(globalThis, {
            screen, keys, pointer, sleep, log,
            console: { log, info: log, warn: log, error: log, debug: log },
            setTimeout: (fn, ms = 0, ...args) => { native.sleep(Number(ms) || 0).then(() => fn(...args)); return 0; },
          });
        })();
        """#
}
