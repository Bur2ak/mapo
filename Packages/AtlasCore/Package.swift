// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtlasCore",
    defaultLocalization: "tr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "atlas-mcp", targets: ["atlas-mcp"]),
    ],
    targets: [
        .target(name: "AtlasCore"),
        .executableTarget(name: "atlas-mcp", dependencies: ["AtlasCore"]),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
