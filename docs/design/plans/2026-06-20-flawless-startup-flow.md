# Flawless Startup Flow Implementation Plan

**Goal:** Make iOS startup, Wi-Fi discovery, first pairing, saved-camera reconnect, and stale-profile recovery reliable before live view work continues.

**Architecture:** Keep pure startup decisions in `OpenZCineCore` so they are unit-tested. Keep network discovery in the iOS adapter, but drive it from a continuous startup loop that treats empty scans and probe errors as transient. A successful camera session now lands on a camera-ready startup state instead of automatically entering live view.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest/Swift Testing, SwiftUI, native iOS PTP-IP sockets.

---

## Task 1: Startup Policy And Wi-Fi Scan Hosts

**Files:**

- Modify: `Sources/OpenZCineCore/PTPIPSavedCameraRecords.swift`
- Modify: `Sources/OpenZCineCore/CameraDiscovery.swift`
- Test: `Tests/OpenZCineCoreTests/CameraStartupPolicyTests.swift`
- Test: `Tests/OpenZCineCoreTests/CameraDiscoveryTests.swift`

- [x] Write failing tests for first-run/add-camera routing, saved-camera routing, deleted-only-camera routing, ZR AP host scanning, and Personal Hotspot subnet scanning.
- [x] Implement `CameraStartupPolicy.launchDestination(savedCameras:)`.
- [x] Implement `CameraDiscovery.automaticScanHosts(localAddresses:)`.
- [x] Run targeted Swift tests and confirm they pass.

## Task 2: Continuous Discovery

**Files:**

- Modify: `ios/Runner/NativeCameraDiscovery.swift`
- Modify: `ios/Runner/NativeAppRoot.swift`

- [x] Use `automaticScanHosts(localAddresses:)` inside the native subnet probe so Wi-Fi scans always include `192.168.1.1` and local hotspot subnet candidates.
- [x] Convert startup scanning from a one-shot call into a cancellable loop while the startup UI is active.
- [x] Treat empty scans and socket/probe errors as transient status updates rather than terminal failure states.
- [x] Keep discovered cameras updated for saved-camera rows so cold boot can show when a saved body becomes available.

## Task 3: Pairing And Ready State

**Files:**

- Modify: `ios/Runner/NativeAppRoot.swift`

- [x] Keep native first-pair alert behavior.
- [x] Save the camera after successful pair confirmation.
- [x] Reconnect after the Nikon ZR briefly drops the first pairing session.
- [x] Skip pairing prompts for saved cameras.
- [x] Stop automatic live-view entry after session setup; show a camera-ready startup surface instead.
- [x] Add clear disconnect, forget-pairing, and pair-new-camera actions from the ready surface.

## Task 4: Documentation And Verification

**Files:**

- Modify: `docs/design/plans/2026-06-20-wireframe-kit-app.md`

- [x] Update Stage 0 checklist to match the new startup milestone boundary.
- [x] Run `swift test`.
- [x] Run native/repo checks that are practical in this environment.
- [x] Commit with a Conventional Commit message.
