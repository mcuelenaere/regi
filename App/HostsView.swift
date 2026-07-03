import SwiftUI
import JetKVMTransport

extension Notification.Name {
    /// Posted by the File-menu "Add Host…" (⌘N) command. HostsView
    /// listens via .onReceive and presents the add-host sheet — the same
    /// one the bottom bar's + button opens.
    static let regiAddHost = Notification.Name("RegiAddHost")
    /// Posted by the File-menu "Connect", "Edit Host…" and "Delete Host"
    /// (⌘⌫) commands. HostsView acts on the currently-selected host; a
    /// no-op when nothing's selected or a sheet is already open. (Menu
    /// commands route through notifications rather than a focused value
    /// because the single-`Window` Hosts scene doesn't surface
    /// `.focusedSceneValue` to `Commands` — see RegiCommands.)
    static let regiConnectHost = Notification.Name("RegiConnectHost")
    static let regiEditHost = Notification.Name("RegiEditHost")
    static let regiDeleteHost = Notification.Name("RegiDeleteHost")
    /// Posted (object: UUID) after a `.vv` file is picked + registered in
    /// SpiceConsoleStore; HostsView opens a session window for it.
    static let regiOpenSpiceConsole = Notification.Name("RegiOpenSpiceConsole")
}

/// Root window: list of saved hosts plus mDNS-discovered devices on
/// the local network. Single-click selects; double-click (or Return on
/// a selection) opens a connection in a new window. The toolbar's `+`
/// adds a host; when a row is selected it gains Edit/Delete (saved) or
/// Save (discovered) alongside the `+`.
///
/// Discovered devices are auto-added when a `_jetkvm._tcp` record
/// shows up on the LAN and disappear when the device leaves. Saved
/// entries with the same hostname win the merge — they keep the
/// user's nickname and the standard "display" icon.
struct HostsView: View {
    @Environment(HostStore.self) private var store
    @Environment(DeviceDiscovery.self) private var discovery
    @Environment(HostMenuModel.self) private var hostMenuModel
    @Environment(\.openWindow) private var openWindow

    @State private var selection: HostListEntry.ID?
    @State private var showingAdd = false
    @State private var editing: SavedHost?
    /// Set non-nil when the user has requested a delete; the alert
    /// binds to this and fires on confirmation. Routes both the
    /// context-menu Delete and the toolbar Delete button through one
    /// confirmation flow. Discovered hosts can't be deleted (they're
    /// ephemeral by definition).
    @State private var hostPendingDelete: SavedHost?

    private var entries: [HostListEntry] {
        var result: [HostListEntry] = []
        let savedHostnames = Set(store.hosts.map { $0.host.lowercased() })
        for saved in store.hosts {
            result.append(.saved(saved))
        }
        for discovered in discovery.hosts {
            // Dedupe: when the user has already saved the same
            // hostname, the saved entry wins (keeps their nickname).
            if savedHostnames.contains(discovered.host.lowercased()) { continue }
            result.append(.discovered(discovered))
        }
        return result
    }

    /// The currently-selected entry (saved or discovered), or nil.
    private var selectedEntry: HostListEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    /// The selected entry if it's a saved host — gates the gutter bar's
    /// Delete/Edit buttons (and the ⌫ shortcut). Discovered hosts can't be
    /// edited or deleted, so this is nil for them.
    private var selectedSavedHost: SavedHost? {
        guard case .saved(let host) = selectedEntry else { return nil }
        return host
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, selection: $selection) { entry in
                    row(for: entry)
                }
                .listStyle(.inset)
                // Selection + double-click-to-connect + per-row context
                // menu, all via the native List API. Custom tap gestures
                // on macOS List rows break the built-in single-click
                // selection (a long-standing SwiftUI bug), so primaryAction
                // is the correct mechanism for the double-click "open" —
                // and it drives Return-to-connect for free.
                .contextMenu(forSelectionType: HostListEntry.ID.self) { ids in
                    if let entry = entry(forSelection: ids) {
                        contextMenuItems(for: entry)
                    }
                } primaryAction: { ids in
                    if let entry = entry(forSelection: ids) {
                        connect(entry)
                    }
                }
                // ⌫ removes the selected saved host — the native list
                // convention — routed through the same confirmation alert.
                .onKeyPress(.delete) {
                    guard let host = selectedSavedHost else { return .ignored }
                    hostPendingDelete = host
                    return .handled
                }
            }
            Divider()
            gutterBar
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Hosts")
        // Mirror the selection into the shared model so the File menu can
        // enable/disable Connect (any host) and Edit/Delete (saved only).
        // See HostMenuModel.
        .onChange(of: selectedEntry?.id, initial: true) {
            hostMenuModel.hasSelection = selectedEntry != nil
            hostMenuModel.hasSavedHostSelected = selectedSavedHost != nil
        }
        .sheet(isPresented: $showingAdd) {
            HostFormSheet(mode: .add) { host in
                store.add(host)
                selection = HostListEntry.saved(host).id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .regiAddHost)) { _ in
            showingAdd = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .regiOpenSpiceConsole)) { note in
            guard let id = note.object as? UUID,
                  let entry = SpiceConsoleStore.shared.entry(for: id) else { return }
            SpiceConsoleStore.shared.clearPendingOpen()
            openWindow(value: KVMSessionWindowID(spiceConsoleID: id, entry: entry))
        }
        .onAppear {
            // Cold launch via a .vv (opened before this window could receive
            // the notification): open it now.
            if let id = SpiceConsoleStore.shared.consumePendingOpen(),
               let entry = SpiceConsoleStore.shared.entry(for: id) {
                openWindow(value: KVMSessionWindowID(spiceConsoleID: id, entry: entry))
            }
        }
        // File-menu Connect/Edit/Delete act on the selection. Guarded so
        // they no-op with nothing selected or while a sheet/alert is up.
        .onReceive(NotificationCenter.default.publisher(for: .regiConnectHost)) { _ in
            guard editing == nil, !showingAdd, let entry = selectedEntry else { return }
            connect(entry)
        }
        .onReceive(NotificationCenter.default.publisher(for: .regiEditHost)) { _ in
            guard editing == nil, !showingAdd, let host = selectedSavedHost else { return }
            editing = host
        }
        .onReceive(NotificationCenter.default.publisher(for: .regiDeleteHost)) { _ in
            guard editing == nil, !showingAdd, hostPendingDelete == nil,
                  let host = selectedSavedHost else { return }
            hostPendingDelete = host
        }
        .sheet(item: $editing) { host in
            HostFormSheet(
                mode: .edit(host),
                onSave: { store.update($0) },
                onDelete: {
                    store.delete(id: host.id)
                    if selection == HostListEntry.saved(host).id { selection = nil }
                }
            )
        }
        .alert(
            "Delete \(hostPendingDelete?.displayName ?? "")?",
            isPresented: Binding(
                get: { hostPendingDelete != nil },
                set: { if !$0 { hostPendingDelete = nil } }
            ),
            presenting: hostPendingDelete
        ) { host in
            Button("Delete", role: .destructive) {
                store.delete(id: host.id)
                if selection == HostListEntry.saved(host).id { selection = nil }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This removes the saved entry. The device itself isn't affected.")
        }
    }

    @ViewBuilder
    private func row(for entry: HostListEntry) -> some View {
        switch entry {
        case .saved(let host):
            HostRow(
                displayName: host.displayName,
                urlString: host.urlString,
                kind: .saved,
                deviceKind: host.kind
            )
            .tag(entry.id)
        case .discovered(let host):
            HostRow(
                displayName: host.displayName,
                urlString: discoveredURLString(host),
                kind: .discovered,
                deviceKind: host.kind
            )
            .tag(entry.id)
        }
    }

    /// Resolve the (single) entry a List context-menu / primary-action
    /// targets from the set of ids the native modifier hands back.
    private func entry(forSelection ids: Set<HostListEntry.ID>) -> HostListEntry? {
        guard let id = ids.first else { return nil }
        return entries.first { $0.id == id }
    }

    /// Right-click menu for a row: Connect plus the kind-appropriate
    /// management actions.
    @ViewBuilder
    private func contextMenuItems(for entry: HostListEntry) -> some View {
        Button { connect(entry) } label: {
            Label("Connect", systemImage: "play.fill")
        }
        Divider()
        switch entry {
        case .saved(let host):
            Button { editing = host } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button(role: .destructive) { hostPendingDelete = host } label: {
                Label("Delete", systemImage: "trash")
            }
        case .discovered(let host):
            Button { save(host) } label: {
                Label("Save Host", systemImage: "square.and.arrow.down")
            }
        }
    }

    private func discoveredURLString(_ host: DiscoveredHost) -> String {
        let scheme = host.useTLS ? "https" : "http"
        let usingDefault = (host.useTLS && host.port == 443) || (!host.useTLS && host.port == 80)
        return usingDefault ? "\(scheme)://\(host.host)" : "\(scheme)://\(host.host):\(host.port)"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No saved hosts")
                .font(.title3)
            Text("Click + at the bottom to add a JetKVM device, or wait for one to appear on your local network.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bottom bar: just Add (on the right). Host management lives in the
    /// row's right-click menu — Edit…/Delete for saved hosts, Save for
    /// discovered — and ⌫ deletes the selected saved host.
    private var gutterBar: some View {
        HStack(spacing: 2) {
            Spacer()
            Button { showingAdd = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(GutterButtonStyle())
            .help("Add a host")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func connect(_ entry: HostListEntry) {
        let id: KVMSessionWindowID
        switch entry {
        case .saved(let host):
            id = KVMSessionWindowID(saved: host)
        case .discovered(let host):
            id = KVMSessionWindowID(discovered: host)
        }
        openWindow(value: id)
    }

    /// Promote a discovered (mDNS) host to a saved one. Future merges
    /// dedupe the discovered entry by hostname — the saved one wins and
    /// keeps the user's now-editable nickname — so move the selection to
    /// it so the user sees their saved entry picked.
    private func save(_ host: DiscoveredHost) {
        let saved = SavedHost(
            name: host.instanceName,
            host: host.host,
            port: host.port,
            useTLS: host.useTLS,
            kind: host.kind
        )
        store.add(saved)
        selection = HostListEntry.saved(saved).id
    }
}

/// Heterogeneous list entry — saved hosts share the list with
/// discovered ones. `id` is namespaced so saved/discovered with the
/// same hostname can coexist (in practice they're deduped before
/// we get here, but the namespacing keeps SwiftUI's diff stable).
enum HostListEntry: Identifiable, Hashable {
    case saved(SavedHost)
    case discovered(DiscoveredHost)

    var id: String {
        switch self {
        case .saved(let h): return "saved:\(h.id.uuidString)"
        case .discovered(let h): return "discovered:\(h.instanceName)"
        }
    }
}

/// Visual marker for HostRow — distinguishes saved vs auto-detected.
private enum HostRowKind: Equatable {
    case saved
    case discovered
}

private struct HostRow: View {
    let displayName: String
    let urlString: String
    let kind: HostRowKind
    let deviceKind: DeviceKind

    var body: some View {
        HStack(spacing: 12) {
            HostRowIcon(kind: kind)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body)
                // Device family + address share the subtitle line, e.g.
                // "JetKVM  •  http://jetkvm.local". Kept in the secondary
                // style so it stays quiet.
                Text(verbatim: "\(deviceKind.displayName)  •  \(urlString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        // Whole-row hit area so selection and the double-click-to-connect
        // gesture register anywhere in the row, not just on the text.
        .contentShape(Rectangle())
    }
}

/// Icon for a host row. The `display` glyph represents the screen-over-
/// IP device (both families); the device family is conveyed as text in
/// the row subtitle, not here. Discovered hosts (always JetKVM, via
/// `_jetkvm._tcp`) get the same glyph with a small
/// `dot.radiowaves.left.and.right` "broadcasting" badge in the
/// bottom-right. Both flip to white on selection — see SelectionTintedIcon.
private struct HostRowIcon: View {
    let kind: HostRowKind

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SelectionTintedIcon(systemName: "display", unselected: Color.secondary)
            if kind == .discovered {
                SelectionTintedIcon(
                    systemName: "dot.radiowaves.left.and.right",
                    font: .system(size: 10, weight: .bold),
                    unselected: Color.green
                )
                .offset(x: 12, y: 12)
            }
        }
    }
}

/// An SF Symbol that renders white when its row is the prominent (active-
/// window) selection and `unselected` otherwise, with the colour change
/// snapped in lockstep with the List's selection background — no fade.
///
/// The colour is driven by `\.backgroundProminence`, NOT a `selection == id`
/// flag. The List is backed by NSTableView, which paints the selection
/// background immediately on click; the SwiftUI `selection` binding is
/// updated by the AppKit→SwiftUI bridge one frame LATER, so a colour
/// derived from it re-renders a frame behind the background — the glyph
/// lingers white-on-white on deselect / low-contrast on blue on select
/// (a visible "flash"). `backgroundProminence` is instead set by the List
/// in the same pass it paints the background (the same mechanism that
/// tints the subtitle text), so the colour change lands in lockstep — and,
/// like that text tint, it does not fade. It also correctly stays
/// `unselected` when the window is inactive (the selection is grey then,
/// not blue).
///
/// Reading `\.backgroundProminence` only works in a descendant of the row
/// (which this always is) — the List publishes it to the row's contents,
/// not to the HostRow root, so reading it there would always be `.standard`.
private struct SelectionTintedIcon: View {
    let systemName: String
    var font: Font = .title2
    let unselected: Color
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundStyle(backgroundProminence == .increased ? Color.white : unselected)
    }
}

/// Borderless icon button for the bottom gutter bar (+/−/edit). Neutral
/// label-coloured glyph with a subtle rounded hover/press highlight, dimmed
/// when disabled — the small "source list" control look, not an accent-
/// tinted `.borderless` button.
private struct GutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GutterButton(configuration: configuration)
    }

    private struct GutterButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var fillOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.18 }
            if isHovering { return 0.10 }
            return 0
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { isHovering = $0 }
        }
    }
}
