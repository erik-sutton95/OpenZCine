// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenZCine",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "OpenZCineCore", targets: ["OpenZCineCore"])
    ],
    targets: [
        .target(name: "OpenZCineCore"),
        .testTarget(
            name: "OpenZCineCoreTests",
            dependencies: ["OpenZCineCore"]
        ),
    ]
)
