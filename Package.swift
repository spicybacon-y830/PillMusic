// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PillMusic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PillMusic",
            path: "Sources/PillMusic"
        )
    ]
)
