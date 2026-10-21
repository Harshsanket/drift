// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Drift",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // GPL tunnel core: OpenVPN + WireGuard (in-process daemon).
        // Pinned exact tag: reproducible release builds.
        .package(url: "https://github.com/partout-io/partout.git", exact: "0.170.0"),
        // Update plumbing: EdDSA-signed appcast + installer. Our SwiftUI
        // surfaces drive the "Update now / Later" decision; Sparkle
        // verifies EdDSA and performs the swap.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Drift",
            dependencies: [
                .product(name: "partout", package: "partout"),
                .byName(name: "PartoutNative"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Drift",
            linkerSettings: [
                // Embed Info.plist so Bundle.main has a bundle identifier
                // even when run bare (Xcode Run / swift run), avoiding
                // linkd.autoShortcut + "missing main bundle identifier" noise.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Support/Info.plist",
                ])
            ]
        ),
        // Root helper: owns the private utun + tunnel daemon + loopback
        // relay. Elevated one-time via osascript (admin password prompt).
        .executableTarget(
            name: "drift-tunnel-helper",
            dependencies: [
                .product(name: "partout", package: "partout"),
                .byName(name: "PartoutNative")
            ],
            path: "Sources/DriftTunnelHelper"
        ),
        .binaryTarget(
            name: "PartoutNative",
            url: "https://github.com/partout-io/partout/releases/download/0.170.0/PartoutNative.xcframework.zip",
            checksum: "e6adfa95f5d4e247b68456b839aee85e4f5f644ad2e308af0e3cabe2d403236f"
        ),
        .testTarget(
            name: "DriftTests",
            dependencies: ["Drift"],
            path: "Tests/DriftTests"
        )
    ]
)
