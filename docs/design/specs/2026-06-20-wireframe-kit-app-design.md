# Wireframe Kit App Design

**Date:** 2026-06-20
**Status:** Drafted from Penpot wireframe inspection
**Source:** Penpot page `Wireframe`, boards `DISP 1 - Live Monitor`, `DISP 2 - Clean`,
`DISP 3 - Command`, assist-tool boards, picker boards, and settings boards.

## Goal

Turn the OpenZCine wireframe kit into the product/design source of truth for the native app
shells, live monitor, camera-control surfaces, view assists, and operator settings. The production
UI should be implemented with SwiftUI on iOS and Jetpack Compose on Android, while the current
Flutter UI remains a prototype/reference. The app should feel like a compact field monitor and
camera-side control panel: live image first, fast controls around it, and deeper configuration only
when the operator asks for it.

## Product Model

The wireframe defines one primary screen with three `DISP` modes:

| Mode | Purpose | Persistent UI |
| --- | --- | --- |
| Live Monitor | Default operating view for framing, exposure, and quick readouts. | Live feed, top status bar, right control rail, left level/battery rail, bottom assist toolbar, bottom camera-value strip. |
| Clean | Low-clutter monitoring view. | Live feed, essential status/readouts, `DISP`, rails, and minimal fps/status. |
| Command | Dense control dashboard. | Live feed is replaced or minimized by command cards for image, focus, exposure, audio, storage, temperature, camera, and lens. |

`DISP` is a mode cycle, not a settings tab. Its order is user-configurable from Settings > Controls.

## Startup And Link Flow

The startup screens are a real workflow, not a placeholder. They own camera discovery, first-time
pairing, saved-profile reconnects, and live-view readiness before the monitor opens.

- The Penpot boards `Startup — Saved Cameras` and `Startup — Pairing` define the startup shell:
  the compact app/version label `OpenZCine - v0.1`, a status pill, and a light neutral
  field-monitor surface.
- Saved cameras are the default startup surface when paired profiles exist. The left side explains
  the saved-camera behavior and exposes `Pair new camera`; the right side lists paired cameras with
  online/offline state, last transport, last-seen context, and a direct reconnect affordance.
- `Pair new camera` opens the discovery surface. Discovery shows a `DISCOVERY` label, `Find your
  camera` headline, Connect to PC guidance, a scope-style discovery graphic, a Wi-Fi/USB-C transport
  segment, discovered camera cards, `Connect camera`, `Enter IP manually`, and `How pairing works`.
- The Wi-Fi/USB-C segment is interactive: it switches the discovery backend between network
  discovery (Bonjour + subnet probe) and USB-attached cameras (ImageCaptureCore device browser),
  and swaps the empty-state copy accordingly (`Waiting for camera on USB-C`). Inside the
  first-pair wizard the segment is seeded from the step-1 transport choice; USB-C paths get
  transport-specific camera-prep and cable/permission instructions instead of network-profile
  steps. A saved USB-C camera reconnects silently the moment it is plugged in.
- First-time Nikon `Connect to PC` profile setup requests pairing and presents the code in a native
  platform dialog. On iOS this is a system alert with `Cancel` and `Pair`, not an inline custom
  panel.
- When the camera reports pairing complete, the app saves the host profile locally, closes the
  transient pairing session, and reconnects through the saved profile without requesting another
  code.
- Returning connections to a saved host skip pairing and proceed directly to the saved Nikon
  profile. If a camera was removed locally but the Nikon still trusts this app identity, the app
  should silently restore the local record by first trying the saved-profile handshake. The pairing
  code should reappear only when the camera rejects that identity or the user is creating a genuinely
  new Nikon profile.
- The monitor must not open until live view is genuinely ready: the app should configure live view,
  start streaming, fetch the first JPEG frame, and decode it successfully before transitioning from
  startup into the live monitor.
- Startup should keep a visible `Remove` action for the current host when local app state and
  camera-side profiles drift apart; this action removes the camera from the app, not from the Nikon
  body.

## Live Monitor Chrome

The live monitor should reserve the center for the live feed and keep controls on predictable edges:

- Top status bar: standby/record state, timecode, record indicator, resolution/framerate, codec,
  media capacity, and measured live-view fps.
- Left rail: camera-side status such as link/battery percentage and another compact state meter.
- Right rail: physical-control equivalents, including utility buttons, record, and `DISP`.
- Bottom assist toolbar: peaking, false color, zebra, waveform, parade, histogram, guides, grid,
  crosshair, level, and desqueeze. Items may overflow into `More`.
- Bottom camera-value strip: ISO, shutter, iris, white balance, and focus mode. Tapping a settable
  value opens its picker.

The existing Flutter overlay is functional prototype evidence. The production native shells should
move toward this monitor-style layout: the camera panel becomes an always-readable bottom strip in
Live Monitor, while deeper editing uses transient picker panels.

## Command View

Command mode is the dense control surface for operators who want all relevant state visible without
opening individual pickers. It groups controls as cards:

- Status: standby/record state and timecode.
- Health: temperature, storage remaining, camera body, lens, and live-view fps.
- Exposure: mode, ISO, shutter, iris, white balance, resolution/framerate, codec, IBIS/e-shutter.
- Focus: AF mode, AF area, subject detection.
- Image: tone/gamma and picture profile.
- Audio: sensitivity, 32-bit float state, input, and wind filter.

Cards that are settable should open the same picker/editing model used by Live Monitor. Cards that
are read-only should display a neutral unavailable state when the camera does not expose a value.

## Picker Panels

The wireframe uses large transient panels over the live monitor for setting changes. These should be
modal enough to focus the operator, but should not leave the live context.

| Picker | Contents | Notes |
| --- | --- | --- |
| ISO | Current ISO list plus Low Base and High Base ranges. | ISO choices follow active base ISO and camera-supported enum values when available. |
| Shutter | Angle values and an Angle/Speed segment. | Preserve angle and speed as two modes backed by the camera's supported values. |
| White Balance | Kelvin list plus Kelvin/Preset segment. | Kelvin and preset modes are related but separate camera properties. |
| Focus | AF mode, area, and subject segments. | Implementation waits for protocol verification; UI shape is established. |
| Resolution/Framerate | Combined resolution and frame-rate choices. | This is one packed camera value, not independent fields. |
| Codec | Recording codec choices such as R3D NE, N-RAW, and ProRes RAW HQ. | Show only camera-supported values when `DevicePropDesc` is available. |

Rejected writes should lock or annotate the row until a refresh proves it is available again.

## View Assists

Assist tools are first-class monitor features:

- Guides: film/social tabs, preset aspect ratios, optional mask, and custom ratio entry.
- Grid: thirds, phi grid, and diagonal overlays.
- Horizon/Level: enable toggle plus horizon/gauge style.
- Desqueeze: enable toggle, standard squeeze factors (`1x`, `1.33x`, `1.5x`, `1.65x`, `1.8x`,
  `2x`), horizontal/vertical orientation, and custom ratio.
- Exposure scopes and assists: peaking, false color, zebra, waveform, parade, and histogram.

Assist state is app-side state layered over the live image. It should not block streaming and should
persist between sessions unless the user resets display settings.

## Settings

Settings use an `Operator Setup` shell with tabs:

| Tab | Purpose | Wireframe fields |
| --- | --- | --- |
| Link | Connection state and stream behavior. | Connected body, link health score, current transport, stream preset, quality bias. |
| View Assist | Behavior for live-view tools. | Toolbar order, false-color scale/units, skin reference, zebra units, highlight and midtone display colors. |
| Controls | Touch behavior and safety. | Record hold, haptics, `DISP` button order. |
| Display | Visibility of live-view chrome. | Status readouts and exposure-tool visibility toggles. |
| System | App-level behavior. | Theme, protocol implementation, app version. |

Settings should be usable while connected and should not disrupt live view unless a setting directly
changes the stream preset or quality bias.

## Data And State

The app needs three state layers:

- Camera state: values read from PTP/MTP, including exposure, recording, storage, lens, focus,
  image, audio, and camera health. Unknown or unsupported properties are hidden or shown as
  unavailable.
- Session state: active `DISP` mode, transient picker/sheet, live-view stream preset, and connection
  health.
- Operator preferences: assist-tool configuration, toolbar order, display visibility, haptics,
  record-hold safety, theme, and `DISP` order.

Camera I/O remains serialized through the live-view safe point in the shared Swift core or the
platform adapter that owns the command socket. App-side preferences must never enqueue camera
transactions unless they actually change a camera-backed setting.

## Protocol Notes

- Media capacity should start from standard PTP storage operations where possible, then compute
  approximate remaining minutes from the selected record format when bitrate data is known.
- Nikon-specific health, audio, focus, IBIS/e-shutter, tone, and profile properties remain
  verify-on-hardware until confirmed against local Nikon references or a camera.
- Bonjour `_ptp._tcp` discovery remains the preferred discovery path before manual IP or subnet
  fallback.
- A visible local `Remove` recovery action remains required when app state and the camera profile
  drift apart. Re-adding a removed camera should first try restoring the existing Nikon profile before
  prompting for a new pairing code.

## Responsive Layout

The wireframe boards are landscape monitor-shaped references, not fixed runtime canvases. Native
implementation should follow the responsive layout rules in
`docs/design/specs/2026-06-20-responsive-native-layout-system-design.md`: safe-area-aware
containers, adaptive columns, priority-based overflow, and no horizontal clipping on supported
devices.

## Out Of Scope For This Spec

- Replacing the live-view transport architecture already covered by the faster live-view spec.
- Implementing Nikon-specific writes before property descriptions or hardware validation confirm
  they are settable.
- Full desktop-class and Android tablet parity before the iOS responsive foundation is stable.
