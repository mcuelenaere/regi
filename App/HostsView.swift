import SwiftUI
import JetKVMTransport

extension Notification.Name {
    /// Posted by the `File > Add Host…` command (and its ⌘N
    /// shortcut). HostsView listens via .onReceive and presents the
    /// add-host sheet — the same one the toolbar's `+` button opens.
    static let regiAddHost = Notification.Name("RegiAddHost")
}

/// Root window: list of saved hosts plus mDNS-discovered devices on
/// the local network. Plus button to add. Single-click selects;
/// Return on a selection or click the per-row play button to open a
/// connection in a new window.
///
/// Discovered devices are auto-added when a `_jetkvm._tcp` record
/// shows up on the LAN and disappear when the device leaves. Saved
/// entries with the same hostname win the merge — they keep the
/// user's nickname and the standard "display" icon.
struct HostsView: View {
    @Environment(HostStore.self) private var store
    @Environment(DeviceDiscovery.self) private var discovery
    @Environment(\.openWindow) private var openWindow

    @State private var selection: HostListEntry.ID?
    @State private var showingAdd = false
    @State private var editing: SavedHost?
    /// Set non-nil when the user has requested a delete; the alert
    /// binds to this and fires on confirmation. Routes both the
    /// context-menu Delete and the per-row trash button through one
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

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, selection: $selection) { entry in
                    row(for: entry)
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    guard let id = selection,
                          let entry = entries.first(where: { $0.id == id })
                    else { return .ignored }
                    connect(entry)
                    return .handled
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .help("Add a new host.")
            }
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
        let isSelected = selection == entry.id
        switch entry {
        case .saved(let host):
            HostRow(
                displayName: host.displayName,
                urlString: host.urlString,
                kind: .saved,
                deviceKind: host.kind,
                isSelected: isSelected,
                onConnect: { connect(entry) },
                onEdit: { editing = host },
                onDelete: { hostPendingDelete = host }
            )
            .tag(entry.id)
            .contextMenu {
                Button("Edit…") { editing = host }
                Button(role: .destructive) {
                    hostPendingDelete = host
                } label: {
                    Text("Delete")
                        .foregroundStyle(.red)
                }
            }
        case .discovered(let host):
            HostRow(
                displayName: host.displayName,
                urlString: discoveredURLString(host),
                kind: .discovered,
                deviceKind: host.kind,
                isSelected: isSelected,
                onConnect: { connect(entry) },
                onEdit: nil,
                onDelete: nil
            )
            .tag(entry.id)
            .contextMenu {
                Button("Save Host") {
                    let saved = SavedHost(
                        name: host.instanceName,
                        host: host.host,
                        port: host.port,
                        useTLS: host.useTLS,
                        kind: host.kind
                    )
                    store.add(saved)
                    // Future merges will dedupe the discovered entry
                    // by hostname; the saved one wins (keeps the
                    // user's now-editable nickname). Move selection
                    // so the user sees their saved entry now picked.
                    selection = HostListEntry.saved(saved).id
                }
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
            Text("Click + in the toolbar to add a JetKVM device, or wait for one to appear on your local network.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let isSelected: Bool
    let onConnect: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HostRowIcon(kind: kind, isSelected: isSelected)
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
            // Edit + Delete reveal next to the play button only on
            // the selected row, and only when the row supports those
            // actions (saved hosts do; discovered ones don't —
            // they're ephemeral).
            if isSelected, let onEdit, let onDelete {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Edit \(displayName)")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Delete \(displayName)")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            // Play button only appears on hover or while the row is
            // selected — keeps the resting list visually quieter.
            if isHovering || isSelected {
                Button(action: onConnect) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        // White on selection blue, .tint on regular
                        // rows — matches the Finder / Mail "icons
                        // invert with the selection background"
                        // convention.
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Connect to \(displayName)")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// Icon for a host row. The `display` glyph represents the screen-over-
/// IP device (both families); the device family is conveyed as text in
/// the row subtitle, not here. Discovered hosts (always JetKVM, via
/// `_jetkvm._tcp`) get the same glyph with a small
/// `dot.radiowaves.left.and.right` "broadcasting" badge in the
/// bottom-right. On selection both the glyph and badge flip to white to
/// match the row text.
private struct HostRowIcon: View {
    let kind: HostRowKind
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            if kind == .discovered {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : Color.green)
                    .offset(x: 12, y: 12)
            }
        }
    }
}
