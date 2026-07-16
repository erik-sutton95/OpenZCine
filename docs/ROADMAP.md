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
  layouts, cancellation-aware 32-object paging across every installed camera card, filtered playback
  navigation, transport/scrub/mute, batch selection, native Share, and scoped-storage Save to Gallery
  for verified MOV/MP4/M4V videos (in progress). Gallery writes stay
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
  requests already accepted by the CameraSession/Swift command seam; descriptor-dependent controls
  become actionable only when the camera advertises exact options through OPE-89. **[VERIFY-ON-HW]**
  Confirm picker writes and the
  tightest fit/fill portrait plus landscape states against a supported Nikon body and inspect all
  four screen edges on the Android hardware floor.
- **Android camera-control and real RTT parity** (OPE-89, in progress): retain exact raw descriptor
  values inside the shared Swift session while Android receives only semantic current values and
  Swift-authorized options. The dynamic option seam now covers ISO scoped to the active codec and
  base circuit, mounted-lens aperture, white-balance Kelvin and presets, focus mode/area/subject,
  audio sensitivity/input/wind filter/attenuator/32-bit float, resolution/frame rate, codec, active
  shutter values, shutter mode and lock, white-balance tint, movie VR, and electronic VR. Exact
  Nikon ZR identity gates the stable fallback domains needed for omitted or temporarily narrowed
  descriptors; other models fail closed. Electronic VR also fails closed until codec readback is
  known and remains unavailable for every RAW codec family. Writes are serialized, rejected when
  the active Swift capability set does not contain the label, and accepted only after authoritative
  property readback matches. Both PTP-IP and USB-C publish measured command/response RTT through the
  session and clear it on disconnect. Fake-camera transport tests cover exact descriptor writes,
  model scoping, base-circuit changes, RAW rejection, readback rejection, RTT, and Compose option
  policy. **[VERIFY-ON-HW]** On a supported Nikon ZR over both Wi-Fi and USB-C, confirm descriptor
  values and raw write acceptance in each recording mode, lens swaps and aperture bounds, Low/High
  base-ISO switching, focus-ring descriptor narrowing, white-balance and audio modes, the omitted
  movie-VR fallback, electronic-VR rejection for R3D NE/N-RAW/ProRes RAW, readback timing and
  rejection feedback, plus RTT freshness across reconnect and transport replacement.
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
- **Android movable monitor-analysis panel parity** (OPE-68, in review): landscape and portrait-fill
  scopes plus the false-colour reference retain iOS-like direct drag while normalized app-local
  positions reconcile across viewport, orientation, and chrome changes. The shared zone map keeps
  every panel and exterior resize target clear of camera controls and system rails; live quick
  settings and accessibility expose per-panel recenter actions. Portrait fit retains its fixed,
  recency-selected two-scope stack, and feed-aligned overlays remain immovable. **[VERIFY-ON-HW]**
  Drag, clamp, relaunch, rotate, remove/re-add, and recenter every supported panel in the tightest
  Samsung landscape and portrait-fill states, then inspect all four edges.
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
- **Android legacy live-assist and portrait-crop parity** (OPE-91, in progress): API 29–32 renders
  LUT, false color, peaking, and zebra through the same shared Swift plan and GLES shader used by
  playback, with clean source frames retained for scopes. Live color input is pinned to original
  SDR and future HDR or unsupported formats fail closed with visible feedback. Portrait-fill
  guides, masks, grids, crosshair, and AF inverse mapping all retain the complete cropped camera
  coordinates, with the physical viewport clipping them exactly as on iOS. **[VERIFY-ON-HW]**
  Confirm all four effects on API 29 and API 32 hardware plus a real supported Nikon stream.
- **Android custom and RED LUT library parity** (in review) — operator-selected `.cube` imports
  are strictly parsed by the shared Swift core, copied into app-private storage under generated
  names, and restored as stored monitor selections. The RED surface is deliberately fail-closed
  until an authorized Android endpoint, terms acknowledgement, and delivery integration exist;
  its shared internet/camera-AP guard is already in place. Non-redistributable LUT assets are
  never bundled or committed.
- **Bluetooth shutter remote** — Android now accepts the same generic HID volume-button triggers
  as iOS while the live monitor is armed, alongside media/headset controls, with default-on
  preference, lifecycle disarm, and duplicate-event debounce. **[VERIFY-ON-HW]** Confirm volume,
  Play/Pause, and headset variants on physical remotes and normal volume behavior after disarm.
- **Media browser & playback** — on-camera and validated-local clip browsing with categories,
  sorting, persisted favorites, grid/list selection and complete-cache-only batch sharing. Camera
  discovery snapshots all usable card slots, alternates their newest handles inside bounded pages,
  publishes each page incrementally, and invalidates a stale cursor when a refresh or source change
  wins; no 256-object ceiling can hide older media or a second card;
  progressive proxy playback with an independent assist toolbar, clean-source waveform and
  vectorscope analysis, decoded-audio metering, display LUT/false-colour/peaking/zebra effects,
  including the API 33 AGSL renderer and an SDR-only Media3 GLES fallback on API 29–32 with a
  pre-effect clean-scope tap and fail-closed HDR gating; and
  anchored long-press configuration panels that share live operator choices while retaining
  playback-only visibility, framing/desqueeze, frame scrubbing, zoom/pan, and transport gestures;
  and a transfer-backed
  Android still-photo viewer (JPEG/PNG progressive preview; explicit thumbnail fallback for
  unsupported HEIF/RAW decoders). Android playback-assist parity is tracked by OPE-69.
- **Android media-library delivery parity** (OPE-87, in progress): the browser persists small,
  medium, and large grid densities and composes container, resolution, Today, and camera-slot
  filters from authoritative clip metadata. Connected camera browsing also shows every valid card's
  Swift-decoded free/total capacity in camera order; those cards select the same storage-ID filter
  and disappear for local or disconnected sources. Paired proxies retain their R3D source dimensions
  before the master is hidden, with proxy-pixel and filename fallbacks matching the shared policy. Saved
  camera cards expose only validated complete cache buckets, so clips and stills remain browsable,
  playable, favoritable, and deliverable without a live session; stale cache files fail closed and
  the persisted index no longer drops history at 1,024 records. Native Share, Save to Gallery, and
  Frame.io use one explicit non-destructive export configuration for an optional approved LUT bake,
  MOV/MP4 output, and bounded metadata inclusion. Frame.io records confirmed uploads by stable clip
  identity, skips completed clips by default, and offers an explicit re-upload override with accurate
  batch counts. All delivery paths accept only finalized approved-cache artifacts and never mutate the
  camera or cached original. **[VERIFY-ON-HW]** Exercise MOV and MP4 export, LUT baking, Android
  chooser and MediaStore publication, and persisted Frame.io history with configured credentials.
- **Android Frame.io delivery options and camera-AP hop parity** (OPE-64, in progress): Adobe IMS
  clip delivery
  accepts only finalized, approved cache artifacts; optionally bakes the selected approved monitor
  LUT into a transient MOV or MP4 without changing the original; and records a bounded, secret-free
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
- **In-app bug reporting paths** (OPE-102, in progress) — iOS and Android offer an anonymous
  report through a small GitHub-App relay or a
  [signed-in GitHub issue](https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml) for richer
  optional details. Both create labelled public GitHub issues. The anonymous path has optional,
  user-selected screenshots re-rendered without embedded file metadata and a closed,
  privacy-filtered app-activity snapshot; it never uploads raw diagnostics, arbitrary logs, device
  names, camera/device identifiers, network identifiers, or original image bytes. Visible screenshot
  content remains the reporter's responsibility to review. Feature requests remain account-backed
  GitHub Discussions.
- **External beta diagnostics & support** (in progress) — Apple-native crash diagnostics,
  a user-reviewed local diagnostics share flow, and direct System links for help, feature requests,
  source, privacy, and terms.
- **First-live-view control guide** (in progress) — a replayable three-step introduction to camera
  controls, View Assist tap and press-and-hold behavior, and monitor system controls on iOS.
- **Android monitor-preference parity** (OPE-88, in progress) — expose the camera-first LEVEL overlay
  in the configurable assist-toolbar order with a labelled device-tilt fallback, and keep tap,
  long-press configuration, Display settings, and persistence synchronized.
- **Stored LUT library management** (OPE-88, in progress) — native deletion for imported Custom and
  downloaded RED LUTs, with built-in looks protected and active selections reconciled first to a
  validated same-category stored look, then to the protected built-in fallback.
- **Waveform/parade brightness calibration** (OPE-88, in progress) — a useful 0–200% trace-intensity
  range where 100% matches the former 25% appearance and saved iOS and Android settings migrate
  without a visual jump; vectorscope brightness retains its original gain contract.
- **Classic-notch iPhone layout hardening** (in progress) — fit the 16:9 feed tightly beside the
  notch and keep live-view chrome collision-free on compact landscape devices such as iPhone 11.
- **Compact-Pro guide panel hardening** (in progress) — keep cinema aspect-ratio choices on one
  line in the five-column Guides grid on non-Max iPhone 15 Pro, 16 Pro, and 17 Pro displays.
- **Android beta-readiness parity** (OPE-90, in progress): retain only bounded, closed-category
  local breadcrumbs and privacy-reduced Android 11+ process-exit reasons; generate an
  operator-readable cache report behind its own narrow FileProvider; and expose native System
  actions for support, account-free native bug reporting, account-backed feature requests,
  diagnostics, source, privacy, and terms without telemetry. The persisted three-step live-view
  guide is armed only by the first successfully decoded real Swift-camera frame, never a
  disconnected or synthetic fixture, and
  blocks phone, remote, and Wear camera commands while visible. Settings can replay it now when a
  real frame is available or schedule the next real frame.
- **Public launch landing actions**: the repository went public on 2026-07-15, so the landing page
  links to it directly. Android stays presented as clearly unavailable until it ships.
- **Landing-page camera compatibility** (in progress): identify the Nikon ZR, Z9, and Z5II as
  working, and the Z6, Z6II, Z6III, Zf, Z8, Z7, and Z7II as untested.

## Milestone Success Criteria

The native-iOS milestone (Phases 1–3) is complete when:

- A Nikon ZR connects, records, and streams live view from the production iOS app on a physical
  device.
- `just native-check` passes with no failures.
- Core line coverage ≥ 80 %.
- No known crashes on iOS 17+ hardware.
