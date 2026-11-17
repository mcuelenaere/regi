// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import KVMCore
import KVMWebRTC
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "os-services")

/// JetKVM OS Services (jetkvm/kvm#1769, jetkvm/os-services): a sender
/// program on the host talks to the KVM over its USB cable, and the KVM
/// relays its clipboard and file services to us. Its video needs nothing
/// from us — it arrives on the same video track as HDMI capture.
///
/// Runs next to the tinypipe agent (`ClipboardBridge`), which wins while
/// it is connected: it carries more (images, files both ways) and pushes
/// its changes.
extension JetKVMBackend {

    /// The service's text limit, in UTF-8 bytes (PROTOCOL.md, clipboard).
    static let guestClipboardMaxBytes = 65_528

    // MARK: - Clipboard

    /// Called whenever an input of the clipboard's availability changes.
    func updateTextClipboard() {
        let guest = videoState?.guestClipboard
        let available = rpcReady && clipboardAgentState != .active
            && (guest?.read == true || guest?.write == true)
        guard available != textClipboard.isAvailable else { return }
        textClipboard.isAvailable = available
        lastGuestClipboardText = nil
        log.info("OS Services clipboard \(available ? "available" : "unavailable", privacy: .public)")
        // What is on the host's clipboard now was put there before sync
        // started: note it, so only a later copy reaches this Mac.
        if available { fetchGuestClipboard(apply: false) }
    }

    /// The service never sends a change of its own, so the host's clipboard
    /// is read when asked; text that differs from what we last saw there
    /// goes to `onRemoteText`.
    func fetchGuestClipboard(apply: Bool = true) {
        guard textClipboard.isAvailable, videoState?.guestClipboard?.read == true else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let content: GuestClipboardContent
            do {
                content = try await guestClipboardGet()
            } catch {
                log.error("guestClipboardGet failed: \(describeRPCError(error), privacy: .public)")
                return
            }
            guard content.status == "ok" else {
                log.debug("guestClipboardGet: \(content.status, privacy: .public)")
                return
            }
            guard textClipboard.isAvailable, content.text != lastGuestClipboardText else { return }
            lastGuestClipboardText = content.text
            guard apply else { return }
            if content.truncated { log.notice("guestClipboardGet: host truncated its text") }
            textClipboard.onRemoteText?(content.text)
        }
    }

    func setGuestClipboard(_ text: String?) {
        guard let text, !text.isEmpty, textClipboard.isAvailable,
              videoState?.guestClipboard?.write == true else { return }
        guard text.utf8.count <= Self.guestClipboardMaxBytes else {
            log.notice("local clipboard text is \(text.utf8.count, privacy: .public) bytes, over OS Services' \(Self.guestClipboardMaxBytes, privacy: .public); not sent")
            return
        }
        // Noted before the answer, so a read that crosses this write can't
        // bring the host's previous text back over the one just copied.
        let previous = lastGuestClipboardText
        lastGuestClipboardText = text
        Task { @MainActor [weak self] in
            guard let self else { return }
            var status = "failed"
            do {
                status = try await guestClipboardSet(text)
            } catch {
                log.error("guestClipboardSet failed: \(describeRPCError(error), privacy: .public)")
            }
            guard status != "ok" else { return }
            log.notice("guestClipboardSet: \(status, privacy: .public)")
            if lastGuestClipboardText == text { lastGuestClipboardText = previous }
        }
    }

    // MARK: - File drop

    /// True while the host's sender takes files (into its Downloads folder).
    public var canDropFiles: Bool {
        rpcReady && videoState?.guestFile?.receive == true
    }

    /// Send files to the host's Downloads folder. Folders are skipped; one
    /// drop runs at a time. Progress and the outcome show in `fileDrop`.
    public func dropFiles(_ urls: [URL]) {
        guard canDropFiles, fileDropTask == nil, let webrtc else { return }
        let files: [(url: URL, size: UInt64)] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { return nil }
            return (url, UInt64(size))
        }
        guard !files.isEmpty else {
            fileDrop = FileDropStatus(fileCount: 0, totalBytes: 0, outcome: "Only files can be sent, not folders.")
            clearFileDropOutcome()
            return
        }
        fileDrop = FileDropStatus(fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
        fileDropTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await sendFileDrop(files, skipped: urls.count - files.count, webrtc: webrtc)
            log.info("file drop: \(outcome, privacy: .public)")
            fileDrop?.outcome = outcome
            fileDropTask = nil
            clearFileDropOutcome()
        }
    }

    /// Stop the running drop. The KVM cancels whatever the host hasn't
    /// written yet; written files stay.
    public func cancelFileDrop() {
        fileDropTask?.cancel()
    }

    private func clearFileDropOutcome() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, fileDrop?.outcome != nil else { return }
            fileDrop = nil
        }
    }

    private func sendFileDrop(_ files: [(url: URL, size: UInt64)], skipped: Int,
                              webrtc: WebRTCFacade) async -> String {
        // The host compares names byte for byte; macOS hands out
        // decomposed ones.
        let names = files.map { $0.url.lastPathComponent.precomposedStringWithCanonicalMapping }
        let drop: GuestFileDropResult
        do {
            drop = try await guestFileDrop(zip(names, files).map { ($0, $1.size) })
        } catch {
            return "Couldn't send: \(describeRPCError(error))"
        }
        guard drop.transfers.count == files.count,
              let channel = await webrtc.openDataChannel(label: drop.channel) else {
            return "Couldn't open the file channel."
        }
        defer { channel.close() }
        let transfers = zip(files, drop.transfers).map {
            GuestFileSender.File(url: $0.url, size: $0.size, transfer: $1)
        }
        let statuses = await GuestFileSender.run(
            transfers,
            messages: channel.textMessages,
            send: { await channel.send($0, isBinary: $1, highWaterMark: GuestFileSender.highWaterMark) },
            progress: { [weak self] sent in
                Task { @MainActor in self?.fileDrop?.sentBytes = sent }
            }
        )
        let failed = zip(names, transfers).filter { statuses[$1.transfer] != "ok" }
        let folders = skipped > 0 ? " Folders were skipped." : ""
        if failed.isEmpty {
            let what = names.count == 1 ? names[0] : "\(names.count) files"
            return "Sent \(what) to the host's Downloads folder.\(folders)"
        }
        if Task.isCancelled { return "Cancelled." }
        let list = failed.map { "\($0.0) (\(statuses[$0.1.transfer] ?? "cancelled"))" }
        return "Couldn't send \(list.joined(separator: ", ")).\(folders)"
    }
}

/// Progress of a file drop, for the App's banner.
public struct FileDropStatus: Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: UInt64
    public var sentBytes: UInt64 = 0
    /// Nil while sending; then one line saying how it ended.
    public var outcome: String?
}

/// The JetKVM's own reason for a failed call (it puts `err.Error()` in the
/// error's `data`), else the error.
func describeRPCError(_ error: Error) -> String {
    if case JSONRPCClientError.server(let object) = error {
        return object.data ?? object.message
    }
    return String(describing: error)
}

/// Streams the files of one OS Services drop over its `guestfile_<drop>`
/// channel (firmware `os_services_channels.go`). Each binary message is a
/// 4-byte little-endian transfer ID and file bytes, sent only within the
/// credit the host grants. The KVM's text messages are
/// `{"type":"credit","transfer":N,"bytes":B}` (credit added) and
/// `{"type":"done","transfer":N,"status":"ok|failed|cancelled"}`; a text
/// `{"type":"cancel","transfer":N}` from us stops a transfer.
enum GuestFileSender {
    struct File {
        let url: URL
        let size: UInt64
        let transfer: UInt32
    }

    /// Bytes per message; the KVM relays each as `file.chunk`s.
    static let chunkBytes: UInt64 = 32 * 1024
    /// Queued bytes before sending pauses. The firmware's own UI keeps a
    /// burst well under the JetKVM's UDP receive buffer: overrunning it
    /// collapses the congestion window for the rest of the transfer.
    static let highWaterMark: UInt64 = 96 * 1024

    private struct Message: Decodable {
        let type: String
        let transfer: UInt32?
        let bytes: UInt64?
        let status: String?
    }

    /// Returns each transfer's final status ("ok", "failed", "cancelled");
    /// a transfer the channel closed on is missing. `progress` gets the
    /// bytes sent so far, at most every 100 ms.
    static func run(
        _ files: [File],
        messages: AsyncStream<String>,
        send: (Data, _ isBinary: Bool) async -> Bool,
        progress: (UInt64) -> Void
    ) async -> [UInt32: String] {
        var credit: [UInt32: UInt64] = [:]
        var handles: [UInt32: FileHandle] = [:]
        var sent: [UInt32: UInt64] = [:]
        var statuses: [UInt32: String] = [:]
        var total: UInt64 = 0
        var reported = ContinuousClock.now
        defer { for handle in handles.values { try? handle.close() } }

        func pump(_ file: File) async {
            while credit[file.transfer, default: 0] > 0, sent[file.transfer, default: 0] < file.size,
                  statuses[file.transfer] == nil, !Task.isCancelled {
                let n = min(chunkBytes, credit[file.transfer]!, file.size - sent[file.transfer, default: 0])
                var message = withUnsafeBytes(of: file.transfer.littleEndian) { Data($0) }
                do {
                    if handles[file.transfer] == nil { handles[file.transfer] = try FileHandle(forReadingFrom: file.url) }
                    let bytes = try handles[file.transfer]!.read(upToCount: Int(n)) ?? Data()
                    guard bytes.count == Int(n) else { throw CocoaError(.fileReadCorruptFile) }
                    message.append(bytes)
                } catch {
                    log.error("file drop: reading \(file.url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    statuses[file.transfer] = "failed"
                    _ = await send(Data(#"{"type":"cancel","transfer":\#(file.transfer)}"#.utf8), false)
                    return
                }
                guard await send(message, true) else { return }
                sent[file.transfer, default: 0] += n
                credit[file.transfer]! -= n
                total += n
                if reported.duration(to: .now) >= .milliseconds(100) || sent[file.transfer] == file.size {
                    reported = .now
                    progress(total)
                }
            }
        }

        for await text in messages {
            guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)),
                  let transfer = message.transfer,
                  let file = files.first(where: { $0.transfer == transfer }) else { continue }
            switch message.type {
            case "credit":
                credit[transfer, default: 0] += message.bytes ?? 0
                await pump(file)
            case "done":
                if statuses[transfer] == nil { statuses[transfer] = message.status ?? "failed" }
                try? handles.removeValue(forKey: transfer)?.close()
            default:
                continue
            }
            if statuses.count == files.count || Task.isCancelled { break }
        }
        return statuses
    }
}
