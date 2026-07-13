# Wireframe Kit App Implementation Plan

**Goal:** Bring the production native apps into alignment with the Penpot wireframe kit:
monitor-style live view, `DISP` modes, transient picker panels, view assists, and operator settings.

**Architecture:** Treat the archived Flutter implementation as prototype/reference evidence.
Production UI is implemented twice, in SwiftUI and Jetpack Compose, backed by the shared Swift core
and thin platform-specific adapters. Split monitor chrome, command cards, picker panels, assist
overlays, and settings into focused components so camera protocol work and UI work can advance
independently.

**Tech Stack:** Swift Package Manager shared core, SwiftUI iOS app, Jetpack Compose Android app,
Kotlin platform adapters, archived Flutter prototype as reference.

**Spec:** `docs/design/specs/2026-06-20-wireframe-kit-app-design.md`
**Responsive layout spec:**
`docs/design/specs/2026-06-20-responsive-native-layout-system-design.md`

**Commits:** This project batches commits unless the user asks otherwise. Do not commit per task.
Run `just check` before claiming the plan is complete.

---

## File Structure

- Create SwiftUI monitor components under `Apps/iOS/OpenZCine/Monitor/`.
- Create SwiftUI settings components under `Apps/iOS/OpenZCine/Settings/`.
- Create Compose monitor components under `Apps/Android/app/src/main/.../monitor/`.
- Create Compose settings components under `Apps/Android/app/src/main/.../settings/`.
- Add shared UI-agnostic enums/state in `Sources/OpenZCineCore/CameraState/`.
- Keep `reference/flutter-prototype/` as archived prototype reference until the native vertical
  slices have parity.

## Stage 0 - Startup, Pairing, And Live Readiness

- [x] iOS startup screen follows Penpot `Startup — Saved Cameras` with app/version label, status
  pill, saved-camera rows, online/offline state, and `Pair new camera`.
- [x] iOS discovery screen follows Penpot `Startup — Pairing` with Connect to PC guidance, discovery
  scope, Wi-Fi/USB-C segment, discovered camera card, manual IP entry, and pairing help.
- [x] iOS first-run and empty saved-camera states route straight into add-camera discovery.
- [x] iOS Wi-Fi discovery runs continuously while startup is visible, treating empty scans and probe
  errors as transient waiting states instead of terminal failures.
- [x] iOS Wi-Fi discovery always checks the Nikon ZR AP address `192.168.1.1` plus local subnet
  candidates such as iPhone Personal Hotspot-assigned `172.20.10.x` addresses.
- [x] iOS first-time Nikon profile setup presents the pairing code in a native system alert.
- [x] iOS saves paired camera records after a successful pairing confirmation and skips pairing on
  reconnect.
- [x] iOS silently restores a locally removed camera when the Nikon body still accepts this app
  identity, falling back to the pairing-code flow only on `rejectedInitiator`.
- [x] iOS reconnects through the saved profile after first-time pairing before marking the camera
  ready.
- [x] iOS stops startup at a camera-ready state; live-view entry is now a separate next milestone.
- [x] iOS startup includes a visible local `Remove` recovery action for stale local state.
- [x] iOS cold boot with saved cameras continuously checks local network availability while the saved
  camera list is visible.
- [ ] Android startup flow mirrors the iOS pairing, saved-profile restore, and live-readiness
  behavior.
- [ ] Add hardware smoke coverage for first pair, saved reconnect, locally removed restore, and
  camera-profile-cleared re-pairing.

## Stage 0.5 - Responsive Native Layout Foundation

- [x] Replace startup fixed Penpot-width compositions with adaptive SwiftUI columns backed by pure
  `OpenZCineCore` layout policies.
- [x] Add no-horizontal-overflow tests for small notched landscape phone, regular landscape phone,
  large Pro Max landscape, and wide iPad/full-width profiles.
- [x] Keep backgrounds full-bleed while all text, cards, buttons, and status pills remain inside the
  safe content bounds.
- [x] Apply the same startup layout container to discovery, saved-camera, and camera-ready states.
- [ ] Define priority overflow rules for live-view assist tools and camera-value strip before the
  live monitor is treated as polished.

## Stage 1 - Monitor Shell And DISP Modes

- [x] Create shared `DispMode` in `OpenZCineCore` with `live`, `clean`, and `command`, plus a default
  order matching the wireframe: Live, Clean, Command.
- [x] Write tests that cycling from each mode follows the configured order and wraps around.
- [x] Create first SwiftUI monitor shell with slots for live content, top status bar, left rail, right
  rail, assist toolbar, and camera-value strip.
- [ ] Create Compose `MonitorShell` with the same slots and behavior.
- [x] Add a `DISP` button in the iOS shell that cycles `DispMode`.
- [ ] Add a `DISP` button in the Android shell that cycles `DispMode`.
- [x] Render iOS `clean` mode with only essential status, rails, fps, and `DISP`.
- [ ] Render Android `clean` mode with only essential status, rails, fps, and `DISP`.
- [x] Render iOS `command` mode through native Command views.
- [ ] Render Android `command` mode through native Command views.
- [ ] Run shared Swift tests plus the available iOS/Android UI tests.

## Stage 2 - Camera Value Strip And Picker Panels

- [ ] Define shared camera-value presentation models in the Swift core.
- [x] Create SwiftUI picker panels with title, subtitle, close affordance, segmented mode controls,
  option list, selected-state highlight, and unavailable-state message.
- [ ] Create Compose picker panels with the same behavior.
- [ ] Route camera writes through the shared core command-intent model and platform command socket
  adapter.
- [ ] Keep enum sources from camera property descriptions, with prototype fallback values only as
  temporary reference data.
- [ ] Add tests for picker option selection, current-value highlighting, and rejected-write lock
  annotations on both native platforms where practical.

## Stage 3 - Command View

- [x] Implement first iOS command cards for status, health, exposure, focus, image, and audio.
- [ ] Populate already-supported fields from `CameraState`: timecode, ISO, base ISO, shutter,
  aperture, WB, resolution/framerate, codec, focal length, and lens descriptor.
- [ ] Show storage and temperature as unavailable until standard storage reads and verified
  Nikon-specific health reads exist.
- [x] Wire exposure cards to the same picker-panel actions as the bottom strip.
- [ ] Add widget tests that unsupported fields render unavailable without throwing.
- [ ] Add native command-view coverage and run `just native-check`.

## Stage 4 - View Assist State And Panels

- [x] Add app-side models for guides, grid, level, desqueeze, and exposure assist visibility.
- [x] Implement the iOS assist toolbar with visible tools in wireframe order and overflow through
  `More`.
- [x] Implement iOS guide panel: Film/Social tabs, preset aspect ratios, mask toggle, and custom ratio
  fields.
- [x] Implement iOS grid panel: Thirds, Phi Grid, and Diagonal.
- [x] Implement iOS level panel: enable toggle and Horizon/Gauge style.
- [x] Implement iOS desqueeze panel: enable toggle, standard ratios, custom ratio, and
  horizontal/vertical orientation.
- [x] Add rendering hooks for app-side overlays over the live image in SwiftUI. Exposure scopes
  initially show configured state without waveform/parade/histogram signal processing.
- [ ] Add rendering hooks for app-side overlays over the live image in Compose.
- [x] Add tests for assist-state toggles and persistence-ready serialization.
- [ ] Add native assist-overlay coverage and run `just native-check`.

## Stage 5 - Operator Settings

- [x] Create `OperatorSettings` with link, view-assist, controls, display, and system sections.
- [x] Add persistence-ready preferences for toolbar order, `DISP` order, display visibility,
  haptics, record-hold, stream preset, and quality bias.
- [ ] Persist operator preferences to device storage.
- [x] Implement first iOS operator settings panel with tabs: Link, View Assist, Controls, Display,
  System.
- [x] Wire Display settings to live monitor chrome visibility.
- [x] Wire Controls settings to `DISP` order and record-hold behavior.
- [x] Wire Link settings to existing stream size/compression choices without disrupting active live
  view.
- [x] Add tests for settings defaults, serialization, and applying display/control preferences.
- [ ] Add native operator-settings coverage and run `just native-check`.

## Stage 6 - Protocol-Backed Additions

- [ ] Add standard PTP storage reads for capacity and free space before estimating remaining minutes.
- [ ] Compute approximate remaining minutes only when media free space and the selected recording
  bitrate/format are known.
- [ ] Add verify-on-hardware probes for Nikon-specific temperature, focus mode/area/subject, audio,
  IBIS/e-shutter, tone, and picture profile properties.
- [ ] Hide or mark each verify-on-hardware field as unavailable until reads are confirmed.
- [ ] Add unit tests for storage/free-space decoding and remaining-minutes calculation.
- [ ] Run the targeted PTP tests, then `just check`.

## Validation

- [x] `swift test`
- [x] iOS app build/tests when target exists
- [ ] Android app build/tests when target exists
- [x] Flutter prototype archived outside the active validation gate
- [x] `just check`
- [ ] On-device smoke test: first pair opens native code alert, camera-side Continue reconnects into
  the saved profile, subsequent reconnect skips the pairing code, local removal restores without a
  code when the Nikon body still has the profile, and monitor opens only after the first live frame
  renders.
- [ ] On-device smoke test: pair/connect, enter live view, cycle `DISP`, open each picker, toggle each
  assist panel, open settings, and confirm live streaming continues.
- [ ] On-device hardware test: verify rejected camera writes annotate the UI and do not disconnect.
