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
        // JNI facade consumed by the Android app (`just android-core`). The JNI
        // shims are `#if os(Android)`-gated; on Darwin only the platform-neutral
        // wire helpers compile, so iOS/macOS behavior is unchanged.
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
            dependencies: ["OpenZCineCore"],
            // Shared canonical JSON schema fixture consumed directly from the
            // source tree by Swift and Android transport tests; it is not an
            // app/runtime resource.
            exclude: ["Fixtures"]
        ),
        // Header-only shim exposing the NDK's <jni.h> to Swift; empty on Darwin.
        .target(name: "CJNI"),
        .target(
            name: "OpenZCineAndroidFacade",
            dependencies: ["OpenZCineCore", "CJNI"]
        ),
        // Runs on Darwin (and on Android via the cross-compile test path):
        // the PTP-IP session layer against a scripted fake camera server, and
        // the platform-independent zone-map wire format (MonitorZoneMapWire).
        // The JNI shims themselves stay Android-only.
        .testTarget(
            name: "OpenZCineAndroidFacadeTests",
            dependencies: ["OpenZCineAndroidFacade", "OpenZCineCore"]
        ),
    ]
)
