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

### Phase 5 — Android Shell (In Progress)

**Goal:** Jetpack Compose Android shell reusing `Sources/OpenZCineCore` via the Swift SDK for
Android.

**Deliverables:**

- Android Gradle project at `Apps/Android/` and release-safe shared-core bridge packaging.
- Swift SDK for Android integration verified for the current core build and runtime path.
- Saved-camera reconnect and Wi-Fi pairing, plus Compose monitor record/live-view control surfaces.
- Camera-property readback, command dashboard, and monitor-assist controls (in progress).
- Media browse, full progressive-proxy playback, still viewing, and complete-cache-only Android
  sharing, including Camera/On-device library sources, categories, sorting, favorites, grid/list
  layouts, filtered playback navigation, transport/scrub/mute, and batch selection (in progress).
- Standalone Operator Setup and app-owned progressive-media cache management (in progress).

**Status:** In progress. Android follows the same product shell while platform-specific USB-camera
transport, OCR, and cloud-account adapters remain separate, explicitly scoped follow-on work.

---

## Additional shipped features (beyond the core phases)

Feature work tracked as its own tasks on the Kaneo board, outside the Phase 0–5 milestone spine:

- **Monitoring & focus assists** (in progress) — focus peaking, vectorscope + waveform scopes,
  false color, 3D monitor LUT display, live audio meters.
- **Android live focus and virtual-horizon parity** (OPE-58, in review) — carry camera-origin
  AF/subject boxes and virtual-horizon angles through the Swift/JNI frame seam, render them over
  the exact aspect-fit feed rect, and offer Horizon/Gauge level styles with an explicitly labelled
  device-tilt fallback when a frame has no reliable camera level (direct gravity sensor
  where available; normalized low-pass accelerometer approximation otherwise). Physical Nikon validation
  remains required; debug-fixture metadata is never presented as camera data.
- **Android monitor feed texture parity** (OPE-72, to do) — mirror iOS's feed-local vignette and
  deterministic static grain after the camera frame/effect pipeline, clipped to the visible image
  without affecting clean-source analysis, framing/focus/horizon geometry, or monitor chrome.
- **Android custom and RED LUT library parity** (in review) — operator-selected `.cube` imports
  are strictly parsed by the shared Swift core, copied into app-private storage under generated
  names, and restored as stored monitor selections. The RED surface is deliberately fail-closed
  until an authorized Android endpoint, terms acknowledgement, and delivery integration exist;
  its shared internet/camera-AP guard is already in place. Non-redistributable LUT assets are
  never bundled or committed.
- **Bluetooth shutter remote** — record start/stop from a BT remote.
- **Media browser & playback** — on-camera and validated-local clip browsing with categories,
  sorting, persisted favorites, grid/list selection and complete-cache-only batch sharing;
  progressive proxy playback; and a transfer-backed Android still-photo viewer (JPEG/PNG
  progressive preview; explicit thumbnail fallback for unsupported HEIF/RAW decoders).
- **Frame.io clip upload** — OAuth/Adobe IMS clip delivery.
- **Apple Watch companion** (in progress) — live-view relay to the watch.
- **Wear OS companion** (OPE-67, in progress) — foreground-only phone-mediated wrist monitor and
  guarded record relay. It shares the canonical iOS watch v1 payload contract and actual Android
  monitor/camera values, while intentionally showing unavailable timecode/live-FPS/read-time fields
  until those camera readbacks land in the Android core seam; no direct Wear camera, pairing, Swift
  core, or network path is in scope.
- **Camera Wi-Fi pairing & join UX** — DJI-style camera-AP join flow, including local CameraX
  preview and bundled ML Kit scanning; transcripts are parsed only by the shared Swift core, and
  confirmed credentials enter encrypted storage only after a successful join.

## Milestone Success Criteria

The native-iOS milestone (Phases 1–3) is complete when:

- A Nikon ZR connects, records, and streams live view from the production iOS app on a physical
  device.
- `just native-check` passes with no failures.
- Core line coverage ≥ 80 %.
- No known crashes on iOS 17+ hardware.
