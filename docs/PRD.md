# Product Requirements Document — OpenZCine

## Executive Summary

OpenZCine is an open-source native iOS and Android application that connects to, controls, and
monitors Nikon Z cinema-line cameras, primarily the **Nikon ZR**, over local PTP-IP or supported
USB transport. The app gives cinematographers and operators a professional remote for camera
control, record triggering, live image monitoring, playback, and media delivery without requiring
proprietary Nikon software.

## Problem Statement

Nikon Z cinema cameras support remote control over Wi-Fi via PTP-IP, but open,
community-maintained native tools remain limited. Independent filmmakers, focus pullers, and
camera operators need a reliable, inspectable tool that exposes camera state, triggers recording,
streams live view, and fits into their production workflow.

## Target Users

### Primary

- **Camera operators and focus pullers** working with supported Nikon Z cameras on professional or
  independent productions who need remote control from a phone or tablet on set.

### Secondary

- **Developers and integrators** who want to build custom tooling on top of the open PTP-IP
  client library (`Sources/OpenZCineCore`), embed camera control in larger production software, or
  contribute to the protocol implementation.

## Success Metrics

| Metric | Target | Notes |
| --- | --- | --- |
| Camera connection time | < 3 s on local Wi-Fi | From tap "Connect" to confirmed ready state |
| Record command round-trip | < 500 ms | Tap record → camera acknowledges REC state |
| Live-view frame latency | < 500 ms | First frame visible after live-view activation |
| Core unit-test coverage | ≥ 80 % line | `Sources/OpenZCineCore` measured by `just test` |
| Crash-free sessions | ≥ 99 % | On supported iOS 17+ and Android 10+ hardware |
| App package size | ≤ 100 MB | Per-platform release artifact before optional media |

## Core Features

### Feature 1 — Camera Discovery and Connection

**User Story:** As a camera operator, I want to discover my Nikon ZR on the local Wi-Fi network
and connect to it in a single tap, so I do not need to enter IP addresses manually.

**Acceptance Criteria:**

- The app scans the local subnet for a camera advertising PTP-IP.
- Discovered cameras are listed by name within 5 seconds of entering the Connect screen.
- Tapping a camera initiates the PTP-IP Init Command + Event socket handshake.
- A stable `appGUID` is persisted per device so the camera can recognise a returning client
  without requiring re-pairing mode (see `docs/nikon-mtp.md`).
- Connection errors surface a human-readable message derived from the PTP response code.

### Feature 2 — Record Start / Stop

**User Story:** As an operator, I want to remotely start and stop recording on the ZR from my
mobile device so I can trigger takes without touching the camera body.

**Acceptance Criteria:**

- The record button reflects the camera's actual recording state (idle / recording).
- Tapping record while idle sends the appropriate MTP operation and transitions the button to
  active within 500 ms of camera acknowledgement.
- Tapping record while recording sends the stop operation and returns the button to idle.
- If the operation is rejected (e.g. card full, overheating), the error is shown in the UI.
- State is re-synced if the connection is briefly interrupted and re-established.

### Feature 3 — Live View Monitoring

**User Story:** As a director or focus puller, I want to see a live image feed from the ZR on my
mobile device so I can confirm framing and focus remotely.

**Acceptance Criteria:**

- The live-view stream activates within 2 seconds of tapping the monitor icon.
- Frames are rendered at the highest rate the camera and connection allow (target ≥ 10 fps).
- The image follows the operator-selected fit or center-cropped fill presentation without
  distorting feed-aligned assists.
- The overlay (REC indicator, settings shortcut) does not obscure the center of frame.
- Live view deactivates cleanly when the app is backgrounded.

### Feature 4 — Camera Settings Readback

**User Story:** As an operator, I want to see the current camera settings (ISO, shutter, aperture,
white balance, codec) so I can confirm the camera is configured correctly without walking to it.

**Acceptance Criteria:**

- Key device properties are fetched and displayed on the main control screen after connection.
- Values update automatically when changed on the camera body.
- Properties not supported by the connected camera model are hidden, not shown as empty.

## Non-Functional Requirements

### Performance

- The app must maintain a stable PTP-IP connection for sessions up to 8 hours.
- Memory usage must remain below 100 MB during live-view streaming.
- The app must not drop below 30 fps in its own UI while streaming live view.

### Accessibility

- All interactive controls must expose native accessibility labels or Compose semantics.
- Dynamic Type and Android scalable text must be supported for text labels.
- Minimum touch targets are 44 × 44 pt on Apple platforms and 48 × 48 dp on Android.
- The record state must be communicable without colour alone (shape + label change required).

### Localization

- iOS strings must be extractable through `String(localized:)`; Android strings must live in
  resource files rather than production UI literals.
- The initial release ships English only; the localisation infrastructure must be in place.

## Out of Scope

- Camera firmware updates.
- Multi-camera switching in a single session (single camera per session, v1).
- Cameras outside the documented compatibility matrix.
- Cloud sync or remote control outside the local network.

## Technical Constraints

- **iOS deployment target:** iOS 17.0 minimum.
- **Android deployment target:** API 29 (Android 10) minimum; compile/target SDK 36.
- **Swift version:** Swift 6.0 strict concurrency.
- **Android language/UI:** Kotlin with Jetpack Compose; Swift SDK for Android packages the shared
  core behind `Sources/OpenZCineAndroidFacade` and a narrow JNI boundary.
- **Xcode:** 26.2 (current CI toolchain).
- **Camera protocol:** Nikon PTP-IP / MTP over Network. Spec located in `vendor/` (gitignored,
  Nikon-proprietary). Public protocol notes in `docs/nikon-mtp.md`.
- **No third-party networking libraries** — the PTP-IP client in `Sources/OpenZCineCore` uses
  Network.framework directly.
- The shared core (`Sources/OpenZCineCore`) must remain UI-free and portable; it must not import
  SwiftUI, UIKit, or any platform-specific framework.

## Timeline

| Phase | Goal | Status |
| --- | --- | --- |
| Phase 0 — Flutter prototype | Validate PTP-IP protocol against ZR | Complete (archived) |
| Phase 1 — Core library | PTP-IP client, connection state machine, property model | In Progress |
| Phase 2 — iOS shell | SwiftUI record/monitor UI wired to core | Complete |
| Phase 3 — Live view | Full live-view streaming pipeline, overlay layout | Complete |
| Phase 4 — Settings readback | Full device-property display and change notifications | In Progress |
| Phase 5 — Android shell | Jetpack Compose shell using Swift SDK for Android | In Progress |
