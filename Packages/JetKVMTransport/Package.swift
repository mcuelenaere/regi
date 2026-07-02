// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JetKVMTransport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JetKVMTransport", targets: ["JetKVMTransport"]),
    ],
    dependencies: [
        .package(path: "../JetKVMProtocol"),
        // Temporarily on AttilaTheFun's fork at 148.0.0 — fixes the
        // missing-headers bug on the macOS slice that's blocked us
        // since M141 (stasel/WebRTC#145, PR #147). Swap back to the
        // upstream `stasel/WebRTC` tag once #147 merges and a real
        // release ships from there.
        .package(url: "https://github.com/AttilaTheFun/WebRTC.git", exact: "148.0.0"),
    ],
    targets: [
        // Vendored, glib-free SPICE image decoders (QUIC / LZ / GLZ) from
        // spice-common + spice-gtk. See Sources/CSpiceCodecs/THIRDPARTY.md.
        .target(
            name: "CSpiceCodecs",
            exclude: [
                // Template files #included textually by quic.c / lz.c /
                // decode-glz.c — must not be compiled as standalone TUs.
                "vendor/quic_tmpl.c",
                "vendor/quic_rgb_tmpl.c",
                "vendor/quic_family_tmpl.c",
                "vendor/lz_compress_tmpl.c",
                "vendor/lz_decompress_tmpl.c",
                "vendor/decode-glz-tmpl.c",
                "THIRDPARTY.md",
                "PATCHES.md",
            ],
            cSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("include"),
            ]
        ),
        .target(
            name: "JetKVMTransport",
            dependencies: [
                "JetKVMProtocol",
                "CSpiceCodecs",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "JetKVMTransportTests",
            dependencies: ["JetKVMTransport", "CSpiceCodecs"]
        ),
    ]
)
