// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import KVMKit
import MCP
import Network
import OSLog
import SwiftUI

private let log = Logger(subsystem: "app.regi.mcp", category: "server")
private let activityLog = Logger(subsystem: "app.regi.mcp", category: "activity")

/// Regi's MCP server: lets an LLM client drive the hosts the user opens.
///
/// The protocol runs in the app, on a Unix socket only this user can reach.
/// MCP clients launch the bundled `regi-mcp` (MCPBridge/main.swift), which
/// relays their stdio to that socket — the same shape as TablePlus's
/// `tableplus-mcp`. A user-only socket needs no token and no TLS, and has no
/// TCP port for a browser to reach.
///
/// Sessions are always ordinary Regi windows, so the user sees everything an
/// agent does; the session windows show a banner while a client is connected
/// and every tool call lands in `activity`.
@MainActor
@Observable
final class MCPHost {
    static let shared = MCPHost()

    static let enabledKey = "RegiMCPServerEnabled"

    /// Both paths must match `MCPBridge/main.swift`, which can't import this
    /// target. Tests move them with a `-RegiMCPDirectory` launch argument
    /// (and `REGI_MCP_DIR` for the relay), so a test build can serve next to
    /// the Regi the user is running.
    static let directory = UserDefaults.standard.string(forKey: "RegiMCPDirectory")
        ?? NSHomeDirectory() + "/Library/Application Support/Regi"
    static let socketPath = directory + "/mcp.sock"
    /// What `regi-mcp` lists while Regi isn't running.
    static let toolCachePath = directory + "/mcp-tools.json"

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// The relay MCP clients launch, inside this app's bundle.
    static var bridgePath: String {
        Bundle.main.url(forAuxiliaryExecutable: "regi-mcp")?.path
            ?? Bundle.main.bundlePath + "/Contents/MacOS/regi-mcp"
    }

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    /// A session window registered by `KVMSessionWindow`.
    struct OpenSession {
        let windowID: KVMSessionWindowID
        let session: Session
        let close: () -> Void
        /// Re-runs the window's bandwidth gate.
        let gate: () -> Void
        var id: String { Self.id(windowID.host, windowID.port) }
        static func id(_ host: String, _ port: Int) -> String { "\(host):\(port)" }
    }

    struct Connection: Identifiable {
        let id: UUID
        var name: String
        let server: Server
    }

    struct Activity: Identifiable {
        let id = UUID()
        let time: Date
        let client: String
        let session: String
        let tool: String
        let details: String
        let result: String
        let isError: Bool
        let duration: TimeInterval
    }

    private(set) var status: Status = .stopped
    private(set) var sessions: [String: OpenSession] = [:]
    private(set) var connections: [UUID: Connection] = [:] {
        // Clients count as someone watching: session windows keep video
        // running while any is connected and may pause once none is.
        didSet {
            if connections.isEmpty != oldValue.isEmpty {
                for open in sessions.values { open.gate() }
            }
        }
    }
    private(set) var activity: [Activity] = []
    /// The running `run_script` calls, by session id: one per session. The
    /// session windows show a banner with a Stop button for each.
    var scripts: [String: ScriptRun] = [:]

    /// Handed over by `HostsView`, the first view up: `open_session` needs a
    /// SwiftUI `openWindow` and the saved hosts.
    var openWindow: OpenWindowAction?
    var hostStore: HostStore?

    private var listener: NWListener?

    func clientName(_ connection: UUID) -> String {
        connections[connection]?.name ?? "client"
    }

    /// Stops the scripts a client started, or every script.
    private func stopScripts(from connection: UUID? = nil, because reason: String) {
        for run in scripts.values where connection == nil || run.connection == connection {
            run.stop(reason)
        }
    }

    // MARK: - Lifecycle

    /// Start or stop to match the persisted toggle.
    func applySettings() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() } else { stop() }
    }

    /// The banner's Stop: disconnect everyone and stay off.
    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stop()
    }

    private func start() {
        guard listener == nil else { return }
        do {
            try Self.prepareSocketDirectory()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: Self.socketPath)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            writeToolCache()
        } catch {
            status = .failed("\(error)")
            log.error("MCP server not started: \(error, privacy: .public)")
        }
    }

    private func stop() {
        let wasServing = listener != nil
        listener?.cancel()
        listener = nil
        stopScripts(because: "Regi's MCP server was turned off")
        for connection in connections.values {
            Task { await connection.server.stop() }
        }
        connections.removeAll()
        // Only our own socket: after a failed start it may be another Regi's.
        if wasServing { unlink(Self.socketPath) }
        status = .stopped
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            // The listener creates the socket with the process umask (0755);
            // the 0700 directory already keeps others out, this makes it explicit.
            chmod(Self.socketPath, 0o600)
            status = .running
            log.notice("MCP server listening at \(Self.socketPath, privacy: .public)")
        case .failed(let error):
            status = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    /// Creates the 0700 directory and clears a stale socket. Refuses when the
    /// path can't work or another Regi (a second build, say) is serving it:
    /// unlinking its socket would silently strand that instance's clients.
    private static func prepareSocketDirectory() throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        // NWListener reports .ready even when the path doesn't fit, and then
        // never creates the file — so check up front.
        guard socketPath.utf8.count < capacity else {
            throw SetupError(description: "socket path is \(socketPath.utf8.count) bytes, over the \(capacity - 1)-byte limit: \(socketPath)")
        }
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        if someoneIsListening(at: socketPath) {
            throw SetupError(description: "another Regi is already serving MCP at \(socketPath)")
        }
        unlink(socketPath)
    }

    private struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    private static func someoneIsListening(at path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withCString { _ = strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    // MARK: - Clients

    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        let server = Server(name: "Regi", version: Self.version, instructions: MCPTools.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        connections[id] = Connection(id: id, name: "client", server: server)

        let transport = NetworkTransport(connection: nwConnection, heartbeatConfig: .disabled,
                                         reconnectionConfig: .disabled)
        Task {
            await MCPTools.install(on: server, connection: id)
            do {
                try await server.start(transport: transport) { info, _ in
                    await MainActor.run { MCPHost.shared.connections[id]?.name = "\(info.name) \(info.version)" }
                }
                await server.waitUntilCompleted()
            } catch {
                log.error("MCP client failed: \(error, privacy: .public)")
            }
            await server.stop()
            MCPHost.shared.connections[id] = nil
            MCPHost.shared.stopScripts(from: id, because: "the MCP client disconnected")
        }
    }

    /// The handshake details and tools `regi-mcp` offers while Regi isn't
    /// running, so a client that starts first still sees what Regi can do.
    private func writeToolCache() {
        struct Info: Encodable { let name: String, version: String }
        struct Cache: Encodable { let serverInfo: Info, instructions: String, tools: [Tool] }
        let cache = Cache(serverInfo: Info(name: "Regi", version: Self.version),
                          instructions: MCPTools.instructions, tools: MCPTools.definitions)
        do {
            try JSONEncoder().encode(cache).write(to: URL(fileURLWithPath: Self.toolCachePath), options: .atomic)
        } catch {
            log.error("couldn't write the MCP tool cache: \(error, privacy: .public)")
        }
    }

    // MARK: - Sessions

    func register(_ windowID: KVMSessionWindowID, session: Session,
                  close: @escaping () -> Void, gate: @escaping () -> Void) {
        let open = OpenSession(windowID: windowID, session: session, close: close, gate: gate)
        sessions[open.id] = open
    }

    func unregister(_ windowID: KVMSessionWindowID, session: Session) {
        let id = OpenSession.id(windowID.host, windowID.port)
        if sessions[id]?.session === session { sessions[id] = nil }
        if let run = scripts[id], run.open.session === session { run.stop("the session's window was closed") }
    }

    // MARK: - Activity

    func record(_ entry: Activity) {
        activity.append(entry)
        if activity.count > 1000 { activity.removeFirst(activity.count - 1000) }
        // Details can carry typed text or screen text: private in unified logs.
        activityLog.notice("\(entry.client, privacy: .public) \(entry.tool, privacy: .public) \(entry.session, privacy: .public) \(entry.details, privacy: .private) -> \(entry.result, privacy: .public)")
    }

    func clearActivity() {
        activity.removeAll()
    }
}
