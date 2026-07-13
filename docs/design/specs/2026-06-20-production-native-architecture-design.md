# Production Native Architecture Design

**Date:** 2026-06-20
**Status:** Drafted from maintainer direction
**Supersedes:** Earlier docs that describe Flutter/Dart as the production target stack.
**External references checked:** Swift.org SDK installation docs
(`https://www.swift.org/documentation/articles/static-linux-getting-started.html` and
`https://www.swift.org/install/`), Android Developers Jetpack Compose docs
(`https://developer.android.com/compose`), and Apple SwiftUI documentation
(`https://developer.apple.com/documentation/swiftui/`).

## Decision

The archived Flutter prototype proved Nikon ZR pairing, PTP-IP behavior, live-view streaming,
camera-property polling/writes, and LUT workflows. It is not the production/release app stack and is
kept only as reference material under `reference/flutter-prototype/`.

Production OpenZCine will use:

- **Shared business/protocol core:** Swift Package Manager package, written in Swift.
- **iOS app:** SwiftUI shell and iOS-native services.
- **Android app:** Jetpack Compose/Android shell, with Android platform services in Kotlin where
  required.
- **Android shared-core bridge:** the Swift core compiled for Android through Swift SDK tooling and
  exposed to Kotlin through a small, explicit interop boundary.

This preserves the prototype's hard-won protocol knowledge while moving the release app toward the
platform-native performance, lifecycle control, media rendering, networking, and stability profile
expected of a field-monitor tool.

## Rationale

The app is unusually sensitive to latency and lifecycle behavior:

- It keeps a PTP-IP command/data connection alive while rendering a live JPEG stream.
- It must serialize command-socket transactions without corrupting an in-flight live-view read.
- It needs predictable foreground/background handling, local network permissions, USB/Wi-Fi
  transport behavior, and media/rendering performance.
- It is meant to feel like camera-side hardware, not a generic cross-platform app.

Native UI is the right production direction. SwiftUI and Jetpack Compose let each platform use its
own rendering, accessibility, lifecycle, permission, and packaging conventions. Sharing the protocol
core in Swift keeps the most valuable logic in one language without forcing shared UI.

## Recommended Boundary

Swift should own:

- PTP/IP packet encoding and decoding.
- Nikon property-code constants, value encoders/decoders, and protocol state machines.
- Pairing/session orchestration that is independent of socket implementation.
- Camera state snapshots and command intents.
- Storage/free-space and remaining-time calculations.
- LUT parsing and pure image-assist math when it is independent of platform GPU APIs.
- Deterministic unit tests and captured-protocol replay tests.

Platform shells should own:

- Sockets, Bonjour/mDNS, USB/session permissions, lifecycle, background/foreground recovery.
- Live-view image decode/display and GPU render path.
- SwiftUI and Jetpack Compose UI.
- App storage, downloads, WebViews, haptics, accessibility, and platform settings.
- Bridging and telemetry around rejected camera writes and connection drops.

This avoids a swollen shared layer. The Swift package should be portable, deterministic, and easy to
test without a camera. Platform-specific code should stay close to the native APIs that make it fast
and reliable.

## Android Swift Risk Posture

Swift on Android is viable enough to investigate for a shared protocol/business package, but it
should be treated as an adoption risk until this repo proves:

- reproducible Android builds for all required ABIs;
- stable Swift runtime packaging in APK/AAB output;
- acceptable binary size and startup overhead;
- clean Kotlin-to-Swift interop for commands, async results, byte buffers, and errors;
- debuggable crash reporting with symbolication;
- CI support on GitHub Actions;
- no blocking issue with Play Store packaging or target-device compatibility.

The mitigation is deliberate layering: Android can still ship a native Jetpack Compose app even if the
first production milestone ports the shared core more slowly or temporarily wraps a Kotlin adapter
around validated behavior from the Flutter prototype.

## Proposed Repository Shape

```text
Package.swift                 # Swift package for shared core once production migration starts
Sources/OpenZCineCore/          # PTP-IP, camera state, Nikon protocol helpers, pure logic
Tests/OpenZCineCoreTests/       # unit and replay tests for shared Swift core
Apps/iOS/                     # SwiftUI app target
Apps/Android/                 # Gradle project, Jetpack Compose UI, Kotlin platform adapters
reference/flutter-prototype/   # archived Flutter prototype reference
docs/design/                  # specs and implementation plans
vendor/                       # proprietary Nikon references, gitignored
ref/                          # reference captures, gitignored
```

The production root is native-only. Prototype files should stay under `reference/flutter-prototype/`
unless a deliberate protocol-reference change is being made.

## Migration Strategy

1. Freeze the archived Flutter prototype as protocol reference evidence while the native stack is
   being built.
2. Extract pure protocol behavior from Dart into a Swift package using tests first:
   packet framing, transaction IDs, init/open-session flow, property decoding, timecode, storage info,
   and live-view object parsing.
3. Build an iOS SwiftUI vertical slice: pair/connect, open session, start live view, render frames,
   show core status.
4. Build the Android Jetpack Compose vertical slice using the Swift core through a minimal bridge.
5. Port the wireframe UI shell and settings model natively on both platforms.
6. Retire the archived Flutter reference only after native iOS and Android can reproduce the
   connection/live-view baseline and no longer need the old implementation notes.

## Testing And Verification

Shared Swift core:

- XCTest for packet encoding/decoding, property parsing, state transitions, storage calculations, and
  captured payload replay.
- No platform UI dependencies.
- Deterministic fixtures from safe, redistributable captures only. Proprietary Nikon docs and private
  captures stay out of git.

iOS:

- XCTest for platform adapters.
- SwiftUI snapshot/interaction tests where practical.
- On-device tests for Local Network permission, USB/Wi-Fi connection, live-view streaming, and
  foreground/background recovery.

Android:

- JVM tests for Kotlin adapters.
- Instrumented tests for bridge loading and platform services.
- Compose UI tests for monitor shell, picker panels, settings, and assist toggles.
- On-device ABI/build verification for Swift runtime packaging.

Prototype:

- Treat archived Flutter files as reference only; they are not part of root CI or production
  verification.

## Open Questions

- Which Swift Android SDK/toolchain version is stable enough to pin for the first Android bridge
  spike?
- Should the first Android bridge expose a C ABI, JNI wrapper, or generated bindings?
- Should `reference/flutter-prototype/` remain long-term as a protocol lab, or be removed once native
  parity is reached?
- Which minimum iOS and Android OS versions are required for production?
