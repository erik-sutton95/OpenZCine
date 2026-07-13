# Production Native Migration Implementation Plan

**Goal:** Migrate OpenZCine from a Flutter prototype to a production native architecture:
shared Swift business/protocol core, SwiftUI iOS app, and Jetpack Compose Android app.

**Architecture:** Preserve the archived Flutter prototype as reference evidence while extracting pure
camera logic into `OpenZCineCore`, a Swift Package Manager package. iOS consumes the package directly
from SwiftUI. Android consumes the same package through a small Kotlin bridge after an explicit Swift
SDK for Android spike proves build, packaging, interop, and runtime behavior.

**Tech Stack:** Swift Package Manager, XCTest, SwiftUI, Xcode, Gradle, Kotlin, Jetpack Compose,
Android instrumented tests, Swift SDK tooling for Android.

**Spec:** `docs/design/specs/2026-06-20-production-native-architecture-design.md`

---

## Stage 0 - Preserve Prototype Evidence

- [x] Record the current Flutter prototype responsibilities: pairing, Bonjour/manual discovery,
  PTP-IP client, live-view stream, camera property polling/writes, LUT import, and monitor UI.
- [x] Add a short `reference/flutter-prototype/README.md` explaining that Flutter is a protocol/UI
  prototype, not the production stack.
- [x] Move Flutter files under `reference/flutter-prototype/` so root tooling stays native-only.
- [x] Remove Flutter from root `just` recipes, CI expectations, and the active Xcode project.

## Stage 1 - Shared Swift Core Skeleton

- [x] Create `Package.swift` with a library target named `OpenZCineCore` and test target
  `OpenZCineCoreTests`.
- [x] Add initial module folders:
  - `Sources/OpenZCineCore/`
  - `Tests/OpenZCineCoreTests/`
- [x] Add first Swift Testing coverage for byte-order helpers and PTP-IP packet framing before
  porting logic.
- [x] Add `just swift-format`, `just swift-test`, and `just swift-check` recipes after the package
  exists.
- [ ] Add CI for `swift test` on macOS.

## Stage 2 - Port Protocol Core From Dart To Swift

- [x] Port first PTP-IP packet/container encoding and decoding primitives.
- [x] Port first operation request/response parsing primitives.
- [x] Port first pairing/init/open-session handshake payloads and session script.
- [x] Port first transaction data-phase collector for StartData/Data/EndData/OperationResponse.
- [x] Port standard PTP `DeviceInfo` identity parsing.
- [ ] Port Nikon property constants and pure value decoders/encoders.
- [ ] Port live-view object parsing, including timecode extraction.
- [ ] Port camera-state snapshots and command intents.
- [ ] Port storage capacity/free-space parsing and remaining-time calculation.
- [ ] Add replay fixtures from redistributable captures or synthetic payloads.
- [ ] Keep Swift tests covering the ported behavioral cases, using archived Dart tests as reference
  when a protocol behavior needs comparison.

## Stage 3 - iOS SwiftUI Vertical Slice

- [x] Rework the existing `ios/Runner.xcodeproj` as the first native SwiftUI iOS app setup.
- [x] Add SwiftUI app shell with pair/connect screen and live-monitor placeholder.
- [x] Implement iOS platform adapter for PTP-IP sockets and local network permission messaging.
- [x] Implement iOS Bonjour discovery plus local subnet PTP-IP probing fallback.
- [ ] Implement iOS app lifecycle reconnection handling.
- [x] Connect iOS socket adapter to `OpenZCineCore` session orchestration.
- [x] Render live-view JPEG frames through a native image pipeline.
- [ ] Add on-device smoke tests for pair/connect/start-live-view/stop-live-view.
- [x] Add `just ios-build` once the app target exists.
- [ ] Add `just ios-test` once native iOS tests exist.

## Stage 4 - Android Swift-Core Spike

- [ ] Pin a Swift SDK for Android/toolchain version and document install commands with checksums.
- [ ] Create a minimal Android build that compiles `OpenZCineCore` for the required Android ABIs.
- [ ] Choose and prove the bridge shape: C ABI, JNI wrapper, or generated bindings.
- [ ] Pass byte buffers from Kotlin to Swift and return typed success/error results.
- [ ] Verify APK/AAB packaging includes the Swift runtime and native libraries correctly.
- [ ] Verify startup time, binary size, crash reporting, and symbolication on at least one device.
- [ ] Add CI or a documented local-only gate if hosted CI is not reliable yet.

## Stage 5 - Android Jetpack Compose Vertical Slice

- [ ] Create `Apps/Android/` as a Gradle project with Jetpack Compose.
- [ ] Add pair/connect screen and live-monitor placeholder.
- [ ] Implement Android platform adapters for sockets, NSD/mDNS, permissions, lifecycle, and storage.
- [ ] Call the Swift core through the proven bridge.
- [ ] Render live-view JPEG frames through native Android image/display APIs.
- [ ] Add Compose tests for the shell and instrumented tests for bridge loading.
- [ ] Add `just android-build` and `just android-test` once the Gradle project exists.

## Stage 6 - Native Wireframe Implementation

- [ ] Reinterpret `docs/design/specs/2026-06-20-wireframe-kit-app-design.md` for native UI:
  SwiftUI components on iOS and Compose components on Android.
- [ ] Implement the three `DISP` modes natively.
- [ ] Implement monitor chrome: status bar, rails, assist toolbar, bottom value strip, and record
  affordance.
- [ ] Implement shared picker behavior in each native UI layer.
- [ ] Implement operator settings in native UI, backed by platform persistence.
- [ ] Keep the Swift shared core free of SwiftUI and Compose dependencies.

## Stage 7 - Prototype Retirement Gate

- [ ] Confirm native iOS can pair, connect, stream live view, show timecode/status, and recover from
  disconnects at least as well as the Flutter prototype.
- [ ] Confirm native Android can pair/connect/stream through the Swift core or document the remaining
  bridge blocker.
- [ ] Confirm wireframe-critical UI flows exist natively.
- [x] Archive the Flutter prototype under `reference/flutter-prototype/`.
- [ ] Update README, AGENTS, CONTRIBUTING, CI, and `justfile` to make native production commands the
  primary path.

## Validation

- [x] `swift test`
- [x] iOS app build.
- [ ] iOS on-device smoke test.
- [ ] Android app build and on-device smoke test.
- [x] Root production checks are native-only; Flutter prototype checks are no longer part of the
  active validation gate.
- [x] `just check`
