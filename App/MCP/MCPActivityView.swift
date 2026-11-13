// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Every MCP tool call, newest first: what an agent read, typed and clicked.
/// Cells show one line; the pane below shows the selected call in full, as
/// selectable text. Right-click or ⌘C copies rows.
struct MCPActivityView: View {
    /// Empty shows every session.
    @State private var sessionFilter = ""
    @State private var selection = Set<MCPHost.Activity.ID>()

    var body: some View {
        let host = MCPHost.shared
        // By start time: a script's own row is recorded when it ends, after its steps.
        let rows = host.activity.filter { sessionFilter.isEmpty || $0.session == sessionFilter }
            .sorted { $0.time > $1.time }
        let selected = rows.filter { selection.contains($0.id) }
        VSplitView {
            Table(rows, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.time, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 64, ideal: 72)
                TableColumn("Client", value: \.client)
                    .width(min: 70, ideal: 120)
                TableColumn("Session", value: \.session)
                    .width(min: 80, ideal: 140)
                TableColumn("Tool", value: \.tool)
                    .width(min: 80, ideal: 110)
                TableColumn("Details") { entry in
                    Text(MCPTools.oneLine(entry.details))
                }
                .width(min: 120, ideal: 280)
                TableColumn("Result") { entry in
                    Text(MCPTools.oneLine(entry.result))
                        .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                }
                .width(min: 60, ideal: 160)
                TableColumn("Duration") { entry in
                    Text(Self.duration(entry))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 64)
            }
            .contextMenu(forSelectionType: MCPHost.Activity.ID.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }
                Button(picked.count > 1 ? "Copy \(picked.count) Rows" : "Copy Row") { Self.copy(picked.map(Self.text)) }
                if picked.count == 1, let entry = picked.first {
                    Button("Copy Details") { Self.copy([entry.details]) }
                    Button("Copy Result") { Self.copy([entry.result]) }
                }
            }
            .onCopyCommand {
                [NSItemProvider(object: selected.map(Self.text).joined(separator: "\n\n") as NSString)]
            }
            .frame(minHeight: 140)

            ActivityDetail(entries: selected)
                .frame(minHeight: 90, idealHeight: 180)
        }
        .toolbar {
            Picker("Session", selection: $sessionFilter) {
                Text("All sessions").tag("")
                ForEach(Array(Set(host.activity.map(\.session).filter { !$0.isEmpty })).sorted(), id: \.self) {
                    Text(verbatim: $0).tag($0)
                }
            }
            Button("Clear") { host.clearActivity() }
                .disabled(host.activity.isEmpty)
        }
        .navigationTitle("MCP Activity")
        .frame(minWidth: 760, minHeight: 320)
    }

    static func duration(_ entry: MCPHost.Activity) -> String {
        entry.duration < 1 ? "\(Int(entry.duration * 1000)) ms" : String(format: "%.1f s", entry.duration)
    }

    /// One call as plain text, in full.
    static func text(_ entry: MCPHost.Activity) -> String {
        let time = entry.time.formatted(.dateTime.hour().minute().second())
        let where_ = [entry.client, entry.session].filter { !$0.isEmpty }.joined(separator: " · ")
        return "\(time)  \(entry.tool)  (\(where_), \(duration(entry)))\n\(entry.details)\n→ \(entry.result)"
    }

    static func copy(_ texts: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
    }
}

/// The selected call in full: its details (a whole script) and result, as
/// text you can select and copy.
private struct ActivityDetail: View {
    let entries: [MCPHost.Activity]

    var body: some View {
        if entries.count == 1, let entry = entries.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(entry.tool) · \(entry.time.formatted(.dateTime.hour().minute().second())) · \(MCPActivityView.duration(entry)) · \([entry.client, entry.session].filter { !$0.isEmpty }.joined(separator: " · "))")
                        .font(.headline)
                    section("Details", entry.details, color: .primary)
                    section("Result", entry.result, color: entry.isError ? .red : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            Text(entries.isEmpty ? "Select a call to see it in full." : "\(entries.count) calls selected. ⌘C copies them.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ title: LocalizedStringKey, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: text.isEmpty ? "—" : text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Over a session window's video while a client's script runs there: the
/// user's keyboard and mouse are paused, and Stop ends the script.
struct MCPScriptBanner: View {
    let run: ScriptRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
            Text("\(run.client) is running a script on this host. Your keyboard and mouse are paused.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop Script") { run.stop("stopped by the user") }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// In every session window's toolbar while an MCP client is connected.
struct MCPAgentMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let names = MCPHost.shared.connections.values.map(\.name).sorted()
        let status = names.count == 1
            ? "\(names[0]) is connected over MCP and can operate this session."
            : "\(names.count) MCP clients are connected and can operate this session."
        Menu {
            Text(status)
            Divider()
            Button("Show Activity…") { openWindow(id: "mcp-activity") }
            Button("Disconnect and Turn Off MCP") { MCPHost.shared.disable() }
        } label: {
            Label("MCP", systemImage: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
        }
        .help(status)
    }
}
