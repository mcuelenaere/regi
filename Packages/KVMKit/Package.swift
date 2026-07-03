// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KVMKit",
    platforms: [.macOS(.v14)],
    products: [
        // One umbrella library. The App links `KVMKit`, which re-exports
        // `KVMCore` and the backend modules (see Exports.swift).
        .library(name: "KVMKit", targets: ["KVMKit"]),
    ],
    dependencies: [
        // Only JetKVMKit's clipboard uses protobuf (the agent.proto bindings).
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
        // Temporarily on AttilaTheFun's fork at 148.0.0 — fixes the
        // missing-headers bug on the macOS slice that's blocked us
        // since M141 (stasel/WebRTC#145, PR #147). Swap back to the
        // upstream `stasel/WebRTC` tag once #147 merges and a real
        // release ships from there. Only the WebRTC-backed targets pull it in.
        .package(url: "https://github.com/AttilaTheFun/WebRTC.git", exact: "148.0.0"),
    ],
    targets: [
        // Shared abstraction with zero external dependencies: the KVMBackend
        // protocol, device/state/capability/power vocabulary, input
        // primitives, TLS delegate, and the local video renderer.
        .target(name: "KVMCore"),

        // WebRTC-aware shared code used by the JetKVM and PiKVM backends: the
        // peer-connection façade, stats parsing, the RTC video renderer, and
        // the HID-RPC / ICE wire types the façade's API is built around.
        .target(
            name: "KVMWebRTC",
            dependencies: [
                "KVMCore",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),

        // JetKVM backend: WebRTC + HID-RPC + JSON-RPC control plane + clipboard.
        .target(
            name: "JetKVMKit",
            dependencies: [
                "KVMCore",
                "KVMWebRTC",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            exclude: [
                // Source-of-truth schema; regenerated bindings live in
                // Clipboard/generated/. Not a Swift source.
                "Clipboard/agent.proto",
            ]
        ),

        // PiKVM backend: Janus WebRTC video + /api/ws JSON input.
        .target(
            name: "PiKVMKit",
            dependencies: [
                "KVMCore",
                "KVMWebRTC",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),

        // VNC backend: RFB 3.8 over TCP, locally decoded. No WebRTC.
        .target(name: "VNCKit", dependencies: ["KVMCore"]),

        // Umbrella: the device-agnostic Session façade + re-exports.
        .target(
            name: "KVMKit",
            dependencies: ["KVMCore", "KVMWebRTC", "JetKVMKit", "PiKVMKit", "VNCKit"]
        ),

        .testTarget(name: "KVMCoreTests", dependencies: ["KVMCore"]),
        .testTarget(name: "KVMWebRTCTests", dependencies: ["KVMWebRTC", "KVMCore"]),
        .testTarget(name: "JetKVMKitTests", dependencies: ["JetKVMKit", "KVMCore", "KVMWebRTC"]),
        // JetKVMKit dep: WebKeyMapTests cross-checks WebKeyMap against JetKVM's
        // KeyMap to assert both keymaps cover the same kVK keys.
        .testTarget(name: "PiKVMKitTests", dependencies: ["PiKVMKit", "KVMCore", "JetKVMKit"]),
        .testTarget(name: "VNCKitTests", dependencies: ["VNCKit", "KVMCore"]),
    ]
)
