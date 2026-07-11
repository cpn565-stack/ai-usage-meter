// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageMeter",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle 2 — 自動更新(需在 package.sh 把 Sparkle.framework 嵌進 .app)
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "UsageMeter",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/UsageMeter"
        )
    ]
)
