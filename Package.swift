// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tonari",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tonari",
            path: "Sources/Tonari"
        )
    ]
)
