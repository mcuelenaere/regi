// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "regi-e2e",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "regi-e2e", targets: ["regi-e2e"]),
        .library(name: "RegiE2ECore", targets: ["RegiE2ECore"]),
    ],
    dependencies: [.package(path: "../../Packages/ProbeKit")],
    targets: [
        .target(name: "RegiE2ECore", dependencies: ["ProbeKit"]),
        .executableTarget(name: "regi-e2e", dependencies: ["RegiE2ECore"]),
        .testTarget(name: "RegiE2ECoreTests", dependencies: ["RegiE2ECore"]),
    ]
)
