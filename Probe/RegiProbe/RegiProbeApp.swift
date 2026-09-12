import AppKit
import SwiftUI

@main
struct RegiProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeAppDelegate.self) private var delegate

    var body: some Scene {
        Window("RegiProbe", id: "probe") {
            ProbeRootView(model: delegate.model) {
                delegate.runWindow.open()
            }
        }
        .defaultSize(width: 620, height: 640)
    }
}

@MainActor
final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    let model = ProbeModel()
    lazy var runWindow = RunWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must happen on the main thread: the TIS APIs carry the same
        // main-queue assertion that crashed the tap callback.
        model.capture.layout.observeLayoutChanges()
        model.startMonitoring()
        runWindow.observeSystemEvents()

        // Backstop for the one case the Stop button cannot cover: the UI wedged
        // while the tap is still swallowing.
        model.capture.onEscapeChord = { [weak self] in
            Task { @MainActor in self?.runWindow.close() }
        }

        // A run must never outlive the process holding the shield.
        for sig in [SIGINT, SIGTERM] { signal(sig, SIG_DFL) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runWindow.close()
        model.capture.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
