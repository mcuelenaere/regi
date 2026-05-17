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
            ]
        ),
        .testTarget(name: "JetKVMProtocolTests", dependencies: ["JetKVMProtocol"]),
    ]
)
