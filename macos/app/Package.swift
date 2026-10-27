// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacProton",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacProton", path: "Sources/MacProton")
    ]
)
