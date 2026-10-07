// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MapoCore",
    defaultLocalization: "tr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MapoCore", targets: ["MapoCore"]),
        .executable(name: "mapo-mcp", targets: ["mapo-mcp"]),
    ],
    targets: [
        .target(name: "MapoCore"),
        .executableTarget(name: "mapo-mcp", dependencies: ["MapoCore"]),
        .testTarget(
            name: "MapoCoreTests",
            dependencies: ["MapoCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
