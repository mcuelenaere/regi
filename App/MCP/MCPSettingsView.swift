// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Settings ▸ MCP: the server toggle and the client setup every MCP client
/// needs — the bundled command, nothing more.
struct MCPSettingsView: View {
    @AppStorage(MCPHost.enabledKey) private var enabled = false
    @Environment(\.openWindow) private var openWindow
    @State private var extensionError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP server", isOn: $enabled)
                LabeledContent("Status") {
                    Text(status.text).foregroundStyle(status.color)
                }
            } footer: {
                Text("Lets MCP clients such as Claude Code or Cursor see and operate the hosts you open in Regi. Sessions open as ordinary windows, every call is listed under Activity, and while a client runs a script on a host your keyboard and mouse on it are paused.")
            }

            Section {
                CopyRow(title: "Command", value: MCPHost.bridgePath)
                CopyRow(title: "JSON", value: jsonSnippet)
                CopyRow(title: "Claude Code", value: "claude mcp add regi -- \(shellQuoted(MCPHost.bridgePath))")
                LabeledContent("Claude Desktop") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Add to Claude Desktop…") {
                            do { try ClaudeExtension.add(); extensionError = nil } catch { extensionError = "\(error)" }
                        }
                        if let extensionError {
                            Text(verbatim: extensionError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("Client setup")
            } footer: {
                Text("MCP clients start the command; it needs no arguments. The Claude Desktop extension runs this copy of Regi's command: if you move Regi, add it again.")
            }

            Section {
                Button("Show Activity…") { openWindow(id: "mcp-activity") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onChange(of: enabled) { MCPHost.shared.applySettings() }
    }

    private var status: (text: String, color: Color) {
        switch MCPHost.shared.status {
        case .stopped:
            return (String(localized: "Stopped"), .secondary)
        case .running:
            let count = MCPHost.shared.connections.count
            return (count == 0 ? String(localized: "Running") : String(localized: "Running · \(count) connected"), .primary)
        case .failed(let reason):
            return (String(localized: "Not running: \(reason)"), .red)
        }
    }

    private var jsonSnippet: String {
        let config = ["mcpServers": ["regi": ["command": MCPHost.bridgePath]]]
        let data = try? JSONSerialization.data(withJSONObject: config,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func shellQuoted(_ path: String) -> String {
        path.contains(where: { " '\"$\\".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}

private struct CopyRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: value)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
        }
    }
}
