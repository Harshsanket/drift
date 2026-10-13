// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Drift",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Drift",
            path: "Sources/Drift"
        )
    ]
)
