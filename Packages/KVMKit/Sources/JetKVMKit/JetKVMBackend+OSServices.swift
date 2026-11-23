// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import KVMCore
import KVMWebRTC
import OSLog
import os

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
        guestClipboardSender?.send(GuestClipboardPush(text: text, previous: previous))
    }

    /// One push from `guestClipboardSender`. A failure puts the note back
    /// to what it was before the copy, unless a later copy has replaced it.
    func pushGuestClipboard(_ push: GuestClipboardPush) async {
        var status = "failed"
        do {
            status = try await guestClipboardSet(push.text)
        } catch {
            log.error("guestClipboardSet failed: \(describeRPCError(error), privacy: .public)")
        }
        guard status != "ok" else { return }
        log.notice("guestClipboardSet: \(status, privacy: .public)")
        if lastGuestClipboardText == push.text { lastGuestClipboardText = push.previous }
    }

    // MARK: - File drop

    /// True while the host's sender takes files (into its Downloads folder).
    public var canDropFiles: Bool {
        rpcReady && videoState?.guestFile?.receive == true
    }

    /// Send files to the host's Downloads folder. Folders are skipped. The
    /// host takes one drop at a time, so files dropped while one runs join
    /// the batch and go as the next drop. Each file and the outcome of the
    /// whole batch show in `fileDrop`.
    public func dropFiles(_ urls: [URL]) {
        guard canDropFiles, let webrtc else { return }
        var added: [QueuedFile] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                fileDropSkipped += 1
                continue
            }
            nextFileDropItemID += 1
            added.append(QueuedFile(id: nextFileDropItemID, url: url, size: UInt64(size)))
        }
        let items = added.map { FileDropStatus.Item(id: $0.id, name: $0.name, size: $0.size) }
        if fileDropTask != nil {
            queuedFileDrop += added
            fileDrop?.items += items
            return
        }
        guard !added.isEmpty else {
            fileDropSkipped = 0
            fileDrop = FileDropStatus(outcome: "Only files can be sent, not folders.")
            clearFileDropOutcome()
            return
        }
        fileDrop = FileDropStatus(items: items)
        queuedFileDrop = added
        fileDropTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !queuedFileDrop.isEmpty, !Task.isCancelled {
                let batch = queuedFileDrop
                queuedFileDrop = []
                await sendFileDrop(batch, webrtc: webrtc)
            }
            queuedFileDrop = []
            let items = fileDrop?.items ?? []
            let sent = items.filter { $0.state == .sent }.map(\.name)
            let failed = items.compactMap { item -> String? in
                guard case .failed(let why) = item.state else { return nil }
                return "\(item.name) (\(why))"
            }
            let folders = fileDropSkipped > 0 ? " Folders were skipped." : ""
            fileDropSkipped = 0
            let outcome: String
            if Task.isCancelled || (sent.isEmpty && failed.isEmpty) {
                outcome = "Cancelled."
            } else if failed.isEmpty {
                let what = sent.count == 1 ? sent[0] : "\(sent.count) files"
                outcome = "Sent \(what) to the host's Downloads folder.\(folders)"
            } else {
                outcome = "Couldn't send \(failed.joined(separator: ", ")).\(folders)"
            }
            log.info("file drop: \(outcome, privacy: .public)")
            fileDrop?.outcome = outcome
            fileDropTask = nil
            clearFileDropOutcome()
        }
    }

    /// Stop the running drop and everything queued behind it. The KVM
    /// cancels whatever the host hasn't written yet; written files stay.
    public func cancelFileDrop() {
        fileDropTask?.cancel()
    }

    /// Stop one file of the batch: a queued one never goes out; one in the
    /// running drop is cancelled on the host, and the rest carry on.
    public func cancelFileDrop(item id: Int) {
        if let index = queuedFileDrop.firstIndex(where: { $0.id == id }) {
            queuedFileDrop.remove(at: index)
        } else if let drop = activeFileDrop, let transfer = drop.transfers[id] {
            drop.cancelled.withLock { _ = $0.insert(transfer) }
            let cancel = Data(#"{"type":"cancel","transfer":\#(transfer)}"#.utf8)
            Task { _ = await drop.channel.send(cancel, isBinary: false, highWaterMark: GuestFileSender.highWaterMark) }
        } else {
            return
        }
        updateFileDropItem(id) { $0.state = .cancelled }
    }

    private func updateFileDropItem(_ id: Int, _ change: (inout FileDropStatus.Item) -> Void) {
        guard let index = fileDrop?.items.firstIndex(where: { $0.id == id }) else { return }
        change(&fileDrop!.items[index])
    }

    private func clearFileDropOutcome() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, fileDrop?.outcome != nil else { return }
            fileDrop = nil
        }
    }

    /// One OS Services drop; each file's progress and end land on its item.
    private func sendFileDrop(_ batch: [QueuedFile], webrtc: WebRTCFacade) async {
        let fail = { (why: String) in
            for file in batch { self.updateFileDropItem(file.id) { $0.state = .failed(why) } }
        }
        let drop: GuestFileDropResult
        do {
            drop = try await guestFileDrop(batch.map { ($0.name, $0.size) })
        } catch {
            return fail(describeRPCError(error))
        }
        guard drop.transfers.count == batch.count,
              let channel = await webrtc.openDataChannel(label: drop.channel) else {
            return fail("no file channel")
        }
        let cancelled = OSAllocatedUnfairLock(initialState: Set<UInt32>())
        activeFileDrop = ActiveFileDrop(
            channel: channel,
            transfers: Dictionary(uniqueKeysWithValues: zip(batch.map(\.id), drop.transfers)),
            cancelled: cancelled
        )
        defer {
            channel.close()
            activeFileDrop = nil
        }
        let ids = Dictionary(uniqueKeysWithValues: zip(drop.transfers, batch.map(\.id)))
        let statuses = await GuestFileSender.run(
            zip(batch, drop.transfers).map { GuestFileSender.File(url: $0.url, size: $0.size, transfer: $1) },
            messages: channel.textMessages,
            isCancelled: { transfer in cancelled.withLock { $0.contains(transfer) } },
            send: { await channel.send($0, isBinary: $1, highWaterMark: GuestFileSender.highWaterMark) },
            progress: { [weak self] transfer, sent in
                guard let id = ids[transfer] else { return }
                Task { @MainActor in self?.updateFileDropItem(id) { $0.sentBytes = sent } }
            }
        )
        for (transfer, id) in ids {
            let status = statuses[transfer] ?? "cancelled"
            updateFileDropItem(id) { item in
                if status == "ok" {
                    item.state = .sent
                    item.sentBytes = item.size
                } else if item.state != .cancelled {
                    // Cancelled by the operator stays that; by anything
                    // else (a stall, the channel closing) it failed.
                    item.state = .failed(status)
                }
            }
        }
    }
}

/// A local copy on its way to the host, with the note to restore if it fails.
struct GuestClipboardPush: Sendable {
    let text: String
    let previous: String?
}

/// A file waiting in the batch for its drop.
struct QueuedFile {
    let id: Int
    let url: URL
    let size: UInt64
    /// The host compares names byte for byte; macOS hands out decomposed
    /// ones.
    var name: String { url.lastPathComponent.precomposedStringWithCanonicalMapping }
}

/// The drop on the wire, so one of its files can be cancelled.
struct ActiveFileDrop {
    let channel: DataChannel
    /// Item ID → transfer ID.
    let transfers: [Int: UInt32]
    let cancelled: OSAllocatedUnfairLock<Set<UInt32>>
}

/// A file drop batch, for the App's banner.
public struct FileDropStatus: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable {
            /// Queued, or sending once `sentBytes` > 0.
            case pending
            case sent
            case cancelled
            case failed(String)
        }
        public let id: Int
        public let name: String
        public let size: UInt64
        public internal(set) var sentBytes: UInt64 = 0
        public internal(set) var state: State = .pending
    }
    /// Grows while files dropped mid-transfer join the batch.
    public internal(set) var items: [Item] = []
    /// Nil while sending; then one line saying how it ended.
    public internal(set) var outcome: String?
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
    /// a transfer the channel closed on is missing. `progress` gets a
    /// transfer's bytes sent so far, at most every 100 ms and when it
    /// completes. No more bytes go out for a transfer once `isCancelled`
    /// says so; whoever cancelled it tells the KVM.
    static func run(
        _ files: [File],
        messages: AsyncStream<String>,
        isCancelled: (UInt32) -> Bool = { _ in false },
        send: (Data, _ isBinary: Bool) async -> Bool,
        progress: (_ transfer: UInt32, _ sent: UInt64) -> Void
    ) async -> [UInt32: String] {
        var credit: [UInt32: UInt64] = [:]
        var handles: [UInt32: FileHandle] = [:]
        var sent: [UInt32: UInt64] = [:]
        var statuses: [UInt32: String] = [:]
        var reported = ContinuousClock.now
        defer { for handle in handles.values { try? handle.close() } }

        func pump(_ file: File) async {
            while credit[file.transfer, default: 0] > 0, sent[file.transfer, default: 0] < file.size,
                  statuses[file.transfer] == nil, !isCancelled(file.transfer), !Task.isCancelled {
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
                if reported.duration(to: .now) >= .milliseconds(100) || sent[file.transfer] == file.size {
                    reported = .now
                    progress(file.transfer, sent[file.transfer]!)
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
