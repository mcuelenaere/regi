import SwiftUI
import JetKVMTransport

/// Add/edit dialog for a SavedHost. Same form for both — the
/// `mode` switches between Save (new entry) and Update + Delete
/// (existing). The modal returns through a callback closure rather
/// than via Bindings so the host's edits stay isolated until the
/// user explicitly confirms.
///
/// One URL field stands in for host/port/TLS — the user types
/// either a URL ("https://kvm.local:8443") or a bare hostname
/// ("kvm.local") and we parse it on save. The bare-hostname path
/// defaults to http/80 for JetKVM and https/443 for PiKVM (KVMD is
/// TLS by default). PiKVM also needs a login username.
struct HostFormSheet: View {
    enum Mode {
        case add
        case edit(SavedHost)
    }

    let mode: Mode
    let onSave: (SavedHost) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var urlText: String
    @State private var kind: DeviceKind
    @State private var username: String
    /// VNC-over-TLS (VeNCrypt) opt-in. PiKVM's kvmd-vnc requires it.
    @State private var vncTLS: Bool
    @State private var showDeleteConfirmation = false

    init(
        mode: Mode,
        onSave: @escaping (SavedHost) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _urlText = State(initialValue: "")
            _kind = State(initialValue: .jetKVM)
            _username = State(initialValue: "admin")
            _vncTLS = State(initialValue: false)
        case .edit(let existing):
            _name = State(initialValue: existing.name)
            _urlText = State(initialValue: existing.urlString)
            _kind = State(initialValue: existing.kind)
            _username = State(initialValue: existing.username)
            _vncTLS = State(initialValue: existing.kind == .vnc && existing.useTLS)
        }
    }

    private var title: String {
        switch mode {
        case .add: return "Add Host"
        case .edit: return "Edit Host"
        }
    }

    private var saveLabel: String {
        switch mode {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private var parsed: (host: String, port: Int, useTLS: Bool)? {
        switch kind {
        case .jetKVM:
            return SavedHost.parse(urlText)
        case .piKVM:
            return SavedHost.parse(urlText, defaultScheme: "https")
        case .vnc:
            // Plain RFB over TCP on the conventional 5900. TLS isn't supported
            // (VeNCrypt is out of scope), so a typed https:// is dropped on save.
            return SavedHost.parse(urlText, defaultPort: 5900)
        }
    }

    private var canSave: Bool { parsed != nil }

    private var addressPrompt: Text {
        switch kind {
        case .jetKVM: return Text(verbatim: "https://kvm.local or kvm.local")
        case .piKVM: return Text(verbatim: "https://pikvm.local or pikvm.local")
        case .vnc: return Text(verbatim: "vm-host.local:5900")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2)

            Form {
                Picker("Type", selection: $kind) {
                    // Brand names — not localizable.
                    Text(verbatim: "JetKVM").tag(DeviceKind.jetKVM)
                    Text(verbatim: "PiKVM").tag(DeviceKind.piKVM)
                    Text(verbatim: "VNC").tag(DeviceKind.vnc)
                }
                .pickerStyle(.segmented)
                TextField("Name (optional)", text: $name, prompt: Text("My desktop"))
                    .textFieldStyle(.roundedBorder)
                TextField("Address", text: $urlText, prompt: addressPrompt)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                if kind == .piKVM {
                    TextField("Username", text: $username, prompt: Text(verbatim: "admin"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                if kind == .vnc {
                    Toggle("Encrypted (TLS / VeNCrypt)", isOn: $vncTLS)
                    if vncTLS {
                        TextField("Username (optional)", text: $username, prompt: Text(verbatim: "e.g. admin"))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                }
            }
            if kind == .vnc, vncTLS {
                Text("Required for PiKVM's VNC server. The password is prompted on connect; a username enables user/password (VeNCrypt Plain) auth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !urlText.isEmpty, parsed == nil {
                Text("Enter a hostname or http(s) URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let parsed {
                // Tiny inline echo of how we parsed it. Helps the user
                // notice if they typed "https://" but actually wanted
                // plain http (or vice-versa). VNC has no scheme (plain TCP),
                // so show bare host:port there.
                Text(verbatim: kind == .vnc
                     ? "→ \(parsed.host):\(parsed.port)"
                     : "→ \(parsed.useTLS ? "https" : "http")://\(parsed.host):\(parsed.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if onDelete != nil {
                    // role: .destructive on a plain macOS Button
                    // doesn't auto-color red — only inside alert /
                    // confirmationDialog. Tint the label explicitly
                    // so it reads as destructive at a glance.
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Text("Delete").foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saveLabel) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(minWidth: 420)
        .alert(
            "Delete \(deleteTitle)?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the saved entry. The device itself isn't affected.")
        }
    }

    private var deleteTitle: String {
        if case .edit(let host) = mode { return host.displayName }
        return ""
    }

    private func save() {
        guard let parsed else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        // VNC keeps the username as typed (empty = no Plain auth); other kinds
        // default to PiKVM's stock `admin`.
        let resolvedUser = kind == .vnc ? trimmedUser : (trimmedUser.isEmpty ? "admin" : trimmedUser)
        // VNC encryption is the explicit VeNCrypt/TLS toggle; other kinds take
        // TLS from the parsed scheme.
        let useTLS = kind == .vnc ? vncTLS : parsed.useTLS
        let existingID: UUID? = { if case .edit(let e) = mode { return e.id } else { return nil } }()
        let saved = SavedHost(
            id: existingID ?? UUID(),
            name: trimmedName,
            host: parsed.host,
            port: parsed.port,
            useTLS: useTLS,
            kind: kind,
            username: resolvedUser
        )
        onSave(saved)
        dismiss()
    }
}
