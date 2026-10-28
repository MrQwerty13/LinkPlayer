// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinkPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Platform-independent business logic: URL validation, media detection,
        // redirect resolution, history, settings, playback state machine.
        .library(name: "LinkPlayerCore", targets: ["LinkPlayerCore"]),
        // macOS-only native application (SwiftUI + AVKit).
        .executable(name: "LinkPlayer", targets: ["LinkPlayerApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LinkPlayerCore"
        ),
        .executableTarget(
            name: "LinkPlayerApp",
            dependencies: ["LinkPlayerCore"]
        ),
        .testTarget(
            name: "LinkPlayerCoreTests",
            dependencies: ["LinkPlayerCore"]
        ),
    ]
)
