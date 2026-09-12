// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProbeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProbeKit", targets: ["ProbeKit"])
    ],
    dependencies: [
        // Already vendored for JetKVMKit's clipboard agent proto; pinned to the
        // same version so one protoc-gen-swift serves both.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1")
    ],
    targets: [
        .target(
            name: "ProbeKit",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(name: "ProbeKitTests", dependencies: ["ProbeKit"])
    ]
)
