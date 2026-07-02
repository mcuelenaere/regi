import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "spice-proxy")

/// A `NWProtocolFramer` that performs an HTTP `CONNECT` tunnel to a target,
/// then becomes a transparent byte pass-through. Placed *below* TLS in the
/// protocol stack, so the flow is: TCP → CONNECT to proxy → TLS to the real
/// node → SPICE. Proxmox's `spiceproxy` (the `.vv` `proxy=` field) is a
/// standard HTTP CONNECT proxy, and the `.vv` `host` is an opaque routing
/// token the proxy resolves.
///
/// The per-connection CONNECT target is handed off via a small FIFO
/// (`enqueueTarget`) consumed in `start()`. Proxied channel setup must be
/// serialized (the backend connects channels one at a time), which keeps the
/// handoff unambiguous.
final class SpiceProxyTunnel: NWProtocolFramerImplementation {
    static let label = "SpiceProxyTunnel"
    static let definition = NWProtocolFramer.Definition(implementation: SpiceProxyTunnel.self)

    private static let lock = NSLock()
    private static var pendingTargets: [String] = []

    /// Enqueue the "host:port" a subsequent connection's framer should CONNECT
    /// to. Call immediately before starting that connection.
    static func enqueueTarget(_ target: String) {
        lock.lock(); pendingTargets.append(target); lock.unlock()
    }
    private static func dequeueTarget() -> String? {
        lock.lock(); defer { lock.unlock() }
        return pendingTargets.isEmpty ? nil : pendingTargets.removeFirst()
    }

    private var established = false
    private var target = ""

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        target = Self.dequeueTarget() ?? ""
        let request = "CONNECT \(target) HTTP/1.0\r\nHost: \(target)\r\n\r\n"
        framer.writeOutput(data: Data(request.utf8))
        // Become ready only once the proxy answers 200 (in handleInput).
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if established {
            return passThroughInput(framer)
        }
        // Accumulate until end-of-headers ("\r\n\r\n"), then check status.
        var headerLength = 0
        var status = 0
        var sawTerminator = false
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65535) { buffer, isComplete in
            guard let buffer, buffer.count > 0 else { return 0 }
            let bytes = Data(bytes: buffer.baseAddress!, count: buffer.count)
            guard let range = bytes.firstRange(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                _ = isComplete
                return 0   // need more; consume nothing
            }
            headerLength = range.upperBound
            status = Self.parseStatus(bytes.prefix(range.lowerBound))
            sawTerminator = true
            return headerLength   // consume exactly the header
        }
        if sawTerminator {
            if status == 200 {
                established = true
                log.debug("proxy CONNECT to \(self.target, privacy: .public) established")
                framer.markReady()
            } else {
                log.error("proxy CONNECT rejected: HTTP \(status)")
                // No markReady → the connect-level timeout in
                // SpiceChannelConnection surfaces this as a failure.
            }
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance,
                      message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        // Transparent pass-through of upper-layer (TLS / SPICE) output.
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: -

    private func passThroughInput(_ framer: NWProtocolFramer.Instance) -> Int {
        let message = NWProtocolFramer.Message(definition: Self.definition)
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65535) { buffer, isComplete in
            guard let buffer, buffer.count > 0 else { return 0 }
            let data = Data(bytes: buffer.baseAddress!, count: buffer.count)
            _ = framer.deliverInput(data: data, message: message, isComplete: isComplete)
            return buffer.count
        }
        return 0
    }

    private static func parseStatus(_ header: Data) -> Int {
        // First line: "HTTP/1.x <code> <reason>".
        guard let line = String(data: header, encoding: .utf8)?
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return 0 }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return 0 }
        return Int(parts[1]) ?? 0
    }
}
