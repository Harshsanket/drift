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
        )
    ]
)
