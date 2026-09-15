import Foundation

/// Contract between Regi and its File Provider extension.
///
/// They are separate processes: the extension is where macOS asks for a
/// file's bytes, but the `ClipboardBridge` that can produce them lives
/// with the WebRTC session in the app. So the extension calls back into
/// the app over the connection the app opens to its service.
///
/// The app is the one that exports an object here; the extension only
/// consumes it. If Regi isn't running there is nothing to serve, which
/// is correct rather than unfortunate — a clipboard promise is only
/// redeemable while its offer is still the host's current clipboard.
@objc protocol ClipboardFileHosting {

    /// The files the host clipboard is currently offering, as JSON-encoded
    /// `[ClipboardFileDescriptor]`.
    ///
    /// JSON rather than `NSSecureCoding` types: it keeps the XPC interface
    /// to primitives, so neither side needs a class allowlist that has to
    /// stay in sync across two targets.
    func listPromisedFiles(reply: @escaping (Data?) -> Void)

    /// Pull one file and hand back an open descriptor positioned at its
    /// start. Returns nil when the offer has been superseded, the peer
    /// refused, or the transfer failed.
    ///
    /// A `FileHandle` rather than a path on purpose: the extension is
    /// sandboxed and cannot open Regi's cache directory by name, but a
    /// descriptor passed across XPC carries its own access.
    func fetchPromisedFile(identifier: String, reply: @escaping (FileHandle?, String?) -> Void)
}

/// Implemented by the extension purely so the app has something to call.
///
/// An `NSXPCConnection` is lazy: the listener is not handed the
/// connection until a message actually crosses it. All the real traffic
/// here runs extension→app, so without one call in the other direction
/// the extension would never learn the connection exists and would
/// answer every request with "Regi is not running".
@objc protocol ClipboardFileProviderPinging {
    func ping(reply: @escaping (Bool) -> Void)
}

/// One file the host clipboard is offering, as the extension sees it.
struct ClipboardFileDescriptor: Codable, Equatable, Sendable {
    /// Stable within one offer; also the File Provider item identifier.
    /// Encodes the offer so a stale item can never resolve against a
    /// newer one — see `ClipboardFilePromise.clipboardId`.
    let identifier: String
    let filename: String
    let size: UInt64

    init(identifier: String, filename: String, size: UInt64) {
        self.identifier = identifier
        self.filename = filename
        self.size = size
    }
}

enum ClipboardFileProviderIPC {
    /// Service name the extension vends and the app asks for.
    static let serviceName = NSFileProviderServiceName("app.regi.mac.clipboard-files")

    static func hostInterface() -> NSXPCInterface {
        NSXPCInterface(with: ClipboardFileHosting.self)
    }

    static func providerInterface() -> NSXPCInterface {
        NSXPCInterface(with: ClipboardFileProviderPinging.self)
    }
}
