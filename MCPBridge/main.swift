// SPDX-License-Identifier: AGPL-3.0-or-later

// regi-mcp: the stdio end of Regi's MCP server. MCP clients start this (no
// arguments). It relays JSON-RPC between the client and the Unix socket the
// running Regi app serves MCP on; the tools live in the app (App/MCP).
//
// It works whether or not Regi is running, and never launches it. While Regi
// is away the relay answers the handshake itself, lists the tools Regi last
// advertised (the cache MCPHost writes) and turns calls into an error that
// says to open Regi. The first message after Regi appears connects, redoes the
// handshake on the client's behalf, and from then on lines pass through as
// they are. If Regi quits, requests it still owed get that same error.

import Darwin
import Foundation

/// REGI_MCP_DIR is for tests (Tools/mcp-harness/relay_check.py).
let directory = ProcessInfo.processInfo.environment["REGI_MCP_DIR"]
    ?? NSHomeDirectory() + "/Library/Application Support/Regi"
let socketPath = directory + "/mcp.sock"        // must match MCPHost.socketPath
let cachePath = directory + "/mcp-tools.json"   // must match MCPHost.toolCachePath
let offline = "Regi isn't running, or its MCP server is off. Ask the user to open Regi and turn on Settings ▸ MCP, then try again."
let handshakeID = "regi-mcp-handshake"

// A write to a closed peer should fail, not kill the process.
signal(SIGPIPE, SIG_IGN)

// MARK: - I/O

/// Newline-delimited reads from a file descriptor.
struct LineReader {
    let fd: Int32
    var buffer = Data()

    mutating func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[(newline + 1)...]
                return Data(line)
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written < 0, errno == EINTR { continue }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

let outputLock = NSLock()

/// One JSON-RPC message to the client. Both directions' threads write here.
func toClient(_ line: Data) {
    outputLock.withLock { _ = writeAll(STDOUT_FILENO, line + Data([0x0A])) }
}

func toClient(_ message: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: message) { toClient(data) }
}

func parse(_ line: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: line) as? [String: Any]
}

func result(_ id: Any, _ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
func failure(_ id: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": offline]] }

/// JSON-RPC ids are strings or numbers; keep 1 and "1" apart.
func key(_ id: Any) -> String { (id as? String).map { "s" + $0 } ?? "n\(id)" }

// MARK: - Regi

let stateLock = NSLock()
var upstream: Int32 = -1             // socket to Regi; -1 while it's away
var pending: [String: Any] = [:]     // requests forwarded to Regi and not yet answered
var clientInitialize: Any = [String: Any]()  // the client's initialize params, replayed to Regi

/// Connect and handshake as the client, so Regi's activity log names it.
/// Returns the socket, Regi's initialize result and any bytes read past it.
func connectToRegi() -> (fd: Int32, initialize: Any, reader: LineReader)? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard socketPath.utf8.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        socketPath.withCString { _ = strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity - 1) }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    let params = stateLock.withLock { clientInitialize }
    let hello: [String: Any] = ["jsonrpc": "2.0", "id": handshakeID, "method": "initialize", "params": params]
    guard connected == 0, let data = try? JSONSerialization.data(withJSONObject: hello),
          writeAll(fd, data + Data([0x0A])) else { close(fd); return nil }
    var reader = LineReader(fd: fd)
    while let line = reader.next() {
        guard let message = parse(line), message["id"] as? String == handshakeID else { continue }
        guard let initialize = message["result"],
              writeAll(fd, Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8) + Data([0x0A]))
        else { break }
        return (fd, initialize, reader)
    }
    close(fd)
    return nil
}

/// Pass Regi's messages to the client until it goes away, then fail what it
/// still owed.
func relayFromRegi(_ fd: Int32, _ reader: LineReader) {
    var reader = reader
    Thread {
        while let line = reader.next() {
            if let message = parse(line), message["method"] == nil, let id = message["id"] {
                _ = stateLock.withLock { pending.removeValue(forKey: key(id)) }
            }
            toClient(line)
        }
        let owed: [Any] = stateLock.withLock {
            if upstream == fd { upstream = -1 }
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        close(fd)
        for id in owed { toClient(failure(id)) }
    }.start()
}

/// The open socket to Regi, connecting first if there is none.
func regi() -> Int32? {
    if let fd = stateLock.withLock({ upstream >= 0 ? upstream : nil }) { return fd }
    guard let (fd, _, reader) = connectToRegi() else { return nil }
    stateLock.withLock { upstream = fd }
    relayFromRegi(fd, reader)
    return fd
}

/// What MCPHost last advertised: serverInfo, instructions and tools.
func cache() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: cachePath) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - Client

while let text = readLine(strippingNewline: true) {
    let line = Data(text.utf8)
    guard let message = parse(line) else { continue }
    let method = message["method"] as? String
    let id = message["id"]

    if method == "initialize", let id {
        stateLock.withLock { clientInitialize = message["params"] ?? [String: Any]() }
        if let (fd, initialize, reader) = connectToRegi() {
            stateLock.withLock { upstream = fd }
            relayFromRegi(fd, reader)
            toClient(result(id, initialize))
        } else {
            // ponytail: echoes the client's protocol version; Regi may settle
            // on an older one once it connects, which tools/* don't notice.
            let cached = cache()
            var initialize: [String: Any] = [
                "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": cached["serverInfo"] ?? ["name": "Regi", "version": "0"],
            ]
            initialize["instructions"] = cached["instructions"]
            toClient(result(id, initialize))
        }
        continue
    }
    // The relay sends its own when it connects to Regi.
    if method == "notifications/initialized" { continue }

    if let fd = regi() {
        if method != nil, let id { stateLock.withLock { pending[key(id)] = id } }
        if writeAll(fd, line + Data([0x0A])) { continue }
        // Regi went away under us: answer here unless its reader thread has.
        if let id, stateLock.withLock({ pending.removeValue(forKey: key(id)) }) != nil { toClient(failure(id)) }
        continue
    }
    guard let id, method != nil else { continue }   // notifications to nobody
    switch method {
    case "tools/list": toClient(result(id, ["tools": cache()["tools"] ?? []]))
    case "ping": toClient(result(id, [String: Any]()))
    // A tool error rather than a protocol error, so the model reads it.
    case "tools/call": toClient(result(id, ["content": [["type": "text", "text": offline]], "isError": true]))
    default: toClient(failure(id))
    }
}
exit(0)
