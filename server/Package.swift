// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "screenstats",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "screenstats", path: "Sources/screenstats")
    ]
)
