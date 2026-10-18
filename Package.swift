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
        // JNI facade consumed by the Android app (`just android-core`): the app's own exports
        // (Kotlin `SwiftCore`) plus OpenCineNikonAndroid's (Kotlin `NikonNative`) and
        // OpenCineFrameIOAndroid's (Kotlin `FrameioNative`). The JNI
        // shims are `#if os(Android)`-gated; on Darwin only the platform-neutral
        // wire helpers compile, so iOS/macOS behavior is unchanged.
        .library(
            name: "OpenZCineAndroid", type: .dynamic, targets: ["OpenZCineAndroidFacade"]),
    ],
    dependencies: [
        // The OpenCine platform package: portable media math (OpenCineMedia: CubeLUT,
        // FrameRateSampler), the optional Frame.io product (OpenCineFrameIO) and the Nikon PTP
        // wire, properties, discovery and session policy (OpenCineNikon, re-exported from
        // OpenZCineCore in Sources/OpenZCineCore/OpenCineNikon.swift). Sibling checkout pinned in
        // opencine-pins.txt until it is published.
        .package(path: "../OpenCine")
    ],
    targets: [
        .target(
            name: "OpenZCineCore",
            dependencies: [
                .product(name: "OpenCineCore", package: "OpenCine"),
                .product(name: "OpenCineMedia", package: "OpenCine"),
                .product(name: "OpenCineNikon", package: "OpenCine"),
                // Deployed relay codecs compose the neutral framing and lifetime policies.
                .product(name: "OpenCineRelay", package: "OpenCine"),
                // Session recovery (re-exported in Sources/OpenZCineCore/OpenCineNikon.swift).
                .product(name: "OpenCineCameraVocabulary", package: "OpenCine"),
                // Shared live chrome layout policy (`MonitorEdgeInsets` and friends).
                .product(name: "MonitorPresentation", package: "OpenCine"),
            ]
        ),
        .testTarget(
            name: "OpenZCineCoreTests",
            dependencies: [
                "OpenZCineCore", .product(name: "MonitorPresentation", package: "OpenCine"),
            ],
            // Shared canonical JSON schema fixture consumed directly from the
            // source tree by Swift and Android transport tests; it is not an
            // app/runtime resource.
            exclude: ["Fixtures"]
        ),
        // Frame.io comes from OpenCineFrameIOAndroid here (the shared wire and its JNI exports,
        // Kotlin `FrameioNative`, with SHA-256 injected from Kotlin), not through OpenZCineCore,
        // so the Watch (links OpenZCineCore) carries no delivery code. The Nikon session layer
        // and its JNI exports (Kotlin `NikonNative`) come from OpenCineNikonAndroid and link into
        // this library; OpenCineJNISupport is the JNI copy helpers over the NDK <jni.h> shim.
        .target(
            name: "OpenZCineAndroidFacade",
            dependencies: [
                "OpenZCineCore",
                .product(name: "OpenCineJNISupport", package: "OpenCine"),
                .product(name: "OpenCineNikonAndroid", package: "OpenCine"),
                .product(name: "OpenCineFrameIOAndroid", package: "OpenCine"),
            ]
        ),
        // Runs on Darwin (and on Android via the cross-compile test path): the app's
        // platform-independent wires (zone map, scopes, feed effects, LUTs, live-view
        // preferences). The Frame.io wire's tests are OpenCine's OpenCineFrameIOAndroidTests. The PTP-IP session layer's tests moved to OpenCineNikonAndroidTests.
        // The JNI shims themselves stay Android-only.
        .testTarget(
            name: "OpenZCineAndroidFacadeTests",
            dependencies: [
                "OpenZCineAndroidFacade", "OpenZCineCore",
                .product(name: "OpenCineNikonAndroid", package: "OpenCine"),
            ]
        ),
    ]
)
