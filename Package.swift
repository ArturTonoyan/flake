// swift-tools-version: 5.9
// Prefer: ./scripts/build.sh  (creates Flake.app)
import PackageDescription

let package = Package(
    name: "Flake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Flake",
            path: "Sources/Flake"
        )
    ]
)
