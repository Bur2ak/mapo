// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtlasCore",
    defaultLocalization: "tr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
    ],
    targets: [
        .target(name: "AtlasCore"),
        .testTarget(
            name: "AtlasCoreTests",
            dependencies: ["AtlasCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
