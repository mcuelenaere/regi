// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// Every MCP tool call, newest first: what an agent read, typed and clicked.
struct MCPActivityView: View {
    /// Empty shows every session.
    @State private var sessionFilter = ""

    var body: some View {
        let host = MCPHost.shared
        let rows = host.activity.reversed().filter { sessionFilter.isEmpty || $0.session == sessionFilter }
        Table(rows) {
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
                Text(entry.details).help(entry.details)
            }
            .width(min: 120, ideal: 280)
            TableColumn("Result") { entry in
                Text(entry.result)
                    .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                    .help(entry.result)
            }
            .width(min: 60, ideal: 160)
            TableColumn("Duration") { entry in
                Text(entry.duration < 1 ? "\(Int(entry.duration * 1000)) ms" : String(format: "%.1f s", entry.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 64)
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
        .frame(minWidth: 760, minHeight: 280)
    }
}

/// Replaces `MCPAgentBanner` on a session window while a client's script runs
/// there: the user's keyboard and mouse are paused, and Stop ends the script.
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

/// Shown on every session window while an MCP client is connected.
struct MCPAgentBanner: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let names = MCPHost.shared.connections.values.map(\.name).sorted()
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text(names.count == 1
                 ? "\(names[0]) is connected over MCP and can operate this session."
                 : "\(names.count) MCP clients are connected and can operate this session.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Activity") { openWindow(id: "mcp-activity") }
            Button("Stop") { MCPHost.shared.disable() }
                .help("Disconnect every MCP client and turn the MCP server off")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
