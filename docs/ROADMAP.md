# Roadmap — OpenZCine

> Live status is mirrored on the Kaneo board (project `OPE`). Keep this file and the board in
> sync — see `docs/PROJECT-MANAGEMENT.md`.

## Current Milestone: Native iOS Implementation

The active milestone delivers a production-quality native iOS app that connects to a Nikon ZR
camera over PTP-IP and provides record control and live-view monitoring.

## Phases

### Phase 0 — Flutter Prototype (Complete)

**Goal:** Validate the PTP-IP / MTP protocol implementation against a real Nikon ZR camera.

**Deliverables:**

- Working PTP-IP Init Command + Event socket handshake with the ZR.
- Record start / stop via MTP operations.
- Live-view frame retrieval and display.
- Protocol notes documented in `docs/nikon-mtp.md`.

**Status:** Complete. Archived at `reference/flutter-prototype/`.

---

### Phase 1 — Portable Core Library (In Progress)

**Goal:** Production Swift implementation of the PTP-IP client and camera state model in
`Sources/OpenZCineCore`.

**Deliverables:**

- `CameraConnection` actor: Init Command socket, Init Event socket, session lifecycle.
- `CameraStateStore`: observable camera property model (ISO, shutter, aperture, codec, REC state).
- `PTPIPClient`: typed MTP operation send/receive with error mapping.
- Stable `appGUID` API consumed by the shell from Keychain.
- `MonitorLayoutPolicy`: layout logic for live-view overlay positioning.
- Unit tests at ≥ 80 % line coverage in `Tests/OpenZCineCoreTests`.

**Key constraint:** No UIKit, SwiftUI, or platform imports. All network I/O via Network.framework
abstracted behind a protocol so it is testable without a live camera.

---

### Phase 2 — iOS Shell Scaffold (Complete)

**Goal:** SwiftUI `ios/Runner` shell wired to the core, with the main control UI functional.

**Deliverables:**

- `@main` app entry, scene configuration, and root `NavigationStack`.
- Camera discovery and connection screen.
- Main control view: record button, live-view toggle, settings shortcut.
- `@Observable` view models bridging `OpenZCineCore` state to SwiftUI.
- Keychain storage for `appGUID`.
- Error presentation for connection and operation failures.

**Status:** Complete. Shell shipped and running in TestFlight.

---

### Phase 3 — Live View Streaming (Complete)

**Goal:** Full live-view pipeline: PTP-IP event stream → frame decode → SwiftUI display with
production overlay layout.

**Deliverables:**

- Live-view activation / deactivation lifecycle (including app-backgrounding).
- Frame decode and rendering at ≥ 10 fps on device.
- Overlay layout: REC indicator anchored top-right, SETTINGS adjacent, record button
  vertically centred at trailing edge.
- `MonitorLayoutPolicy` integration for layout rules.

**Status:** Complete. Live-view pipeline ships; the ≥ 10 fps target is verified on device
during hardware sessions, not in CI.

---

### Phase 4 — Settings Readback (In Progress)

**Goal:** Full camera device-property display with real-time change notifications.

**Deliverables:**

- Complete MTP device-property list: ISO, shutter, aperture, WB, codec, remaining card space.
- Properties panel in the iOS shell.
- Change-notification subscription over the Event socket.
- Graceful hiding of properties not supported by the connected camera model.

---

### Phase 5 — Android Shell (Planned)

**Goal:** Jetpack Compose Android shell reusing `Sources/OpenZCineCore` via the Swift SDK for
Android.

**Deliverables:**

- Android Gradle project at `Apps/Android/`.
- Swift SDK for Android integration verified for the core build and runtime.
- Feature parity with the iOS shell for connect, record, and live-view.

---

## Additional shipped features (beyond the core phases)

Feature work tracked as its own tasks on the Kaneo board, outside the Phase 0–5 milestone spine:

- **Monitoring & focus assists** (in progress) — focus peaking, vectorscope + waveform scopes,
  false color, 3D monitor LUT display, live audio meters.
- **Bluetooth shutter remote** — record start/stop from a BT remote.
- **Media browser & playback** — on-camera clip browse and playback.
- **Frame.io clip upload** — OAuth/Adobe IMS clip delivery.
- **Apple Watch companion** (in progress) — live-view relay to the watch.
- **Camera Wi-Fi pairing & join UX** — DJI-style camera-AP join flow.
- **External beta diagnostics & support** (in progress) — Apple-native crash diagnostics,
  privacy-safe support reports, and direct System links for help, bugs, feature requests, source,
  privacy, and terms.
- **First-live-view control guide** (in progress) — a replayable three-step introduction to camera
  controls, View Assist tap and press-and-hold behavior, and monitor system controls on iOS.
- **Stored LUT library management** (in progress) — native long-press deletion for imported Custom
  and downloaded RED LUTs, with built-in looks protected and active selections reconciled safely.
- **Waveform/parade brightness calibration** (in progress) — a useful 0–200% trace-intensity range
  where 100% matches the former 25% appearance and saved iOS settings migrate without a visual jump.
- **Classic-notch iPhone layout hardening** (in progress) — fit the 16:9 feed tightly beside the
  notch and keep live-view chrome collision-free on compact landscape devices such as iPhone 11.
- **Android beta-readiness parity** (planned) — port the diagnostics, support links, and live-view
  guide after the iOS behavior is validated with external testers.

## Milestone Success Criteria

The native-iOS milestone (Phases 1–3) is complete when:

- A Nikon ZR connects, records, and streams live view from the production iOS app on a physical
  device.
- `just native-check` passes with no failures.
- Core line coverage ≥ 80 %.
- No known crashes on iOS 17+ hardware.
