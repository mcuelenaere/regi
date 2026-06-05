import SwiftUI
import JetKVMTransport
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "app")

/// Identifier for a KVM session window. Carries the full set of
/// fields needed to connect (display name + endpoint) so the same
/// shape works for both saved and discovered (mDNS) hosts — the
/// session window doesn't need to look anything up.
///
/// Codable conformance refuses to decode: SwiftUI's macOS-14
/// WindowGroup auto-restores prior windows from Codable values, and
/// we'd rather always launch into HostsView. Encoding still works in
/// case SwiftUI persists state during a runtime session.
/// (`restorationBehavior(.disabled)` would express this more
/// directly but it's macOS 15+.)
struct KVMSessionWindowID: Hashable, Codable {
    let displayName: String
    let host: String
    let port: Int
    let useTLS: Bool
    let kind: DeviceKind
    let username: String

    init(saved: SavedHost) {
        self.displayName = saved.displayName
        self.host = saved.host
        self.port = saved.port
        self.useTLS = saved.useTLS
        self.kind = saved.kind
        self.username = saved.username
    }

    init(discovered: DiscoveredHost) {
        self.displayName = discovered.instanceName
        self.host = discovered.host
        self.port = discovered.port
        self.useTLS = discovered.useTLS
        self.kind = discovered.kind
        // PiKVM needs a username; discovery doesn't carry one, so use
        // its stock default. JetKVM ignores this field.
        self.username = "admin"
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "KVM session windows are intentionally not restored"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([displayName, host, "\(port)", "\(useTLS)"])
    }
}

/// Bridges SwiftUI's App lifecycle to a small NSApplicationDelegate.
/// Implements Sublime-style window management:
///   - Closing the last window leaves the app alive (returning `false`
///     from `applicationShouldTerminateAfterLastWindowClosed`).
///   - Clicking the dock icon when no windows are visible reopens the
///     Hosts window (`applicationShouldHandleReopen`).
///   - Dock right-click adds a "Show Hosts" entry that does the same.
///
/// `openWindow(id:)` lives on the SwiftUI environment and isn't
/// reachable from a plain NSObject. To reopen Hosts from any windowing
/// state — including "no windows alive, no views to receive a
/// notification" — we invoke the SwiftUI-auto-generated `Window >
/// Hosts` menu item via `NSApp.sendAction`. SwiftUI registers that
/// item for every `Window` scene and it ends up calling
/// `openWindow(id: "hosts")` under the hood whether or not an
/// instance currently exists.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock left-click reopen handler. When no windows are visible,
    /// open Hosts; otherwise let macOS perform its standard behaviour
    /// (bring app forward, no extra window).
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openHostsViaMenu()
        }
        return true
    }

    /// Items to add to the dock icon's right-click menu. The
    /// system-provided entries (Quit, Show, Options, etc.) appear
    /// below ours automatically.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showHosts = NSMenuItem(
            title: String(localized: "Show Hosts"),
            action: #selector(showHosts(_:)),
            keyEquivalent: ""
        )
        showHosts.target = self
        menu.addItem(showHosts)
        return menu
    }

    @objc private func showHosts(_ sender: Any?) {
        openHostsViaMenu()
    }

    /// Look up the SwiftUI-auto-generated `Window > Hosts` item by its
    /// localized title and trigger it. Works regardless of whether the
    /// hosts window is currently open, closed, or never opened this
    /// session — SwiftUI's underlying action calls
    /// `openWindow(id: "hosts")`.
    private func openHostsViaMenu() {
        guard let windowsMenu = NSApp.windowsMenu else {
            log.error("openHostsViaMenu: NSApp.windowsMenu is nil — cannot reopen Hosts")
            return
        }
        let target = String(localized: "Hosts")
        for item in windowsMenu.items where item.title == target {
            if let action = item.action {
                NSApp.sendAction(action, to: item.target, from: self)
                return
            }
        }
        log.error("openHostsViaMenu: no 'Hosts' item in Window menu — SwiftUI menu structure may have changed")
    }
}

/// Closures the active KVM session window publishes so the app-wide
/// File menu can switch from "Add Host…" (hosts window focused) to
/// session-specific commands (KVM window focused). Closures capture
/// each window's local SwiftUI state — the menu just invokes them.
struct SessionActions {
    /// Whether the device's controls are available right now — a control-
    /// capable device with its RPC channel ready. Drives the File-menu
    /// "Show Controls" enabled state, mirroring the toolbar button (which
    /// is hidden for non-control devices and disabled until rpcReady).
    let canShowControls: Bool
    let toggleControls: () -> Void
    let toggleStats: () -> Void
}

private struct SessionActionsFocusedValueKey: FocusedValueKey {
    typealias Value = SessionActions
}

extension FocusedValues {
    /// Set by the focused KVM session window; nil when any other
    /// window (the hosts list, or no window) is active.
    var sessionActions: SessionActions? {
        get { self[SessionActionsFocusedValueKey.self] }
        set { self[SessionActionsFocusedValueKey.self] = newValue }
    }
}

/// Shared bridge that lets the File menu (RegiCommands) reflect whether
/// the Hosts list currently has a saved host selected, so Edit/Delete can
/// enable/disable correctly.
///
/// `.focusedSceneValue` would be the idiomatic channel, but it doesn't
/// reach `Commands` from the single-instance `Window` Hosts scene the way
/// it does from the session `WindowGroup`. A plain `@Observable` reference
/// shared by the App, HostsView, and the menu sidesteps that: HostsView
/// writes the flag on selection changes; RegiCommands reads it (Commands
/// bodies participate in Observation, so the menu re-evaluates).
@MainActor
@Observable
final class HostMenuModel {
    /// Any host selected (saved or discovered) — gates Connect.
    var hasSelection = false
    /// A saved host selected — gates Edit/Delete (discovered hosts can't
    /// be edited or deleted).
    var hasSavedHostSelected = false
}

/// File-menu command set. Replaces the entire SwiftUI-auto-generated
/// `.newItem` group (which would otherwise add "New Regi Window" and
/// "New KVM Session Window" entries — both wrong: hosts is single-
/// instance, session windows are opened by selecting a host).
///
/// Menu contents switch on whether a session window is frontmost (keyed
/// off `sessionActions`, the reliably-propagated focused value — gating on
/// the hosts side instead can fall through to an empty menu):
///   - KVM session focused      → "Show Controls" / "Show Connection
///                                Stats" (no "Disconnect" — ⌘W close-window
///                                already tears the session down)
///   - otherwise (hosts or none) → "Add Host…", "Edit Host…", "Delete
///                                Host" (host management — in File, not
///                                Edit)
/// Reopening the Hosts list is intentionally NOT a File command: the
/// Window menu's auto-injected "Hosts" entry (from the `Window("Hosts", …)`
/// scene) and the dock menu already do that from everywhere.
///
/// Host actions post notifications rather than reading a focused value:
/// the Hosts scene is a single `Window` (not a `WindowGroup`), and its
/// `.focusedSceneValue` doesn't reach `Commands` reliably, so the items
/// stay enabled and HostsView no-ops them when nothing's selected.
struct RegiCommands: Commands {
    @FocusedValue(\.sessionActions) private var sessionActions
    let hostMenuModel: HostMenuModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if let sessionActions {
                // A session window is frontmost: its view commands. (No
                // "Show Hosts" — the Window menu's auto "Hosts" entry and
                // the dock menu already reopen the list.)
                Button("Show Controls", action: sessionActions.toggleControls)
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!sessionActions.canShowControls)
                Button("Show Connection Stats", action: sessionActions.toggleStats)
                    .keyboardShortcut("i", modifiers: .command)
            } else {
                // Hosts window (or no window) is frontmost — host
                // management. (These belong in File, not Edit.) Add (create)
                // sits on its own; below the divider are the commands that
                // act on the selected host — Connect (any selection), Edit
                // and Delete (saved only). Each posts a notification
                // HostsView handles. Delete also gets ⌘⌫ — plain ⌫ is
                // handled inside the list so it doesn't shadow Backspace in
                // text fields.
                Button {
                    NotificationCenter.default.post(name: .regiAddHost, object: nil)
                } label: {
                    Label("Add Host…", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button {
                    NotificationCenter.default.post(name: .regiConnectHost, object: nil)
                } label: {
                    Label("Connect", systemImage: "play.fill")
                }
                .disabled(!hostMenuModel.hasSelection)

                Button {
                    NotificationCenter.default.post(name: .regiEditHost, object: nil)
                } label: {
                    Label("Edit Host…", systemImage: "pencil")
                }
                .disabled(!hostMenuModel.hasSavedHostSelected)

                Button {
                    NotificationCenter.default.post(name: .regiDeleteHost, object: nil)
                } label: {
                    Label("Delete Host", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hostMenuModel.hasSavedHostSelected)
            }
        }
        // No custom `Window > Hosts` command: SwiftUI auto-injects
        // a Window menu entry for every scene (titled "Hosts" via the
        // `Window("Hosts", …)` first parameter). AppDelegate also
        // invokes that auto-entry via NSApp.sendAction for the dock
        // left-click reopen + right-click "Show Hosts" paths, so all
        // three reopen surfaces share one underlying mechanism.
    }
}

@main
struct RegiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hostStore = HostStore()
    @State private var trustStore = TrustedHostStore()
    @State private var discovery = DeviceDiscovery()
    @State private var hostMenuModel = HostMenuModel()

    var body: some Scene {
        // Root window: the saved-hosts list. `Window` (singular) —
        // not `WindowGroup` — because we want a strict single-
        // instance scene. `WindowGroup` permits multiple instances
        // and `openWindow(id:)` spawns a new one each call, which
        // breaks the "Window > Hosts" / dock-icon-reopen flow.
        // `Window`'s `openWindow(id:)` brings the existing instance
        // forward instead.
        Window("Hosts", id: "hosts") {
            HostsView()
                .environment(hostStore)
                .environment(trustStore)
                .environment(discovery)
                .environment(hostMenuModel)
                .onAppear { discovery.start() }
        }
        .defaultSize(width: 520, height: 420)
        .commands { RegiCommands(hostMenuModel: hostMenuModel) }

        // One window per connected host. Spawned by openWindow(value:)
        // from HostsView with a KVMSessionWindowID. Each window owns
        // its own Session so multiple hosts can be connected at the
        // same time. The window id carries all the connection info
        // it needs — saved hosts and discovered (mDNS) hosts both
        // route through here without HostStore lookup.
        WindowGroup("KVM Session", for: KVMSessionWindowID.self) { $sessionID in
            if let id = sessionID {
                KVMSessionWindow(sessionID: id)
                    // Per-host trust opt-ins persist via TrustedHostStore
                    // so a "Trust certificate" click from one window
                    // applies to every future window for the same host
                    // (saved or mDNS-discovered).
                    .environment(trustStore)
                    // 16:9 video at minWidth=800 wants ~525pt of
                    // video height (plus toolbar / status strip).
                    // The previous minHeight=600 floored the shrink-
                    // resize from KVMVideoView and left letterbox
                    // bars. 400 accommodates 16:9 and most 21:9
                    // ultrawide displays without going absurdly
                    // small.
                    .frame(minWidth: 800, minHeight: 400)
            } else {
                // No valid id — typically a window macOS tried to
                // restore from a previous launch (the system "Reopen
                // windows on logon" path), where our Codable wrapper
                // refused to decode. SwiftUI still spawns the window
                // with a nil binding; self-dismiss it so the user
                // doesn't see an empty session window flash.
                OrphanSessionWindowDismisser()
            }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private struct OrphanSessionWindowDismisser: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .onAppear { dismissWindow() }
    }
}

extension Session.State.Phase {
    var label: String {
        switch self {
        case .checkingStatus: return "Checking device…"
        case .authenticating: return "Authenticating…"
        case .signaling: return "Opening signaling channel…"
        case .offering: return "Negotiating WebRTC offer…"
        case .awaitingAnswer: return "Waiting for answer…"
        case .iceGathering: return "Establishing connection…"
        }
    }
}
