// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sauron",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DiskCore"),
        .executableTarget(name: "sauron-cli", dependencies: ["DiskCore"]),
        .executableTarget(name: "SauronApp", dependencies: ["DiskCore"]),
        .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"]),
    ]
)
