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
    dependencies: [
        // Non-Darwin SHA256 for PKCE (FrameioOAuth); Darwin builds keep using CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "OpenZCineCore",
            dependencies: [
                .product(
                    name: "Crypto", package: "swift-crypto",
                    condition: .when(platforms: [.linux, .android]))
            ]
        ),
        .testTarget(
            name: "OpenZCineCoreTests",
            dependencies: ["OpenZCineCore"]
        ),
    ]
)
