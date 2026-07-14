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
        .library(name: "OpenZCineCore", targets: ["OpenZCineCore"]),
        // JNI facade consumed by the Android app (`just android-core`). The facade
        // sources are fully `#if os(Android)`-gated, so on Darwin this product
        // compiles to an empty module and iOS/macOS behavior is unchanged.
        .library(
            name: "OpenZCineAndroid", type: .dynamic, targets: ["OpenZCineAndroidFacade"]),
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
        // Header-only shim exposing the NDK's <jni.h> to Swift; empty on Darwin.
        .target(name: "CJNI"),
        .target(
            name: "OpenZCineAndroidFacade",
            dependencies: ["OpenZCineCore", "CJNI"]
        ),
    ]
)
