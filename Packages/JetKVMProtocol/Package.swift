// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JetKVMProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JetKVMProtocol", targets: ["JetKVMProtocol"]),
    ],
    dependencies: [
        // First external dep on this module. Used by the Clipboard/
        // subdirectory to ship swift-protobuf-generated bindings for the
        // shared agent.proto. 1.27.0+ keeps us on a Swift 5.9-compatible
        // toolchain.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
    ],
    targets: [
        .target(
            name: "JetKVMProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: [
                // Source-of-truth schema; regenerated bindings live in
                // Clipboard/generated/. The .proto itself isn't a Swift
                // source — SPM would otherwise warn about it.
                "Clipboard/agent.proto",
            ]
        ),
        .testTarget(name: "JetKVMProtocolTests", dependencies: ["JetKVMProtocol"]),
    ]
)
