// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UsageMeter",
            path: "Sources/UsageMeter"
        )
    ]
)
