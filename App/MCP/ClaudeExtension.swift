// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// Regi as a Claude Desktop extension (.mcpb: a zip with manifest.json at its
/// root), made from this copy of Regi when the user asks for it. The bundle
/// holds no binary: its entry point is a launcher that runs this app's own
/// regi-mcp, so it never goes stale when Regi updates in place, and a file
/// written here carries no quarantine flag for Gatekeeper to trip on. Moving
/// Regi breaks it; adding it again fixes that.
@MainActor
enum ClaudeExtension {
    /// Writes Regi.mcpb to a temporary folder and opens it, which brings up
    /// Claude Desktop's install dialog.
    static func add() throws {
        let files = FileManager.default
        let stage = files.temporaryDirectory.appendingPathComponent("Regi-mcpb-\(UUID().uuidString)")
        defer { try? files.removeItem(at: stage) }
        try files.createDirectory(at: stage.appendingPathComponent("server"), withIntermediateDirectories: true)

        let launcher = stage.appendingPathComponent("server/regi-mcp")
        let quoted = "'" + MCPHost.bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nexec \(quoted) \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        guard let template = Bundle.main.url(forResource: "ClaudeExtension", withExtension: "json") else {
            throw MCPTools.Failure("this build of Regi has no extension manifest")
        }
        try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "__VERSION__", with: MCPHost.version)
            .write(to: stage.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try icon().write(to: stage.appendingPathComponent("icon.png"))

        let package = files.temporaryDirectory.appendingPathComponent("Regi.mcpb")
        try? files.removeItem(at: package)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // The folder's contents at the zip's root; without the ._ files ditto adds for extended attributes.
        zip.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", stage.path, package.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw MCPTools.Failure("couldn't write \(package.path)") }

        guard NSWorkspace.shared.open(package) else {
            throw MCPTools.Failure("nothing opens .mcpb files here; is Claude Desktop installed?")
        }
    }

    /// The app icon as a 512 px PNG.
    private static func icon() throws -> Data {
        let size = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw MCPTools.Failure("couldn't draw the icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw MCPTools.Failure("couldn't draw the icon")
        }
        return png
    }
}
