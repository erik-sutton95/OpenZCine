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
- Link health, transport presentation, and Swift-owned preview size/compression/thermal policy
  (in progress). **[VERIFY-ON-HW]** Nikon live-view compression values and warning-state behavior
  require a supported camera pass; this policy must never alter recording configuration or card writes.
- Media browse, full progressive-proxy playback, still viewing, and complete-cache-only Android
  delivery, including Camera/On-device library sources, categories, sorting, favorites, grid/list
  layouts, filtered playback navigation, transport/scrub/mute, batch selection, native Share, and
  scoped-storage Save to Gallery for verified MOV/MP4/M4V videos (in progress). Gallery writes stay
  hidden with `IS_PENDING` until their exact byte count is copied, clean up failed or cancelled rows,
  and report skipped non-video or incomplete selections without exposing camera paths or `.part`
  files.
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
  the exact rendered fit/fill feed rect, and offer Horizon/Gauge level styles with an explicitly labelled
  device-tilt fallback when a frame has no reliable camera level (direct gravity sensor
  where available; normalized low-pass accelerometer approximation otherwise). Physical Nikon validation
  remains required; debug-fixture metadata is never presented as camera data.
- **Android advanced framing-assist parity** (OPE-59, in review): local multi-select Film/Social
  delivery frames with inverse-union masking, independent thirds/phi/diagonal grids, centre
  crosshair, and horizontal/vertical de-squeeze. Live-monitor assists resolve against the same
  exact rendered fit/fill content rect as focus and horizon, and never change Nikon Grid Display.
- **Android monitor picker and portrait-fill parity** (OPE-62, in review): persist the iOS fit 16:9
  versus fill portrait choice, forward it into the shared Swift zone map, centre-crop the feed and
  every feed-aligned overlay through one content rectangle, and seat fill capture/assist chrome
  from shared zones. Live ISO, shutter, iris, focus, and white-balance pickers reuse only typed
  requests already accepted by the CameraSession/Swift command seam; descriptor-dependent
  resolution and codec controls remain read-only. **[VERIFY-ON-HW]** Confirm picker writes and the
  tightest fit/fill portrait plus landscape states against a supported Nikon body and inspect all
  four screen edges on the Android hardware floor.
- **Android authoritative monitor readouts** (OPE-63, in review): render live-view timecode only
  from the camera frame accepted for display; render resolution, codec, card space, recording FPS,
  camera battery, ISO, shutter, iris, focus, and white balance from `CameraPropertySnapshot`; and
  read handset battery from Android. Missing, disabled, malformed, or unsupported values remain
  visibly unavailable. Synthetic timecode exists only in the explicit debug feed. The readout path
  adds no live-frame subscriber, so OPE-60 link scoring and DISP 3 stream shutdown retain their
  existing ownership. **[VERIFY-ON-HW]** Confirm timecode on/off and frame progression, property and
  battery readback (including external power), card-space formatting, live link bars, connected-idle
  DISP 3 behavior, and every chrome edge against a supported Nikon body on the Android hardware floor.
- **Android direct-manipulation monitor parity** (OPE-65, in review): toolbar taps retain their
  existing local assist behavior while long-press opens the real, persisted configuration panel at
  the measured tool anchor without click-through. Command-dashboard tiles and the supported View
  Assist Toolbar order use direct long-press drag, persist their exact destination, expose equivalent
  accessibility move actions, respect the haptic preference, and leave locked or pending camera
  writes on the typed `CameraSession`/Swift seam. **[VERIFY-ON-HW]** Exercise every configurable
  assist plus dashboard/settings drags against a supported Nikon camera in Samsung portrait and
  landscape, then inspect all four panel and dragged-row edges.
- **Android configurable DISP and monitor-chrome parity** (OPE-66, in review): persist and reconcile
  the enabled Live/Clean/Command order, recover a disabled active mode, and project the typed mode
  through the existing shared Swift zone map. Android now honors supported chrome and individual
  status-readout visibility while retaining a Settings recovery control, plus an active-recording
  control, when the landscape rails are hidden. Pending camera writes remain on the typed session
  seam as modes or chrome change. Samsung SM-A127F demo-fixture verification covers portrait and
  landscape, reorder/disable persistence, active-mode recovery, two-mode DISP cycling, hidden-rail
  Settings recovery, and the tight 602dp noncompact grid. **[VERIFY-ON-HW]** Repeat command-mode
  stream release and recording safety against a supported Nikon body.
- **Android direct AF-point and feed-gesture parity** (OPE-71, in progress): inverse-map feed taps
  through the exact fit/fill and de-squeezed image rectangle into authoritative camera focus
  coordinates, then send Nikon `ChangeAfArea` and tracking-safe reset sequences only through the
  shared Swift session. One gesture arbiter preserves portrait pinch, uses vertical swipes for
  explicitly enabled Live/Clean modes, and provides a session-local long-hold AF-point lock with
  truthful progress, haptics, and accessibility state. Real sessions fail closed when focus
  dimensions or headers are unavailable; debug fixtures never pretend that a camera accepted a
  move. **[VERIFY-ON-HW]** Confirm tap coordinates, tracking release/re-latch reset order, lock and
  reset affordances, pinch/swipe arbitration, and every feed edge on the Samsung hardware floor
  against a supported Nikon body.
- **Android monitor feed texture parity** (OPE-72, in review): the Android monitor now mirrors
  iOS's feed-local vignette and deterministic static grain after the camera frame/effect pipeline.
  Resolution-only state and cached draw resources keep same-resolution frames from rebuilding its
  render plan, while the exact fit/fill and de-squeezed visible-image intersection excludes
  letterbox and chrome and leaves clean-source analysis plus framing/focus/horizon geometry
  unchanged. **[VERIFY-ON-HW]** Confirm the presentation ordering with every API 33 effect and a
  supported Nikon live stream.
- **Android custom and RED LUT library parity** (in review) — operator-selected `.cube` imports
  are strictly parsed by the shared Swift core, copied into app-private storage under generated
  names, and restored as stored monitor selections. The RED surface is deliberately fail-closed
  until an authorized Android endpoint, terms acknowledgement, and delivery integration exist;
  its shared internet/camera-AP guard is already in place. Non-redistributable LUT assets are
  never bundled or committed.
- **Bluetooth shutter remote** — record start/stop from a BT remote.
- **Media browser & playback** — on-camera and validated-local clip browsing with categories,
  sorting, persisted favorites, grid/list selection and complete-cache-only batch sharing;
  progressive proxy playback with an independent assist toolbar, clean-source waveform and
  vectorscope analysis, decoded-audio metering, display LUT/false-colour/peaking/zebra effects,
  including the API 33 AGSL renderer and an SDR-only Media3 GLES fallback on API 29–32 with a
  pre-effect clean-scope tap and fail-closed HDR gating; and
  anchored long-press configuration panels that share live operator choices while retaining
  playback-only visibility, framing/desqueeze, frame scrubbing, zoom/pan, and transport gestures;
  and a transfer-backed
  Android still-photo viewer (JPEG/PNG progressive preview; explicit thumbnail fallback for
  unsupported HEIF/RAW decoders). Android playback-assist parity is tracked by OPE-69.
- **Android Frame.io delivery options and camera-AP hop parity** (OPE-64, in progress): Adobe IMS
  clip delivery
  accepts only finalized, approved cache artifacts; optionally bakes the selected approved monitor
  LUT into a transient MP4 without changing the original; and records a bounded, secret-free
  app-private metadata sidecar after confirmed upload. A real saved camera-AP session can leave only
  after a second explicit operator confirmation, retains the delivery context while waiting for
  validated internet, and rejoins the exact saved profile after completion, cancellation, or timeout.
  Rejoin is claimed only after fresh protocol-connected evidence. Fixtures cannot use the hop.
  **[VERIFY-ON-HW]** Adobe sign-in/upload, Media3 LUT export, all delivery-dialog edges, and the real
  Nikon leave/rejoin path still require configured Android hardware validation.
- **Apple Watch companion** (in progress) — live-view relay to the watch.
- **Wear OS companion** (OPE-67, in progress) — foreground-only phone-mediated wrist monitor and
  guarded record relay. It shares the canonical iOS watch v1 payload contract, actual Android
  monitor/camera values, camera timecode, and measured live-view FPS. Display-baked previews reuse
  the phone's active effects pipeline, while a bounded three-frame acknowledgement-paced relay
  adapts resolution and JPEG quality to the Wear link. No direct Wear camera, pairing, Swift core,
  or network path is in scope.
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
